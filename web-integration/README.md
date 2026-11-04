# 网站桥接：问卷 email → 保存到 App（OTP 认领，magic-link 关闭）

本目录是对 Shopify 主题两个文件（`sections/pet-tools.liquid`、`assets/pet-tools.js`）的**增量**改造，
把「问卷 email（+ 可选姓名）→ 保存到 App → 邮箱 OTP 验证 → 认领游客会话」接到现有宠物问卷上。
后端契约依据 `docs/mobile-api-contract.md` §5；本目录不启动后端、不部署、不改仓库其他目录。

> **安全状态（2026-11-04 第二轮）**：P0 认领链接（magic-link）账户接管已关闭。
> `POST /v1/claims/{id}/link`、`GET /v1/claims/link/{token}`、`POST /v1/claims/link/redeem` 默认 503
> `claim_link_disabled`，且任何 API 响应都不包含可兑换 token/URL；网站 DOM 不再有链接/复制按钮。
> 认领统一走 OTP：`POST /v1/claims` → `POST /v1/claims/{id}/verify`。

## 0. 交付物与校验和

| 文件 | 说明 |
| --- | --- |
| `pet-tools.liquid` | 改后的 section 文件（直接替换主题 `sections/pet-tools.liquid`） |
| `pet-tools.js` | 改后的 asset 文件（直接替换主题 `assets/pet-tools.js`） |
| `pet-tools.patch` | 对 `.handoff/2026-11-04/staging/migration/theme/` 原始快照的 unified diff，`patch -p0` 可从 `migration/` 根目录应用 |
| `apply-to-migration-chat.md` | 给迁移聊天的最小应用说明 |
| `tests/pure-logic.test.js` | 从 JS `@pure` 区块抽取纯函数测试（42 项） |
| `tests/static-checks.js` | 结构/契约/安全/补丁一致性静态检查（以脚本实际 SUMMARY 为准） |
| `tests/claim-interaction.test.js` | 无浏览器 DOM/网络 stub 的认领交互（6 场景/37 断言） |
| `README.md` | 本文件 |

`shasum -a 256` 校验和：

```
a2961678eb3980e565c2d21972abfff048a083b640efe698e6147180b4a27eed  pet-tools.liquid
73c333f7eeb29ee7e1d694648aab37e1891dae89dee8a35743d0ad2eb5ff3a9a  pet-tools.js
3f873bc22ccf942da7793f3482e99620dbf4ec3fbb853e84bd7bc34f3275b17d  pet-tools.patch
```

## 1. 改动摘要

**`sections/pet-tools.liquid`（原 6 行 → 26 行；section 主体仍是单行压缩结构）**

- 问卷表单 `form[data-pet-profile]` 新增 email（HTML 不写 required，由新 JS 运行时设置）与可选 `full_name`。
- 生成面板内新增「保存到 App」区块 `section.pet-tools__claim[data-pet-claim][hidden]`：
  邮箱展示、`data-claim-send`、内联 6 位 OTP 表单、`data-claim-status`。
  **没有** `data-claim-link` / `data-claim-copy` / `data-claim-url` 等链接能力节点。
- 新增 20 个 `assistant.claim_*` copy 变量；缺失或 Shopify 翻译缺失时回退英文。
- 认领区块默认 hidden，旧 JS 缓存时不会出现死按钮。

**`assets/pet-tools.js`（原 169 行 → 385 行，原生 JS、无构建、无新依赖）**

- 新增 `// @pure:start … // @pure:end` 纯函数区：邮箱/姓名规范化、6 位 OTP 校验、认领错误映射。
- 认领流程：
  - `POST /v1/claims {email}` → 读取后端真实字段 **`challenge_id`**（兼容旧响应 `claim_id`/`challengeId`），
    显示 `email_masked`/`expires_at` 并展开 OTP 表单。
  - `POST /v1/claims/{challenge_id}/verify {code}` → 成功后 `session.claimed = true`（仅本标签页）。
  - 旧版 section 缓存残留的 link 按钮：只调用一次并提示改用验证码；**永不读取响应中的 url/token，不写 DOM、不写剪贴板**。
- 错误处理：只有明确的会话失效 detail（`session_expired_or_invalid` 等）才清 guest；
  错 OTP（401 `invalid_otp`）、422、限流、过期均保留 session，允许重输/重发。
- 会话/生成/上传/推荐/购物袋逻辑未改；`X-Wagelpaw-Session`、App Proxy 前缀、sessionStorage key 不变；
  OTP 只存在输入框内存，不进 URL/localStorage/console。

## 2. DOM 契约

| 挂载点 / 字段 | 用途 |
| --- | --- |
| `input[name=email]` | 问卷 email（`/v1/sessions` body.email；认领兜底来源） |
| `input[name=full_name]` | 可选姓名 |
| `[data-pet-claim]` | 认领区块容器（缺失 → 认领逻辑整体跳过） |
| `[data-claim-email]` | 当前邮箱展示 |
| `[data-claim-send]` | 发起 OTP 认领 |
| `[data-claim-verify]` / `input[name=code]` | 内联 OTP 验证 |
| `[data-claim-status]` | 状态文本（未验证/已发送/验证成功/失败/不可用） |

## 3. 端点契约（App Proxy 前缀下同源相对路径）

| # | 方法 / 路径 | 请求 | 响应（关键字段） | 前端用途 |
| --- | --- | --- | --- | --- |
| 1 | `POST /v1/sessions` | `{profile, consent, email, full_name?}` | 原有 `session_token/expires_at/profile...` | 建游客会话 |
| 2 | `POST /v1/claims` | `{email}` + `X-Wagelpaw-Session` | 202 `{challenge_id, email_masked, expires_at, delivery, dev_code?}` | 发 OTP，进入验证码输入 |
| 3 | `POST /v1/claims/{challenge_id}/verify` | `{code}` + 会话头 | `{claimed:true, email_verified:true, claimed_session_ids:[...]}` | 完成认领 |
| 4 | `POST /v1/claims/{id}/link` | 会话头 | **本阶段 503 `claim_link_disabled`**，不返回 token/URL | 不展示；仅旧 DOM 防御 |
| 5 | `GET /v1/claims/link/{token}`、`POST /v1/claims/link/redeem` | — | **本阶段 503** | 部署方 claim 页面不启用 |

## 4. 错误处理

| HTTP / 场景 | 前端状态键 | 行为 |
| --- | --- | --- |
| 会话失效 detail（`session_expired_or_invalid` 等） | 原 `assistant.expired` | 清 session、隐藏认领区 |
| 401 `invalid_otp` / 422 验证码格式 | `claim_invalid_code` | **保留 session**，可重输 |
| 410 过期/已消费 | `claim_expired` | 保留 session，提示重发 |
| 429 尝试超限/限流 | `claim_attempts_exceeded` / `claim_rate_limited` | 保留 session |
| 503 / `delivery === "unavailable"` | `claim_unavailable` | 显示邮件不可用 |
| 404 / 405 端点未部署 | `claim_unavailable` | 显示不可用 |
| 其它 | `copy.error` | 通用错误 |

后端 `dev_code` 前端不读取、不展示；只在 development/test 显式开启时由后端 outbox 调试。

## 5. 应用到 Shopify 主题（只改两个文件）

方式 A（推荐）：在 `migration/` 根目录执行

```bash
patch -p0 < web-integration/pet-tools.patch
# 或 git apply -p0 web-integration/pet-tools.patch
```

方式 B：把 `web-integration/pet-tools.liquid` 覆盖 `sections/pet-tools.liquid`，
`web-integration/pet-tools.js` 覆盖 `assets/pet-tools.js`；不要改第三个文件。

- 主题设置 `app_proxy_path` 继续用现有值（默认 `/apps/wagelpaw`），JS 保留前缀校验。
- 不新增 CSS：认领区复用 `button`、`form-note`、`pet-tools__status` 等既有 class。
- 可选：把 20 个 `assistant.claim_*` 键补进 `locales/*.json`；不补时英文回退。
- 资源缓存：Shopify 可能继续命中旧 JS。新旧混用窗口内认领区隐藏/跳过，其余问卷与生成行为不变。

## 6. 后端部署（单实例，不另起第二套）

- 端点：`POST /v1/sessions`、`POST /v1/claims`、`POST /v1/claims/{id}/verify`。magic-link 端点保持关闭。
- 邮件投递：未配置 SMTP 时 `/v1/claims` 返回 503 `email_delivery_unavailable`；development/test 可用
  `WAGELPAW_DEV_EMAIL_OUTBOX=1` 的本地 outbox（**不发真实邮件**）。
- OTP：6 位、TTL 10 分钟、最多 5 次、60s 重发冷却、按邮箱/IP 小时限流；`user_id` 不透明，登录不自动认领。
- 部署顺序：后端 → 邮件 → 未发布主题验收 → 发布。本机不启动公网服务、不改线上站点。

## 7. 兼容说明

- **旧 JS + 新 Liquid**：email 字段无 HTML required，旧问卷行为不变；认领区 hidden。
- **新 JS + 旧 Liquid**：认领 DOM 取不到 → 认领整段跳过，其余流程不变。
- **新 JS + 旧后端**：`/v1/sessions` 明确 422 校验数组时自动去掉新字段重试一次。
- **旧 session 无 email**：提示补填，不阻塞生成。

## 8. 可验证性与真实结果（2026-11-04 本轮重跑）

Node 可执行文件由 DSH 运行时提供（`.../node/bin/node`）。日志在仓库 `var/logs/`；交付包内为脱敏副本 `var/logs-public/`：

| 检查 | 结果 |
| --- | --- |
| `node --check web-integration/pet-tools.js` | exit 0 |
| `node web-integration/tests/pure-logic.test.js` | **42 passed / 0 failed** |
| `node web-integration/tests/static-checks.js` | 以脚本 SUMMARY 为准（含 patch/README 校验和一致性） |
| `node web-integration/tests/claim-interaction.test.js` | **6 scenarios / 37 assertions / 0 failures** |
| patch 在原始主题快照副本上 `patch -p0` | 应用成功，两个文件与 `web-integration/` 逐字节一致 |

未做：真实 Shopify 主题上传/浏览器联调、线上 WordPress 修改、真实邮件发送。`docs/known-limits.md` 如实记录。
