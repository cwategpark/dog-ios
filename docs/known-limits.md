# 当前边界与未完成项（诚实清单）

## 已真实完成

- 后端：快照基线 69 项 + 新增 76 项（身份/OTP/并发 OTP/refresh/claim/归档补偿/清理/部分 cartoon+崩溃恢复/0003+0004 迁移/附近/联系/block pair mutex/部署静态校验/第三轮回归）= **145 passed**。
- 真实进程验证：`scripts/live_http_smoke.py` 启动真实 uvicorn（127.0.0.1 随机端口）走通 问卷→上传→OTP 认领→手机登录→图库下载→金毛 manifest→公开模型 46,036,096 B（`glTF` 魔数）→附近接口。
- 迁移：`0001` 原样保留，新增 `0002`、`0003_guest_session_pets` 与 `0004_archive_compensation_pair_locks`；从 0001 升级保留旧行、head 幂等、downgrade/re-upgrade 均测试通过。
- 安全修复：magic-link 默认关闭（503、不返回 token，避免未验证游客账户接管）；OTP 绑定 purpose/guest session 且原子尝试/消费；refresh 单事务轮换与家族撤销；认领 CAS 单胜者；block 撤销 pending；archive/cleanup 与 claim 使用条件更新协议。
- 金毛默认模型：真实文件、真实大小/sha256/格式；个人模型仅在已归档且 `glb` 格式时优先，`bin` 等回退并给 `fallback_reason`。
- 归档规则：成功任务归档全部产物；失败/needs_review 任务把已真实落盘的可信 checkpoint（如 `cartoon_ready`）以 `partial` 归档并保留失败阶段，不伪造模型成功；worker 崩溃后由 lease 恢复路径补归档；终态成功/失败 job 由 worker 循环的 `archive_pending_jobs` 有界重试补归档（首次失败/重启可恢复），cleanup 对无 archive 但 Upload.owner_id 已认领的源文件同样保护。`uploads.archived=1` + `asset_archive`；已认领资产清理受保护；未认领按 24h TTL 清理。
- 安全：OTP/链接仅存哈希、一次性消费、TTL、尝试上限、限流；邮箱只做 trim/lowercase；`user_id` 随机不透明；登录不自动认领；跨账号下载 404；移动 token 轮换/复用吊销/登出。
- 附近隐私：默认关闭；0.05° 固定网格、24h TTL、radius ≤25km；响应只有宠物公开信息 + 粗区域 + 距离档位；只用本人已保存区域查询；拉黑双向过滤。
- 网站桥接：`web-integration/` 两个主题文件增量 diff、Node 语法检查、纯逻辑 42 项、静态契约 126 项、认领交互 6 场景/37 断言、patch 在快照副本上应用后与源文件逐字节一致。
- iOS 数据层：`swift test --disable-sandbox` **102 tests / 1 skipped / 0 failures**（10 项会话并发回归；跳过项为由 `scripts/acceptance_live.py` 单独真实 HTTP 跑通的 live 测试）。SwiftUI 入口为 `PawlyDemoApp → MobileRootView`，真实模拟器使用 ad-hoc 签名；未在本轮重跑模拟器测试（主审独立验收）；证据见仓库 `var/logs/` 与交付包 `var/logs-public/`，说明 `ios/README-INTEGRATION.md`。

## 未完成 / 需要外部条件

| 项 | 状态 | 需要什么 |
| --- | --- | --- |
| 真实邮件投递 | 未接 | 生产 SMTP 凭据（环境变量）；本轮用 test/development 显式 outbox 做真实 HTTP 测试，不发真实邮件 |
| Docker / PostgreSQL | 本机不可用 | Mac 无 docker/podman/psql；`deploy/Dockerfile+compose` 已修复 context/COPY/public-assets 并静态校验，**未真实 build/up/PG 迁移**，需在有 Docker 的主机验证 |
| Google Maps | 未接通 | Mac 无 SDK/key；数据层只给可配置接入口与 `google_unconfigured` 状态，MapKit 免 key 回退可用；**不声称已接通 Google** |
| 真实商品/结账 | 不属本轮 | 新 App 无商城入口，`PawlyDemoApp` 根只到 `MobileRootView`；旧 demo 商城源码保留但不可达 |
| 真实生成供应商 | 测试替身 | 本轮不消耗额度；HTTP/持久化/worker 归档路径真实执行，产物为测试字节（非真实 AI 模型） |
| 个人 3D 模型显示 | WKWebView 预览 | 新 SwiftUI 用本地 three.js/GLTFLoader 在 WKWebView 预览授权 GLB；未在 RealityKit 原生渲染，也未做 GLB→USDZ 转换（绝不改后缀） |
| 生产云部署 | 未部署 | Ubuntu/Docker 文档已给；需一台主机 + PostgreSQL + 邮件服务 + TLS + App Proxy 配置 |
| 网站浏览器联调 | 未做 | 需要在 Shopify 未发布主题中验证；本机禁止改线上 WordPress |
| 旧 WordPress 资产 | 未迁移 | 4 张留存 PNG 无 email/owner，不能自动归属；未复制私有旧图，历史归属需新链路重新产生 |
| 附近/消息的真实用户量 | 测试 fixture | 生产默认不注入假附近人；测试用户均为显式 fixture |
| 地图/GPS 精确位置 | 不支持 | 只支持粗网格与手选区域；不申请后台/Always 定位 |

## 安全/合规注意

- 生产必须配置 SMTP 且关闭 `WAGELPAW_DEV_EMAIL_OUTBOX`、`WAGELPAW_EXPOSE_DEV_OTP`；否则 Settings 拒绝启动。
- 本仓库不含任何真实密钥；`backend/.env.example` 仅有占位。
- 移动 token 只访问本人已认领数据；跨用户/跨店拒绝；不要在前端把私有下载 URL 当公开链接缓存或分享。
