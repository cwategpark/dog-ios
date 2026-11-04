# 工作流与独立后端迁移审计

审计日期：2026-11-04（Asia/Shanghai）。来源提交：`b4cdc846756f6ed41db8c85aa67b6daca1933263`。本报告仅依据克隆仓库静态代码，未运行工作流、访问现有站点、读取仓库外凭据、发送邮件或调用生图模型。仓库中的实测说明是历史记录，不等于本次验证。

## 实际功能边界

`workflows/dify/current/index.json` 记录 23 个当前应用，其中 39 份 DSL 成功导出，一个 Agent 导出失败。发布版本应按 `published_workflow_id` 选择；`draft.yml` 不等于正在调用的发布版。`workflows/dify/archive` 是历史来源，不应整体恢复到新系统。

网站静态调用链确认如下：

| 功能 | 当前调用方 | Dify 当前应用 | 迁移目标 |
| --- | --- | --- | --- |
| 商品目录规范化/每日快照 | `wordpress/app/public/wp-content/plugins/pawly-pet-profile/includes/dify.php` | `d489ead8-827f-46e4-b6e4-fb800262769c` | Shopify 目录适配器、Webhook 增量更新、定时全量校验 |
| 宠物问卷→推荐礼物盒 | 同上；入口为 `pawly-pet-profile.php` | `12996135-6676-4233-a41b-389321982cdb` | 确定性规则服务，可配置 AI 排序，输出白名单复核 |
| 宠物照片+商品照片→穿戴图 | `pawly-pet-tryon/includes/api.php`、`client.php` | `0cef0445-ec5c-48ac-9006-efd4dc83e04b` | 上传/任务 API、持久队列、Seedream 提供商适配器 |
| 穿戴图→卡通图→3D GLB | `pawly-pet-tryon/includes/avatar.php` | `599e9abc-844c-4570-9442-1ab2073870e4` | 依赖原试穿任务的分阶段异步服务 |
| 默认小猫+胸背佩戴定位 | `pawly-cat-fitting/pawly-cat-fitting.php` | 配置 Key 指向的应用；语义与 `d74aa32a-a3b4-4ca1-beed-a7148bf31d30` 发布 DSL 匹配 | 资产清单与确定性坐标计算；已保存人工校准优先 |

小猫链的运行时应用 Key 未读取，所以不能仅凭仓库确认实际 Key 的归属。该插件为有效人工校准记录优先返回 `source=manual`，仅无有效人工记录时调用 Dify；不能把所有小猫预览都描述为 AI 生成。人工校准记录在数据库中，本次未读取。

## 已核对接口和业务契约

### 商品目录

当前发布 DSL：`workflows/dify/current/d489ead8-827f-46e4-b6e4-fb800262769c/8bd38da4-8c9f-48d0-aa5a-cdb13e69d677.yml`。

输入：`catalog_json` JSON 字符串。对象含 `schema_version`、`generated_at`、`currency`、`products`。商品含 ID、名称、发布/可购买/库存状态、价格、币种、分类、宠物类型、犬型、适龄上下限、主人配件、规格、需尺码确认标记和人工排除标记。

输出：`catalog_json`（含清洗后商品和排除原因）、`product_count`、`excluded_count`。

原站仅从 `_pawly_demo=yes` 的公开商品导出目录，且排除无价、缺货、无可售规格、缺少宠物适用分类、人工排除的商品。Shopify 迁移必须明确是否改为所有 Online Store 已发布商品。展示范围与推荐资格是两件事：新商品可以正常展示，但缺失适用信息时不应自动进入宠物推荐。

原调度为 WP-Cron 每日同步，商品/规格变化后延迟 15 秒合并刷新。新服务不能依赖页面访问触发：使用 Shopify Webhook + 定时任务，Webhook 去重、事件乱序处理和定期全量对账。价格库存真值仍以 Shopify 为准。

### 问卷和礼物盒

当前发布 DSL：`workflows/dify/current/12996135-6676-4233-a41b-389321982cdb/6007ad7b-386f-4d01-a22f-267d0db9667d.yml`。

输入：`profile_json`、`catalog_json` JSON 字符串，`use_ai=on/off`。档案为 `user_information`、`user_pets[].pet_information`、`consent` 层级。宠物支持 cat/dog、年龄 0–480 月，狗须 small/medium/large。JSON 支持多宠物，现有选品只针对第一只。

输出：`product_ids`、`bundle_json`、`source`、`selected_count`、`normalized_profile_json`。最多三件；允许一至两件或零件，不凑数。模型仅允许在候选 ID 中选择；去重、忽略不存在 ID、模型失败规则回退。匿名模型输入只有宠物类型、月龄、犬型和候选商品属性，联系人、邮箱和宠物名字不进入提示词。

可复用纯 Python 源码：

- `workflows/dify/archive/05_本地源文件参考/项目Dify工作流源文件/nodes/normalize_profile.py`
- 同目录 `normalize_catalog.py`、`filter_products.py`、`validate_bundle.py`
- 同项目 `test_rules.py` 已有猫狗/年龄/犬型/缺货/无效 ID/模型失败/隐私边界测试。

迁移前须与当前发布 DSL 逐节点比对，再建立受版本控制的独立领域模块；历史源码不能不经比对直接充当线上真值。现有 PHP 本地回退的品类优先顺序与 Python 规则节点存在差异：PHP 为 toys、wear、cleanup、beds、leashes；Python 为 toys、cleanup、beds、wear、leashes、litter、bags。应统一并记录业务决定。

当前 PHP 创建私密用户/宠物档案，生成一小时礼物盒令牌，加购时再次检查商品与规格。Shopify API 使用 Product/Variant GID，新服务不应把 ID 强转旧 WooCommerce 数字 ID；建议内部保留平台 ID 字符串，历史映射独立存表。

### 首单三件 20% 优惠

来源：`wordpress/app/public/wp-content/plugins/pawly-pet-profile/includes/bundle.php`。

规则：推荐三件不同商品、全部选入购物车、按支付订单邮箱判首单；优惠仅作用于对应购物车行每件最多一个数量，20%，不可叠加，资格两小时有效，结账邮箱再次复核。问卷邮箱不应作为最终身份依据。

这不能仅靠 Liquid/浏览器改价实现。是否保留必须询问用户，并按店铺计划和应用类型选择 Shopify 原生折扣、受控折扣码或 Shopify Function。未实现严格复核时不能展示已生效的 20% 优惠。

### 照片试穿

当前发布 DSL：`workflows/dify/current/0cef0445-ec5c-48ac-9006-efd4dc83e04b/03f3976e-7897-4cca-9524-e3147f0dcfaa.yml`。

工作流输入：`pet_photo`、`product_photo`（Dify 文件对象）、`product_json`、32 位十六进制 `request_id`、`consent=yes`。商品元信息为 `id`、`variation_id`、`name`、`attributes`、`usage`，服务端选择商品/规格图，不能信任浏览器提交任意商品 URL。工作流输出包含 `job_id`、`status`、`product_id`、`message`、`result_json`，成功表示已提交异步任务，不表示生图完成。

浏览器当前收到临时 64 位十六进制令牌，而非服务密钥；轮询时验证任务商品匹配。上传最大 8MB，清洗图像/EXIF，适配器图像最多 2400 万像素并缩至 1536 边长；当前每 IP 每小时三次，失败返还额度；结果最长 24 小时。静态参考预览模式会明确关闭生成。新服务应使用可信代理后的限流身份，不能原样依赖代理 IP。

可复用实现：`services/adapter/workspace/image_service/tryon_service.py`、`ark_tryon.py`。其中 `source_file()` **仍只接受 Dify `/files/` 路径并拼接 `DIFY_INTERNAL_URL`**，因此单纯移除 DSL 调用无法脱离 Dify；须改为新服务管理的受控上传对象，不接受客户端任意 URL。

生成器当前为火山方舟 Seedream，可配置模型，仓库默认 `doubao-seedream-5-0-flash-260915`，返回一张 2048×2048 图，原调用不自动重试付费生成。模型名称、余额、地域与网络可用性未验证。迁移保持提供商接口隔离和幂等请求；网络超时后状态应为结果待核查，不能盲目重试收费请求。

### 卡通与 3D 角色

当前发布 DSL：`workflows/dify/current/599e9abc-844c-4570-9442-1ab2073870e4/d5554cbf-9fe2-4d2c-ab21-f3bcc91d5c8b.yml`。

输入：`source_job_id`、`consent=yes`。原穿戴任务必须成功且未过期。输出任务状态，轮询后下载 PNG/GLB。实现：`services/adapter/workspace/image_service/avatar_service.py`。

阶段：Seedream 生成完整单只 3/4 低面数参考图→TripoSR 预处理/去背景→`generate_lowpoly`→GLB 校验。目标 5000 面，保留顶点色；不是动画绑定、真实尺寸测量或所有商品自动精确贴合。

已有幂等和局部恢复：重复 source ID 复用结果；已有卡通图时本地建模最多重试两次，不再次生图。当前本地建模地址硬编码 `host.docker.internal:10044`，须配置化并部署在独立 GPU worker 或受保护推理服务。模型权重不在 Git 仓库。

### 默认小猫试穿

发布 DSL `d74aa32a-a3b4-4ca1-beed-a7148bf31d30/9d68a83b-ff2c-4511-a23b-0d25bcee9427.yml` 为纯 Python 规则/数学节点，没有 LLM：商家标注优先，其次商品名/分类关键词判 harness/collar/vest→骨架锚点→四元数/位置/缩放→场景 manifest。

输入：`pet_id`、`product_id`、`product_json`、`pet_landmarks_json`、`garment_profile_json`。输出：JSON 字符串 `manifest`。当前精确限制 toon-cat+daily-harness 和已校准 GLB 组合，不是任意商品上传后自动可穿。

人工校准实现 `pawly-cat-fitting/manual-studio.php` 含资产 hash/fingerprint、模型方向、position/quaternion/scale、revision 乐观锁、编辑权限校验。这些规则可以迁成独立资产配置服务，需决定是否制作运营校准界面。猫模型 CC BY 4.0 来源署名必须保留。

## 不应默认整合的其他应用

| 范围 | 证据与状态 |
| --- | --- |
| 穿戴三视图 Demo | `services/threeview/README.md` 明确未嵌入正式 WordPress 商品页，Dify 草稿未发布。独立服务读 WooCommerce Store API、每任务三次生图、无付费自动重试；当前 localhost 结果链接和无完整用户隔离不能直接上线。 |
| 商品三图/批量生图 | `services/adapter/workspace/image_service/service.py`、当前 `8dd8c7a5...` 是商品运营工具，含规划、分阶段生图、视觉 QA、分组 ZIP；前台主站未发现直接调用。支持 OpenAI edits/JSON reference/Gemini 协议，但配置可用性未验证。 |
| Zoho 邮箱自动回复 | `workflows/email-autoreply` 是独立收信监听与发信流程；示例默认 disabled/preview，含去重与发信配额，仍通过 Dify 做模型处理。应单独确认是否迁移，未经授权不运行或发信。 |
| 客服/知识库 Demo、真假问答、URL 爬取、宠物数据采集 | 多数只有草稿或历史原型；没有发现这些应用的有效前台调用证据。知识库实际数据与运行凭据并不在可直接恢复的 DSL 内。 |
| 企业微信/飞书/Sorftime 跨平台机器人 | 独立外部消息/市场工具，不属于当前商城前台主链，接入范围须另行确认。 |
| Workflow Agent/整合工作流 | 有导出失败或未完成应用，不能承诺功能完整。 |

## 建议的后端分层与稳定性要求

采用一个模块化业务服务和独立 worker，先避免过多微服务：

1. `catalog`：Shopify 平台数据映射、分页同步、Webhook 验签和幂等、快照与对账；前台商品价格库存和购物车仍由 Shopify 承担。
2. `profiles`：档案、同意记录、匿名/登录身份、保留期限；可单独禁用持久档案而保留即时推荐。
3. `recommendations`：纯规则领域模块、可选模型排序、候选与加购复核；不把 AI 放入页面渲染主链。
4. `media_jobs`：图片上传、对象存储、任务状态机、幂等键、过期清理、访问授权、进度轮询。
5. `providers`：Seedream、可选排序模型、TripoSR；接口隔离、超时与错误分类、费用请求可审计。
6. `fitting`：资产清单、校准参数和权限；有配置的商品启用，无配置时正常使用普通商品页。

生产持久化建议关系数据库记录任务、Webhook inbox/outbox、档案和资产修订；队列须持久、任务有租约/心跳和故障恢复。当前 daemon Thread + JSON 文件 + 进程内锁在多实例/进程崩溃时不可靠，不能直接原封部署为“稳定后端”。图片与结果进入私有对象存储，短时授权下载；不可把用户照片放入公开主题 assets。

主题首屏不等待推荐、生图或 GPU。问卷、3D、上传 SDK 和查看器按交互加载；目录数据可以缓存，价格库存不得凭陈旧快照结算。Shopify App Proxy 或受控同源接口负责身份与签名校验；浏览器不保存 Admin API Token 或模型 Key。

## 必须确认的产品决定

- 是否完整保留“问卷/礼物盒、照片试穿、卡通转3D、小猫人工校准”，三视图是否也需要进入正式商品页？邮件、飞书、运营批量生图是否属于本次交付？
- 是否保留首单三件 20% 折扣；首单定义、是否允许叠加、是否仍按结账邮箱复核？
- 独立后端部署地点及是否具备 GPU，是否继续使用 Seedream/DeepSeek，预期并发、单用户生成额度和月成本范围？
- 宠物档案与照片是否需登录、保存多久、是否迁移旧客户数据；新增站点是否继续使用原同意文案和四种语言？
- Shopify 中如何维护宠物类型、年龄/犬型适用条件、试穿启用及 GLB/校准信息；普通上架商品自动进入主题不等于自动具备 3D 资产。

以上决定明确前，可以推进目录/规则模块的隔离、接口与数据模型文档及独立本地测试；不应替用户默认开放付费生成、折扣或历史消息功能。

## 本次已实现与后续确认结果

用户随后明确：本次仅迁网站现有功能，排除邮件、飞书和未上线 Demo；沿用原模型供应商，通过环境变量接入；访客填写问卷后即可使用，不强制登录；保留推荐礼物组合，暂不启用优惠；需支持以后更换 Shopify 店铺账号和迁移后端到云端。

对应源码已实现于 `migration/backend/app/domain` 与 `migration/backend/app/providers`：

- `catalog.py` 以 Shopify Product/Variant GID 映射原生商品，活跃及 Online Store 发布状态参与过滤；线上库存采用 `sellableOnlineQuantity`，支持不跟踪库存和允许超卖配置，价格保留 Decimal 字符串。
- `recommendations.py` 固定使用当前发布 DSL 的品类优先顺序，输出最多三件，不使用新 LLM；输入形状校验和最新目录复核独立提供。
- `service.py` 提供任务入口与配置检查，照片私有存储字节直接发送给模型，不经过 Dify。试穿生成前重新读取真实 Shopify 商品及所选规格；卡通完成后先保存 checkpoint，再进行 3D 重建。
- `providers/shopify.py` 通过官方 ShopifyAPI Session/GraphQL 建立授权请求，使用有明确超时的 HTTPX 传输；全量产品/规格分页和增量单品重读均已实现，凭据不进入浏览器。
- `providers/images.py` 直连原 Ark Seedream 或 Gemini Interactions 协议，无付费自动重试；不明确结果以 `GenerationUncertain` 交给任务系统处理，未配置返回真实不可用状态。
- `providers/triposr.py` 实现原 Gradio 预处理、低面数推理、受限输出路径下载与 GLB 校验。
- `fitting.py` 实现原确定性锚点与四元数计算、人工校准参数校验。归档公开猫/胸背校准数据在 `domain/data`；仅本店明确配置的商品 handle 与两资源 URL 对应使用，不绑定旧 WooCommerce ID，也不自动赋予其他商品试穿能力。

浏览器模块 `migration/theme/assets/cat-fitting.js` 使用本地随包 Three.js/GLTFLoader，按需加载。支持两模型合成、旋转/缩放、键盘操作、手机取景、离屏暂停、资源清理及 WebGL 不可用回退；不执行自动持续动画。原猫模型的 CC BY 4.0 署名保留在查看器中，Three.js MIT 许可随包提供。

本次验证：领域/提供商 23 项测试通过；包含当时基础设施测试的后端总计 36 项通过。真实 Edge headless 在新建的 `127.0.0.1:18765` 本地预览站验证两 GLB 可见、键盘旋转改变画面、390px 手机无横向溢出、无 WebGL 文字回退，正常加载路径没有页面或控制台错误。证据为 `migration/artifacts/cat-fitting-qa.json` 及两张截图。本次未使用真实店铺凭据、未调用收费模型，也未访问原站。
