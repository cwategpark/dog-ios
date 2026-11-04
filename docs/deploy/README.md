# docs/deploy 已并入仓库根 `deploy/`

为避免两份 Docker 示例漂移，本目录只保留 Caddy 反代示例；**唯一可构建的交付**是仓库根：

- 构建上下文：仓库根目录
- Dockerfile：`../deploy/Dockerfile`（显式 `COPY backend/` 与 `COPY public-assets/`）
- Compose：`../deploy/compose.yml`（PostgreSQL + migrate + api + worker）
- 环境模板：`../deploy/.env.docker.example`

用法见 [`../../deploy/README.md`](../../deploy/README.md)。旧 `docs/deploy/Dockerfile` 与
`docs/deploy/compose.yml` 的 `context: ..` 实际指向 `docs/`，`COPY backend/` 必然失败，已删除。
