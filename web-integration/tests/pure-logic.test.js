#!/usr/bin/env node
'use strict';

// 纯逻辑测试：从 pet-tools.js 的 `// @pure:start` … `// @pure:end` 区块抽取纯函数，
// 在 Node 中直接求值（不需要 DOM / 浏览器 / 构建），验证 email 规范化与 OTP/认领错误状态映射。
// 用法：node web-integration/tests/pure-logic.test.js
// 输出：PASS/FAIL 行 + 汇总；退出码 0=全部通过，1=有失败。

const fs = require('node:fs');
const path = require('node:path');

const sourcePath = path.join(__dirname, '..', 'pet-tools.js');
const source = fs.readFileSync(sourcePath, 'utf8');
const startMarker = '// @pure:start';
const endMarker = '// @pure:end';
const start = source.indexOf(startMarker);
const end = source.indexOf(endMarker);

if (start < 0 || end < 0 || end <= start) {
  console.error('FAIL 纯函数区块标记缺失：' + startMarker + ' / ' + endMarker);
  process.exit(1);
}

const block = source.slice(start, end);
let helpers;
try {
  helpers = new Function(block + '\nreturn { normalizeEmail, normalizeFullName, isOtpCode, claimErrorKey };')();
} catch (error) {
  console.error('FAIL 纯函数区块无法在 Node 中求值：' + error.message);
  process.exit(1);
}

const { normalizeEmail, normalizeFullName, isOtpCode, claimErrorKey } = helpers;

let passed = 0;
let failed = 0;
const check = (name, actual, expected) => {
  const actualText = JSON.stringify(actual);
  const expectedText = JSON.stringify(expected);
  if (actualText === expectedText) {
    passed += 1;
    console.log('PASS ' + name);
  } else {
    failed += 1;
    console.log('FAIL ' + name + ' => ' + actualText + ' (expected ' + expectedText + ')');
  }
};

const email = (value) => normalizeEmail(value);

// ---------- email 规范化 ----------
check('email: trim + lowercase', email('  Foo@Example.COM  '), { ok: true, email: 'foo@example.com', reason: '' });
check('email: 空字符串为必填错误', email(''), { ok: false, email: '', reason: 'required' });
check('email: 全空白为必填错误', email(' \t\n '), { ok: false, email: '', reason: 'required' });
check('email: 非字符串为必填错误', email(undefined), { ok: false, email: '', reason: 'required' });
check('email: 无顶级域为格式错误', email('foo@bar'), { ok: false, email: 'foo@bar', reason: 'format' });
check('email: 含空格为格式错误', email('foo @bar.com'), { ok: false, email: 'foo @bar.com', reason: 'format' });
check('email: 双 @ 为格式错误', email('foo@@bar.com'), { ok: false, email: 'foo@@bar.com', reason: 'format' });
check('email: 顶级域过短为格式错误', email('foo@bar.c'), { ok: false, email: 'foo@bar.c', reason: 'format' });
check('email: 254 字符通过', email('a'.repeat(249) + '@b.co'), { ok: true, email: 'a'.repeat(249) + '@b.co', reason: '' });
check('email: 255 字符过长', email('a'.repeat(250) + '@b.co'), { ok: false, email: 'a'.repeat(250) + '@b.co', reason: 'too_long' });
check('email: 保留 +tag 与点号（只 trim/lowercase）', email(' A.B+tag@Example.com '), { ok: true, email: 'a.b+tag@example.com', reason: '' });

// ---------- 姓名规范化 ----------
check('name: 折叠空白并 trim', normalizeFullName('  Ada   Lovelace  '), 'Ada Lovelace');
check('name: 非字符串为空', normalizeFullName(undefined), '');
check('name: 全空白为空', normalizeFullName('   '), '');
check('name: 超长截断到 120', normalizeFullName('x'.repeat(130)), 'x'.repeat(120));
check('name: 恰好 120 不截断', normalizeFullName('y'.repeat(120)), 'y'.repeat(120));

// ---------- OTP 校验 ----------
check('otp: 6 位数字通过', isOtpCode('123456'), true);
check('otp: 首尾空白通过', isOtpCode(' 123456 '), true);
check('otp: 5 位拒绝', isOtpCode('12345'), false);
check('otp: 7 位拒绝', isOtpCode('1234567'), false);
check('otp: 字母拒绝', isOtpCode('12345a'), false);
check('otp: 数字类型拒绝', isOtpCode(123456), false);
check('otp: 空值拒绝', isOtpCode(''), false);

// ---------- 认领错误映射（HTTP 状态 / detail -> copy key） ----------
check('error: start 503 -> 不可用', claimErrorKey('start', 503, ''), 'claim_unavailable');
check('error: start 404 -> 不可用（端点未部署）', claimErrorKey('start', 404, ''), 'claim_unavailable');
check('error: start 405 -> 不可用', claimErrorKey('start', 405, ''), 'claim_unavailable');
check('error: start 429 -> 限流', claimErrorKey('start', 429, ''), 'claim_rate_limited');
check('error: start 410 -> 过期', claimErrorKey('start', 410, ''), 'claim_expired');
check('error: start 422 -> 邮箱无效', claimErrorKey('start', 422, ''), 'claim_email_invalid');
check('error: start detail email_delivery_unavailable -> 不可用', claimErrorKey('start', 400, 'email_delivery_unavailable'), 'claim_unavailable');
check('error: start 401 -> 会话失效', claimErrorKey('start', 401, ''), 'session');
check('error: verify 422 -> 验证码错误', claimErrorKey('verify', 422, 'invalid_code'), 'claim_invalid_code');
check('error: verify 400 -> 验证码错误', claimErrorKey('verify', 400, 'invalid_otp'), 'claim_invalid_code');
check('error: verify 410 -> 过期', claimErrorKey('verify', 410, ''), 'claim_expired');
check('error: verify 404 -> 过期（claim 不存在）', claimErrorKey('verify', 404, ''), 'claim_expired');
check('error: verify 429 -> 尝试次数超限', claimErrorKey('verify', 429, ''), 'claim_attempts_exceeded');
check('error: verify 503 -> 不可用', claimErrorKey('verify', 503, ''), 'claim_unavailable');
check('error: link 503 -> 不可用（PUBLIC_BASE_URL 未配置）', claimErrorKey('link', 503, ''), 'claim_unavailable');
check('error: link 404 -> 不可用', claimErrorKey('link', 404, ''), 'claim_unavailable');
check('error: link 410 -> 过期', claimErrorKey('link', 410, ''), 'claim_expired');
check('error: 未知上下文 -> 通用错误', claimErrorKey('unknown', 500, ''), 'error');
check('error: 未覆盖状态 -> 通用错误', claimErrorKey('start', 500, ''), 'error');

console.log('');
console.log('SUMMARY passed=' + passed + ' failed=' + failed + ' source=' + sourcePath);
process.exit(failed === 0 ? 0 : 1);
