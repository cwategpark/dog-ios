# Wagelpaw 独立后端

本服务不依赖 Dify。它为 Shopify 主题提供问卷访客会话、宠物档案、确定规则选品、私有图片、照片试穿、卡通/3D 与已校准小猫试衣任务。商品价格、库存、变体、购物车和结账由 Shopify 管理；本服务不会生成优惠码或宣称折扣已生效。

## 本地启动

在本目录用 Python 3.12+ 创建虚拟环境。安装 `requirements.lock.txt` 中的固定版本，再执行 `pip install --no-deps -e .`。复制 `.env.example` 为不提交版本库的 `.env`，设置随机开发 token 与限速 HMAC salt。

```powershell
python -m app.db init
uvicorn app.main:app --host 127.0.0.1 --port 18766
python -m app.worker
```

API 与 worker 是两个进程。开发认证仅用于隔离本地代理，由代理注入 `Authorization: Bearer <WAGELPAW_DEV_TOKEN>`，不得写进 Shopify 主题。生产环境配置该 token 会拒绝启动。

未设置模型/店铺连接时，可验证问卷、会话、私有文件与空目录。生成请求明确返回 HTTP 503，不会用静态图片冒充生成成功。测试使用受控 fake provider 和 HTTPX mock，不产生真实模型费用：`python -m pytest -q`。

## 访客接口契约

所有 `/v1/*` 请求先验证来源：生产为 Shopify App Proxy 签名、店铺白名单与时效；开发为本地代理 token。填写有效问卷并同意保存后，`POST /v1/sessions` 签发一次性的高熵会话 token，数据库只保存 SHA-256 摘要。

问卷请求为 `{ "profile": { "type": "cat", "age_months": 24 }, "consent": true }`。狗需增加 `dog_size`，取 `small`、`medium` 或 `large`。后续请求增加 `X-Wagelpaw-Session: <session_token>`；无需 Shopify 顾客登录，也不使用会被 App Proxy 去掉的 Cookie。访客 token 持有者拥有该会话访问权，前端应只在当前站点会话存储，不能放进 URL、分析事件或日志。

| 接口 | 行为 |
| --- | --- |
| GET `/healthz` | 进程存活 |
| GET `/readyz` | 数据库已迁移；返回模型/Shopify 配置布尔值，不返回密钥 |
| POST `/v1/sessions` | 验证问卷与同意，签发访客会话 |
| GET / PUT `/v1/pet-profile` | 读取/更新当前访客的匿名宠物档案 |
| GET `/v1/catalog?q=&pet=&scene=&kind=` | 当前店铺商品投影，筛选已上架商品 |
| POST `/v1/recommendations` | `{}` 使用当前档案；确定规则选品，返回前实时复核候选商品 |
| POST `/v1/uploads` | multipart `file`，JPEG/PNG/WebP；默认 8 MiB，重编码并去 EXIF |
| GET `/v1/uploads/{id}` | 会话 owner 校验后返回私有文件；前端 fetch 为 blob |
| POST `/v1/jobs` | `{kind,input}`，必须有 `Idempotency-Key`；创建 202，重复 200，冲突 409 |
| GET `/v1/jobs/{id}` | 仅 owner 可读取状态、结果、阶段输出 |
| POST `/webhooks/shopify` | 校验原始请求体 HMAC、店铺、事件 ID，并持久化去重 |

试穿输入：`{ "kind": "tryon", "input": { "pet_upload_id": "...", "product_id": "gid://shopify/Product/...", "variant_id": "gid://shopify/ProductVariant/...", "consent": true } }`，`variant_id` 可省略。

卡通/3D 输入：`{ "kind": "avatar", "input": { "source_job_id": "已完成的本人试穿任务", "consent": true } }`。小猫试衣输入为 `kind: "cat-fitting"`、`input: { "product_id": "...", "consent": true }`。模型/商品数据未配置完整时会明确失败，不能把任意商品猜成已校准模型。

结果 `assets` 中的 `url` 是受保护的相对 API 路径。前端需保留实际 App Proxy 前缀并带会话头请求，再创建 blob URL 展示；不能把该相对路径当成公开图片链接。

## 队列与费用边界

PostgreSQL 持久表同时承担任务队列，API 入队与额度更新在一个事务中提交。worker 使用租约、心跳、领取条件和完成时的 owner fencing；SQLite 仅供本地单进程验证。

任务状态为 `queued`、`running`、`succeeded`、`failed` 或 `needs_review`。同一 owner、店铺、幂等键和请求体只创建一个任务；同键不同请求体拒绝。已完成请求的幂等读取不受后续模型配置变化影响。worker 中断后，尚未发送的任务可以回到队列；已经开始执行生成、供应商超时/5xx/返回无法确认的结果时转为 `needs_review`，不会自动重新发起付费请求。

卡通生成完成即记录阶段输出。后续 3D 失败时，已有卡通仍可从任务结果访问。当前版本没有自动恢复未知供应商执行的管理操作，也不承诺外部模型 exactly-once；需要人工检查供应商记录后决定是否新建请求。

默认单会话与受信 IP 每小时各 3 次生成；IP 为带 salt 的 HMAC 摘要。会话总额、每小时额度与签发频率均可配置。匿名限速会受共享出口、代理拓扑、换 IP 影响，不能充当防刷账单系统；正式开放前应在入口增加适合实际流量的验证与费用告警。

## 商品同步与配置

首次可执行 `python -m app.worker --sync-catalog`，只读 Shopify Admin API。API 接收商品变更/删除与库存事件后，worker 重读 Shopify 当前状态更新投影，不依赖 webhook 到达顺序；worker 启动及默认每 24 小时完整对账一次，失败后约 5 分钟重试。`WAGELPAW_CATALOG_RECONCILE_SECONDS=0` 可关闭周期对账。未配置连接时不发起同步。

当前一个安装只对应一个 Shopify 店铺，生产 `ALLOWED_SHOPS` 必须恰好包含 `SHOPIFY_STORE_DOMAIN`。其他账号部署需独立环境文件、应用 secret、数据库和媒体 volume；同数据库换店会被 installation 绑定检查拒绝。无需修改 Python 中的店铺域名或商品 GID。

App Proxy 指向服务根路径，主题中的代理前缀由主题设置配置。官方签名与头部规则参见 [Authenticate app proxies](https://shopify.dev/docs/apps/build/online-store/app-proxies/authenticate-app-proxies) 与 [App proxies](https://shopify.dev/docs/apps/build/online-store/app-proxies)。重复查询参数按 Shopify 文档合并为逗号列表后参与 HMAC。签名证明请求来源，访客 token 证明任务所有权，两者均需验证。

生产反向代理必须配置请求体大小、TLS 和真实 IP 链。仅将受控代理的直接 peer IP 加入 `WAGELPAW_TRUSTED_PROXY_IPS`。`TRUSTED_PROXY_HOPS=1` 取 XFF 末项，适合本地代理；若 Nginx 在 Shopify XFF 后追加 Shopify 节点 IP，则在确认链路后使用 2，取倒数第二项客户 IP。不要盲信客户端提交的 XFF，也不要把 Shopify 节点当成所有顾客的共同 IP。部署验收需实际验证两个客户端是否获得独立额度。

## 存储、更新与迁移

媒体使用不在 Web 根目录中的私有文件系统，通过随机 storage key 写入。默认 24 小时后不可读取，worker 每分钟清理到期文件。原始上传被重编码为 JPEG，输入不接收任意外部 URL；商品图从服务端核实的 Shopify CDN 读取。模型及生成密钥只保存在运行环境，Settings 的 secret 字段不会在 repr/JSON 中泄露。

Ubuntu 首版可使用单主机 Docker 持久私有 volume + PostgreSQL + 定时备份。不支持多台主机各自独立媒体目录共享同一数据库；需要多主机时先实现兼容 `PrivateStorage.get_owned/save_output` 的共享对象存储适配器。更换服务器需同步数据库和媒体卷、配置文件及密钥，并验证照片 TTL 与任务状态；只拷贝代码不能恢复业务数据。

数据库升级由 `python -m app.db init` 执行捆绑的 Alembic migration；API 与 worker 拒绝未升级 schema。已经发布的 revision 不得修改，新增字段使用新版本迁移。运行升级前备份数据库与媒体，优先做兼容旧应用的增量迁移；备份恢复与镜像版本回退需配套验证。初始 schema 说明见 `migrations/001-initial.md`。

## dog-ios 共享后端增量（2026-11-04）

在原独立后端之上新增（原 0001 与旧接口保持不变）：

- `0002_identity_assets_social` 迁移：`users`（稳定不透明 user_id + 规范化邮箱唯一）、`email_challenges`、`mobile_sessions`、`pets`、`asset_archive`、`discovery_profiles`、`contact_requests`、`contacts`、`contact_messages`、`user_blocks`；`guest_sessions` 增 `user_id/email_normalized/full_name/claimed_at`，`uploads` 增 `archived/sha256`。
- `/mobile/v1`：邮箱 OTP 登录（短 access + 可轮换 refresh）、`/me`、`/pets`、`/pet-home`、`/assets`（分页 + 认证下载 + manifest）、`/discovery`+`/nearby`、联系人申请/接受、一对一消息、拉黑。
- `/v1/claims*`：网站游客会话的显式邮箱认领（OTP；magic-link 默认关闭并返回 503），认领前绝不自动继承同邮箱数据。
- `/public-assets/website-golden-master.glb`：默认金毛 GLB（真实 46,036,096 B）。
- worker 成功归档全部产物；失败/needs_review 的可信 checkpoint（如 cartoon）以 `partial` 归档且不伪造模型成功；已认领资产不受 24h 清理误删；SMTP 通过 `WAGELPAW_SMTP_*` 环境变量，未配置时明确 503，dev/test 可显式启用本地 outbox。
- 测试：原 69 项 + 新增 76 项（身份/OTP/并发/跨账号/归档/清理/部分产物+崩溃恢复/0003 迁移/附近/联系/App Proxy 认领/部署静态校验）= 145 项；另含真实 uvicorn + Swift 数据层跨语言 HTTP 验收脚本 `scripts/acceptance_live.py`。

细节见仓库根 `README.md`、`docs/endpoints.md`、`docs/deployment.md`、`docs/migration-handoff.md`。
