# 主题维护、升级与跨店铺迁移

## 主题职责与目录

`migration/theme` 是可上传的 Shopify Online Store 2.0 主题根目录。源码使用 Shopify Liquid、JSON 模板和小型原生 JavaScript；商品、价格、变体和购物袋均使用 Shopify 对象及原生接口。

| 修改需求 | 唯一或主要入口 |
| --- | --- |
| 全站导航、公告、商标 | `sections/header.liquid` 与 Shopify 的导航菜单、主题编辑器 |
| 全站页脚、政策链接、语言 | `sections/footer.liquid` |
| 首页品牌开场 | `sections/home-hero.liquid` |
| 品牌滚动条 | `sections/brand-band.liquid` |
| 首页或商品页精选商品 | `sections/featured-products.liquid` 的 collection 资源选择器 |
| 首页生活方式叙事 | `sections/lifestyle-stories.liquid` 的 story blocks |
| 集合介绍与商品筛选 | `sections/collection-hero.liquid`、`sections/main-collection.liquid` |
| 默认商品页 | `templates/product.json`；`sections/main-product.liquid` 组织布局与章节 |
| 所有商品的购买表单 | `snippets/product-form.liquid` |
| 所有商品的卡片 | `snippets/product-card.liquid` |
| 所有商品页的圣诞节或雪花效果 | 主题设置 → Seasonal effects；算法只在 `snippets/seasonal-effects.liquid` |
| 宠物问卷、推荐礼盒、试穿、卡通/3D | `sections/pet-tools.liquid`、`assets/pet-tools.js`；独立后端实现业务 |
| 已校准猫咪3D穿戴视图 | 按需加载的 `assets/cat-fitting.js`；后端返回可用配置 |
| 基础配色、间距、响应式 | `assets/theme.css`；主题设置中维护基础色值 |
| 商品舞台、图库与变体交互 | `assets/product.css`、`assets/product.js` |
| 英文/中文/西语/韩语界面 | `locales/en.default.json`、`zh-CN.json`、`es.json`、`ko.json` |

JSON templates 只编排 sections、blocks 和运营设置；不要把完整页面重新塞入一个 Custom Liquid。新增功能应保持相同边界。

## 商品与模板自动联动

主题的 `product.json` 是默认商品模板。商店启用此主题后，未指定其他模板的商品自动使用这一模板，无需为每次新上架商品执行代码或调用 Admin API。只有选择了替代模板的商品需要手工改回默认或继续使用其选择。

商品标题、描述、价格、媒体和变体来自当前 `product`。上传到 Shopify 商品媒体的 3D model 可点击后显示；没有模型时显示该商品图片，不会将其他商品的模型冒充当前商品。

商品特有的章节与养护内容在主题编辑器接入动态源。新商品未填写时，简介和章节使用商品描述，未确认的材质/尺码不会补造。扩展字段的定义、商品素材上传及店铺配置应纳入部署交接。

当前 variant selector 使用 Shopify Liquid `product.variants`，面向最多 250 个变体的商品。超过该规模的商品需要进一步接入 Shopify `option_values` 和按需 section rendering；不要将此版本宣传为已验证 2,048 个变体。Shopify 始终负责最后的库存与加购校验。

集合筛选使用 Shopify 原生 `collection.filters`。在 Shopify Search & Discovery 中启用需要的宠物类型、场景、商品类别及价格等筛选，主题会自动展示平台返回的筛选项。不要在浏览器下载全量商品自行过滤。

## 节日效果只维护一处

进入主题设置 → Seasonal effects，打开 Enable on every product page，并选择 Christmas stars 或 Soft snow。效果不需要逐商品编辑，不影响购买表单；`prefers-reduced-motion` 下关闭装饰动画。新增节日效果只扩展 `snippets/seasonal-effects.liquid` 以及全局配置选项。

## 后端连接与隐私

主题设置 Backend 的 `app_proxy_path` 默认 `/apps/wagelpaw`，部署时配置为安装应用的 Shopify App Proxy。只有完成后台部署与代理配置后才启用 Enable pet assistant。主题中不配置 Admin token、模型密钥或开发令牌。

用户完成问卷并同意后，前端调用 `/v1/sessions` 获得访客会话，仅在当前标签页 sessionStorage 保存；无需登录。后续上传、生成、查询和私有结果携带 `X-Wagelpaw-Session`。私有媒体通过带会话的 fetch 获取 blob，不以裸公开 URL 引用。后端必须校验访客归属及过期时间。

礼盒展示后端返回的真实商品与变体；需要确认尺寸的商品必须勾选适配确认，最多将三件选中商品通过 Shopify cart API 加购。此版本不配置、不承诺组合优惠。

已校准猫咪穿戴不能自动应用到所有商品。只有后端明确配置的宠物模型、服装模型、位置、旋转和比例组合才允许展示；没有配置时应返回不可用。该视图仅供外观参考。

## 跨店铺迁移

1. 在新店铺安装独立应用、配置新店铺域名、Admin API 凭据、Webhook 和 App Proxy；密钥留在后端环境变量。
2. 上传主题安装包为未发布主题。
3. 通过 Shopify 商品导入或迁移工具导入商品、媒体、集合及扩展字段定义；保留稳定 handles 便于映射，但不要假定 Shopify 数字 ID 或 GID 跨店相同。
4. 在主题编辑器重新绑定 collection、menu、image 和动态源资源。主题的 collection 选择器保存店铺资源引用，无法把旧店铺引用直接当成新店铺对象。
5. 配置语言、Markets、货币、政策与商品筛选；设置店铺导航并选用 cats/dogs 集合模板。
6. 核对新店铺 API 授权与商品可售渠道，使用未发布主题预览验收后再切换。

主题没有写死 Shopify 商店域名、商品数字 ID 或 WordPress 地址。仓库包含的宠物与生活方式图片是主题的品牌素材，可按授权继续使用；它们不会伪装成新店铺商品数据。模型 URL 与校准配置必须重新绑定新店铺资源。

## 安全升级与回滚

每个目标店铺保存代码版本、主题 ID 和发布记录。在升级前下载目标主题并备份：

- `config/settings_data.json`：该店铺的全局设置与资源选择。
- `templates/*.json`：运营人员的 section 顺序、内容和各模板设置。
- `sections/header-group.json` 与 `sections/footer-group.json`：共享模块组合与设置。
- Shopify 后台中的商品模板分配、扩展字段、菜单、集合、翻译、应用与代理配置。

不要用仓库中的空 `settings_data.json` 直接覆盖已运营店铺。新版本通过 Git diff 与店铺下载版本做三方合并；保留运营设置，同时新增或迁移新版本需要的 schema 字段。`settings_schema.json` 中已有 setting ID、section type 和 block type 是兼容接口，改名时提供迁移映射。

先将合并后的版本上传为新的未发布主题，验证主页、集合、搜索、普通商品、有模型商品、售罄商品、多变体、购物袋、四语言、深色和手机布局。新主题发布后保留上一版本主题，发现问题可在 Shopify 后台重新发布上一版本。主题回滚不等于后端或数据库回滚，后端变更需保持兼容并单独记录迁移。

## 性能与验收

首屏不加载仓库中的 43 MiB 宠物模型；商品模型在用户点击后加载，猫咪穿戴仅在生成相应 manifest 后导入 Three.js。浏览器普通购物、搜索和表单不依赖这些3D模块成功。

本地预览可验证页面、尺寸和交互，但不能证明 Shopify 线上渲染、付款、税率、库存以及真实 AI 提供商已联通。发布前必须在目标店铺未发布主题中验收这些集成，并记录 Lighthouse 移动端结果及真实模型传输大小。
