# iOS 前后端开发验收（2026-11-04）

## 本轮结果
Mac dog-ios 开发版具备邮箱验证登录、宠物主页、网站作品集、附近地图、联系申请、联系人聊天及账号页。没有商城、购物车或结账入口。后端由 Mac DSH 开发修复；前端视觉、SwiftUI 和 GLB viewer 由主审直接在 Mac Public 工作副本完成，随后由 DSH 原样集成回仓库。Windows 仅做文件传输、审查和结果留档。

## 数据现在能做什么
| 数据 | iOS 可用行为 | 归属/限制 |
|---|---|---|
| 问卷宠物资料与邮箱 | 同邮箱验证登录后读取宠物资料，展示稳定 user_id | 通过网站明确认领并验证邮箱；用户识别码不是登录凭据 |
| 网站保存的图片、试穿产物、cartoon、GLB | 私有作品列表、授权读取、图片/GLB 预览 | 仅本人可读；生成动作仍在网站 |
| 网站默认金毛 | 静态模型真实渲染，可手势旋转和缩放 | 原网站公开 GLB，46,036,096 B，SHA256 96efb8f20105d2280b332a13e926966c935c8e01e5ef5843be5183352283146b |
| 主动开启发现的区域 | 按粗网格查询附近宠友，申请联系后聊天 | 地图不代表实时精确位置；不采集后台轨迹 |
| 原站 4 张无邮箱/owner 关联的 PNG | 暂不能安全自动分配到某邮箱 | 没有复制私图或按猜测批量认领；需补足原游客归属证据 |

## 验证证据
- Mac 后端完整回归：145 passed；真实 uvicorn→Swift HTTP 契约联调通过。
- 后续独立复核：资产竞态/归档补偿 6 passed，迁移 3 passed；社交 pair 锁 8 passed，并独立复现确认拉黑后申请不会复活、消息被拒绝。
- 新会话并发修复：SwiftPM 97 项，0 失败，1 项 live test 在常规运行中因未设环境跳过；live HTTP 已另行执行。新增 10 项可控请求时序测试覆盖迟到 /me、401、refresh、OTP、退出和重新登录。
- 模拟器：Xcode 27.1，iPhone 18 Pro / iOS 27.0，ad-hoc 签名，完整 UI 测试最终 ui-acceptance-10.xcresult 为 TEST SUCCEEDED。
- 实际 UI 路径：输入邮箱→获取开发 OTP→正常验证登录→GLB ready→图库横向边界检查→授权图片预览→真实 MapKit→联系人/申请入口→发送消息→展示稳定用户识别码→退出登录且私有图片不再可见。
- 截图位于 docs/screenshots/ios。图中的 UI Golden、UI Neighbor、UI Friend 和 SYNTHETIC SAMPLE 都属于隔离 QA 数据，不是用户生产历史。
- 已人工检查最终金毛材质、地图、图片集与聊天截图。内嵌纹理已正确加载；图库缩略图约束在网格内，VoiceOver 将卡片作为按钮读取。
- 构建与测试日志和源码同包。未发真实邮件、未调用付费生成、未开公网、未 commit/push。

## 运行
Mac 项目：/Users/jbf/Documents/dog-ios/ios/PawlyDemo.xcodeproj，scheme PawlyDemo。
隔离开发 API：http://127.0.0.1:18766（仅 Mac/同机模拟器）。后端 scripts/run_ui_backend.sh start|status|stop，测试数据 scripts/seed_ui_fixtures.py。
联调邮箱：ios-ui-owner@example.test。开发环境请求验证码才返回 dev_code；生产不返回。iOS DEBUG 可预填开发 outbox 验证码，仍必须调用真实 verify 接口；不注入 token。
前端配置 DOGIOS_API_BASE_URL 指向 API 根域名；生产只允许 HTTPS。模拟器运行应使用正常/ad-hoc 签名，关闭签名只适用于纯编译，无法作为 Keychain 登录验收。
完整 UI 测试：xcodebuild test，destination 使用可用模拟器，建议 -parallel-testing-enabled NO -collect-test-diagnostics never。此 Mac 老 iOS 27.0 runtime 的失败 sysdiagnose 收集较慢；关闭该额外诊断不影响断言或截图附件。

## 尚未接入正式环境
- Google Maps SDK/API key 尚未配置；目前实际运行的是 Apple MapKit（中国区域底图由系统地图服务提供）。
- SMTP 尚未接真实投递；开发使用隔离 outbox。网站 web-integration 是开发改动及补丁，未声称已部署至正式 Shopify/WordPress。
- PostgreSQL 与容器在此 Mac 无运行时，只做迁移/SQL/部署静态检查；生产并发与容器上线仍须真实环境验收。
- 未完成 Apple 开发者真机签名、TestFlight、公网 HTTPS API 或正式站历史数据迁移。当前回环地址不能直接供实体 iPhone 连接。
