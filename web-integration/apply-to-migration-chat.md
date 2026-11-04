# 迁移聊天 · 最小应用说明（网站桥接 email → 保存到 App，OTP 认领）

> 目标：把「问卷 email（+可选姓名）→ 保存到 App → 邮箱 OTP 验证」接到现有 Shopify 主题。
> 只改 **2 个主题文件**；后端按 `docs/mobile-api-contract.md` §5 部署即可，**不要另起第二套后端**。
> 当前未部署、未在线上主题/浏览器联调（详见 `web-integration/README.md`）。
> Magic-link 已默认关闭：不存在「复制认领链接」这一步，认领只用 6 位 OTP。

## 1. 文件与命令

源文件（本仓库）：`web-integration/pet-tools.liquid`、`web-integration/pet-tools.js`、`web-integration/pet-tools.patch`。
目标主题路径（`migration/theme/` 下）：

| 源 | 目标 |
| --- | --- |
| `web-integration/pet-tools.liquid` | `theme/sections/pet-tools.liquid` |
| `web-integration/pet-tools.js` | `theme/assets/pet-tools.js` |

在 `migration/` 根目录应用补丁（推荐；会同时改两个文件）：

```bash
cd <migration>                     # 含 theme/ 的目录
patch -p0 < web-integration/pet-tools.patch
# 或：git apply -p0 web-integration/pet-tools.patch
```

等价手工操作：用 `web-integration/` 下两个改后文件直接覆盖对应主题文件；**不要改第三个文件**。

改后校验（sha256 应一致；以 `web-integration/README.md` §0 为准）：

```bash
shasum -a 256 theme/sections/pet-tools.liquid theme/assets/pet-tools.js
# a2961678eb3980e565c2d21972abfff048a083b640efe698e6147180b4a27eed  sections/pet-tools.liquid
# 73c333f7eeb29ee7e1d694648aab37e1891dae89dee8a35743d0ad2eb5ff3a9a  assets/pet-tools.js
```

可选回归（不依赖浏览器）：

```bash
node --check theme/assets/pet-tools.js
node web-integration/tests/pure-logic.test.js
node web-integration/tests/static-checks.js
node web-integration/tests/claim-interaction.test.js
```

## 2. 行级改动（便于 review / 手工合并）

`pet-tools.liquid`（原 6 行 → 26 行）：

1. `<script src="pet-tools.js" defer>` 之后新增 20 行 `{% assign copy_claim_* = 'assistant.claim_*' | t %}`
   + 缺失/空时英文回退（不依赖 locales 也能上线）。
2. `data-pet-copy` JSON 末尾追加 20 个 `"claim_*":{{ copy_claim_* | json }}`。
3. 问卷 `form[data-pet-profile]` 中新增：
   `<input type="email" name="email" autocomplete="email" inputmode="email" maxlength="254">`、
   `<input type="text" name="full_name" autocomplete="name" maxlength="120">`（复用现有 `<label>`，未加 HTML `required`）。
4. `pet-profile-saved` 与 `form[data-pet-generation]` 之间新增 `section.pet-tools__claim[data-pet-claim][hidden]`
   （标题/说明、`data-claim-email`、`data-claim-send`、`form[data-claim-verify]` + `input[name=code]`、
   `data-claim-status`）。**不包含**链接按钮/复制按钮/URL 输入框。

`pet-tools.js`（原 169 行 → 385 行；只加不改既有流程）：

1. 文件顶部 `// @pure:start … // @pure:end` 纯函数区：`normalizeEmail` / `normalizeFullName` / `isOtpCode` /
   `claimErrorKey` / `isSessionExpiredDetail`。
2. `init()` 内新增认领 DOM 引用、状态机；`showProfileState()` 增加认领区显隐。
3. `request()` 仅在 `!response.ok` 时解析 `{"detail": ...}`；**只有**明确会话失效 detail 才清 guest。
4. 问卷 submit：email 校验 → `/v1/sessions` 带 `email`、可选 `full_name`；旧后端 422 时去掉新字段重试一次。
5. 认领：`POST /v1/claims` 读取 **`challenge_id`**（兼容 `claim_id` 别名）→ `POST /v1/claims/{id}/verify`。
   错 OTP 401 保留会话与输入，可重试。
6. 生成/上传/推荐/购物袋加购、`X-Wagelpaw-Session`、App Proxy 前缀、sessionStorage key 均**未变**。

## 3. 后端需部署的端点（契约 §5）

App Proxy 前缀（主题 `settings.app_proxy_path`，默认 `/apps/wagelpaw`）下：

| 方法 / 路径 | 说明 |
| --- | --- |
| `POST /v1/sessions` | 接受 `email` + 可选 `full_name`；旧客户端不传仍可用 |
| `POST /v1/claims` | body `{"email"}` + `X-Wagelpaw-Session` → 202 `{challenge_id, email_masked, expires_at, delivery}` |
| `POST /v1/claims/{id}/verify` | body `{"code"}` → `claimed/email_verified/claimed_session_ids` |
| `POST /v1/claims/{id}/link` | **本阶段 503 `claim_link_disabled`**；不返回 token/URL，前端不展示 |
| `GET /v1/claims/link/{token}`、`POST /v1/claims/link/redeem` | **本阶段 503**；部署方不启用 claim 页面 |

## 4. 环境变量 / 部署配置

- 复用**现有唯一后端实例**，App Proxy 指向它；网站 JS 全部同源相对路径，不硬编码域名/密钥。
- 邮件投递：未配置 SMTP 时 `/v1/claims` 503 `email_delivery_unavailable`；development/test 可用
  `WAGELPAW_DEV_EMAIL_OUTBOX=1` 本地 outbox（不发真实邮件）。
- OTP：6 位、TTL 10 分钟、最多 5 次、60s 冷却、按邮箱/IP 限流。
- `WAGELPAW_CLAIM_LINK_ENABLED` 保持 `0`（默认）；不要为网站开启 magic-link。
- 部署顺序：后端端点 → 邮件投递 → 未发布主题验收 → 发布。**不要本地起第二套后端/数据库**。

## 5. 回滚

恢复 `theme/sections/pet-tools.liquid`、`theme/assets/pet-tools.js` 两个文件到应用前版本即可
（`patch -R -p0` 或主题版本回滚）；不影响其它主题文件与后端。后端字段为向后兼容扩展，回滚主题不需要回滚后端。
