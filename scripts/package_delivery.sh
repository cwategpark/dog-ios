#!/usr/bin/env bash
# Build the read-only review bundle for the current dog-ios delivery.
# Includes all source, every test suite/fixtures, sanitized evidence logs and the public golden model.
# Excludes runtimes, build products, databases, secrets, private uploads, outboxes and source snapshots.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${1:-/Users/jbf/Public/codex-handoff}"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/dog-ios-delivery-$STAMP.tar.gz"

# Sanitized evidence logs (emails/tokens/dev codes redacted) are what ships; raw logs stay local.
python3 "$ROOT/scripts/sanitize_logs.py"

mkdir -p "$ROOT/var/logs-public"
cd "$ROOT"
tar -czf "$OUT" \
  --exclude='./.git' \
  --exclude='./.handoff' \
  --exclude='./.pytest_cache' \
  --exclude='./test.txt' \
  --exclude='./backend/.venv' \
  --exclude='*/.venv' \
  --exclude='./backend/var' \
  --exclude='./backend/uploads' \
  --exclude='./var/logs' \
  --exclude='./var/ui-backend' \
  --exclude='./var/media' \
  --exclude='./var/outbox' \
  --exclude='./var/*outbox*' \
  --exclude='*outbox*' \
  --exclude='*.jsonl' \
  --exclude='*.token' \
  --exclude='*.db' \
  --exclude='*.db-shm' \
  --exclude='*.db-wal' \
  --exclude='*.sqlite' \
  --exclude='*.sqlite3' \
  --exclude='*.pyc' \
  --exclude='*/__pycache__' \
  --exclude='*/.pytest_cache' \
  --exclude='*.egg-info' \
  --exclude='./ios/build' \
  --exclude='./ios/.build' \
  --exclude='*/.build' \
  --exclude='*/DerivedData' \
  --exclude='*/xcuserdata' \
  --exclude='*.tar.gz' \
  --exclude='*.tar' \
  --exclude='.env' \
  --exclude='*/.env' \
  --exclude='*.env' \
  --exclude='.env.docker' \
  --exclude='.env.production' \
  --exclude='.env.local' \
  --exclude='._*' \
  --exclude='*/._*' \
  --exclude='*/__MACOSX/*' \
  --exclude='.DS_Store' \
  --exclude='*/node_modules' \
  .

# Hard requirements: tests, fixtures, public golden, sanitized logs must be in the archive.
LIST="$(mktemp)"
tar -tzf "$OUT" | sed 's#^\./##' > "$LIST"
for required in \
  'backend/tests/test_identity.py' \
  'backend/tests/test_concurrency_backend.py' \
  'backend/tests/test_deploy_examples.py' \
  'backend/tests/test_round3_regressions.py' \
  'backend/tests/test_social_pair_lock.py' \
  'backend/app/migrations/versions/0004_archive_compensation_pair_locks.py' \
  'docs/round3-fixes.md' \
  'scripts/run_ui_backend.sh' \
  'scripts/seed_ui_fixtures.py' \
  'docs/ui-qa-backend.md' \
  'web-integration/tests/pure-logic.test.js' \
  'web-integration/tests/static-checks.js' \
  'web-integration/tests/claim-interaction.test.js' \
  'ios/Tests/DataLayerTests/DTODecodingTests.swift' \
  'ios/Tests/DataLayerTests/SessionRaceTests.swift' \
  'ios/PawlyDemo/Features/Mobile/MobileRootView.swift' \
  'ios/PawlyDemo/Resources/Viewer/THREE-LICENSE.txt' \
  'docs/ios-frontend-acceptance.md' \
  'docs/frontend-import-manifest.json' \
  'docs/screenshots/ios/07-account.png' \
  'artifacts/frontend-qa/ui-acceptance-final.json' \
  'public-assets/website-golden-master.glb' \
  'var/logs-public/'; do
  if ! grep -q "^${required}" "$LIST"; then
    echo "missing required archive entry: $required" >&2
    rm -f "$LIST"
    exit 1
  fi
done
# No live secrets/private runtime state may ship.
if grep -E '(^|/)\.env$|\.env\.docker$|/email-outbox|\.jsonl$|/([0-9a-f]{64})$|\.db(-shm|-wal)?$|\.sqlite3?$' "$LIST" >/dev/null; then
  echo "refusing to ship secret/runtime entry; inspect archive listing" >&2
  grep -E '(^|/)\.env$|\.env\.docker$|/email-outbox|\.jsonl$|/([0-9a-f]{64})$|\.db(-shm|-wal)?$|\.sqlite3?$' "$LIST" >&2
  rm -f "$LIST"
  exit 1
fi
TEST_COUNT="$(grep -cE '^backend/tests/.*\.py$' "$LIST")"
WEB_COUNT="$(grep -cE '^web-integration/tests/.*\.js$' "$LIST")"
SWIFT_COUNT="$(grep -cE '^ios/Tests/.*\.swift$' "$LIST")"
echo "archive entries: $(wc -l < "$LIST" | tr -d ' '); backend tests=$TEST_COUNT; web tests=$WEB_COUNT; swift tests=$SWIFT_COUNT"
rm -f "$LIST"

shasum -a 256 "$OUT" | tee "$OUT.sha256"
du -h "$OUT"
echo "$OUT"
