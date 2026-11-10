# iOS 网站账号联动 · 2026-11-10

Mac 的实际工程 `/Users/jbf/Documents/dog-ios/ios` 已更新。通过 DSH 完成数据层实现及最终文件同步；界面由主代理修改。12 个交付文件已逐一校验，Mac 原工程与验收副本 SHA256 全部一致。

## 已实现

- 同一已验证邮箱登录，读取本人宠物名字、网站保存的模型及原始上传照片。
- 宠物页支持“全部宠物”和单只宠物筛选，照片与模型分页、原图认证预览和 GLB 模型查看。
- 兼容照片生成、文字生成及品种参考模型；保留原有模型全身取景、旋转和缩放实现。
- “我的 → 商品物流”：订单编号、商品名称/数量、发货状态、多包裹、承运商、运单号和承运商查询链接。
- 旧商城、商品详情、购物车、结算及旧购物客户端已排除出 App 编译；原有宠物社交功能保留。
- 私有资源由 Bearer 请求下载。退出或切换账号重建私有页面，旧账号响应不得写回新账号。
- 明确区分正常空历史和服务不可用；新刷新不会被旧请求的 busy 状态吞掉，非终页空结果不误报“暂无订单”。

## 真实物流仍需的配置

当前环境没有可用于订单读取的 Shopify Admin token，真实订单尚无法联调。App 会显示服务暂不可用，不会伪造空订单。

在现有网站服务端配置 `WAGELPAW_SHOPIFY_ACCESS_TOKEN`，对应当前单店的 `WAGELPAW_SHOPIFY_STORE_DOMAIN`，具备 `read_orders` 和订单邮箱访问权限。超过 60 天的订单还需要 `read_all_orders`。凭据只保存在服务端，不写入 iOS。

已加载的只读路由：`GET /mobile/v1/orders/logistics?cursor=...`。账号邮箱取自已验证 Bearer 用户，客户端不能指定其他身份；上游结果再次精确核对邮箱。订单邮箱缺失或被脱敏时返回 503。每页最多 20 单，每单至多 50 个商品行和 50 个包裹。

网站原有“已验证并保存”的数据可以共用账号；未认领的访客上传不会仅凭输入邮箱自动合并。

## 当前连接

App Debug/Release 已更新为网站当前地址：`https://quebec-week-preparing-treating.trycloudflare.com`。保留 `DOGIOS_API_BASE_URL` 和 Info.plist 的显式覆盖能力。该地址沿用网站现有临时隧道，隧道地址变化时需要一起更新 App 配置。

网站 API 和 BFF 已重新加载，现有网址及模型 worker 保留，健康检查通过；匿名访问新物流路由返回 401。

## 验证证据

- Swift：136 项测试，1 项按环境跳过，0 失败。
- Xcode：模拟器 `build-for-testing` 成功；最终编译源清单不含旧购物模块。
- 小屏 UI：iPhone SE（375 点宽）5 项验收全通过，覆盖正常多包裹、空订单、未配置不可用、宠物名字/文字模型/私有照片预览、最大辅助字号与返回导航。
- 系统深色外观与减少动态效果开启后，最大辅助字号的物流导航复验另 1 项通过，截图已目视检查，见 `ui-reduced-motion-verification.json` 与 `screenshots-reduced-motion/`。
- 后端物流：17 项通过；BFF：3 项通过；Shopify 查询通过固定 2026-07 schema 验证。
- Canonical 账号链路：7 项通过，覆盖网站上传、验证认领、宠物名、照片/模型归档、App 列表与认证下载、跨账号拒绝。
- 界面验收结果与截图：见同目录 `ui-verification.json` 和 `screenshots/`。界面夹具使用明确标记的合成账号与模拟订单；不代表真实订单联调结果。iPhone 现有配置锁定竖屏，横屏请求测试不代表新增横屏支持。

账号链路证据：[account-linkage-evidence.json](../ios-sync-verification/account-linkage-evidence.json)。可复用夹具：[verify_account_linkage.py](../ios-sync-verification/verify_account_linkage.py)。测试数据库、媒体和 OTP 已清理，无真实邮件或付费模型生成请求。

## Mac 备份与证据位置

原文件备份：`/Users/jbf/Public/codex-handoff/ios-account-sync-20261110/original-before-primary-sync/`。

验收副本、构建日志和 xcresult：`/Users/jbf/Public/codex-handoff/ios-account-sync-20261110/`。

新版 App 已安装至 Mac 现有 iPhone 18 Pro 模拟器。测试回环服务、临时私有登录文件及本次新建小屏模拟器均已清理；原有 iPhone 18 Pro 模拟器保留。

本机 `ios/` 是同步后的源码副本；`qa/fixture_server.py` 是仅监听 Mac 回环地址的测试服务。验收使用 InMemoryTokenStore，不改用户 Keychain。
