# 部署、迁移与升级（Ubuntu / Docker）

本仓库本轮**没有启动公网服务**，以下为迁移聊天部署到 Ubuntu 时的操作基线；请保持「一套后端、一份数据库」，不要为网站和 App 各起一套独立身份库。

## 1. 运行时

- Python ≥ 3.12（3.12.16 已验证）。后端依赖锁定在 `backend/requirements.lock.txt`。
- 进程：`uvicorn app.main:app`（API）+ `python -m app.worker`（生成任务、归档、清理）。两者共享同一数据库与媒体卷。
- 数据库：开发 SQLite；生产 PostgreSQL（`WAGELPAW_DATABASE_URL=postgresql+psycopg://…`）。
- 媒体：私有文件系统目录（`WAGELPAW_STORAGE_PATH`），**不能放在 Web 根目录**；多机部署前必须先做共享对象存储适配器。

## 2. 首次启动

```bash
cd backend
python3.12 -m venv .venv
./.venv/bin/pip install -r requirements.lock.txt
./.venv/bin/pip install --no-deps -e .
cp .env.example .env    # 按部署环境修改；.env 不入库
./.venv/bin/python -m app.db init   # Alembic upgrade head（0001 → 0002 → 0003 → 0004）
./.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 18766
```

健康检查：`GET /healthz`；`GET /readyz` 返回 `email_delivery`、`default_model`、`mobile_api` 等布尔/枚举状态，不返回密钥。

## 3. 关键环境变量

- 身份/邮件：`WAGELPAW_PUBLIC_BASE_URL`（仅未来启用 magic-link 时需要；本阶段链接默认关闭）、`WAGELPAW_SMTP_HOST/PORT/USERNAME/PASSWORD/FROM/USE_TLS`、`WAGELPAW_OTP_*`、`WAGELPAW_ACCESS_TOKEN_TTL_SECONDS`、`WAGELPAW_REFRESH_TOKEN_TTL_SECONDS`。
- 资产/模型：`WAGELPAW_PUBLIC_ASSETS_DIR`（指向含 `website-golden-master.glb` 的目录）、`WAGELPAW_ARCHIVED_UPLOAD_RETENTION_SECONDS`。
- 附近：`WAGELPAW_DISCOVERY_LOCATION_TTL_SECONDS`、`WAGELPAW_DISCOVERY_MAX_RADIUS_KM`、`WAGELPAW_DISCOVERY_DEFAULT_RADIUS_KM`。
- 生产禁止：`WAGELPAW_EXPOSE_DEV_OTP=0`、`WAGELPAW_DEV_EMAIL_OUTBOX=0`、`WAGELPAW_DEV_TOKEN` 必须为空（Settings 会在生产启动时拒绝）。

## 4. 数据库升级

- 已有 0001 的数据库直接 `python -m app.db init` 增量升级到 head；`0002_identity_assets_social` 与 `0003_guest_session_pets` 只新增表/列，不改写 0001/0002，可重复执行。
- 升级前：备份数据库 + `WAGELPAW_STORAGE_PATH` 媒体卷；在预发先验证。
- 回滚：回滚镜像前先确认旧版本能容忍新表（本次 0001 代码不读 0002 表，可回退镜像；数据保留）。需要降级 schema 用 `alembic downgrade`，但生产更推荐「迁移前备份 + 前滚修复」。
- 容器部署使用仓库根 [`deploy/`](../deploy/)：`deploy/Dockerfile`（构建上下文为仓库根，显式 `COPY public-assets/` 并设 `WAGELPAW_PUBLIC_ASSETS_DIR=/app/public-assets`）+ `deploy/compose.yml`（PostgreSQL 为默认，api/worker/migrate 共享 `/data` 卷，数据库密码由 `deploy/.env` 的 `POSTGRES_PASSWORD` 统一注入）。旧 `docs/deploy/` 重复示例已移除，避免构建上下文指向 `docs/` 的确定性错误。
- 本轮 Mac 无 Docker/PostgreSQL 运行时，`docker build/compose up` 未真实执行（见 `deploy/README.md`）；首次在有 Docker 的机器上需实际构建并验证 `/readyz` 的 `default_model`。

## 5. 生产硬性要求

- App Proxy 签名、店铺白名单、`WAGELPAW_TRUSTED_PROXY_IPS` 必须按真实反代链路配置；不接受任意客户端 XFF。
- HTTPS（App Transport Security 默认只允许 HTTPS；iOS 数据层对非 localhost 的 http baseURL 直接报 `insecureBaseURL`）。
- 单店铺单安装：同一数据库换店会被 `installation` 绑定检查拒绝；换店需新数据库 + 新媒体卷 + 新密钥。
- 邮件未配置时 `/v1/claims` 与 `/mobile/v1/auth/email/start` 明确 503，不会静默降级或打印 OTP。
