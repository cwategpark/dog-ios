(() => {
  // @pure:start — pure helpers (no DOM/network); extracted by tests/pure-logic.test.js
  const EMAIL_MAX_LENGTH = 254;
  const FULL_NAME_MAX_LENGTH = 120;
  const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
  const SESSION_EXPIRED_DETAILS = new Set(['session_expired_or_invalid', 'questionnaire_session_required', 'session_invalid', 'session_expired']);
  const CHALLENGE_ID_FIELDS = ['challenge_id', 'claim_id', 'challengeId'];
  const OTP_INVALID_DETAILS = new Set(['invalid_otp', 'invalid_otp_format', 'invalid_code', 'code_invalid', 'invalid_otp_code']);
  const OTP_EXPIRED_DETAILS = new Set(['challenge_expired', 'challenge_already_consumed', 'challenge_not_found', 'claim_not_found']);
  const normalizeEmail = (value) => {
    if (typeof value !== 'string') return { ok: false, email: '', reason: 'required' };
    const email = value.trim().toLowerCase();
    if (!email) return { ok: false, email: '', reason: 'required' };
    if (email.length > EMAIL_MAX_LENGTH) return { ok: false, email, reason: 'too_long' };
    if (!EMAIL_PATTERN.test(email)) return { ok: false, email, reason: 'format' };
    return { ok: true, email, reason: '' };
  };
  const normalizeFullName = (value) => {
    if (typeof value !== 'string') return '';
    const name = value.replace(/\s+/g, ' ').trim();
    return name.length > FULL_NAME_MAX_LENGTH ? name.slice(0, FULL_NAME_MAX_LENGTH).trim() : name;
  };
  const isOtpCode = (value) => typeof value === 'string' && /^[0-9]{6}$/.test(value.trim());
  const isSessionExpiredDetail = (detail) => typeof detail === 'string' && SESSION_EXPIRED_DETAILS.has(detail);
  // 后端 POST /v1/claims 以 challenge_id 返回；兼容旧响应/别名的 claim_id、challengeId。
  const normalizeChallengeId = (response) => {
    if (!response || typeof response !== 'object') return '';
    for (const field of CHALLENGE_ID_FIELDS) {
      const value = response[field];
      if (typeof value === 'string' && value.trim()) return value.trim();
      if (typeof value === 'number' && Number.isFinite(value)) return String(value);
    }
    return '';
  };
  const claimErrorKey = (context, status, detail) => {
    if (context !== 'start' && context !== 'verify' && context !== 'link') return 'error';
    const code = typeof detail === 'string' ? detail : '';
    if (code === 'claim_link_disabled') return 'claim_link_disabled';
    if (code === 'email_delivery_unavailable') return 'claim_unavailable';
    if (context === 'verify') {
      if (OTP_INVALID_DETAILS.has(code)) return 'claim_invalid_code';
      if (code === 'challenge_attempts_exceeded') return 'claim_attempts_exceeded';
      if (OTP_EXPIRED_DETAILS.has(code)) return 'claim_expired';
    }
    if (status === 401) return 'session';
    if (status === 403) return 'error';
    if (status === 410) return 'claim_expired';
    if (status === 429) return context === 'verify' ? 'claim_attempts_exceeded' : 'claim_rate_limited';
    if (status === 503) return 'claim_unavailable';
    if (status === 404) return context === 'verify' ? 'claim_expired' : 'claim_unavailable';
    if (status === 405) return 'claim_unavailable';
    if (status === 422) return context === 'verify' ? 'claim_invalid_code' : 'claim_email_invalid';
    return 'error';
  };
  // @pure:end
  const init = (scope = document) => scope.querySelectorAll('[data-pet-tools]').forEach((root) => {
    if (root.dataset.bound) return;
    root.dataset.bound = 'true';
    const base = root.dataset.proxy.replace(/\/$/, '');
    if (!base.startsWith('/') || base.startsWith('//')) return;
    const copy = JSON.parse(root.querySelector('[data-pet-copy]').textContent);
    const key = 'wagelpaw:guest:' + location.host;
    const profileForm = root.querySelector('[data-pet-profile]');
    const generationForm = root.querySelector('[data-pet-generation]');
    const panel = root.querySelector('[data-generation-panel]');
    const status = root.querySelector('[data-pet-status]');
    const results = root.querySelector('[data-pet-results]');
    const claimBlock = root.querySelector('[data-pet-claim]');
    const claimSend = root.querySelector('[data-claim-send]');
    const claimCodeForm = root.querySelector('[data-claim-verify]');
    const claimCodeInput = claimCodeForm && claimCodeForm.elements.code;
    // 旧版 section 缓存可能仍带 magic-link 节点；新 UI 不再展示/复制任何链接，仅做防御性清理。
    const legacyLinkButton = root.querySelector('[data-claim-link]');
    const legacyCopyButton = root.querySelector('[data-claim-copy]');
    const legacyUrlInput = root.querySelector('[data-claim-url]');
    const claimEmailNote = root.querySelector('[data-claim-email]');
    const claimStatus = root.querySelector('[data-claim-status]');
    const objectUrls = new Set();
    let session;
    let busy = false;
    let operation = 0;
    try { session = JSON.parse(sessionStorage.getItem(key)); } catch {}
    const setStatus = (value) => { status.textContent = value; };
    const remember = () => { try { if (session) sessionStorage.setItem(key, JSON.stringify(session)); else sessionStorage.removeItem(key); } catch {} };
    const expiresAt = (value) => typeof value === 'number' ? value * 1000 : Date.parse(value);
    const claim = { busy: false, id: '' };
    const claimCopy = (key) => copy[key] || copy.error;
    const setClaimStatus = (value) => { if (claimStatus) claimStatus.textContent = value; };
    const setClaimEmail = (value) => { if (claimEmailNote) claimEmailNote.textContent = typeof value === 'string' && value ? value : ''; };
    const resetClaim = () => {
      claim.busy = false; claim.id = '';
      if (claimCodeForm) { claimCodeForm.reset(); claimCodeForm.hidden = true; }
      if (claimSend) claimSend.hidden = false;
      if (legacyLinkButton) legacyLinkButton.hidden = true;
      if (legacyCopyButton) legacyCopyButton.hidden = true;
      if (legacyUrlInput) { legacyUrlInput.value = ''; legacyUrlInput.hidden = true; }
      if (claimBlock) claimBlock.removeAttribute('aria-busy');
      setClaimStatus('');
    };
    if (session && (!session.session_token || !Number.isFinite(expiresAt(session.expires_at)) || expiresAt(session.expires_at) <= Date.now())) session = undefined;
    const showProfileState = () => {
      profileForm.hidden = !!session;
      panel.hidden = !session;
      if (claimBlock) {
        claimBlock.hidden = !session;
        setClaimEmail(session && session.email);
        if (claimSend) claimSend.hidden = !!(session && session.claimed);
        if (session) setClaimStatus(session.claimed ? copy.claim_verified : (session.email ? copy.claim_unverified : copy.claim_missing_email));
        else setClaimStatus('');
      }
    };
    showProfileState();
    const revoke = () => { objectUrls.forEach((url) => URL.revokeObjectURL(url)); objectUrls.clear(); };
    const clearResults = () => { results.querySelectorAll('[src^="blob:"], [href^="blob:"]').forEach((element) => { const url = element.src || element.href; URL.revokeObjectURL(url); objectUrls.delete(url); }); results.replaceChildren(); };
    const privateUrl = (path) => {
      if (typeof path !== 'string' || !path.startsWith('/v1/uploads/')) throw new Error('asset_path');
      return base + path;
    };
    const request = async (path, options = {}, unauthenticated = false) => {
      const headers = new Headers(options.headers);
      if (!unauthenticated) {
        if (!session) throw new Error('session');
        headers.set('X-Wagelpaw-Session', session.session_token);
      }
      const response = await fetch(base + path, { ...options, headers, credentials: 'same-origin' });
      if (!response.ok) {
        let detail = '';
        try { const body = await response.json(); if (body && typeof body.detail === 'string') detail = body.detail; } catch {}
        // 只有明确的「会话失效」detail 才清 guest 会话；invalid_otp 等认领错误必须保留会话。
        // 空 detail 视为旧后端 401，沿用基线的清会话行为。
        if (response.status === 401 && !unauthenticated && (!detail || isSessionExpiredDetail(detail))) {
          session = undefined; remember(); showProfileState(); setStatus(copy.expired); throw new Error('session');
        }
        const error = new Error('request_' + response.status); error.status = response.status; error.detail = detail; throw error;
      }
      return response.json();
    };
    const jsonRequest = (path, body, headers = {}, unauthenticated = false) => request(path, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) }, unauthenticated);
    const setBusy = (value) => {
      busy = value;
      root.setAttribute('aria-busy', String(value));
      root.querySelectorAll('button[type="submit"], [data-recommend]').forEach((button) => { button.disabled = value; });
    };
    const updatePet = () => { const dog = profileForm.elements.type.value === 'dog'; root.querySelector('[data-dog-size]').hidden = !dog; profileForm.elements.dog_size.disabled = !dog; };
    profileForm.addEventListener('change', updatePet);
    updatePet();
    if (profileForm.elements.email) profileForm.elements.email.required = true;
    profileForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      if (busy || !profileForm.reportValidity()) return;
      setBusy(true); setStatus('');
      try {
        const data = new FormData(profileForm);
        const profile = { type: data.get('type'), age_months: Number(data.get('age_months')) };
        if (profile.type === 'dog') profile.dog_size = data.get('dog_size');
        const emailField = profileForm.elements.email;
        const nameField = profileForm.elements.full_name;
        let email = '';
        if (emailField) {
          const normalized = normalizeEmail(emailField.value);
          if (!normalized.ok) {
            emailField.setCustomValidity(copy.claim_email_invalid);
            emailField.reportValidity();
            emailField.addEventListener('change', () => emailField.setCustomValidity(''), { once: true });
            return;
          }
          emailField.setCustomValidity('');
          email = normalized.email;
        }
        const body = { profile, consent: true };
        const fullName = nameField ? normalizeFullName(nameField.value) : '';
        if (email) body.email = email;
        if (fullName) body.full_name = fullName;
        try {
          session = await jsonRequest('/v1/sessions', body, {}, true);
        } catch (error) {
          // 兼容尚未升级的旧后端：它用 extra="forbid" 拒绝新字段（422 + 校验数组），此时退回旧请求体。
          if (!email || error.status !== 422 || error.detail) throw error;
          delete body.email; delete body.full_name;
          session = await jsonRequest('/v1/sessions', body, {}, true);
        }
        if (session) session.email = email;
        remember(); showProfileState();
      } catch { setStatus(copy.error); } finally { setBusy(false); }
    });
    root.querySelector('[data-profile-reset]').addEventListener('click', () => {
      operation += 1; session = undefined; remember(); revoke(); clearResults(); setStatus(''); resetClaim(); showProfileState(); generationForm.reset(); root.querySelector('[data-photo-preview]').hidden = true; setBusy(false);
    });
    if (claimBlock && claimSend && claimCodeForm && claimCodeInput) {
      const claimEmailValue = () => {
        if (session && typeof session.email === 'string' && session.email) return normalizeEmail(session.email);
        const field = profileForm.elements.email;
        return field ? normalizeEmail(field.value) : { ok: false, email: '', reason: 'required' };
      };
      const claimTime = (value) => {
        const timestamp = expiresAt(value);
        if (!Number.isFinite(timestamp)) return '';
        try { return new Date(timestamp).toLocaleTimeString(document.documentElement.lang || undefined, { hour: '2-digit', minute: '2-digit' }); }
        catch { return new Date(timestamp).toISOString().slice(11, 16); }
      };
      const setClaimBusy = (value) => {
        claim.busy = value;
        if (claimBlock) claimBlock.setAttribute('aria-busy', String(value));
        claimSend.disabled = value;
        claimCodeForm.querySelector('button[type="submit"]').disabled = value;
        if (legacyLinkButton) legacyLinkButton.disabled = value;
        if (legacyCopyButton) legacyCopyButton.disabled = value;
      };
      const handleClaimError = (context, error) => {
        if (!error || error.message === 'session') return;
        const key = claimErrorKey(context, error.status, error.detail);
        if (key !== 'session') setClaimStatus(claimCopy(key));
      };
      const sendClaimCode = async () => {
        if (claim.busy) return;
        const normalized = claimEmailValue();
        if (!normalized.ok) { setClaimStatus(copy.claim_missing_email); return; }
        claimCodeInput.value = '';
        setClaimBusy(true); setClaimStatus(copy.working);
        try {
          const response = await jsonRequest('/v1/claims', { email: normalized.email });
          claim.id = normalizeChallengeId(response);
          if (!claim.id) { setClaimStatus(copy.claim_response_invalid); return; }
          claimCodeForm.reset();
          claimCodeForm.hidden = response.delivery === 'unavailable';
          if (response.delivery === 'unavailable') {
            setClaimStatus(copy.claim_unavailable);
          } else {
            const expiry = claimTime(response.expires_at);
            setClaimStatus([response.email_masked || normalized.email, copy.claim_sent, expiry ? copy.claim_expires + ' ' + expiry : ''].filter(Boolean).join(' · '));
            claimCodeInput.focus();
          }
        } catch (error) { handleClaimError('start', error); }
        finally { setClaimBusy(false); }
      };
      claimSend.addEventListener('click', sendClaimCode);
      claimCodeForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        if (claim.busy) return;
        if (!isOtpCode(claimCodeInput.value)) {
          claimCodeInput.setCustomValidity(copy.claim_invalid_code);
          claimCodeInput.reportValidity();
          claimCodeInput.addEventListener('input', () => claimCodeInput.setCustomValidity(''), { once: true });
          return;
        }
        claimCodeInput.setCustomValidity('');
        if (!claim.id) { setClaimStatus(copy.claim_expired); return; }
        setClaimBusy(true); setClaimStatus(copy.working);
        try {
          const response = await jsonRequest('/v1/claims/' + encodeURIComponent(claim.id) + '/verify', { code: claimCodeInput.value.trim() });
          if (!response || response.claimed !== true) throw new Error('claim_verify');
          claimCodeForm.reset(); claimCodeForm.hidden = true;
          if (session) { session.claimed = true; remember(); }
          setClaimStatus(copy.claim_verified);
          claimSend.hidden = true;
          if (legacyLinkButton) legacyLinkButton.hidden = true;
          if (legacyCopyButton) legacyCopyButton.hidden = true;
          if (legacyUrlInput) { legacyUrlInput.hidden = true; legacyUrlInput.value = ''; }
        } catch (error) { handleClaimError('verify', error); }
        finally { setClaimBusy(false); }
      });
      // 旧版 section 缓存残留下来的 magic-link 按钮：后端已默认关闭（503 claim_link_disabled），
      // 新 UI 不展示链接能力；若误触旧按钮，绝不读取响应中的 url/token，也不写 DOM/剪贴板，只提示改用验证码。
      if (legacyLinkButton) legacyLinkButton.addEventListener('click', async () => {
        if (claim.busy || !claim.id) return;
        setClaimBusy(true); setClaimStatus(copy.working);
        try {
          await jsonRequest('/v1/claims/' + encodeURIComponent(claim.id) + '/link', {});
          setClaimStatus(copy.claim_link_disabled);
        } catch (error) { handleClaimError('link', error); }
        finally {
          if (legacyUrlInput) { legacyUrlInput.value = ''; legacyUrlInput.hidden = true; }
          if (legacyCopyButton) legacyCopyButton.hidden = true;
          setClaimBusy(false);
        }
      });
      if (legacyCopyButton) legacyCopyButton.addEventListener('click', () => {
        if (legacyUrlInput) { legacyUrlInput.value = ''; legacyUrlInput.hidden = true; }
        setClaimStatus(copy.claim_link_disabled);
      });
    }
    generationForm.elements.kind.addEventListener('change', () => { generationForm.elements.file.required = generationForm.elements.kind.value !== 'cat-fitting'; });
    generationForm.elements.file.addEventListener('change', () => {
      const file = generationForm.elements.file.files[0];
      const preview = root.querySelector('[data-photo-preview]');
      if (!file) { preview.hidden = true; return; }
      const url = URL.createObjectURL(file); objectUrls.add(url); preview.src = url; preview.hidden = false;
    });
    const pollJob = async (job, currentOperation) => {
      for (let attempt = 0; attempt < 180; attempt += 1) {
        if (currentOperation !== operation) throw new Error('cancelled');
        if (job.status === 'succeeded') return job;
        if (job.status === 'failed' || job.status === 'cancelled') throw new Error(job.error_code || 'failed');
        await new Promise((resolve) => setTimeout(resolve, Math.min(2000 + attempt * 300, 5000)));
        job = await request('/v1/jobs/' + encodeURIComponent(job.id));
      }
      throw new Error('timeout');
    };
    const createJob = async (kind, input, currentOperation) => pollJob(await jsonRequest('/v1/jobs', { kind, input }, { 'Idempotency-Key': crypto.randomUUID() }), currentOperation);
    const showResult = async (job) => {
      clearResults();
      if (job.result?.manifest) {
        const host = document.createElement('div'); host.className = 'pet-fitting-host'; results.append(host);
        await import(root.dataset.fittingModule);
        root.dispatchEvent(new CustomEvent('wagelpaw:fitting-ready', { bubbles: true, detail: { manifest: job.result.manifest, host, container: host } }));
      }
      for (const asset of job.result?.assets || []) {
        const response = await fetch(privateUrl(asset.url || '/v1/uploads/' + encodeURIComponent(asset.id)), { headers: { 'X-Wagelpaw-Session': session.session_token }, credentials: 'same-origin' });
        if (!response.ok) throw new Error('asset');
        const blob = await response.blob();
        const url = URL.createObjectURL(blob); objectUrls.add(url);
        const figure = document.createElement('figure');
        if (blob.type.startsWith('image/')) { const image = document.createElement('img'); image.src = url; image.alt = copy.photos; image.loading = 'lazy'; figure.append(image); }
        const link = document.createElement('a'); link.href = url; link.download = asset.filename || (asset.role === 'model' ? 'pet-model.glb' : 'pet-preview.png'); link.textContent = copy.download; figure.append(link); results.append(figure);
      }
      setStatus(copy.ready);
    };
    generationForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      if (busy || !generationForm.reportValidity()) return;
      const currentOperation = ++operation;
      setBusy(true); clearResults(); setStatus(copy.working);
      try {
        const kind = generationForm.elements.kind.value;
        const productId = 'gid://shopify/Product/' + root.dataset.productId;
        let job;
        if (kind === 'cat-fitting') job = await createJob(kind, { product_id: productId, consent: true }, currentOperation);
        else {
          const uploadForm = new FormData(); uploadForm.append('file', generationForm.elements.file.files[0]);
          const upload = await request('/v1/uploads', { method: 'POST', body: uploadForm });
          const variantId = root.dataset.variantId;
          const input = { pet_upload_id: upload.id, product_id: productId, consent: true };
          if (variantId) input.variant_id = 'gid://shopify/ProductVariant/' + variantId;
          job = await createJob('tryon', input, currentOperation);
          if (kind === 'avatar') job = await createJob('avatar', { source_job_id: job.id, consent: true }, currentOperation);
        }
        if (currentOperation === operation) await showResult(job);
      } catch (error) { if (currentOperation === operation && error.message !== 'session') setStatus(copy.error); }
      finally { if (currentOperation === operation) setBusy(false); }
    });
    root.querySelector('[data-recommend]').addEventListener('click', async () => {
      if (busy) return;
      setBusy(true); clearResults(); setStatus('');
      try {
        const recommendation = await jsonRequest('/v1/recommendations', {});
        const products = recommendation.products || [];
        if (!products.length) { setStatus(copy.no_recommendations); return; }
        const form = document.createElement('form'); form.className = 'pet-recommendations';
        const note = document.createElement('p'); note.textContent = copy.result_note; form.append(note);
        products.slice(0, 3).forEach((product) => {
          const row = document.createElement('div'); row.className = 'pet-recommendation';
          const chosen = document.createElement('input'); chosen.type = 'checkbox'; chosen.name = 'chosen'; chosen.value = product.id; chosen.checked = true; chosen.setAttribute('aria-label', product.title); row.append(chosen);
          const body = document.createElement('div'); const title = document.createElement('h4'); title.textContent = product.title; body.append(title);
          const variants = document.createElement('select'); variants.name = 'variant'; variants.setAttribute('aria-label', product.title);
          (product.variants || []).filter((variant) => variant.available).forEach((variant) => { const option = document.createElement('option'); option.value = variant.id.split('/').pop(); let price = variant.price; try { price = new Intl.NumberFormat(document.documentElement.lang, { style: 'currency', currency: product.currency }).format(Number(variant.price)); } catch {} option.textContent = variant.title + ' — ' + price; variants.append(option); });
          if (!variants.options.length) { chosen.checked = false; chosen.disabled = true; }
          body.append(variants);
          const item = (recommendation.items || []).find((entry) => entry.product_id === product.id);
          if (product.needs_fit_check || item?.fit_confirmation_required) { const fit = document.createElement('label'); fit.className = 'pet-recommendation__fit'; const check = document.createElement('input'); check.type = 'checkbox'; check.name = 'fit_confirmed'; fit.append(check, document.createTextNode(copy.fit_confirm)); body.append(fit); }
          row.append(body); form.append(row);
        });
        const submit = document.createElement('button'); submit.type = 'submit'; submit.className = 'button'; submit.textContent = copy.select; form.append(submit);
        form.addEventListener('submit', async (event) => {
          event.preventDefault();
          const rows = [...form.querySelectorAll('.pet-recommendation')].filter((row) => row.querySelector('[name=chosen]').checked);
          if (!rows.length || rows.length > 3) { setStatus(copy.max_three); return; }
          const unconfirmed = rows.find((row) => row.querySelector('[name=fit_confirmed]') && !row.querySelector('[name=fit_confirmed]').checked);
          if (unconfirmed) { const check = unconfirmed.querySelector('[name=fit_confirmed]'); check.setCustomValidity(copy.fit_confirm); check.reportValidity(); check.addEventListener('change', () => check.setCustomValidity(''), { once: true }); return; }
          submit.disabled = true;
          try {
            const items = rows.map((row) => ({ id: row.querySelector('[name=variant]').value, quantity: 1 }));
            const response = await fetch(root.dataset.rootUrl + 'cart/add.js', { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, credentials: 'same-origin', body: JSON.stringify({ items }) });
            if (!response.ok) throw new Error('cart');
            location.assign(root.dataset.cartUrl);
          } catch { setStatus(copy.error); submit.disabled = false; }
        });
        results.append(form);
      } catch (error) { if (error.message !== 'session') setStatus(copy.error); }
      finally { setBusy(false); }
    });
    document.addEventListener('wagelpaw:variant-change', (event) => { root.dataset.variantId = event.detail.id; });
    window.addEventListener('pagehide', revoke, { once: true });
  });
  document.addEventListener('shopify:section:load', (event) => init(event.target));
  init();
})();