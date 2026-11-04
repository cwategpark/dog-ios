# Shopify 主题迁移审计

依据仓库提交 `b4cdc846756f6ed41db8c85aa67b6daca1933263` 的源码与脱敏数据库索引。没有访问运行站点，没有启动 WordPress、数据库或历史工具，没有修改 `test.local:10004`。

## 当前站点来源

主要实现位于 `wordpress/app/public/wp-content/plugins/pawly-platform/`，并非 Twenty Twenty-Five 主题。页面 12、122、123、248 的基础布局在 `_elementor_data`；PHP 通过运行时替换追加首页开场、猫/狗目录、全部商品首屏与生活方式故事。不能只迁 Elementor 静态 HTML，否则会丢失商品数据和这些运行时模块。

| 旧路由 | 当前入口 | Shopify 目标 |
| --- | --- | --- |
| `/` | page12，home-intro、scene-carousel、editorial-story、global-reach | `templates/index.json`，各模块独立 section |
| `/pawly-shop/?pet=cat` | page122，cat-entry + catalog | 猫商品 collection，可独立选择 collection 模板 |
| `/pawly-shop/?pet=dog` | page122，dog-playground + catalog | 狗商品 collection，可独立选择 collection 模板 |
| `/pawly-shop/all/` | page248，cozy-shop + catalog | `/collections/all` 与可配置集合首屏 |
| `/product/*` | private page123，共享 gallery/summary/details | `templates/product.json` 默认通用商品页 |
| `/product/daily-harness/` | `templates/harness-story.php` | 默认采用其无边框3D/图像与常驻购买设计语言，商品内容动态读取 |
| `/cart/` | WooCommerce 原生表单 | Shopify 原生 cart form |
| `/checkout/` | WooCommerce 原生结账 | Shopify 托管 checkout |
| `/my-account/` | WooCommerce 账户 | Shopify 店铺启用的 customer accounts |
| 搜索 | 目录 `q` 与 WordPress `s` 两套 | Shopify `/search`、`search.results`、原生筛选 |

## 需要保留的模块边界

共享 header/footer、全局 token、语言/深色偏好、节日效果各维护一处。首页拆为品牌开场、生活场景、精选商品、生活方式专题、品牌横幅等 sections；商品页拆为通用商品舞台、商品表单、媒体、商品信息和 AI 功能入口。商品卡片、价格、图标、媒体、分页使用 snippets。JSON 模板只负责模块组合，禁止将完整页面 HTML 放入单一 Custom Liquid。

用户已确认以 `daily-harness` 的设计语言作为全部商品默认模板。有 Shopify 原生 3D media 时提供3D，没有时显示该商品图片。胸背的三章文案、黑/橙、S/M/L 不是通用商品事实，不得硬编码到其他商品。未指定自定义模板的新商品直接采用 product.json，不需要逐件执行 Admin API 写入；明确选择其他模板的商品继续使用其选择。

## 商品数据映射

`includes/data.php` 当前只查询 `_pawly_demo=yes` 已发布 WooCommerce 商品，且 pet/scene/kind 都借用 `product_cat`。迁移后商品标题、图片、价格、SKU、变体、可售状态、库存策略直接来自 Shopify；不把旧 demo 标记变成新上架的前提条件。

旧 `_pawly_highlights`、`_pawly_story_*`、`_pawly_faq`、`_pawly_video` 与 `_pawly_tryon_enabled` 应映射为有明确类型的 Shopify 扩展字段或主题块设置；商品 GLB 优先进入 Shopify product media。筛选应使用 Shopify collection filters/Search & Discovery 配置，避免在前端拉取所有商品后自行过滤。旧路径跳转需在目标店铺 URL redirects 中导入，主题文件本身不能创建服务器重定向。

## 性能证据与约束

`pawly-platform/assets` 共 161 个文件、143,482,591 bytes（136.84 MiB），这是文件总量，并非已测量的首屏下载量。

| 文件 | 大小 |
| --- | --- |
| `assets/pet-experience/assets/pet.glb` | 43.903 MiB |
| `assets/pet-experience/assets/product.glb` | 19.660 MiB |
| `assets/pet-experience/assets/product-models/product-225.glb` | 6.423 MiB |
| `assets/pet-experience/assets/cat.glb` | 6.280 MiB |
| `assets/global-reach/dist/3d-globe-DmoHF8Vo.js` | 1.522 MiB |
| `assets/vendor/model-viewer-4.4.0.min.js` | 约 1 MiB |

首页 `includes/home-intro.php` 当前 eager iframe，`home-intro.js` 与 `scroll-pets.js` 用同源 postMessage；`site-preferences.js` 直接读取 frame.contentDocument。Shopify CDN 域名与商店域名可能不同，不能原样嵌套沿用同源假设。`catalog.js/json` 还硬编码 WordPress 商品ID、价格/链接与本地域名，应改成 Liquid 生成的数据契约。

迁移建议：首屏先交付原品牌图片、真实商品文本和可购买表单；首屏图片有固定尺寸、响应式 srcset、仅关键图片高优先级；视频 preload=none；3D 交互按用户点击加载，商品模型只加载当前商品；离屏/后台停止动画；prefers-reduced-motion 与 Save-Data 可回退。CSS/JS 按组件加载，普通筛选按钮不需 React/Motion/Tailwind 整套运行时。保留3D的部分统一模型与 Three.js 版本，并单独设置优化预算，不能让购物依赖 WebGL 成功。

## 视觉与内容来源

品牌为 `wagelpaw`，插件仍叫 Pawly。现有配色暖白 `#faf8f4`、森林绿 `#263a30`、鼠尾草绿 `#77836b`；字体是 Inter/DM Serif 的本地文件。可选轻资源包括 `assets/editorial/{home,walk,play}.webp` 和 `assets/cozy-shop/{golden,cat,dachshund}.png`。生活方式图片为 AI 素材，原 global-reach 中城市/弧线是愿景示意，标准标志不代表已获认证，迁移内容不能改变其含义。

语言现有 en/zh/es/ko 共用 `assets/locales/site-copy.json`；Shopify 宜改为 locale key 和本地化表单，避免 MutationObserver 遍历整页改商品文案。深浅主题可以保持轻量本地偏好。

## 验收边界

静态本地预览只能检查布局、模块和交互，不等同于 Shopify Liquid 在线渲染、库存校验、付款或 App Proxy 验证。需另在目标店铺的未发布主题上验证真实变体、已售罄、折扣、税/运费、Markets、多语言与购买流程。复杂首页3D开场、狗狗物理软袋、地球和手动3D穿戴工作台属于独立重模块，若尚未完整迁移需明确列为差异，不应以图片替代后声称全部完成。
