# iOS 数据层集成说明（Dogios · 2026-11-04）

本文件说明本轮新增的 iOS 数据层：结构、配置注入、测试与构建方式，以及明确的能力边界。
**本轮不包含 UI/视觉/布局/SwiftUI 页面**，也不引入商城、支付或 Shopify SDK 依赖。

## 1. 本轮交付范围

| 交付 | 路径 |
|---|---|
| 数据层源码 | `ios/PawlyDemo/Core/Data/`（15 个文件，自动进入 App target） |
| SwiftPM 包（库 + 测试） | `ios/Package.swift` |
| 单元测试 | `ios/Tests/DataLayerTests/`（135 个 XCTest，含 1 个 live skip；URLProtocol stub） |
| 账号同步数据层 | `LogisticsService.swift`、`PrivateModelsService.swift`，见下方 |
| 工程配置 | `ios/Info.plist`、`ios/PawlyDemo.xcodeproj/project.pbxproj` |
| 本文档 | `ios/README-INTEGRATION.md` |

原有演示工程（`PawlyDemo/Features/**`、`Core/{APIClient,Models,AppState,Keychain,Theme,L10n}.swift`、
`Resources/**`）是原 PawlyDemo 演示基线，**本轮未改动、不属本轮交付**；数据层与其共存于同一 target。

## 2. 数据层结构

```
PawlyDemo/Core/Data/
  AppConfig.swift        配置：baseURL 优先级 + https 规则 + Google key + 地图能力状态
  DTO.swift              全部 Codable DTO（snake_case、Unix 秒数字为主并兼容 ISO8601、可选/未知字段安全）
  MobileAPIError.swift   状态码 → 语义错误（含网络/解码/取消单列）
  TokenStore.swift       TokenStoring 协议 + Keychain 实现 + 内存测试替身
  MobileAPIClient.swift  URLSession async/await、Bearer、401 单飞刷新、错误映射
  IdentityService.swift  email/start、email/verify、refresh、logout、me
  AssetService.swift     资产分页、需认证的私有下载、manifest
  PetHomeService.swift   pet-home 清单 + personal/default 选择规则
  LogisticsService.swift 账号订单物流分页
  PrivateModelsService.swift 账号模型注册表与 archive 下载
  SocialProfileService.swift 公开昵称/头像
  DiscoveryService.swift 发现开关、区域上报、附近列表（无地图依赖）
  ContactService.swift   好友申请/接受/拒绝、联系人、拉黑
  MessageService.swift   私聊幂等发送与分页
  LocationProviding.swift 位置协议 + CoreLocation provider + MapKit/Google provider 能力状态
```

`ios/Package.swift` 的库 target 直接指向 `PawlyDemo/Core/Data`（同一份源码，不复制），
测试 target 为 `ios/Tests/DataLayerTests`；`Tests/` 不在 `PawlyDemo` 同步组内，不会进入 App target。

## 3. 配置注入

### 3.1 API baseURL

解析优先级（`AppConfig.resolveBaseURL`）：

1. `ProcessInfo.processInfo.environment["DOGIOS_API_BASE_URL"]`
2. Info.plist `DogiosAPIBaseURL`（工程里为 `$(DOGIOS_API_BASE_URL)`）
3. 默认 `http://127.0.0.1:18766`

规则：

- 非 localhost 且非 https → `AppConfigError.insecureBaseURL`（生产必须 https）。
- `http` 仅允许 `localhost` / `127.0.0.1` / `[::1]` / `0.0.0.0`。
- 空字符串、未展开的 `$(...)` 构建设置占位符会被忽略并回退下一优先级（防止构建设置缺失时把占位符当 URL）。
- 直接 `AppConfig(baseURL:googleMapsAPIKey:)` 同样走 https 校验，便于显式覆盖/测试。

工程内位置：

- `ios/Info.plist`：`DogiosAPIBaseURL = $(DOGIOS_API_BASE_URL)`。
- `ios/PawlyDemo.xcodeproj/project.pbxproj`：target Debug/Release 的
  `DOGIOS_API_BASE_URL` 当前指向 `https://quebec-week-preparing-treating.trycloudflare.com`。
  应用运行时仍可用环境变量或用户级 xcconfig 覆盖；源码 fallback 为 `http://127.0.0.1:18766`。

本机/生产覆盖方式（**不要改提交的默认值**）：

```bash
# 构建期覆盖
xcodebuild -project ios/PawlyDemo.xcodeproj -scheme PawlyDemo \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath ios/build build CODE_SIGNING_ALLOWED=NO \
  DOGIOS_API_BASE_URL=https://api.example.com

# 运行期覆盖（Xcode：Edit Scheme → Run → Arguments → Environment Variables）
DOGIOS_API_BASE_URL=https://api.example.com
```

真实地址/密钥建议放在本机（不入库）的 xcconfig 或用户级 build setting 中，例如
`~/Library/Developer/Xcode/UserData/xcconfig/…`；仓库内只保留可公开的 localhost 默认值与空 key。

### 3.2 Google Maps key

- `ios/Info.plist`：`GoogleMapsAPIKey = $(GOOGLE_MAPS_API_KEY)`。
- `project.pbxproj`：target Debug/Release `GOOGLE_MAPS_API_KEY = ""`（**真实 key 不入库**）。
- 读取优先级：环境变量 `GOOGLE_MAPS_API_KEY` → Info.plist `GoogleMapsAPIKey`；缺失/空即 nil。
- 本轮**未集成 Google Maps SDK**（Package.swift 与 Xcode 工程均无该依赖），因此：

```swift
AppConfig.mapProviderStatus == .googleUnconfigured
AppConfig.preferredMapProviderID == "mapkit"   // 回退 MapKit
```

`#if canImport(GoogleMaps)` 隔离在 `LocationProviding.swift`：将来加入 SDK 时，无需改调用方，
有 key 才会变成 `.googleConfigured`。**本轮不渲染地图**（属 UI 层）。

### 3.3 定位

- 只申请 **when-in-use**（`requestWhenInUseAuthorization()`），不申请 Always、不开启后台更新、不存轨迹。
- `ios/Info.plist` 已加 `NSLocationWhenInUseUsageDescription` 供系统弹窗使用。
- 拒绝定位不影响其它能力（附近可手选城市；数据层只上报一次坐标，服务端量化为 0.05° 网格）。

## 4. 关键行为

- **认证头**：`requiresAuth` 请求自动加 `Authorization: Bearer <access_token>`。
- **401 处理**：用 refresh token **单飞（single-flight）** 刷新（并发 401 只发一次 `/auth/refresh`），
  成功后原请求重试一次；refresh 失败清空 token 并抛 `MobileAPIError.unauthorized`。
- **不做自动重试**：非幂等请求（消息发送等）不自动重试；唯一重试是 401 刷新后重放原请求（保留原 body / `client_id`）。
- **错误映射**（`MobileAPIError.Kind`）：401 unauthorized、403 forbidden、404 notFound、409 conflict、
  410 gone、422 validation、429 rateLimited（解析 `Retry-After`）、503 unavailable、5xx server；
  网络错误 `.network`、解码错误 `.decoding`、取消 `.cancelled` 单独成类。
- **私有资产下载**：`AssetService.download(assetId:)` 必须带 Bearer，直接返回 `Data`；
  绝不把 `download_url` 当公开链接分发；默认 session 关闭 local cache（私有字节不落缓存）。
- **pet-home**：个人模型**仅当存在且 `format == "glb"`** 才优先；否则用默认模型并给出
  `fallbackReason`（`personal_model_missing` / `unsupported_personal_format`），不伪造「已生成」。
- **发现/附近**：`DiscoveryService` 不 import MapKit/GoogleMaps；`nearby` 只带 `radius_km`，不接受任意中心参数；
  `radius_km` 客户端收敛到 1…25。
- **消息**：`client_id` 幂等键，body 1…2000 字（超长本地拒绝，不发请求）。
- **Token**：`KeychainTokenStore`（service/account 可配置，整包 JSON 存 access+refresh）+
  `InMemoryTokenStore` 测试替身；数据层不把 token 写入 UserDefaults/日志。

### 命名冲突处理（重要）

数据层与既有演示基线同属一个 App target，故两处命名做了调整并在代码中注释原因：

| 契约/要求名 | 实际名 | 原因 |
|---|---|---|
| `MeResponse` | `MobileMeResponse` | 旧演示 `Core/Models.swift` 已有同名 `MeResponse` |
| `APIError` | `MobileAPIError` | 旧演示 `Core/APIError.swift` 已有同名 `APIError` |
| 文件 `APIError.swift` | `MobileAPIError.swift` | 与旧文件同 basename 时 `SWIFT_EMIT_LOC_STRINGS` 会产生重复 `.stringsdata`，构建失败 |

其余文件名与 DTO/服务类型名均按契约命名。

## 5. 运行测试与构建

### 5.1 单元测试（macOS，无需模拟器，不连真实网络）

```bash
cd ios && swift test
# 或
swift test --disable-sandbox --package-path ios
```

- 覆盖：DTO 解码（缺可选字段/未知字段/ISO8601）、baseURL 优先级与 https 规则、Bearer 头、
  401→单飞 refresh→重试一次、refresh 失败清 token、状态码语义映射、私有下载带 token 与 403/404、
  pet-home personal/default fallback、AssetPage 游标分页、Google 无 key 时 `google_unconfigured` 与 MapKit 回退、
  发现上报/附近查询、消息幂等与分页、订单物流分页/503 错误、私有模型 archive 下载、自由 source 兼容。
- 全部用 `URLProtocol` stub（`StubURLProtocol`），无真实网络。
- 本机结果：**135 tests, 1 skipped, 0 failures**（跳过 live 测试；跨语言 live 由 `scripts/acceptance_live.py` 跑通）。

### 5.2 Xcode 构建（iOS 模拟器）

```bash
xcrun simctl list devices available      # 选一个可用 UDID

xcodebuild -project ios/PawlyDemo.xcodeproj -scheme PawlyDemo \
  -destination 'platform=iOS Simulator,id=2CB00C4E-A293-4C46-A87C-D08C79E8D152' \
  -derivedDataPath ios/build build CODE_SIGNING_ALLOWED=NO
```

本机结果：**BUILD SUCCEEDED**。产物 Info.plist 的 `DogiosAPIBaseURL` 由工程构建设置/环境变量展开；仓库不保存真实密钥。

构建产物目录：`ios/build/`（根 `.gitignore` 已忽略）、`ios/.build/`（`ios/.gitignore` 已忽略）。

## 6. 验证证据（2026-11-04）

| 文件 | 内容 |
|---|---|
| `var/logs/final-ios-build.log` | xcodebuild 全量日志，末尾 `** BUILD SUCCEEDED **` |
| `var/logs/final-swift-test.log` | `swift test` 全量日志，末行测试运行器以 XCTest 输出为准 |

## 7. 已知边界（本轮未做/未验证）

- **未真实接通 Google Maps**：无 SDK、无 key，`MapProviderStatus.googleUnconfigured`，回退 `mapkit`；
  不渲染地图（地图 UI 属后续 UI 阶段）。
- **未与真实后端联调**：单测全部 URLProtocol stub；真实契约以 `docs/mobile-api-contract.md` 为准，
  后端若以 OpenAPI 修订字段需同步 `DTO.swift`（当前按契约 v1 实现）。
- **未在真机运行**：仅 iOS 27 模拟器编译验证；未启动 App 做运行时联调（本轮只交付数据层与编译验证）。
- 数据层当前包含 SwiftUI 入口所需的 API/DTO；UI 页面由主代理另行维护。
- **未实现**：APNs 推送、WebSocket 实时消息、双方短时精确位置共享、社区 Feed/文章（契约未定义或属后续阶段）。
- Keychain 的 token 存取未在真机做端到端验证；单测使用 `InMemoryTokenStore` 替身（不碰真实钥匙串）。
- 无商城/支付/Shopify SDK 依赖；数据层不 import 任何商城服务。
