#!/usr/bin/env bash
# Isolated loopback development backend for iOS UI QA (development only).
#
#   scripts/run_ui_backend.sh start     # default; binds 127.0.0.1:18766 only
#   scripts/run_ui_backend.sh status    # /healthz + /readyz + PID
#   scripts/run_ui_backend.sh stop
#
# Data lives under var/ui-backend/ (SQLite + private media + dev email outbox).
# It never uses the production database, real SMTP, paid providers, or a public interface.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$ROOT/backend"
WORK="${WAGELPAW_UI_WORKDIR:-$ROOT/var/ui-backend}"
PORT="${WAGELPAW_UI_PORT:-18766}"
PID_FILE="$WORK/uvicorn.pid"
ENV_FILE="$WORK/ui.env"
PY="$BACKEND/.venv/bin/python"
BASE="http://127.0.0.1:$PORT"
COMMAND="${1:-start}"

mkdir -p "$WORK/media"

health() { curl -fsS --max-time 3 "$BASE/healthz" >/dev/null 2>&1; }
ready() { curl -fsS --max-time 3 "$BASE/readyz" >/dev/null 2>&1; }

case "$COMMAND" in
  status)
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "pid=$(cat "$PID_FILE")"
    else
      echo "pid=none"
    fi
    if health; then echo "healthz=ok url=$BASE/healthz"; else echo "healthz=down"; fi
    if ready; then echo "readyz=ok"; curl -fsS --max-time 3 "$BASE/readyz"; echo; else echo "readyz=down"; fi
    exit 0
    ;;
  stop)
    if [[ -f "$PID_FILE" ]]; then
      PID="$(cat "$PID_FILE")"
      kill "$PID" 2>/dev/null || true
      for _ in $(seq 1 30); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
      rm -f "$PID_FILE"
      echo "stopped pid=$PID"
    else
      echo "no pid file"
    fi
    exit 0
    ;;
  start) ;;
  *) echo "usage: $0 {start|status|stop}" >&2; exit 2 ;;
esac

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null && health; then
  echo "already_running pid=$(cat "$PID_FILE") base=$BASE work=$WORK"
  exit 0
fi
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; refusing to start a second backend" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  umask 077
  DEV_TOKEN="$(openssl rand -hex 24)"
  SALT="$(openssl rand -hex 24)"
  cat > "$ENV_FILE" <<EOF
# Local iOS UI QA only. Never commit or ship this file.
WAGELPAW_ENVIRONMENT=development
WAGELPAW_DATABASE_URL=sqlite:///$WORK/ui.db
WAGELPAW_STORAGE_PATH=$WORK/media
WAGELPAW_PUBLIC_ASSETS_DIR=$ROOT/public-assets
WAGELPAW_PUBLIC_BASE_URL=$BASE
WAGELPAW_DEV_TOKEN='$DEV_TOKEN'
WAGELPAW_RATE_LIMIT_SALT='$SALT'
WAGELPAW_ALLOWED_SHOPS='["ui-qa.myshopify.com"]'
WAGELPAW_ALLOWED_ORIGINS='[]'
WAGELPAW_SHOPIFY_STORE_DOMAIN=ui-qa.myshopify.com
WAGELPAW_SHOPIFY_API_SECRET='ui-qa-shopify-secret'
WAGELPAW_SHOPIFY_ACCESS_TOKEN=
WAGELPAW_IMAGE_PROVIDER=ark
WAGELPAW_ARK_API_KEY=
WAGELPAW_SESSIONS_PER_IP_HOUR=2000
WAGELPAW_OTP_PER_EMAIL_HOUR=2000
WAGELPAW_OTP_PER_IP_HOUR=2000
WAGELPAW_OTP_RESEND_COOLDOWN_SECONDS=0
WAGELPAW_EXPOSE_DEV_OTP=1
WAGELPAW_DEV_EMAIL_OUTBOX=1
WAGELPAW_EMAIL_OUTBOX_PATH=$WORK/email-outbox.jsonl
WAGELPAW_CLAIM_LINK_ENABLED=0
WAGELPAW_CLAIM_LINK_SECRET=
WAGELPAW_SMTP_HOST=
WAGELPAW_SMTP_USERNAME=
WAGELPAW_SMTP_PASSWORD=
WAGELPAW_SMTP_FROM=
WAGELPAW_ACCESS_TOKEN_TTL_SECONDS=3600
WAGELPAW_MEDIA_RETENTION_SECONDS=604800
EOF
  chmod 600 "$ENV_FILE"
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
if [[ "${WAGELPAW_ENVIRONMENT:-}" != "development" && "${WAGELPAW_ENVIRONMENT:-}" != "test" ]]; then
  echo "refusing: UI QA backend must run in development/test" >&2
  exit 1
fi

cd "$BACKEND"
nohup "$PY" -m uvicorn app.main:app --host 127.0.0.1 --port "$PORT" --log-level info \
  >> "$WORK/uvicorn.log" 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"

for _ in $(seq 1 80); do
  if health; then
    echo "started pid=$PID base=$BASE work=$WORK"
    echo "healthz=$BASE/healthz readyz=$BASE/readyz"
    echo "seed=scripts/seed_ui_fixtures.py"
    exit 0
  fi
  sleep 0.25
done

echo "backend did not become healthy; last log lines:" >&2
tail -40 "$WORK/uvicorn.log" >&2 || true
exit 1
