# dog-ios 共享后端容器镜像（构建上下文 = 仓库根目录）
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    WAGELPAW_PUBLIC_ASSETS_DIR=/app/public-assets \
    WAGELPAW_STORAGE_PATH=/data/media
# DATABASE_URL 由 compose env_file（deploy/.env）提供；生产必须是 PostgreSQL，
# 不在镜像里内置 sqlite 默认值，避免误用与生产守卫冲突。

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# 依赖锁文件来自 backend/，与生产 Python 3.12 匹配
COPY backend/requirements.lock.txt /app/requirements.lock.txt
RUN pip install -r /app/requirements.lock.txt

# 应用源码
COPY backend/ /app/
# 公开金毛模型必须随镜像交付（默认宠物主页 manifest 依赖真实文件）
COPY public-assets/ /app/public-assets/

RUN pip install --no-deps -e /app

EXPOSE 18766
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -fsS http://127.0.0.1:18766/healthz || exit 1

CMD ["sh", "-c", "python -m app.db init && uvicorn app.main:app --host 0.0.0.0 --port 18766"]
