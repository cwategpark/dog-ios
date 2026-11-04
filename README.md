# dog-ios · 共享后端 + 新 SwiftUI 前端 + 网站认领桥接

本仓库是 dog-ios 开发线在 Mac DSH 上的当前基线。**App 无商城**：入口为邮箱验证登录后的
「宠物 / 附近 / 消息 / 我的」，图片/模型生成仍在网站完成。

- 后端：FastAPI + SQLAlchemy + Alembic（0001 原样保留 + 0002/0003/0004），共享身份、认领、资产、附近与消息。
- iOS：PawlyDemo 工程已接入本轮 SwiftUI；入口 `PawlyDemoApp → MobileRootView`，旧 demo 的
  `MainTabView`/商城页面保留源码但**不再从根入口可达**。
- 网站桥接：`web-integration/` 对 `pet-tools.liquid` / `pet-tools.js` 的增量补丁（OTP 认领，magic-link 关闭）。
- 模型：`public-assets/website-golden-master.glb`，46,036,096 B 真实 GLB（sha256 `96efb8…146b`），未改名 USDZ。
- 前端预览：WKWebView + 本地固定 three.js 0.169.0/GLTFLoader/OrbitControls；许可证
  `ios/PawlyDemo/Resources/Viewer/THREE-LICENSE.txt` 随源入包，不依赖 CDN。

## 目录

```
backend/            FastAPI 共享后端（0001 + 0002/0003/0004）
backend/tests/      145 项（身份/OTP/并发/归档补偿/迁移/附近/联系/pair mutex 等）
public-assets/      网站首页金毛 GLB 原文件（公开只读）
ios/                PawlyDemo 工程 + 新 SwiftUI（Features/Mobile）+ Core/Data + SwiftPM 单测
ios/Tests/          102 项 Swift 单测（1 项 live 无 env 时 skip）+ 20 个真实后端 fixture
web-integration/    网站 OTP 认领桥接 + diff + 测试
docs/               契约、部署、边界、前端设计/验收、OpenAPI 实生成
scripts/            loopback dev server、UI fixture seed、真实 HTTP 冒烟、OpenAPI、打包
artifacts/          UI QA 证据（构建期间由主审写入）
```

## 运行入口（iOS）

- Xcode 工程：`ios/PawlyDemo.xcodeproj`，scheme `PawlyDemo`，入口文件
  `ios/PawlyDemo/PawlyDemoApp.swift` → `MobileRootView`。
- 登录：只走邮箱 OTP `POST /mobile/v1/auth/email/start` → `/verify`；`MobileAppStore` +
  `KeychainTokenStore` 保存/轮换凭据，页面不使用旧 `AppState/APIClient` 登录，也不注入 token。
- 页面：宠物（默认金毛/个人 GLB/授权作品）、附近（MapKit 临时地图 + 手选/前台定位、默认关闭发现）、
  消息（申请/联系人/分页/拉黑）、我的（邮箱验证、用户识别码、同步、退出）。
- 真实模拟器需要 Keychain，必须：
  `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`（ad-hoc 签名）；
  `CODE_SIGNING_ALLOWED=NO` 仅用于编译，不能据此判断 Keychain/UI 运行成功。
- 本轮验收不启动模拟器测试；单元与真实 HTTP 契约见下。

## 快速启动（仅回环）

```bash
# 隔离 dev 后端（127.0.0.1:18766）+ UI QA fixtures
scripts/run_ui_backend.sh start
backend/.venv/bin/python scripts/seed_ui_fixtures.py
scripts/run_ui_backend.sh status
```

后端手工启动仍可用：

```bash
cd backend
./.venv/bin/pip install -r requirements.lock.txt
./.venv/bin/pip install --no-deps -e .
cp .env.example .env                     # 按需修改；不要提交 .env
./.venv/bin/python -m app.db init        # Alembic 升级到 head（含 0004）
./.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 18766
```

- 健康：`GET /healthz`；就绪：`GET /readyz`（不返回密钥）。
- 默认金毛：`GET /public-assets/website-golden-master.glb`。

## 网站 → 邮箱验证认领 → 手机登录 → 图库 → 附近联系

1. 网站问卷 `POST /v1/sessions`（email + 可选 full_name）→ 游客会话，不认领既有账号数据。
2. 「保存到 App」`POST /v1/claims`（`X-Wagelpaw-Session`）→ 6 位 OTP → `POST /v1/claims/{id}/verify`
   完成认领；magic-link 默认关闭（503，不返回 token/URL）。
3. iOS 登录 `POST /mobile/v1/auth/email/start` → `.../verify` → 短期 access + 可轮换 refresh。
4. 图库 `GET /mobile/v1/assets` 分页；私有下载必须 Bearer，非本人 404。
5. 宠物主页 `GET /mobile/v1/pet-home`：默认金毛 manifest；本人已归档 GLB 时 `selected=personal`，
   格式不支持时回退并给 `fallback_reason`。
6. 附近/联系/消息：发现默认关闭、粗网格 24h；申请/接受、一对一消息、拉黑双向过滤。

## 验证

```bash
cd backend && ./.venv/bin/python -m pytest -q            # 145 passed
backend/.venv/bin/python scripts/acceptance_live.py      # 真实 uvicorn + Swift 数据层真实 HTTP 联调
backend/.venv/bin/python scripts/live_http_smoke.py      # 真实 uvicorn 进程 + HTTP 全链路
python3 scripts/export_openapi.py                        # docs/openapi.json（37 paths）
cd ios && swift test --disable-sandbox                   # 102 tests / 1 skipped / 0 failures（workbench 97 + 保留 5 项回归）
xcodebuild -project ios/PawlyDemo.xcodeproj -scheme PawlyDemo \
  -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath ios/build build CODE_SIGNING_ALLOWED=NO
```

证据日志：仓库 `var/logs/`（原始）；交付包内 `var/logs-public/`（邮件/token/OTP 已脱敏）。
UI 截图与 QA 证据：`docs/screenshots/ios/`、`artifacts/frontend-qa/`、[`docs/ios-frontend-acceptance.md`](docs/ios-frontend-acceptance.md)；导入清单 `docs/frontend-import-manifest.json`。

## 边界（详见 `docs/known-limits.md`、`docs/ios-frontend-design.md`）

- 未配置生产 SMTP；本轮只使用 development outbox，不发真实邮件。
- MapKit 是当前可用临时地图，**不是 Google Maps 接入完成**；Google SDK/key 仍未配置。
- 网站已验证保存的资产可读；旧 WordPress 4 张无序 PNG **无 email/owner 归属，不能自动挂到邮箱**。
- 本机无 Docker/PostgreSQL 运行时；部署静态校验不等于生产构建/迁移成功。
- 生成供应商仍是测试替身；未接真实付费生成。真实模拟器 UI 由主审在 ad-hoc 签名下验收。
- 不 commit/push；不启动公网服务。
