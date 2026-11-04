# 端点清单（dog-ios 共享后端）

生成来源：`scripts/export_openapi.py` → `docs/openapi.json`（37 个路径，以实生成为准）。

## 认证方式

| 通道 | 认证 |
| --- | --- |
| 网站 `/v1/*` | Shopify App Proxy 签名 + 店铺白名单（生产）；开发/测试可用 `Authorization: Bearer <WAGELPAW_DEV_TOKEN>` 并在回环使用 |
| 访客会话 | `X-Wagelpaw-Session: <session_token>`（问卷签发，数据库只存 SHA-256） |
| 移动 `/mobile/v1/*` | `Authorization: Bearer <access_token>`（短期 15 分钟，refresh 30 天，可轮换/吊销） |
| 公开资产 | 无认证，只读 |

## 网站（App Proxy，/v1）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/v1/sessions` | 问卷：`profile` + `consent` + 新增 `email`（必填新问卷）/`full_name`；只建游客会话，**不认领** |
| GET/PUT | `/v1/pet-profile` | 当前游客档案（与认领无关） |
| GET | `/v1/catalog`、`/v1/recommendations` | 原商城投影/推荐（保留，App 不用） |
| POST | `/v1/uploads` | 图片上传（重编码去 EXIF）；同时归档为 `photo`（游客期间 24h TTL） |
| GET | `/v1/uploads/{id}` | 仅 owner 可读 |
| POST | `/v1/jobs` | 生成任务，`Idempotency-Key` 必填 |
| GET | `/v1/jobs/{id}` | 仅 owner；worker 成功后归档全部产物；失败/needs_review 的可信 checkpoint 以 `partial` 归档，不伪造成功模型 |
| POST | `/v1/claims` | 显式认领当前游客会话：`{email}` → `{challenge_id, email_masked, expires_at, delivery, dev_code?}` |
| POST | `/v1/claims/{id}/verify` | `{code}` → 认领成功；challenge 必须绑定当前 `X-Wagelpaw-Session` |
| POST | `/v1/claims/{id}/link` | **本阶段关闭**：503 `claim_link_disabled`，不返回任何 token/URL |
| GET | `/v1/claims/link/{token}` | **本阶段关闭**（503/404），不再提供能力链接 |
| POST | `/v1/claims/link/redeem` | **本阶段关闭**：503 `claim_link_disabled` |
| POST | `/webhooks/shopify` | 原样保留（HMAC + 幂等） |

## 公开（/public-assets）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/public-assets/website-golden-master.glb` | 默认金毛模型；`Content-Type: model/gltf-binary`、`ETag=sha256`、真实 46,036,096 B |

## 移动（/mobile/v1）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/auth/email/start` | `{email, purpose:"login"}`；未配置投递 → 503 `email_delivery_unavailable` |
| POST | `/auth/email/verify` | `{challenge_id, code}` → user_id + access/refresh |
| POST | `/auth/refresh` | 轮换；旧 refresh 复用 → 吊销整族 |
| POST | `/auth/logout` | 204，吊销族 |
| GET | `/me` | user/public_ref/email/full_name/pets |
| GET | `/pets` | 已认领会话产生的宠物 |
| GET | `/pet-home?pet_id=` | manifest：默认金毛（static=true、真实 bytes/sha256/glb）；有本人已归档 GLB 时 `selected=personal` |
| GET | `/assets?kind=&cursor=&limit=` | 仅本人已认领资产，分页 |
| GET | `/assets/{id}/download` | Bearer；非本人 404 |
| GET | `/assets/{id}/manifest` | format/mime/bytes/sha256/source_job_id |
| POST | `/claims/link/redeem` | **本阶段关闭**：503 `claim_link_disabled`（不签发移动 token） |
| POST/GET | `/discovery` | 主动开启/关闭发现；位置量化为 0.05° 固定网格，TTL 24h，默认关闭 |
| GET | `/nearby?radius_km=` | 只用认证者已保存网格；仅宠物公开信息 + 粗区域 + 距离档位 |
| POST/GET | `/contacts/requests` | 联系申请（幂等）/收件箱·发件箱 |
| POST | `/contacts/requests/{id}/accept`、`/decline` | 接受/拒绝 |
| GET | `/contacts` | 已建立联系人（拉黑过滤） |
| POST | `/messages` | 一对一消息，`(contact_id, client_id)` 幂等；未接受/拉黑拒绝 |
| GET | `/messages?contact_id=&before=&before_id=&limit=` | 持久化分页（复合游标 `next_before`+`next_before_id`） |
| POST/GET/DELETE | `/blocks` | 拉黑/列表/解除；双向可见性与收发均拦截 |

## 错误码约定

`401` 未认证/OTP 错误；`403` 被拉黑/会话不匹配；`404` 资源不存在或非本人；`409` 状态冲突（已认领、Discovery 未开启）；`410` challenge/链接已消费或过期；`422` 参数/邮箱格式；`429` 限流/OTP 尝试超限；`503` 邮件投递/供应商/链接能力未配置。
