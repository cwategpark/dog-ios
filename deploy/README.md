# deploy/ 容器部署说明

本目录提供可直接构建的 Docker 交付（构建上下文 = **仓库根目录**，因此 `COPY backend/` 与
`COPY public-assets/` 都能命中；旧 `docs/deploy/` 重复示例已移除）。

## 组成

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | Python 3.12 + 依赖锁 + `backend/` 源码 + `public-assets/` 金毛模型；启动前自动 `app.db init`（Alembic head） |
| `compose.yml` | PostgreSQL + `migrate` + `api` + `worker`；api/worker 共享 `/data` 卷；数据库密码统一由 `deploy/.env` 注入 |
| `.env.docker.example` | 环境变量模板（生产 + PostgreSQL，无真实密钥） |
| `../.dockerignore` | 防止把 `.venv`、`.git`、数据库、构建产物打进镜像 |

关键点：镜像内 `WAGELPAW_PUBLIC_ASSETS_DIR=/app/public-assets` 是**显式**路径，不依赖 Mac
工作目录；媒体在 `/data/media`；worker 与 api 使用同一 PostgreSQL 与媒体卷。

## 启动

```bash
cd deploy
cp .env.docker.example .env
# 编辑 .env：店铺域名、Shopify secret/token、RATE_LIMIT_SALT、POSTGRES_PASSWORD、SMTP。
# 不要提交 .env；WAGELPAW_DATABASE_URL 与 POSTGRES_PASSWORD 中的密码必须一致。
docker compose up -d --build
curl -fsS http://127.0.0.1:18766/healthz
curl -fsS http://127.0.0.1:18766/readyz
```

`compose.yml` 的 `${POSTGRES_PASSWORD:?...}` 由 Compose 从 **deploy/.env** 插值，同时该文件
通过 `env_file` 注入容器；因此只需维护一处密码。生产 `Settings` 会拒绝 sqlite、空 Shopify
secret 和空 rate-limit salt，启动失败即表示 `.env` 未填全。

## 验证状态（诚实）

- 本轮 Mac 上**没有 Docker / Podman / psql 运行时**（`docker`、`psql` 均未安装），因此
  **未真实执行 `docker build` / `docker compose up` / PostgreSQL 迁移**。已做静态校验：
  构建上下文与 COPY 路径存在、compose YAML 可解析、env 示例可被生产 `Settings` 接受、
  `public-assets/website-golden-master.glb` 随镜像复制、依赖锁文件包含 psycopg。
- 迁移与升级在宿主 Python 3.12 上已用 0001→head 测试覆盖（见 `backend/tests/test_migration_upgrade.py`）。
- 首次在有 Docker 的机器上请按上面命令实际构建，并验证 `/readyz` 的 `default_model` 为
  `website-golden-master`、`database`/`email_delivery` 与配置一致。
