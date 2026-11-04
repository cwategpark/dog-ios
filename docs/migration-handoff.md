# 交接：给「网站 Shopify 迁移」聊天的最小应用说明

> 目的：网站侧继续用现有迁移工程，dog-ios 只新增身份/认领/移动/资产管理能力；**不要另建第三套独立身份数据库**，也不要本地同时跑两套后端。

## 1. 事实基线

- 本轮后端来自 2026-11-04 你方源快照（`migration/backend`，FastAPI + SQLAlchemy + Alembic，`0001_initial`），已在 dog-ios 仓库 `backend/` 落地并保留原 69 项测试。
- 新增内容：`0002_identity_assets_social` 迁移（用户/邮箱挑战/移动会话/宠物/资产归档/发现/联系/消息/拉黑）、`/mobile/v1` 移动 API、`/v1/claims*` 网站认领、`/public-assets/website-golden-master.glb`、邮件 OTP（SMTP 或本地 outbox）、资产归档与清理保护、附近/联系最小闭环。
- 旧业务接口（`/v1/sessions`、`/v1/pet-profile`、catalog/recommendations、uploads/jobs、webhook）保持兼容；`/v1/sessions` 只新增可选 `email`、`full_name` 字段与响应字段，旧客户端不传不报错。

## 2. 网站侧需要接入的 4 个端点（契约 §5）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/v1/claims` | 带 `X-Wagelpaw-Session` + `{email}` → OTP（或返回 dev_code 仅开发） |
| POST | `/v1/claims/{challenge_id}/verify` | `{code}` 完成认领（challenge 绑定当前游客会话） |
| POST | `/v1/claims/{challenge_id}/link` | **本阶段关闭**：503 `claim_link_disabled`，不返回 token；网站需去掉链接展示/复制 |

- 问卷提交时把 `email`（新问卷必填）与可选 `full_name` 一并 POST `/v1/sessions`。
- 前端补丁已在 `web-integration/`：`pet-tools.liquid` / `pet-tools.js` 的增量 diff 与纯逻辑/静态检查。应用方式：`cd <migration 仓库> && patch -p0 < dog-ios/web-integration/pet-tools.patch`（或直接替换两文件，README 有字段/事件说明）。
- 旧客户端兼容：新 Liquid 不强制 `required`（由新 JS 运行时设置），旧 DOM 缺失时新 JS 静默跳过；旧后端对未知字段 422 时前端自动去掉新字段重试。

## 3. 部署要点（只部署一套后端）

1. 使用 dog-ios `backend/` 作为唯一共享后端源码（或把 0002 迁移 + 新模块合并回你方迁移仓库，二者不要各跑一份）。
2. 数据库执行 `python -m app.db init`（0001 → 0002 增量，保留原数据）。
3. 配置 `WAGELPAW_PUBLIC_BASE_URL`、SMTP（或生产关闭 dev outbox 并接真实邮件）、`WAGELPAW_PUBLIC_ASSETS_DIR` 指向含金毛 GLB 的目录。
4. App Proxy 仍只把店铺请求转发到该后端；移动 App 直连 `/mobile/v1`，不依赖 App Proxy、不保存店铺 secret。
5. iOS 数据层在 `ios/PawlyDemo/Core/Data`，baseURL 通过 `DOGIOS_API_BASE_URL` / Info.plist 注入。

## 4. 不可以做的事（本轮已明确）

- 不要把本机/线上 WordPress 的 4 张留存 PNG 复制进新资产库来「伪造历史联通」：它们没有 email/owner 归属，无法自动归属；历史资产只能通过新的「邮箱验证 → 认领」链路产生归属。
- 不要为网站和 App 各建一套身份表/游客会话表；`users.email_normalized` 必须是唯一身份映射。
- 不要把 OTP 写入日志/URL/响应（生产）；不要在前端硬编码店铺 secret 或 dev token。

## 5. 需要你方确认的对接点

- 本阶段只走 OTP：网站提交 `POST /v1/claims` 后让用户在页面输入验证码即可；不再生成/展示 magic-link。
- 迁移聊天后续若修改问卷字段，需保持 `email` 规范化（trim/lowercase，不删点/不删 +tag）并在提交前做前端校验。
- 资产（图/穿搭/GLB）最终只在后端 `asset_archive` 归档；网站旧生成结果迁移需要另开数据迁移任务（本轮未做旧站数据搬运）。
