# Ubuntu 部署、升级和搬迁

建议单主机模块化服务：API、worker、PostgreSQL 和私有媒体卷。AI 推理可在另一台受保护 GPU 主机；业务数据库、图片不能挂到公网静态目录。首次无需 Redis 或 Kubernetes。

## 单店部署

安装 Docker Engine 与 Compose v2 后，将独立源码包放到新目录。在 `deploy` 复制 `.env.production.example` 为 `.env.production`，设置本店凭据、URL 安全随机数据库密码、独立 HMAC salt 和模型配置。密钥文件限制权限并交由自己的密钥管理流程保存。

```bash
cd deploy
docker compose --env-file .env.production -p wagelpaw_store_a build
docker compose --env-file .env.production -p wagelpaw_store_a up -d
docker compose --env-file .env.production -p wagelpaw_store_a ps
curl --fail http://127.0.0.1:18766/readyz
```

每家店使用不同 `-p`、目录、环境文件和 API 端口。Compose volume 名按 project 隔离；数据库不映射宿主端口。迁移服务完成后才启动 API/worker。媒体卷允许同主机 API 与 worker 共享，当前不支持跨多台主机各自独立存放媒体却共用数据库。

API 仅绑定回环地址，通过服务器 Caddy/Nginx 配置 HTTPS。`Caddyfile.example` 是拓扑示例，需要替换域名并核对真实 IP 链。请求体上限需兼容 8 MiB 图片和 multipart 开销。不能直接将应用开发 token 放进公网请求；生产配置非空开发 token 会拒绝启动。

Shopify App Proxy、反代和容器可能有多层代理，生产必须按实际链配置 `TRUSTED_PROXY_IPS`、`TRUSTED_PROXY_HOPS`。不能盲信访客自报 XFF，或把同一个代理出口误当成全部用户。用两个实际网络来源验证额度隔离后再开放生成。

生成模型沿用仓库 Seedream/可选 Gemini + 私有 TripoSR。权重和 GPU 环境不在主题安装包内，参考仓库 `services/triposr` 的部署源码，单独在隔离环境构建。`TRIPOSR_BASE_URL` 为服务器配置，不由访客输入。真实外部服务尚需用自己的地域、网络和额度联调。

## 数据备份与服务器搬迁

备份单位是 **数据库、私有媒体、配置密钥、当前代码/镜像版本和主题运营配置**。只备份源码无法恢复用户文件和任务。备份含私有照片，应加密、限制访问并遵守同样的保留期限。

为获得一致快照，维护窗口暂停接新任务并停止 API/worker，保留数据库运行；已执行中的收费任务需要核对供应商状态，不可当成普通队列随意重发。示例命令应在确认目标 project 后执行：

```bash
docker compose --env-file .env.production -p wagelpaw_store_a stop api worker
docker compose --env-file .env.production -p wagelpaw_store_a exec -T db pg_dump -U wagelpaw -d wagelpaw -Fc > /secure-backups/wagelpaw-db.dump
docker compose --env-file .env.production -p wagelpaw_store_a run --rm --no-deps -T --entrypoint tar api -C /data/media -czf - . > /secure-backups/wagelpaw-media.tar.gz
docker compose --env-file .env.production -p wagelpaw_store_a up -d api worker
```

新服务器使用同一店铺、同一代码/数据库版本和 **新的空目标 volume**。先恢复数据库 dump 和媒体，确认安装绑定与版本，再启动服务、执行增量迁移，验证文件 owner、有效期和队列状态。恢复会覆盖目标数据，因此不能对现有其他店铺运行；这份文档不会自动执行恢复或删除卷。

迁移店铺账号与迁移同店服务器不同：同店服务器搬迁保留原安装身份和数据；换店账号建立新 DB/volume，重新绑定公开商品资源，不能复制原访客数据或强改 installation 店铺字段绕过保护。

## 更新发布和回滚

1. 固定新代码标签、镜像标签、锁文件和安装清单；先在独立测试数据库和未发布主题验收。
2. 备份线上数据库、媒体、旧镜像版本、主题 `settings_data.json` 和运营 JSON 模板。
3. 新增 Alembic revision，使用兼容旧应用的扩展式数据库迁移；不可修改已经发布的 revision。迁移服务执行 `python -m app.db init`。
4. 后端升级后先检查 readiness、队列、目录对账和 Webhook。主题新代码以未发布主题安装，并合并本店运营设置、菜单、系列和资源引用，不能用源码默认配置直接覆盖。
5. 验收后切换主题。回滚优先切回旧主题和旧兼容镜像，保留任务和媒体；数据库是否需要恢复取决于迁移兼容性。不要把删除卷当回滚命令。

每次变更记录代码版本、schema revision、Shopify API 版本、模型/提示词版本、配置差异、执行人和验证结果。Shopify API 按固定 `2026-07` 开发，升级时重新运行 GraphQL 校验、后端测试和目标店回归；不要靠无版本 URL 自动漂移。
