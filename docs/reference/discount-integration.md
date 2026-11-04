# 首单三件八折：规则合同与 Shopify 接入边界

当前交付：`backend/app/discounts.py` 的纯业务规则、平台适配 Protocol 与测试。没有连接真实店铺、创建优惠码、修改价格或启用折扣接口。默认适配器 `UnavailableDiscountAdapter` 抛出带 `status_code=503` 的明确未配置异常；前台不能因此展示“已优惠”或“八折已生效”。

用户最新规则覆盖先前“优惠暂不启用”的业务选择：保留三件商品首单八折，首单与最终金额由 Shopify 校验。店铺套餐、应用分发方式和结账能力尚待接店确认，因此本次先完成可验证的规则与接口边界。

促销期的“每月 $1”是价格信息，不能用来判断 Functions 权限。需确认店铺后台显示的实际 Basic / Grow / Advanced / Plus 等计划，以及应用是 App Store 公开分发还是 custom app；本方案不会仅凭促销价格认定功能不可用。

## 已实现的合同

- 礼盒固定三个不同的 Shopify Product GID，各选一个 ProductVariant GID；只能来自后端已经保存的真实三件推荐，不能由浏览器替换推荐名单。部分推荐不足三件时没有该优惠资格。
- 三个已选变体必须在经 Shopify 核实的同一购物车中且可售。增加其他商品不增加优惠范围；换成同一商品的另一变体需要重新确认已选变体。
- 每个所选商品仅优惠一件，20%。数量大于一或同变体被拆成多条购物车行时，也只选择一行的一件；其余数量、其他变体和其他商品不受此优惠影响。
- 服务端签发后恰好两小时有效，在到期秒起拒绝。不能由浏览器延长有效期。
- 不与商品、订单或运费折扣叠加。当前纯规则在平台确认购物车已有其他折扣时明确拒绝，不假定后端能够替用户取消其他折扣。
- 首单必须有可信平台适配器返回的 Shopify 资格证明，包含已核实的买家引用、购物车绑定、店铺与确认时间。未知买家、资格未知、资格失效或已非首单均拒绝；不能把“没有查到客户”当成“已经确认首单”。
- 申请和结账时均需复核。与当前 owner、店铺或购物车不匹配的证明不可复用；默认平台证明最多沿用 60 秒。
- 指令要求平台原子兑现一次，并提供按店铺、规则版本、已确认买家生成的稳定 `redemption_scope`。未来适配器必须防止同一买家经不同问卷会话/不同 offer 绕过首次资格，且需处理并发结账；后端一次查询订单数不足以证明结账时仍有资格。

`ShopifyCheckoutEvidence` 是仅限服务端适配器创建的内部类型，不是鉴权机制，也不是允许浏览器提交的数据模型。未来端点使用 `DealClientRequest`，只接受 `offer_id` 和受控 `cart_reference`；邮箱、`first_order`、`is_eligible`、价格、比例和数量等自报字段会被拒绝。`cart_reference` 指向后端已绑定的真实平台购物车，不可直接相信前端随意提交的购物车内容。

## 平台职责和金额

Python 规则输出的是内部 `DiscountInstruction`：真实购物车行 ID、各一件、20%、到期时间、禁叠加与最终首单复核要求。它不是 Shopify GraphQL 或 Function 输出，不可直接转发为平台 API 请求，更不能用来改写主题中的商品价格。

金额只接收由 Shopify 提供的有限非负 `Decimal`，拒绝浮点、NaN、Infinity 和负数。可选诊断函数 `unrounded_estimate` 保留十进制精度，并明确 `final=false`、`rounding_authority=shopify`；它不会假定所有币种都有两位小数。例如 JPY 的未舍入计算或 KWD 的四位中间结果不会被伪装成最终应付金额。真实税费、运费、现价、Markets 换汇、最小货币单位和逐行优惠分配均由 Shopify 结账决定。

前台最终显示金额必须读取 Shopify 的实际购物车/结账返回值。符合后端规则只表示可以请求平台处理，不等于平台已经应用优惠；真实适配器返回 `pending`、`applied` 或 `rejected`，必须以新鲜的平台响应为依据。

## 适配器与未来端点

`DiscountPlatformAdapter` 需要实现：

1. `capabilities()`：说明当前安装是否能完成全部规则，缺少任何一项则不能启用功能。
2. `inspect_checkout(request)`：服务端通过 Shopify 确认购物车、商品/变体、币种、当前价格、买家首单资格及其他折扣，不接受前端提交的证据。
3. `request_application(instruction)`：使用经核对的平台能力申请优惠，并在 Shopify 结账时执行最终复核、两小时到期、一次兑现和禁叠加，返回真实平台回执。

`prepare_discount` 只有在能力全部满足后才读取平台证明和申请优惠；拒绝资格时不调用申请。适配器能力并非由主题设置或客户端开关指定。`discount_feature_status` 即使平台准备完成也默认返回 `applied=false`，避免把功能可用误报为当前购物车已打折。

未来可增加受访客会话与 App Proxy 来源双重鉴权的 deal 端点，但当前未注册该端点。端点还需要持久化 offer、可信购物车/owner 绑定、幂等申请与平台回执；不能简单把本文件的 dataclass 从请求 JSON 直接构建。推荐/礼盒加购可继续使用现有 Shopify 购物车链，折扣状态单独显示。

## Shopify 能力核对结果

以下来自本次读取的官方文档，接店时应按所选版本与实际权限复核：

| 路线 | 已核实的平台限制 | 本项目处理 |
| --- | --- | --- |
| 含 Functions 的 App Store 公开应用 | Shopify 文档说明任何套餐商店可使用包含 Functions 的 App Store 公开应用 | 可评估已有或正式分发的合适应用；仍需证明其支持本项目所有规则，不能仅凭“支持八折”启用 |
| 含 Functions 的 custom app | 官方文档说明仅 Shopify Plus 商店可使用包含 Function APIs 的 custom apps | 未确认套餐与应用类型前，不承诺能把自写 Function 作为普通商店的自定义应用安装 |
| Discount Function 的普通 run | run 使用输入数据执行，不能在代码中任意联网查本后端或读取主机当前时间 | 所需资格、配置、购物车、时间语义均须通过该版本允许的输入与平台折扣有效期机制提供；缺少可验证输入则拒绝 |
| Discount Function 的 network fetch | 官方当前文档将 Functions 网络访问限制为 Shopify for enterprise 计划，且是 Shopify 代发 fetch target 请求 | 不能把网络 fetch 当成所有套餐默认能力；需要时核对实际计划和开通能力 |
| 原生百分比优惠 | 原生平台能提供百分比等标准折扣，但“买够三件”不自动等于“三个不同商品各一件” | 需现场核对 distinct 商品、行数量上限、首单、期限、禁叠加与兑现完整性；任意一项不能严格执行时，native adapter 保持不可用 |

本交付没有手写未经生成/校验的 Shopify Function 文件，也没有冒用弃用的 Product Discount API。若确认使用自写 Discount Function，应通过 Shopify CLI 正式生成扩展，使用该扩展锁定版本的 schema 构造输入/输出，运行构建与夹具测试，再接未发布环境进行结账验收。

网站问卷和照片生成仍允许访客使用。礼盒折扣的 Shopify 买家资格可以在实际购物车/结账识别后确认；如果平台没有提供可验证的访客首单身份，优惠应显示待核实，不能为了立即展示优惠而相信问卷邮箱或要求用户为使用网站功能先登录。

## 接店验收

必须在真实开发/测试店铺验证：三个不同产品、选错变体、停售/库存变化、单行数量二以上、同变体拆行、额外商品、已有其他优惠、两小时边界、首次与已有订单买家、身份改变、并发结账、重复 offer/请求、JPY/KWD/其他 Markets 币种和实际逐行金额。仅规则单元测试不能证明某个 Shopify 套餐已经支持完整策略。

当前测试覆盖三件固定名单、身份与购物车隔离、资格未知/拒绝、可售变体、数量上限、拆行、不叠加、期限、币种、Decimal 精度、未配置 503、能力不足和平台回执边界；不产生真实优惠或外部写入。

官方来源：

- [Shopify Functions：计划与分发可用性](https://shopify.dev/docs/apps/build/functions)
- [Discounts overview](https://shopify.dev/docs/apps/build/discounts)
- [Build a Discount Function that has network access](https://shopify.dev/docs/apps/build/discounts/network-access)
- [Shopify Help：金额/百分比折扣与最低数量条件](https://help.shopify.com/en/manual/discounts/discount-types/percentage-fixed-amount)
