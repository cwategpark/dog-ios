#!/usr/bin/env node
'use strict';

// 静态检查：不渲染 Liquid、不启动浏览器，仅对两个主题文件做结构与契约断言。
// 用法：node web-integration/tests/static-checks.js
// 输出：PASS/FAIL 行 + 汇总；退出码 0=全部通过，1=有失败。

const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');

const repo = path.join(__dirname, '..', '..');
const liquidPath = path.join(repo, 'web-integration', 'pet-tools.liquid');
const jsPath = path.join(repo, 'web-integration', 'pet-tools.js');
const snapshotDir = path.join(repo, '.handoff', '2026-11-04', 'staging', 'migration', 'theme');
const liquid = fs.readFileSync(liquidPath, 'utf8');
const js = fs.readFileSync(jsPath, 'utf8');

let passed = 0;
let failed = 0;
const check = (name, condition) => {
  if (condition) { passed += 1; console.log('PASS ' + name); }
  else { failed += 1; console.log('FAIL ' + name); }
};
const has = (text, needle) => text.includes(needle);
const count = (text, needle) => text.split(needle).length - 1;

// 安全修复（P0 账户接管）：magic-link 已默认关闭，网站不再展示/复制能力链接；
// 认领只剩 OTP 路径，因此 claim_link / claim_copy / claim_link_sent / claim_copy_failed 不再需要。
const claimKeys = [
  'claim_title', 'claim_explain', 'claim_email', 'claim_name', 'claim_send', 'claim_code', 'claim_verify',
  'claim_unverified', 'claim_sent', 'claim_verified', 'claim_expired', 'claim_rate_limited',
  'claim_invalid_code', 'claim_email_invalid', 'claim_missing_email', 'claim_unavailable',
  'claim_link_disabled', 'claim_attempts_exceeded', 'claim_response_invalid', 'claim_expires',
];

// ---------- 1) 原有问卷/生成结构必须保留 ----------
const legacyLiquidTokens = [
  '{% if settings.ai_enabled %}', '{{ \'pet-tools.css\' | asset_url | stylesheet_tag }}',
  '<script src="{{ \'pet-tools.js\' | asset_url }}" defer></script>',
  'data-pet-tools', 'data-pet-copy', 'data-pet-profile', 'name="type"', 'name="age_months"',
  'data-dog-size', 'name="dog_size"', 'name="consent"', 'class="consent-label"',
  'data-pet-generation', 'data-generation-panel hidden', 'data-profile-reset', 'data-recommend',
  'data-pet-results', 'data-pet-status', 'role="status"', 'aria-live="polite"',
  'pet-tools__workspace', 'pet-tools__generation', 'pet-profile-saved', 'form-note', 'text-link',
  'class="button"', 'data-photo-preview', 'data-fitting-module', 'data-root-url', 'data-cart-url',
  'data-proxy', 'data-product-id', 'data-variant-id', 'data-product-image',
  '{% schema %}', '{% endschema %}', '{% endif %}',
];
legacyLiquidTokens.forEach((token) => check('liquid 保留原有结构: ' + token, has(liquid, token)));

// ---------- 2) 新增问卷字段 ----------
check('liquid 新增 email 问卷字段（name="email"）', has(liquid, 'name="email"'));
check('liquid email 字段为 type="email"', has(liquid, 'type="email" name="email"'));
check('liquid email 字段 maxlength=254', /type="email" name="email"[^>]*maxlength="254"/.test(liquid));
check('liquid email 字段不在 HTML 写 required（避免旧 JS 缓存被必填卡住）', !/type="email" name="email"[^>]*\brequired\b/.test(liquid));
check('js 在初始化时把 email 字段设为 required', has(js, 'if (profileForm.elements.email) profileForm.elements.email.required = true;'));
check('liquid 新增可选姓名字段（name="full_name"）', has(liquid, 'name="full_name"'));

// ---------- 3) 认领区块 DOM 挂载点 ----------
const claimDom = ['data-pet-claim', 'data-claim-email', 'data-claim-send', 'data-claim-verify', 'data-claim-status'];
claimDom.forEach((token) => check('liquid 认领区块 DOM: ' + token, has(liquid, token)));
check('liquid 认领区块默认 hidden（旧 JS 缓存时不会出现死按钮）', /data-pet-claim hidden/.test(liquid));
check('liquid 不再包含 magic-link 展示/复制 DOM（data-claim-link/copy/url）',
  !has(liquid, 'data-claim-link') && !has(liquid, 'data-claim-copy') && !has(liquid, 'data-claim-url'));
check('liquid 认领区块复用既有 class（button/form-note/pet-tools__status）',
  has(liquid, 'class="button" type="button" data-claim-send') && has(liquid, 'data-claim-status'));
check('liquid 认领区块使用 role="status" aria-live="polite"', /data-claim-status/.test(liquid) && has(liquid, 'role="status" aria-live="polite" data-claim-status'));

// ---------- 4) i18n copy 变量与 JSON 注入 ----------
claimKeys.forEach((key) => {
  check('liquid 定义回退 copy 变量 copy_' + key, has(liquid, 'copy_' + key + ' = \'assistant.' + key + '\' | t'));
  check('liquid JSON copy 注入 " ' + key + ' "', has(liquid, '"' + key + '":{{ copy_' + key + ' | json }}'));
});
check('liquid ' + claimKeys.length + ' 个 copy 变量均含 blank/翻译缺失回退', count(liquid, '== blank or copy_claim_') === claimKeys.length);

// ---------- 5) 后端契约端点（docs/mobile-api-contract.md §5） ----------
check('js 保留 /v1/sessions', has(js, '\'/v1/sessions\''));
check('js 调用 POST /v1/claims（发起认领/OTP）', has(js, '\'/v1/claims\''));
check('js 调用 POST /v1/claims/{id}/verify', has(js, '\'/v1/claims/\' + encodeURIComponent(claim.id) + \'/verify\''));
check('js 旧 DOM 兼容：link 调用仅用于旧 section 且 503 时提示用验证码', has(js, '\'/v1/claims/\' + encodeURIComponent(claim.id) + \'/link\'') && has(js, 'claim_link_disabled'));
check('js 保留 X-Wagelpaw-Session 会话头', has(js, "headers.set('X-Wagelpaw-Session', session.session_token)"));
check('js 保留 sessionStorage 会话键', has(js, "'wagelpaw:guest:' + location.host"));
check('js 保留 App Proxy 前缀校验（base 必须为同源相对路径）', has(js, "if (!base.startsWith('/') || base.startsWith('//')) return;"));

// ---------- 6) 安全 / 兼容约束 ----------
check('js 不使用 localStorage', !has(js, 'localStorage'));
check('js 不打印 console.log/debug', !has(js, 'console.log') && !has(js, 'console.debug'));
check('js 不把 OTP 写进 URL 查询串', !/\?(?:code|otp)=/i.test(js) && !has(js, 'code='));
check('js 不硬编码 token/密钥', !/(api[_-]?key|secret|access_token|dev_token)\s*[:=]\s*['"][A-Za-z0-9_\-]{16,}/i.test(js));
check('js fetch 使用 base + 相对路径', has(js, 'fetch(base + path'));
check('js 无绝对 URL 的 fetch', !/fetch\(\s*['"]https?:/i.test(js));
check('js 认领逻辑整体有 DOM 缺失静默跳过守卫', has(js, 'if (claimBlock && claimSend && claimCodeForm && claimCodeInput)'));
check('js 读不到 email 节点时跳过（向后兼容）', has(js, 'if (emailField) {'));
check('js 会话请求保留旧后端兼容回退（422 extra forbid）', has(js, 'if (!email || error.status !== 422 || error.detail) throw error;') && has(js, 'delete body.email; delete body.full_name;'));
check('js 认领成功后清空 OTP 输入框', has(js, 'claimCodeForm.reset(); claimCodeForm.hidden = true;'));
check('js 不清空/不存储 OTP 到 storage（sessionStorage 只写 session/email）',
  !/sessionStorage\.setItem\([^)]*code/i.test(js));

// ---------- 7) 与原文件的行级增量对照 ----------
if (fs.existsSync(snapshotDir)) {
  const snapshotLiquid = fs.readFileSync(path.join(snapshotDir, 'sections', 'pet-tools.liquid'), 'utf8');
  const snapshotJs = fs.readFileSync(path.join(snapshotDir, 'assets', 'pet-tools.js'), 'utf8');
  check('liquid 原文件每个标签仍出现在新文件（顺序无关）', legacyLiquidTokens
    .filter((token) => has(snapshotLiquid, token))
    .every((token) => has(liquid, token)));
  check('js 未删除原有请求端点', [...new Set(snapshotJs.match(/\/v1\/[a-z-]+/g) || [])].every((token) => has(js, token)));
  check('js 生成/上传/推荐逻辑保留（createJob/pollJob/showResult 仍在）', has(js, 'const pollJob = async') && has(js, 'const createJob = async') && has(js, 'const showResult = async'));
  check('js 原文件行为行数量增加（纯增量）', js.split('\n').length > snapshotJs.split('\n').length);
} else {
  console.log('SKIP 快照目录不存在，跳过与 snapshot 的对照: ' + snapshotDir);
}

// ---------- 8) 真实契约字段与错误处理（第二轮审查回归） ----------
check('js 优先读取后端真实字段 challenge_id（兼容 claim_id 别名）',
  /CHALLENGE_ID_FIELDS\s*=\s*\['challenge_id',\s*'claim_id'/.test(js));
check('js 只有明确的会话失效 detail 才清 guest 会话', has(js, 'isSessionExpiredDetail(detail)'));
check('js 将 invalid_otp 映射为可重输而不是会话过期', has(js, 'OTP_INVALID_DETAILS') && has(js, "if (status === 401) return 'session';"));
check('js 错 OTP 后保留 verifier 表单且有可重试提示键', has(js, "claim_invalid_code") && has(js, 'claim_attempts_exceeded'));

// ---------- 9) 补丁与 README 不漂移 ----------
const patchPath = path.join(repo, 'web-integration', 'pet-tools.patch');
const readmePath = path.join(repo, 'web-integration', 'README.md');
const patch = fs.readFileSync(patchPath, 'utf8');
const readme = fs.readFileSync(readmePath, 'utf8');
const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');
check('patch 是当前修复版（含 challenge_id/会话错误处理，不含 response.url）',
  has(patch, 'challenge_id') && has(patch, 'isSessionExpiredDetail') && !has(patch, 'response.url'));
check('patch 不读取/写入 response.url 或剪贴板 token', !has(patch, 'response.url') && !has(patch, 'claimUrlInput.value = response.url'));
check('patch 头部指向两个主题文件', has(patch, '--- sections/pet-tools.liquid') && has(patch, '--- assets/pet-tools.js'));
check('README 记录的 liquid sha256 与文件一致', has(readme, sha256(liquid)));
check('README 记录的 js sha256 与文件一致', has(readme, sha256(js)));
check('README 记录的 patch sha256 与文件一致', has(readme, sha256(patch)));
check('README 不再把 claim_id 当作主字段或宣称展示/复制认领链接',
  !has(readme, '展示/复制') && !has(readme, '"claim_id"') && has(readme, 'challenge_id'));

console.log('');
console.log('SUMMARY passed=' + passed + ' failed=' + failed + ' liquid=' + liquidPath + ' js=' + jsPath);
process.exit(failed === 0 ? 0 : 1);
