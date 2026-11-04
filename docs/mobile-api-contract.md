# dog-ios · 共享后端与 iOS 数据层集成契约（v1）

> 本文件是 dog-ios 本轮实现的内部契约，供后端 / iOS / 网站桥接三方并行开发。
> 后端最终以 `docs/openapi.json`（由 `scripts/export_openapi.py` 从 FastAPI 实生成）与实现测试为准；
> 若本文与 OpenAPI 有出入，以 OpenAPI 为准并由后端负责人修订本文。

## 0. 边界

- App 本阶段**无商城**：不创建购物车/订单，不依赖 Shopify 商品/结账。
- 身份：网站问卷（无需 Shopify 登录）录入 `email`（必填）+ `full_name`（可选），后端把规范化邮箱映射到**稳定不透明 `user_id`**。`user_id` 只用于业务归属，**不是登录凭据**。
- 邮箱归属必须 OTP 证明；**只登录不会自动认领**任何填过同邮箱的游客会话。认领是显式动作：
  - 网站浏览器内：`POST /v1/claims` + `POST /v1/claims/{id}/verify`（guest token + OTP）；
  - magic-link 认领链接本阶段**默认关闭**（503 `claim_link_disabled`，不向发起者返回 token/URL）。
- 移动端认证不依赖 Shopify App Proxy / 店铺 secret；Swift 端不保存任何 Shopify 密钥或开发 token。
- 默认宠物模型 = 网站首页金毛 `public-assets/website-golden-master.glb`（46,036,096 B，GLB，不作 USDZ 改名）。
- 附近/联系：默认关闭发现；位置只保存粗网格；响应不含邮箱或精确 GPS。

## 1. 通用

- 移动前缀：`/mobile/v1`；网站前缀：`/v1`（App Proxy 签名）与 `/public-assets/*`（公开只读）。
- 移动认证头：`Authorization: Bearer <access_token>`（短期，默认 15 分钟）。
- JSON：snake_case；金额无（无商城）。
- 错误格式：`{"detail": "<code>"}`，HTTP 401/403/404/409/410/422/429/503。
- `email` 规范化：trim + lowercase（不做 Gmail 点号/`+tag` 归一），长度 ≤254，唯一约束在规范化列上。

## 2. 移动认证（OTP）

### POST /mobile/v1/auth/email/start
body: `{"email": "a@b.com", "purpose": "login"}`
- 移动登录只接受 `purpose="login"`；网站认领使用独立的 `/v1/claims` OTP，不能拿认领码登录。
- 202: `{"challenge_id", "purpose", "email_masked", "expires_at", "cooldown_seconds", "delivery": "email"|"outbox"|"unavailable", "dev_code": "123456"(仅 development/test 且显式开启)}`
- 生产未配置 SMTP → 503 `email_delivery_unavailable`；不得在日志/响应泄露 OTP。

### POST /mobile/v1/auth/email/verify
body: `{"challenge_id", "code"}`
- 200: `{"user_id", "email", "email_verified_at", "access_token", "refresh_token", "access_expires_at", "refresh_expires_at", "claimed_session_ids": []}`
- OTP：6 位数字、HMAC 哈希存储、TTL 10 分钟、最多 5 次尝试、成功原子消费、60s 重发冷却、每邮箱/每 IP 小时限流。

### POST /mobile/v1/auth/refresh
body: `{"refresh_token"}` → 新 access/refresh（轮换）。旧 refresh 再用 → 401 并吊销该会话族。

### POST /mobile/v1/auth/logout
`Authorization` + body `{"refresh_token": "..."}` → 204，吊销。

## 3. 移动数据

### GET /mobile/v1/me
→ `{"user_id", "public_ref", "email", "full_name", "email_verified_at", "created_at", "pets": [Pet]}`

### GET /mobile/v1/pets
→ `{"pets": [{"pet_id", "name", "species", "breed", "age_months", "avatar_url"|null}]}`
- 仅返回已认领会话产生的宠物；同一邮箱多个游客会话未认领前不并入。

### GET /mobile/v1/pet-home?pet_id=...
→ 清单：
```json
{
  "pet_id": "...",
  "manifest_version": 1,
  "selected": "default" | "personal",
  "avatar_url": null,
  "default_model": {
    "role": "default", "static": true, "is_default": true,
    "format": "glb", "mime": "model/gltf-binary",
    "bytes": 46036096,
    "sha256": "96efb8f20105d2280b332a13e926966c935c8e01e5ef5843be5183352283146b",
    "url": "/public-assets/website-golden-master.glb",
    "source": "website-golden-master"
  },
  "personal_model": null
}
```
- 个人模型仅当存在已归档、格式受支持（`glb`）且属于该用户/宠物的模型资产时才出现；`selected` 随之为 `personal`。
- 个人模型 `url` = `/mobile/v1/assets/{asset_id}/download`（需 Bearer；数据层负责带授权取字节）。

### GET /mobile/v1/assets?kind=&cursor=&limit=
→ `{"items": [{"asset_id","kind","format","mime","bytes","sha256","source_job_id"|null,"created_at","download_url"}], "next_cursor": null}`
- kind ∈ `photo|tryon|outfit|cartoon|model|manifest`；仅本人已认领资产；分页游标不透明。

### GET /mobile/v1/assets/{asset_id}/download
Bearer；非本人 → 404；返回字节流（`Content-Disposition`），不缓存。

### GET /mobile/v1/assets/{asset_id}/manifest
→ `{"asset_id","format","mime","bytes","sha256","source_job_id","available": true}`

## 4. 发现 / 附近 / 联系 / 消息

### POST /mobile/v1/discovery
body: `{"enabled": true, "region": {"lat": 31.23, "lon": 121.47}, "radius_km": 5}`
- 位置在服务端立即量化为固定网格（0.05°，≈5.5km，仅保存网格与中心整数）；TTL 24h；`radius_km` 上限 25；默认关闭。
- `enabled: false` → 202 关闭。响应 `{"enabled", "grid", "expires_at", "radius_km"}`。

### GET /mobile/v1/nearby?radius_km=
→ `{"items": [{"public_ref","pet": {"name","species","breed","age_months","avatar_url"},"coarse_region": {"grid": "x:y", "label": "..."},"distance_bucket": "lt_1km|1_3km|3_10km|10_25km"}], "radius_km", "generated_at"}`
- 服务端只用认证者**已保存**的网格查询（拒绝任意中心参数），排除自己/过期/未开启/被拉黑。

### POST /mobile/v1/contacts/requests `{"target_public_ref", "message"?}`
→ `{"request_id", "status": "pending", "created_at"}`（幂等：同向 pending 复用；被对方拉黑 403）。

### GET /mobile/v1/contacts/requests?direction=incoming|outgoing
→ `{"items": [{"request_id","direction","user_public_ref","pet", "status", "created_at"}]}`

### POST /mobile/v1/contacts/requests/{request_id}/accept | /decline → `{"contact_id", "status"}`

### GET /mobile/v1/contacts → `{"items": [{"contact_id","user_public_ref","pet","since"}]}`

### POST /mobile/v1/messages `{"contact_id", "body", "client_id"}`
→ `{"message_id","contact_id","body","created_at","client_id"}`；同 `(contact_id, client_id)` 幂等；非成员 404；被拉黑 403；body ≤ 2000。

### GET /mobile/v1/messages?contact_id=&before=&before_id=&limit=
→ `{"items": [{"message_id","sender":"me"|"them","body","created_at"}], "next_before": <float|null>, "next_before_id": <string|null>}`
- 游标是 `(created_at, id)` 复合键：翻页必须同时带 `before` + `before_id`，否则同一秒内的消息可能漏页/重复。

### POST /mobile/v1/blocks `{"target_public_ref"}`；DELETE /mobile/v1/blocks/{public_ref}；GET /mobile/v1/blocks
→ `{"items": [{"user_public_ref", "created_at"}]}`（解除拉黑用 `user_public_ref`）
- 反向互申请自动接受时返回 `{"request_id", "contact_id", "status":"accepted", "auto_accepted":true}`；block 会撤销双方 pending 申请。
- block 后：双方 nearby 不可见、请求/消息拒绝。

## 5. 网站认领（App Proxy / 公开链接）

### POST /v1/sessions（扩展，向后兼容）
body 增加 `"email"`（新问卷必填）与可选 `"full_name"`；响应不变 + `"profile": ...`。
- 只创建/关联**未验证**用户行（邮箱唯一），绝不把该用户既有已认领数据返回给游客。
- 未传 email 的旧客户端仍可建会话（认领时再要求邮箱）。

### POST /v1/claims（需 App Proxy 签名 + `X-Wagelpaw-Session`）
body `{"email"}` → 202 `{"challenge_id","email_masked","expires_at","delivery","dev_code?"}`
### POST /v1/claims/{challenge_id}/verify `{"code"}` → `{"claimed": true, "email_verified": true, "claimed_session_ids": [...]}`
### Magic-link（本阶段默认关闭）

> 2026-11-04 安全修复：为避免未验证游客拿到可兑换能力链接造成账户接管，本阶段**关闭** magic-link 可选流程。
> `POST /v1/claims/{id}/link`、`POST /v1/claims/link/redeem`、`POST /mobile/v1/claims/link/redeem` 均返回 **503 `claim_link_disabled`**，
> 且任何 API 响应都不包含可兑换 token/URL。邮箱认领统一走 OTP：`POST /v1/claims` → `POST /v1/claims/{id}/verify`。
> `Settings.claim_link_enabled` 默认 `False`；如未来重新启用，必须做到「仅邮件投递、API 不返回 token、发信限频、一次性短 TTL、有落地页」，并另开安全评审。

## 6. 资产归档规则（后端内部）

- 生成任务/上传成功后归档：`asset_archive(guest_session_id, user_id|null, job_id, upload_id, kind, format, mime, bytes, sha256, source_role, provenance)`。
- `uploads.archived=1`；清理任务跳过已归档且 `expires_at` 被延长（认领后 +10 年）的文件。
- 未认领：资产随 guest session 原 24h TTL 清理；已认领：永久保留；认领前/后生成都可归档。
- 失败/needs_review 任务不伪造成功模型；已真实落盘的可信 checkpoint（如 `cartoon_ready`）以 `partial` 归档，worker 崩溃后由 lease 恢复路径补归档。幂等归档（同 job+role+upload 唯一）。

## 7. iOS 数据层（交付给 Swift）

- 文件：`ios/PawlyDemo/Core/Data/`（自动进 target）＋ SwiftPM 测试包 `ios/Package.swift`。
- `AppConfig`：baseURL 优先级 `ProcessInfo.env["DOGIOS_API_BASE_URL"]` → Info.plist `DogiosAPIBaseURL` → `http://127.0.0.1:18766`；生产要求 https（非 localhost 且非 https 时 `AppConfigError.insecureBaseURL`）。
- `GoogleMaps` 可选：`#if canImport(GoogleMaps)` 隔离；无 key 时 `MapProviderStatus.googleUnconfigured`；回退 MapKit provider，返回 `provider: "mapkit"`。不得申请后台/Always 定位；只用 when-in-use。
- 无商城依赖、无 Shopify SDK。

## 8. 网站桥接（web-integration/）

- 仅增量修改 `pet-tools.liquid` + `pet-tools.js`：问卷新增 email（可选姓名）、"保存到 App"认领区（**仅 OTP**，magic-link 关闭）、状态提示；保持原布局与视觉风格。
- 旧客户端不传新字段必须不报错；生成 URL/会话头（X-Wagelpaw-Session）复用；不硬编码 token。
