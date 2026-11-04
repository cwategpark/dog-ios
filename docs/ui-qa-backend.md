# 本地 UI QA 后端（仅 loopback / development）

本说明只覆盖**后端联调准备**，不涉及 SwiftUI 布局或视觉设计。服务器只监听
`127.0.0.1:18766`，使用独立 SQLite、私有媒体目录与本地 dev outbox；不使用生产库、真实 SMTP、
付费生成供应商或任何公网服务。

## 启动 / 状态 / 停止

```bash
cd /Users/jbf/Documents/dog-ios
scripts/run_ui_backend.sh start     # 首次会生成 var/ui-backend/ui.env（600，含随机 dev token）
scripts/run_ui_backend.sh status
scripts/run_ui_backend.sh stop
```

- 健康：`http://127.0.0.1:18766/healthz`
- 就绪：`http://127.0.0.1:18766/readyz`（`environment=development`、`email_delivery=outbox`）
- 数据目录：`var/ui-backend/`（`ui.db`、`media/`、`email-outbox.jsonl`、`fixtures.json`）。
  该目录**不进入**交付包，也不应提交/外发。

## Fixtures（可重入）

```bash
backend/.venv/bin/python scripts/seed_ui_fixtures.py
```

脚本只允许在 `development/test` + loopback 下运行；重复执行会复用现有数据，不会重复宠物、
资产、联系人、申请或消息。当前一次性/幂等结果写在 `var/ui-backend/fixtures.json`（只有公开 ID
与测试邮箱，没有 token/OTP）：

| 项目 | 内容 |
| --- | --- |
| owner | `ios-ui-owner@example.test`，宠物 `UI Golden`，3 个资产（2 张测试图片 + 1 个 GLB 模型 fixture） |
| neighbor | `ios-ui-neighbor@example.test`，已接受的联系人，双向各有 1 条测试消息 |
| friend | `ios-ui-friend@example.test`，向 owner 发出的**待接受**联系申请 |
| discovery | 三个账号同一 0.05° 粗网格；owner `/nearby` 可见 neighbor/friend |
| 默认模型 | `/public-assets/website-golden-master.glb`，46,036,096 B，sha256 `96efb8…146b` |

owner 的宠物资料与图片通过**实际网站流程**创建：
`POST /v1/sessions`（问卷 email/profile）→ `POST /v1/uploads`（仓库 sample 图片）→
`POST /v1/claims`（email OTP）→ `POST /v1/claims/{challenge_id}/verify`。
模型 fixture 通过真实 storage/archive 代码写入同库，是**测试用途的 minimal GLB**，不是付费供应商产物，
也不是私人 orphan 图片；未读取/复制任何旧 WordPress 私有图片。

## 前端登录（不得注入 token）

模拟器/前端使用 OTP 接口登录：

1. `POST /mobile/v1/auth/email/start` body `{"email":"ios-ui-owner@example.test"}`；
2. development 响应含 `dev_code`（仅本机 dev；前端测试流程可读取）；
3. `POST /mobile/v1/auth/email/verify` body `{"challenge_id","code"}` → access/refresh；
4. 后续用 `Authorization: Bearer <access_token>` 调 `/me`、`/pets`、`/pet-home`、`/assets`、`/nearby`、
   `/contacts`、`/contacts/requests`、`/messages`。

**不要**把任何 access/refresh token 写进代码、fixtures、日志或 UI 预览；不要用内部脚本注入 token
代替 OTP。neighbor/friend 同样走 OTP（脚本已用同一接口建立测试账号）。

## 复验命令

```bash
curl -fsS http://127.0.0.1:18766/healthz
curl -fsS http://127.0.0.1:18766/readyz
curl -fsSI http://127.0.0.1:18766/public-assets/website-golden-master.glb | head
shasum -a 256 public-assets/website-golden-master.glb
backend/.venv/bin/python scripts/seed_ui_fixtures.py   # 幂等；输出 summary + manifest 路径
scripts/run_ui_backend.sh status
```

如确需清空本机 QA 数据（仅本地）：

```bash
scripts/run_ui_backend.sh stop
rm -rf var/ui-backend
scripts/run_ui_backend.sh start
backend/.venv/bin/python scripts/seed_ui_fixtures.py
```

## 边界

- 只监听 `127.0.0.1`，不启公网/反向代理。
- `WAGELPAW_SMTP_*` 为空；`EMAIL_OUTBOX` 仅本地 JSONL；`EXPOSE_DEV_OTP=1` 只在 development。
- `ARK_API_KEY` 为空，生成端点会 503，不产生付费调用；模型 fixture 不经过供应商。
- 本服务器仅供本轮本机模拟器 UI QA；不提交/不 push，不导出私有 db/outbox 到交付包。
