# 跨 Shopify 账号安装

一份主题和后端代码可以重复用于其他账号。每次安装的店铺连接、资源选择、数据库和私有媒体独立，不能把上一个店铺的 token、商品 GID 或生成结果复制给新店。

## 安装顺序

1. 在目标店铺上传 `wagelpaw-shopify-theme.zip` 为未发布主题。先确认 Online Store 发布渠道和商品自身可售状态。
2. 主题编辑器设置导航菜单、首页精选系列、页脚、品牌、配色与文案。猫/狗系列分别设置自己的集合；`collection.cats.json`、`collection.dogs.json` 是可选择的版式，并不自动替运营创建系列。
3. 新品保持“默认商品”模板即可自动应用 `product.json`。既有显式模板分配不会被迁移工具偷偷改写，需要在目标店铺核对后批量更换。不同商品的叙事内容用动态来源，不能把某件胸背的文案复制到所有商品。
4. 商品媒体上传到该店铺。图片/视频/3D 模型属于商品内容，不能把旧店 CDN URL 和主题 ID 当跨店稳定标识。模型先做体积/纹理检查；无模型仍可正常浏览和购买。
5. 为新店建立自己的 Shopify 应用安装和凭据，在新后端配置 `SHOPIFY_STORE_DOMAIN`、`ALLOWED_SHOPS`、`SHOPIFY_ACCESS_TOKEN` 与 `SHOPIFY_API_SECRET`。只读目录需要 `read_products`、`read_inventory`；本服务不会改库存或价格。
6. 配置应用代理：店铺 `/apps/wagelpaw/*` 转发到本店后端根路径。代理前缀可在主题全局设置中改，但前后端必须一致。应用代理由 Shopify 应用管理，不是上传主题 ZIP 就会自动创建；须在目标店完成安装和配置。
7. 在应用中订阅商品创建/更新/删除及库存变更 Webhook，目标为后端 `/webhooks/shopify`。它验证原始 body HMAC、店铺与事件 ID。使用受 HTTPS 保护的独立后端域名。
8. 运行一次 `python -m app.worker --sync-catalog` 读取本店商品。worker 按周期对账，前台商品浏览直接使用 Shopify，不依赖后台同步完成。
9. 配置模型密钥及私有 TripoSR 服务，验证连通和费用配额后再在主题设置打开宠物助手。每个店铺的匿名用户额度、留存和费用限制应单独配置。
10. 在未发布主题验证全部流程后，再由店主选择发布。

## 商品字段约定

展示与推荐资格分开：商品上架自动获得页面，但没有宠物适用性信息时不自动加入推荐，也不会自动产生模型或正确贴合。

当前映射使用 **商家拥有的 `pawly` 命名空间**，方便主题、独立服务及其他运营工具共同维护并跨安装迁移。先在目标店建立定义，再写入值，最后读取/同步。定义不是浏览器自由提交的数据。

| key | Shopify 类型 | 用途 |
| --- | --- | --- |
| `pet_types` | `list.single_line_text_field` | `cat`、`dog` |
| `categories` | `list.single_line_text_field` | `toys`、`cleanup`、`beds`、`wear`、`leashes`、`litter`、`bags` |
| `dog_sizes` | `list.single_line_text_field` | `small`、`medium`、`large` |
| `min_age_months` / `max_age_months` | `number_integer` | 适用月龄，留空表示没有该边界 |
| `owner_accessory` | `boolean` | 主人配件 |
| `needs_fit_check` | `boolean` | 加购前核对实际尺码 |
| `exclude_gift` | `boolean` | 从推荐中排除，仍可公开售卖 |
| `tryon_enabled` | `boolean` | 此商品经运营确认可做照片预览 |
| `tryon_usage` | `multi_line_text_field` | 穿戴/使用方式，仅为模型元数据 |
| `model_url` | `url` | 扩展模型资产，可供校准运营使用；主题商品主模型优先原生商品媒体 |
| `fitting` | `json` | 校准的宠物/服装 GLB、transform 与 revision，必须经过运营核对 |

少量商品可用 `pet:cat` / `pet:dog`、`category:toys` 等标签作为后端推荐备用；首页/集合筛选仍应通过目标店的 Search & Discovery 配置原生筛选。复杂字段使用标准定义及动态来源，不要长期依赖从标题猜适用条件。

写入值：在本店商品编辑器的自定义数据中选择类型并填写，或由经授权的后台运营工具写入 Shopify。读取：运行目录同步后在本店问卷会话请求 `/v1/catalog` 核对映射，模型使用原生商品媒体核对。不要从前台开放任意 metafield 写接口。

小猫校准仅适用于匹配的资产和商品。若复用仓库内公开校准模型，把本店主题对应的 `fitting-cat.glb`、`fitting-harness.glb` URL 写入后端配置，并设置 `CAT_FITTING_PRODUCT_HANDLE`。换了模型必须重校准，不能只换 URL。保留主题内 CC BY 4.0 署名。

## 必须在真实店铺完成的验收

新品/下架、价格库存变化、变体和加购、搜索筛选、语言发布、客户账户链接、应用代理签名和访客隔离、Webhook 去重、真实照片生成、GPU 结果下载，以及 Shopify 托管结账。主题不能改写托管结账和新版客户账户全部界面。首单优惠另见折扣接入文档。
