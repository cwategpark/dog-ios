# Pawly iOS Demo (SwiftUI)

Pawly 的 iOS 演示 App：连接本地 demo 后端 `http://127.0.0.1:8788`，覆盖「登录 / 认领 → 首页宠物与推荐 → 商城 → 商品详情 → 购物车 → 演示 Checkout → 生成宠物形象 → 我的」完整主链路。所有商品、价格、推荐文案、失败/降级状态都来自后端 API，不在客户端写死商品内容或价格。

- bundle id：`app.pawly.demo`
- 部署目标：iOS 17.0（模拟器 iPhone 17 / iOS 27 验证）
- Xcode：16+（工程使用 `objectVersion = 77` 的 `PBXFileSystemSynchronizedRootGroup`，源码文件夹自动同步进 target）
- 语言：zh-CN / es / en；主题：system / light / dark（读取后端 appearance tokens）

## 工程结构

```
pawly/ios/
  PawlyDemo.xcodeproj/                 # 工程（含共享 scheme）
  Info.plist                           # ATS 允许本地 HTTP（仅 demo）
  PawlyDemo/
    PawlyDemoApp.swift                 # App 入口、RootView（主题注入、Toast、启动）
    Core/
      APIClient.swift                  # async/await URLSession 封装：Bearer、X-Pawly-Language、ETag/If-Match、Idempotency-Key、错误体解析
      Models.swift                     # DTO（snake_case 解码；含本地化文本/金额/变体/任务/外观等）
      APIError.swift                   # 统一错误类型（401/409/412/422/网络）
      AppState.swift                   # 会话、Keychain、me/pets/偏好/外观/购物车、语言与主题、Toast
      Keychain.swift                   # Security 封装，token 存钥匙串
      Theme.swift                      # appearance tokens → SwiftUI 配色（含深色 key 与兜底）
      L10n.swift                       # zh-CN / es / en 本地字典型文案
    Features/
      Login/LoginView.swift            # 演示客户登录 / 游客 / 6 位认领码
      MainTabView.swift                # 4 Tab + 购物车角标 + 全局购物车 sheet
      Home/HomeView.swift              # 问候、宠物切换、宠物大卡、推荐、精选
      Shop/ShopView.swift              # 搜索（debounce）、受众/场景/类目筛选、分页网格
      Shop/ProductDetailView.swift     # 图集、选项组合、可售性、价格/原价、3D 能力、加购
      Cart/CartView.swift              # 购物车行、数量±、删除、演示优惠、Checkout（confirm 后才已付）
      Generate/GenerateView.swift      # 样张/相册、两项同意、上传→complete→任务→1s 轮询→poster/GLB/manifest/USDZ 降级→头像写回
      Profile/ProfileView.swift        # 资料 PATCH（If-Match/412）、宠物、同意记录、语言/主题、appearance、隐私请求、退出
      Shared/                          # 卡片/按钮/Chip/AsyncImage/Toast/空态等组件、添加宠物
    Resources/
      Assets.xcassets/                 # AppIcon（1024）、BrandIcon、AccentColor
      Samples/photo-cat.jpg 等         # 内置合成样张 + 演示头像
```

## 构建 / 运行

```bash
# 1) 先启动 demo 后端（另一个进程，127.0.0.1:8788）
cd pawly/backend && node src/main.ts   # 具体命令见 backend README

# 2) 构建
cd pawly
xcodebuild -project ios/PawlyDemo.xcodeproj -scheme PawlyDemo \
  -destination 'platform=iOS Simulator,id=0DF598F0-A8C6-4D26-ADD2-0EF27B5EDE04' \
  -derivedDataPath ios/build build CODE_SIGNING_ALLOWED=NO

# 3) 安装 / 启动
xcrun simctl install 0DF598F0-A8C6-4D26-ADD2-0EF27B5EDE04 ios/build/Build/Products/Debug-iphonesimulator/PawlyDemo.app
xcrun simctl launch 0DF598F0-A8C6-4D26-ADD2-0EF27B5EDE04 app.pawly.demo

# 4) 截图
xcrun simctl io 0DF598F0-A8C6-4D26-ADD2-0EF27B5EDE04 screenshot pawly/docs/screenshots/ios-home.png
```

也可直接用 Xcode 打开 `pawly/ios/PawlyDemo.xcodeproj`，选择 iPhone 模拟器运行（bundle id 已固定，签名关闭即可跑模拟器）。

## API 对接

统一走 `pawly/docs/DEMO_CONTRACT.md` 的 `/v1` 端点（不调用契约外接口）：

| 场景 | 端点 |
|---|---|
| 登录 / 游客 / 认领 | `POST /v1/auth/exchange`（固定 `demo-customer-token-2026`）、`POST /v1/auth/guest`、`POST /v1/auth/claim`、`POST /v1/auth/logout` |
| 恢复会话 | `GET /v1/me`（含 profile / preferences / pets / `demo_latest_recommendation_id`） |
| 资料 / 偏好 / 同意 | `GET/PATCH /v1/me/profile`（If-Match）、`GET/PATCH /v1/me/preferences`（If-Match）、`GET /v1/me/consents`、`POST /v1/consents` |
| 宠物 | `GET/POST /v1/pets`、`GET /v1/pets/{id}` |
| 推荐 / 商品 | `GET /v1/recommendations/{id}`、`GET /v1/products`（搜索/筛选/排序/分页）、`GET /v1/products/{gid}`（URL 编码） |
| 购物车 / 结账 | `POST /v1/carts/resolve`、`GET /v1/carts/{id}`、`POST /v1/carts/{id}/lines`、`DELETE /v1/carts/{id}/lines/{line_id}`、`POST /v1/carts/{id}/checkout`、`GET/POST /v1/checkout-sessions/{token}(/confirm)`、`GET /v1/orders/{id}` |
| 上传 / 生成 | `POST /v1/uploads` → `PUT ticket.url` → `POST /v1/uploads/{id}/complete`、`GET /v1/config/templates`、`POST /v1/generation-jobs`（`Idempotency-Key` + 两个 granted consent_event_id）、`GET /v1/generation-jobs(/{id})`、`POST .../cancel` |
| 外观 / 隐私 / 健康 | `GET /v1/config/appearance?channel=ios`、`POST /v1/privacy/requests` + `GET /v1/privacy/requests/{id}`、`GET /healthz` |

要点：

- **认证**：`Authorization: Bearer <pawly_...>`，token 存 Keychain；启动有 token 时 `GET /v1/me` 恢复，401 清理会话回登录页。
- **语言**：每个请求带 `X-Pawly-Language: zh-CN|es|en`；切换语言后重拉商品/推荐，并与 `PATCH /v1/me/preferences` 同步（If-Match）。
- **主题**：读取 appearance `tokens`（浅色 key 为基础、`.dark` 后缀为深色）解析成 SwiftUI 颜色；读取失败用内置兜底色板。用户偏好 `system/light/dark` 通过 `preferredColorScheme` 应用。
- **并发/幂等**：`PATCH` 带 `If-Match`（412 时拉取最新 revision 并提示冲突）；创建型 POST 带 `Idempotency-Key`；金额一律用 Decimal 字符串，不用浮点。
- **错误**：401 → 回登录；409 → 状态冲突提示；412 → 冲突提示 + 刷新；422 → 展示 `field_errors`/字段错误；网络失败可重试。
- **媒体**：`/media/*` 直接 AsyncImage；私人资产用任务输出的 `access_url` 或 `POST /v1/assets/{id}/access` 短期签名 URL，过期重新申请。

### 生成流程（与后端联调顺序一致）

1. 选择宠物 + 内置样张（或 PhotosPicker 相册）
2. 两项本地同意开关（photo_processing / model_generation，默认开，未全选不可提交）
3. `POST /v1/consents`（Idempotency-Key）申请两个 granted consent events（已存在则复用）
4. `POST /v1/uploads` → `PUT` 二进制 → `POST /v1/uploads/{id}/complete`
5. `GET /v1/config/templates` 选对应物种模板 → `POST /v1/generation-jobs`（202）
6. 每 1s `GET /v1/generation-jobs/{id}`，展示 status/stage/progress；succeeded 后展示 poster（签名 URL）、GLB ready、manifest ready、USDZ failed + 「静态形象与购买仍可继续」降级文案
7. 自动 `GET /v1/pets` 刷新宠物 `avatar_url`，并刷新生成历史

## 演示流程（建议）

1. **登录页**：选择语言 →「以演示 Shopify 客户登录」（`demo@pawly.invalid` / 陈小雨 / Milo 与阿福）；或「游客浏览」后「我的」里看认领码；或在登录页输入网站问卷得到的 6 位认领码，先 exchange demo 客户再 claim。
2. **首页**：Milo 宠物大卡（头像/品种/月龄/体重）、「为 Milo 推荐」（来自推荐 API，reason 文案来自后端）、精选商品网格；宠物 chips 切换阿福（金毛/large/体尺）。
3. **商城**：搜索、受众（猫/狗/主人）、场景、类目筛选、排序、分页；点整卡进详情。
4. **商品详情**：图集、本地化选项（不可售置灰）、价格/原价、fit_summary、3D 能力徽章（GLB 就绪 / USDZ 暂不可用）、数量、加购（Idempotency-Key + customization_id=pet_id）。
5. **购物车**：从各页右上角购物袋进入；数量±、删除、演示优惠预览；「演示 Checkout」→ 应用内展示摘要 →「模拟支付完成」调用 confirm 后才显示「订单已支付（演示）」；关闭不会变成已付。
6. **生成**：生成成功后宠物头像更新，首页大卡同步。
7. **我的**：编辑资料（If-Match，412 冲突提示）、宠物体尺、同意记录、语言/主题切换、appearance release/revision、隐私导出/注销演示（状态轮询）、退出登录（撤销会话 + 清 Keychain 与私人缓存）。

## 截图清单（真实模拟器运行）

位于 `pawly/docs/screenshots/`：

| 文件 | 页面 |
|---|---|
| `ios-login.png` | 登录/品牌页（演示客户 / 游客 / 认领码 / 语言切换） |
| `ios-home.png` | 首页（Milo + 推荐 + 精选） |
| `ios-shop.png` | 商城（搜索/筛选/网格） |
| `ios-product.png` | 商品详情（大图/标题/价格/适配/3D 徽章） |
| `ios-product-options.png` | 商品详情下滑（变体选项 + 3D 能力） |
| `ios-cart.png` | 购物车（行/数量/演示优惠/Checkout） |
| `ios-checkout-paid.png` | 演示 Checkout confirm 后「订单已支付（演示）」 |
| `ios-generate.png` | 生成页（宠物/样张/两项同意） |
| `ios-generate-success.png` | 生成成功（poster/GLB ready/manifest ready/USDZ 不可用降级 + 历史） |
| `ios-profile.png` | 我的（资料/宠物/同意记录） |
| `ios-profile-settings.png` | 我的下滑（语言/主题/外观配置/隐私/退出） |
| `ios-home-dark.png` | 深色模式（bonus） |
| `ios-shop-es.png` | 西班牙语商城（bonus） |

## 调试用启动参数（仅 DEBUG）

仅用于自动化截图/联调，正式演示直接点按即可：

```bash
xcrun simctl launch <udid> app.pawly.demo -demoLogout -demoAutoLogin -screen home|shop|product|cart|generate|profile
#  -theme dark|light|system   -lang zh-CN|es|en
#  -productScroll options|caps   -profileScroll settings|appearance
#  -runGenerate（自动走完生成）  -runCheckout（自动结账并 confirm）
```

## 已知限制（Demo 边界）

- 登录使用固定 demo token 代替真实 Shopify OAuth/PKCE；未接入 Customer Account API。
- 商品/价格/库存/购物车/订单均为本地种子投影与模拟交易；**未接入 Shopify**，未接真实支付/Webhook。
- AI/3D 生成为后端定时状态机 + 占位 poster/GLB/manifest；USDZ 固定不可用（能力降级展示）；未接入真实 AI 供应商与 USDZ 转换。
- appearance 只读取单个 release 的 tokens，无发布/预览/回滚管理。
- 隐私请求只记录状态，不执行真实删除；订单财务记录保留。
- 3D 模型未在原生 RealityKit 中渲染，只展示能力徽章/输出就绪状态（demo 范围）。
- 购物车数量减一通过「删除该行 + 以剩余数量重新加购」实现（契约没有 quantity PATCH 端点）。
- 推荐依赖 `/v1/me` / Pet 的 `demo_latest_recommendation_id`；无推荐记录时回退精选商品并注明。
- 截图自动化参数仅在 DEBUG 生效，Release 行为不受影响。
