#!/usr/bin/env node
'use strict';

// 真实 HTTP + 受控 DOM 交互测试（无 npm 依赖、无浏览器）：
//  - 自实现 pet-tools.js 用到的最小 DOM/事件/sessionStorage/clipboard shim；
//  - 用 node:http 起本地替身后端（真实字段形状、真实状态码）；
//  - 用 vm 在受控上下文里加载真实的 web-integration/pet-tools.js，驱动 claim UI。
// 用法：node web-integration/tests/claim-interaction.test.js
// 输出：每个场景的 PASS/FAIL、断言计数、SUMMARY；退出码 0=全过，1=有失败。
// 覆盖：
//  a) 发送 → challenge_id 正确渲染 OTP 表单（回归阻塞 K1）
//  b) 错误 OTP（401 invalid_otp）→ 显示错误、guest session 仍在、OTP 表单仍可重输
//  c) 正确 OTP → verify 成功、显示已认领状态
//  d) magic-link 关闭（503 claim_link_disabled）→ 不产生/不复制任何 token，只提示用验证码
//  e) 旧响应无 challenge_id → 明确错误、不崩溃、无重试死循环
//  f) 旧响应带 claim_id 别名 → 仍可继续验证（向后兼容）
//  g) 401 session_expired_or_invalid → 仍按基线清 guest 会话
//  h) 429 challenge_attempts_exceeded → 保留会话、明确提示、可重发

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const vm = require('node:vm');

const petToolsSource = fs.readFileSync(path.join(__dirname, '..', 'pet-tools.js'), 'utf8');

// ---------------------------------------------------------------------------
// 最小 DOM shim
// ---------------------------------------------------------------------------

const CAMEL = (name) => name.slice(5).replace(/-([a-z])/g, (_, char) => char.toUpperCase());

const matchesSimple = (element, simple) => {
  let rest = simple;
  const tag = /^[a-zA-Z][\w-]*/.exec(rest);
  if (tag) {
    if (element.tagName !== tag[0].toUpperCase()) return false;
    rest = rest.slice(tag[0].length);
  }
  const classRe = /\.([\w-]+)/g;
  let classMatch;
  while ((classMatch = classRe.exec(rest))) {
    const classes = String(element.className || '').split(/\s+/);
    if (!classes.includes(classMatch[1])) return false;
  }
  const attrRe = /\[([^\]]+)\]/g;
  let attrMatch;
  while ((attrMatch = attrRe.exec(rest))) {
    const expression = attrMatch[1].trim();
    const operation = expression.match(/^([\w:-]+)\s*(\^=|=)\s*"?([^"\]]*)"?$/);
    if (operation) {
      const [, name, operator, value] = operation;
      const actual = element.getAttribute(name);
      if (actual === null) return false;
      if (operator === '=' && actual !== value) return false;
      if (operator === '^=' && !actual.startsWith(value)) return false;
    } else if (!element.hasAttribute(expression)) {
      return false;
    }
  }
  return true;
};

const matchesSelector = (element, selector) => selector.split(',').some((part) => {
  const simple = part.trim();
  return !!simple && matchesSimple(element, simple);
});

class ShimElement {
  constructor(tagName, attributes = {}) {
    this.nodeType = 1;
    this.tagName = String(tagName).toUpperCase();
    this.nodeName = this.tagName;
    this.attributes = new Map();
    this.children = [];
    this.parentNode = null;
    this.listeners = new Map();
    this.dataset = {};
    this.elements = {};
    this.hidden = false;
    this.disabled = false;
    this.required = false;
    this.checked = false;
    this.value = '';
    this.type = '';
    this.className = '';
    this.customValidity = '';
    this.files = [];
    this.focused = false;
    this.selected = false;
    this._text = '';
    for (const [name, value] of Object.entries(attributes)) this.setAttribute(name, value);
  }

  setAttribute(name, value) {
    const key = String(name);
    const text = String(value);
    this.attributes.set(key, text);
    if (key.startsWith('data-')) this.dataset[CAMEL(key)] = text;
    if (key === 'value') this.value = text;
    if (key === 'type') this.type = text;
    if (key === 'class') this.className = text;
    if (key === 'checked') this.checked = text !== 'false';
    if (key === 'disabled') this.disabled = true;
    if (key === 'required') this.required = true;
  }

  getAttribute(name) {
    const value = this.attributes.get(String(name));
    return value === undefined ? null : value;
  }

  hasAttribute(name) { return this.attributes.has(String(name)); }

  removeAttribute(name) { this.attributes.delete(String(name)); }

  append(...nodes) {
    for (const node of nodes) {
      if (!node) continue;
      if (node.nodeType === 3) {
        this._text += node.data;
        continue;
      }
      node.parentNode = this;
      this.children.push(node);
    }
  }

  appendChild(node) { this.append(node); return node; }

  replaceChildren(...nodes) { this.children = []; this._text = ''; this.append(...nodes); }

  get textContent() { return this._text; }

  set textContent(value) { this._text = String(value); this.children = []; }

  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(listener);
  }

  removeEventListener(type, listener) { const set = this.listeners.get(type); if (set) set.delete(listener); }

  dispatchEvent(event) {
    if (!event.target) event.target = this;
    const set = this.listeners.get(event.type);
    if (set) for (const listener of [...set]) listener.call(this, event);
    return !event.defaultPrevented;
  }

  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }

  querySelectorAll(selector) {
    const matches = [];
    const visit = (node) => {
      for (const child of node.children) {
        if (matchesSelector(child, selector)) matches.push(child);
        visit(child);
      }
    };
    visit(this);
    return matches;
  }

  focus() { this.focused = true; }

  select() { this.selected = true; }

  setCustomValidity(value) { this.customValidity = String(value == null ? '' : value); }

  reportValidity() { return !this.customValidity; }

  reset() {
    for (const control of this.querySelectorAll('input, select, textarea')) {
      control.value = '';
      control.checked = false;
      control.customValidity = '';
    }
  }
}

class ShimDocument {
  constructor() {
    this.nodeType = 9;
    this.listeners = new Map();
    this.documentElement = new ShimElement('html');
    this.documentElement.lang = 'en';
    this.body = new ShimElement('body');
    this.documentElement.append(this.body);
  }

  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(listener);
  }

  removeEventListener(type, listener) { const set = this.listeners.get(type); if (set) set.delete(listener); }

  dispatchEvent(event) {
    const set = this.listeners.get(event.type);
    if (set) for (const listener of [...set]) listener.call(this, event);
    return !event.defaultPrevented;
  }

  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }

  querySelectorAll(selector) {
    const matches = [];
    const visit = (node) => {
      if (matchesSelector(node, selector)) matches.push(node);
      for (const child of node.children) visit(child);
    };
    visit(this.documentElement);
    return matches;
  }

  createElement(tagName) { return new ShimElement(tagName); }

  createTextNode(data) { return { nodeType: 3, data: String(data), textContent: String(data) }; }
}

const element = (tagName, attributes = {}, props = {}) => {
  const node = new ShimElement(tagName, attributes);
  return Object.assign(node, props);
};

const createStorage = () => {
  const store = new Map();
  return {
    store,
    getItem(key) { return store.has(String(key)) ? store.get(String(key)) : null; },
    setItem(key, value) { store.set(String(key), String(value)); },
    removeItem(key) { store.delete(String(key)); },
    clear() { store.clear(); },
  };
};

const registerFormControls = (form) => {
  for (const control of form.querySelectorAll('input, select, textarea')) {
    const name = control.getAttribute('name');
    if (name && !form.elements[name]) form.elements[name] = control;
  }
  return form;
};

const BASE_COPY = {
  working: 'Working…', error: 'Something went wrong.', ready: 'Ready.', expired: 'Session expired.',
  download: 'Download', select: 'Add to cart', no_recommendations: 'No matches.', result_note: 'Suggested for you.',
  max_three: 'Pick up to three.', fit_confirm: 'I checked the fit.', missing_fitting: 'Fitting unavailable.',
  photos: 'Preview',
  claim_title: 'Save to the app',
  claim_explain: 'Verify your email to keep this pet profile and its results in the app.',
  claim_email: 'Email', claim_name: 'Name (optional)', claim_send: 'Save to app', claim_code: '6-digit code',
  claim_verify: 'Verify', claim_unverified: 'Email not verified yet.', claim_sent: 'Verification code sent',
  claim_verified: 'Saved. Your email is verified and this device is linked to it.',
  claim_expired: 'The code expired or is no longer valid. Please send a new one.',
  claim_rate_limited: 'Too many attempts. Please wait a minute and try again.',
  claim_invalid_code: 'That code is incorrect. Check the email and try again.',
  claim_email_invalid: 'Enter a valid email address (up to 254 characters).',
  claim_missing_email: 'Add an email address before saving to the app.',
  claim_unavailable: 'Saving to the app is not available right now. Please try again later.',
  claim_expires: 'expires',
  claim_attempts_exceeded: 'Too many incorrect codes. Send a new code to continue.',
  claim_link_disabled: 'Claim links are unavailable right now. Please use the verification code.',
  claim_response_invalid: 'Could not start email verification. Please refresh and try again.',
};

const createFixture = ({ legacyLink = false, session = true } = {}) => {
  const document = new ShimDocument();
  const location = { host: 'test.example', assign() {} };
  const clipboard = {
    calls: [],
    writeText: async (value) => { clipboard.calls.push(String(value)); },
  };
  const navigator = { clipboard };
  const window = {
    listeners: new Map(),
    addEventListener(type, listener) {
      if (!window.listeners.has(type)) window.listeners.set(type, new Set());
      window.listeners.get(type).add(listener);
    },
    removeEventListener(type, listener) { const set = window.listeners.get(type); if (set) set.delete(listener); },
  };
  const sessionStorage = createStorage();
  const sessionKey = 'wagelpaw:guest:' + location.host;
  if (session) {
    sessionStorage.setItem(sessionKey, JSON.stringify({
      session_token: 'guest-token-123',
      expires_at: Math.floor(Date.now() / 1000) + 3600,
      email: 'visitor@example.com',
    }));
  }

  const root = element('section', {
    'data-pet-tools': '', 'data-fitting-module': '/cat-fitting.js', 'data-root-url': '/',
    'data-cart-url': '/cart', 'data-proxy': '/apps/wagelpaw', 'data-product-id': '111',
    'data-variant-id': '222', 'data-product-image': '',
  });
  const copyScript = element('script', { 'data-pet-copy': '' });
  copyScript.textContent = JSON.stringify(BASE_COPY);
  root.append(copyScript);

  const profileForm = element('form', { 'data-pet-profile': '' });
  const dogSize = element('label', { 'data-dog-size': '' });
  const dogSizeSelect = element('select', { name: 'dog_size' });
  dogSizeSelect.value = 'small';
  dogSize.append(dogSizeSelect);
  profileForm.append(
    element('input', { type: 'radio', name: 'type', value: 'dog', checked: '' }),
    element('input', { type: 'radio', name: 'type', value: 'cat' }),
    element('input', { type: 'number', name: 'age_months', value: '24' }),
    dogSize,
    element('input', { type: 'email', name: 'email', value: '' }),
    element('input', { type: 'text', name: 'full_name', value: '' }),
    element('input', { type: 'checkbox', name: 'consent', checked: '' }),
    element('button', { type: 'submit' }),
  );
  registerFormControls(profileForm);

  const panel = element('div', { 'data-generation-panel': '', class: 'pet-tools__generation' }, { hidden: true });
  panel.append(element('button', { 'data-profile-reset': '', type: 'button' }));

  const claimBlock = element('section', { 'data-pet-claim': '' }, { hidden: true });
  const claimEmail = element('p', { 'data-claim-email': '', class: 'form-note' });
  const claimSend = element('button', { 'data-claim-send': '', type: 'button', class: 'button' });
  const claimCodeForm = element('form', { 'data-claim-verify': '' }, { hidden: true });
  const claimCodeInput = element('input', { name: 'code', type: 'text', pattern: '[0-9]{6}', maxlength: '6' });
  const claimCodeLabel = element('label');
  claimCodeLabel.append(claimCodeInput);
  claimCodeForm.append(claimCodeLabel, element('button', { type: 'submit' }));
  const claimStatus = element('p', { 'data-claim-status': '', role: 'status', class: 'pet-tools__status' });
  claimBlock.append(claimEmail, claimSend, claimCodeForm);
  if (legacyLink) {
    claimBlock.append(
      element('button', { 'data-claim-link': '', type: 'button', class: 'text-link' }, { hidden: true }),
      element('button', { 'data-claim-copy': '', type: 'button', class: 'text-link' }, { hidden: true }),
      element('input', { 'data-claim-url': '', type: 'text', readonly: '' }, { hidden: true }),
    );
  }
  claimBlock.append(claimStatus);
  panel.append(claimBlock);

  const generationForm = element('form', { 'data-pet-generation': '' });
  generationForm.append(
    element('input', { type: 'file', name: 'file' }),
    element('select', { name: 'kind' }),
    element('button', { type: 'submit' }),
  );
  panel.append(
    generationForm,
    element('button', { 'data-recommend': '', type: 'button', class: 'text-link' }),
    element('div', { 'data-pet-results': '' }),
  );

  const workspace = element('div', { class: 'pet-tools__workspace' });
  workspace.append(panel);
  root.append(
    profileForm,
    workspace,
    element('p', { 'data-pet-status': '', role: 'status', class: 'pet-tools__status' }),
    element('img', { 'data-photo-preview': '' }, { hidden: true }),
  );
  document.body.append(root);
  registerFormControls(claimCodeForm);
  registerFormControls(generationForm);

  const find = (selector) => root.querySelector(selector);
  return {
    document, location, navigator, window, sessionStorage, sessionKey, root,
    profileForm, panel, claimBlock, claimEmail, claimSend, claimCodeForm, claimCodeInput, claimStatus,
    legacyLinkButton: find('[data-claim-link]'),
    legacyCopyButton: find('[data-claim-copy]'),
    legacyUrlInput: find('[data-claim-url]'),
    status: find('[data-pet-status]'),
    clipboard,
  };
};

// ---------------------------------------------------------------------------
// 本地 HTTP 替身服务
// ---------------------------------------------------------------------------

const makeServer = (handler) => new Promise((resolve, reject) => {
  const requests = [];
  const server = http.createServer((request, response) => {
    let raw = '';
    request.on('data', (chunk) => { raw += chunk; });
    request.on('end', () => {
      const entry = { method: request.method, path: request.url, headers: request.headers, body: raw };
      requests.push(entry);
      let result;
      try { result = handler(entry, requests) || { status: 404, body: { detail: 'not_found' } }; }
      catch (error) { result = { status: 500, body: { detail: 'stub_error' } }; }
      response.statusCode = result.status || 200;
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify(result.body === undefined ? {} : result.body));
    });
  });
  server.on('error', reject);
  server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port, requests }));
});

const closeServer = (handle) => new Promise((resolve) => {
  handle.server.closeAllConnections?.();
  handle.server.close(() => resolve());
});

// ---------------------------------------------------------------------------
// 在受控上下文加载真实 pet-tools.js
// ---------------------------------------------------------------------------

const boot = (fixture, port) => {
  const fetchCalls = [];
  const consoleCalls = [];
  const fetchShim = async (input, init = {}) => {
    const raw = typeof input === 'string' ? input : input.url;
    const absolute = /^https?:\/\//i.test(raw) ? raw : 'http://127.0.0.1:' + port + raw;
    fetchCalls.push({ path: raw, method: String(init.method || 'GET').toUpperCase(), headers: init.headers, body: init.body });
    return globalThis.fetch(absolute, init);
  };
  const context = {
    document: fixture.document,
    window: fixture.window,
    location: fixture.location,
    navigator: fixture.navigator,
    sessionStorage: fixture.sessionStorage,
    fetch: fetchShim,
    Headers: globalThis.Headers,
    FormData: globalThis.FormData,
    URL: globalThis.URL,
    crypto: globalThis.crypto,
    setTimeout,
    clearTimeout,
    console: {
      log: (...args) => consoleCalls.push(['log', ...args]),
      warn: (...args) => consoleCalls.push(['warn', ...args]),
      error: (...args) => consoleCalls.push(['error', ...args]),
    },
    Intl: globalThis.Intl,
    CustomEvent: globalThis.CustomEvent,
  };
  vm.createContext(context);
  vm.runInContext(petToolsSource, context, { filename: 'web-integration/pet-tools.js' });
  return { context, fetchCalls, consoleCalls };
};

// ---------------------------------------------------------------------------
// 断言 / 驱动工具
// ---------------------------------------------------------------------------

let assertions = 0;
let assertionFailures = 0;
const assert = (condition, message) => {
  assertions += 1;
  if (condition) return;
  assertionFailures += 1;
  throw new Error(message);
};
const assertIncludes = (actual, expected, message) => assert(String(actual).includes(expected), message + ' (actual: ' + actual + ')');

const click = (target) => target.dispatchEvent({ type: 'click', target, preventDefault() {} });
const submit = (target) => target.dispatchEvent({ type: 'submit', target, preventDefault() {} });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitFor = async (predicate, label, timeout = 4000) => {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (predicate()) return;
    await sleep(10);
  }
  throw new Error('timeout waiting for: ' + label);
};

const walkStrings = (node, out = []) => {
  if (!node) return out;
  if (node.nodeType === 3) { out.push(String(node.data)); return out; }
  out.push(String(node.textContent || ''));
  if (node.value) out.push(String(node.value));
  if (node.attributes) for (const [name, value] of node.attributes) out.push(name + '=' + value);
  for (const child of node.children || []) walkStrings(child, out);
  return out;
};

const collectFixtureStrings = (fixture, bootResult) => {
  const strings = walkStrings(fixture.document.documentElement);
  strings.push(...fixture.sessionStorage.store.values());
  strings.push(...fixture.clipboard.calls);
  for (const call of bootResult.fetchCalls) strings.push(String(call.path));
  for (const call of bootResult.consoleCalls) strings.push(call.map(String).join(' '));
  return strings;
};

const assertNoTokenExposure = (fixture, bootResult) => {
  // The baseline website legitimately keeps its *guest session* token in sessionStorage and
  // /v1/sessions returns `session_token`; that is not a claim capability. This test guards the
  // bug where an unverified visitor receives a redeemable claim link/token. Only capability-like
  // values are rejected: claim links (`token=` / `/claim?`), raw `token` fields, or the
  // `<payload>.<hmac>` link-token shape.
  const strings = collectFixtureStrings(fixture, bootResult);
  const suspicious = strings.filter((value) => {
    if (value.includes('guest-token-123')) return false;
    if (/"session_token"\s*:/.test(value)) return false;
    return /token=/i.test(value)
      || /"token"\s*:/i.test(value)
      || /\/claim\?/i.test(value)
      || /[A-Za-z0-9_-]{40,}\.[0-9a-f]{64}/.test(value);
  });
  assert(suspicious.length === 0, 'no claim capability token may leak into DOM/clipboard/fetch/console (found: ' + suspicious.slice(0, 3).join(' | ') + ')');
};

const assertNoOtpLeak = (fixture, bootResult, code) => {
  assert(fixture.clipboard.calls.length === 0, 'clipboard must never receive an OTP');
  const consoleText = bootResult.consoleCalls.map((call) => call.map(String).join(' ')).join('\n');
  assert(!consoleText.includes(code), 'OTP must not be printed to console');
  const storageText = [...fixture.sessionStorage.store.values()].join('\n');
  assert(!storageText.includes(code), 'OTP must not be persisted in sessionStorage');
  assert(!bootResult.fetchCalls.some((call) => /code=/i.test(String(call.path))), 'OTP must not appear in request URLs');
};

// ---------------------------------------------------------------------------
// 场景
// ---------------------------------------------------------------------------

const scenarios = [];
const scenario = (name, fn) => scenarios.push({ name, fn });

const startPayload = () => ({
  status: 202,
  body: {
    challenge_id: 'challenge_abc123',
    purpose: 'claim',
    email_masked: 'v***@example.com',
    expires_at: Math.floor(Date.now() / 1000) + 600,
    delivery: 'email',
    link_available: false,
  },
});

scenario('a/b/c: challenge_id 渲染 OTP、invalid_otp 保留会话、正确 OTP 认领成功', async () => {
  const handle = await makeServer((request) => {
    if (request.path === '/apps/wagelpaw/v1/claims' && request.method === 'POST') return startPayload();
    if (request.path === '/apps/wagelpaw/v1/claims/challenge_abc123/verify') {
      const body = JSON.parse(request.body || '{}');
      if (body.code === '123456') {
        return { status: 200, body: { claimed: true, email_verified: true, email_masked: 'v***@example.com', claimed_session_ids: ['s1'] } };
      }
      return { status: 401, body: { detail: 'invalid_otp' } };
    }
    return { status: 404, body: { detail: 'not_found' } };
  });
  const fixture = createFixture();
  const bootResult = boot(fixture, handle.port);
  try {
    click(fixture.claimSend);
    await waitFor(() => fixture.claimCodeForm.hidden === false, 'OTP form visible after claim start');
    assertIncludes(fixture.claimStatus.textContent, 'v***@example.com', 'masked email rendered (K1 regression)');
    assertIncludes(fixture.claimStatus.textContent, BASE_COPY.claim_sent, 'sent status rendered');
    const startRequest = handle.requests[0];
    assert(startRequest.path === '/apps/wagelpaw/v1/claims', 'start endpoint is /v1/claims');
    assert(startRequest.headers['x-wagelpaw-session'] === 'guest-token-123', 'start request carries X-Wagelpaw-Session');
    assert(JSON.parse(startRequest.body).email === 'visitor@example.com', 'start request carries normalized email');
    assert(!handle.requests.some((entry) => entry.path.endsWith('/link')), 'magic-link endpoint must not be called by the new UI');

    // b) 错误 OTP：401 invalid_otp 不能清掉 guest session
    fixture.claimCodeInput.value = '000000';
    submit(fixture.claimCodeForm);
    await waitFor(() => fixture.claimStatus.textContent === BASE_COPY.claim_invalid_code, 'invalid_otp message');
    const stored = JSON.parse(fixture.sessionStorage.getItem(fixture.sessionKey) || 'null');
    assert(stored && stored.session_token === 'guest-token-123', 'guest session survives invalid_otp 401');
    assert(fixture.claimCodeForm.hidden === false, 'OTP form remains usable after invalid_otp');
    assert(fixture.claimSend.hidden === false, 'resend button remains available after invalid_otp');
    assert(fixture.claimBlock.hidden === false, 'claim block remains visible after invalid_otp');
    assertNoOtpLeak(fixture, bootResult, '000000');

    // c) 正确 OTP：验证成功并显示已认领状态
    fixture.claimCodeInput.value = '123456';
    submit(fixture.claimCodeForm);
    await waitFor(() => fixture.claimStatus.textContent === BASE_COPY.claim_verified, 'verified message');
    assert(fixture.claimCodeForm.hidden === true, 'OTP form hidden after verify success');
    assert(fixture.claimSend.hidden === true, 'send button hidden after verify success');
    const claimed = JSON.parse(fixture.sessionStorage.getItem(fixture.sessionKey) || 'null');
    assert(claimed && claimed.claimed === true, 'sessionStorage records claimed session state');
    assert(handle.requests.length === 3, 'exactly start + 2 verify requests (no retry loop)');
    assertNoTokenExposure(fixture, bootResult);
  } finally {
    await closeServer(handle);
  }
});

scenario('d: link 503 claim_link_disabled → 不产生/不复制 token，只提示用验证码', async () => {
  const handle = await makeServer((request) => {
    if (request.path === '/apps/wagelpaw/v1/claims' && request.method === 'POST') return startPayload();
    if (request.path.endsWith('/link')) return { status: 503, body: { detail: 'claim_link_disabled' } };
    return { status: 404, body: { detail: 'not_found' } };
  });
  const fixture = createFixture({ legacyLink: true });
  const bootResult = boot(fixture, handle.port);
  try {
    click(fixture.claimSend);
    await waitFor(() => fixture.claimCodeForm.hidden === false, 'OTP form visible');
    // 模拟旧版 section 缓存残留的 magic-link 按钮被触发
    click(fixture.legacyLinkButton);
    await waitFor(() => fixture.claimStatus.textContent === BASE_COPY.claim_link_disabled, 'link disabled message');
    assertIncludes(fixture.claimStatus.textContent, 'verification code', 'message points to OTP, not a link');
    assert(fixture.legacyUrlInput.value === '', 'legacy URL input stays empty (no token in DOM)');
    assert(fixture.legacyUrlInput.hidden === true, 'legacy URL input stays hidden');
    assert(fixture.legacyCopyButton.hidden === true, 'legacy copy button stays hidden');
    assert(fixture.clipboard.calls.length === 0, 'clipboard never written');
    assert(handle.requests.filter((entry) => entry.path.endsWith('/link')).length === 1, 'legacy link click issues one defensive request only');
    // 旧 copy 按钮也只能提示用验证码
    click(fixture.legacyCopyButton);
    assert(fixture.claimStatus.textContent === BASE_COPY.claim_link_disabled, 'legacy copy click keeps OTP guidance');
    assert(fixture.clipboard.calls.length === 0, 'legacy copy click never writes clipboard');
    assertNoTokenExposure(fixture, bootResult);
  } finally {
    await closeServer(handle);
  }
});

scenario('e: 旧响应无 challenge_id → 明确错误、会话保留、无重试死循环', async () => {
  const handle = await makeServer((request) => {
    if (request.path === '/apps/wagelpaw/v1/claims' && request.method === 'POST') {
      return { status: 202, body: { email_masked: 'v***@example.com', expires_at: Math.floor(Date.now() / 1000) + 600, delivery: 'email' } };
    }
    return { status: 404, body: { detail: 'not_found' } };
  });
  const fixture = createFixture();
  boot(fixture, handle.port);
  try {
    click(fixture.claimSend);
    await waitFor(() => fixture.claimStatus.textContent === BASE_COPY.claim_response_invalid, 'explicit missing challenge id error');
    assert(fixture.claimCodeForm.hidden === true, 'OTP form stays hidden when challenge id missing');
    const stored = JSON.parse(fixture.sessionStorage.getItem(fixture.sessionKey) || 'null');
    assert(stored && stored.session_token === 'guest-token-123', 'guest session survives malformed start response');
    assert(handle.requests.length === 1, 'no retry loop on malformed start response');
  } finally {
    await closeServer(handle);
  }
});

scenario('f: 旧响应 claim_id 别名 → 仍可继续验证（向后兼容）', async () => {
  const handle = await makeServer((request) => {
    if (request.path === '/apps/wagelpaw/v1/claims' && request.method === 'POST') {
      return { status: 202, body: { claim_id: 'legacy_claim_1', email_masked: 'v***@example.com', expires_at: Math.floor(Date.now() / 1000) + 600, delivery: 'email' } };
    }
    if (request.path === '/apps/wagelpaw/v1/claims/legacy_claim_1/verify') {
      return { status: 200, body: { claimed: true, email_verified: true, claimed_session_ids: ['s1'] } };
    }
    return { status: 404, body: { detail: 'not_found' } };
  });
  const fixture = createFixture();
  boot(fixture, handle.port);
  try {
    click(fixture.claimSend);
    await waitFor(() => fixture.claimCodeForm.hidden === false, 'OTP form visible with claim_id alias');
    fixture.claimCodeInput.value = '123456';
    submit(fixture.claimCodeForm);
    await waitFor(() => fixture.claimStatus.textContent === BASE_COPY.claim_verified, 'verified via claim_id alias');
    assert(handle.requests.some((entry) => entry.path === '/apps/wagelpaw/v1/claims/legacy_claim_1/verify'), 'verify uses claim_id alias path');
  } finally {
    await closeServer(handle);
  }
});

scenario('g: 401 session_expired_or_invalid → 仍按基线清 guest 会话', async () => {
  const handle = await makeServer((request) => {
    if (request.path === '/apps/wagelpaw/v1/claims' && request.method === 'POST') return startPayload();
    if (request.path.endsWith('/verify')) return { status: 401, body: { detail: 'session_expired_or_invalid' } };
    return { status: 404, body: { detail: 'not_found' } };
  });
  const fixture = createFixture();
  boot(fixture, handle.port);
  try {
    click(fixture.claimSend);
    await waitFor(() => fixture.claimCodeForm.hidden === false, 'OTP form visible');
    fixture.claimCodeInput.value = '123456';
    submit(fixture.claimCodeForm);
    await waitFor(() => fixture.sessionStorage.getItem(fixture.sessionKey) === null, 'session cleared on session expiry');
    assert(fixture.claimBlock.hidden === true, 'claim block hidden after session expiry');
    assert(fixture.status.textContent === BASE_COPY.expired, 'global expired status shown after session expiry');
  } finally {
    await closeServer(handle);
  }
});

scenario('h: 429 challenge_attempts_exceeded → 保留会话、明确提示、可重发', async () => {
  const handle = await makeServer((request) => {
    if (request.path === '/apps/wagelpaw/v1/claims' && request.method === 'POST') return startPayload();
    if (request.path.endsWith('/verify')) return { status: 429, body: { detail: 'challenge_attempts_exceeded' } };
    return { status: 404, body: { detail: 'not_found' } };
  });
  const fixture = createFixture();
  boot(fixture, handle.port);
  try {
    click(fixture.claimSend);
    await waitFor(() => fixture.claimCodeForm.hidden === false, 'OTP form visible');
    fixture.claimCodeInput.value = '123456';
    submit(fixture.claimCodeForm);
    await waitFor(() => fixture.claimStatus.textContent === BASE_COPY.claim_attempts_exceeded, 'attempts exceeded message');
    const stored = JSON.parse(fixture.sessionStorage.getItem(fixture.sessionKey) || 'null');
    assert(stored && stored.session_token === 'guest-token-123', 'guest session survives attempts exceeded');
    assert(fixture.claimSend.hidden === false, 'resend button available after attempts exceeded');
    assert(fixture.claimBlock.hidden === false, 'claim block stays visible after attempts exceeded');
  } finally {
    await closeServer(handle);
  }
});

// ---------------------------------------------------------------------------
// 运行
// ---------------------------------------------------------------------------

(async () => {
  const started = Date.now();
  let scenarioFailures = 0;
  for (const item of scenarios) {
    const scenarioStart = Date.now();
    try {
      await item.fn();
      console.log('PASS scenario: ' + item.name + ' (' + (Date.now() - scenarioStart) + 'ms)');
    } catch (error) {
      scenarioFailures += 1;
      console.log('FAIL scenario: ' + item.name + ' => ' + error.message);
    }
  }
  console.log('');
  console.log('SUMMARY scenarios=' + scenarios.length + ' scenario_failures=' + scenarioFailures
    + ' assertions=' + assertions + ' assertion_failures=' + assertionFailures
    + ' duration_ms=' + (Date.now() - started));
  process.exit(scenarioFailures === 0 && assertionFailures === 0 ? 0 : 1);
})();
