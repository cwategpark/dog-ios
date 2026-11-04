# 可复制演示：网站 → 邮箱验证认领 → 手机登录 → 图库 → 附近联系

以下全部在 Mac、**仅回环**运行，使用 test/development 本地邮箱 outbox（不发真实邮件）。
仓库根目录为 `/Users/jbf/Documents/dog-ios`。

## 0. 启动

```bash
cd backend
python3.12 -m venv .venv
./.venv/bin/pip install -r requirements.lock.txt
./.venv/bin/pip install --no-deps -e .
export WAGELPAW_ENVIRONMENT=development
export WAGELPAW_DEV_TOKEN=demo-token
export WAGELPAW_RATE_LIMIT_SALT=demo-salt
export WAGELPAW_DEV_EMAIL_OUTBOX=1
export WAGELPAW_EXPOSE_DEV_OTP=1
export WAGELPAW_EMAIL_OUTBOX_PATH=./var/email-outbox.jsonl
export WAGELPAW_PUBLIC_BASE_URL=http://127.0.0.1:18766
export WAGELPAW_ALLOWED_SHOPS='["example.myshopify.com"]'
export WAGELPAW_SHOPIFY_API_SECRET=demo-shopify-secret
./.venv/bin/python -m app.db init
./.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 18766
```

（自动化版：`backend/.venv/bin/python scripts/live_http_smoke.py`。）

## 1. 网站问卷（游客会话，不认领）

```bash
S=$(curl -s -X POST localhost:18766/v1/sessions \
  -H 'Authorization: Bearer demo-token' -H 'content-type: application/json' \
  -d '{"profile":{"type":"dog","age_months":18,"dog_size":"large","name":"直播金毛"},"consent":true,"email":"demo@example.com","full_name":"Demo"}')
TOKEN=$(echo "$S" | python3 -c 'import sys,json;print(json.load(sys.stdin)["session_token"])')
```

## 2. 保存到 App（OTP 认领）

```bash
C=$(curl -s -X POST localhost:18766/v1/claims \
  -H 'Authorization: Bearer demo-token' -H "X-Wagelpaw-Session: $TOKEN" \
  -H 'content-type: application/json' -d '{"email":"demo@example.com"}')
echo "$C"    # 含 challenge_id、dev_code（仅开发/测试暴露）
CH=$(echo "$C" | python3 -c 'import sys,json;print(json.load(sys.stdin)["challenge_id"])')
CODE=$(echo "$C" | python3 -c 'import sys,json;print(json.load(sys.stdin)["dev_code"])')
curl -s -X POST localhost:18766/v1/claims/$CH/verify \
  -H 'Authorization: Bearer demo-token' -H "X-Wagelpaw-Session: $TOKEN" \
  -H 'content-type: application/json' -d "{\"code\":\"$CODE\"}"
```

本阶段 magic-link 默认关闭（`POST /v1/claims/$CH/link` 返回 503 `claim_link_disabled`，不返回 token）；认领统一使用上面的 OTP 路径。

## 3. 手机邮箱登录

```bash
M=$(curl -s -X POST localhost:18766/mobile/v1/auth/email/start \
  -H 'content-type: application/json' -d '{"email":"demo@example.com"}')
CH2=$(echo "$M" | python3 -c 'import sys,json;print(json.load(sys.stdin)["challenge_id"])')
CODE2=$(echo "$M" | python3 -c 'import sys,json;print(json.load(sys.stdin)["dev_code"])')
V=$(curl -s -X POST localhost:18766/mobile/v1/auth/email/verify \
  -H 'content-type: application/json' -d "{\"challenge_id\":\"$CH2\",\"code\":\"$CODE2\"}")
ACCESS=$(echo "$V" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s localhost:18766/mobile/v1/me -H "Authorization: Bearer $ACCESS"
```

## 4. 图库与宠物主页

```bash
curl -s localhost:18766/mobile/v1/assets -H "Authorization: Bearer $ACCESS"
curl -s localhost:18766/mobile/v1/pet-home -H "Authorization: Bearer $ACCESS"   # 默认金毛 manifest
curl -s localhost:18766/public-assets/website-golden-master.glb -o /tmp/golden.glb
shasum -a 256 /tmp/golden.glb   # 96efb8f20105d2280b332a13e926966c935c8e01e5ef5843be5183352283146b
```

## 5. 附近与联系（需要两个已验证用户）

1. 用户 A、B 各自 `POST /mobile/v1/discovery {"enabled":true,"region":{"lat":31.23,"lon":121.47}}`；
2. `GET /mobile/v1/nearby`（A）拿到 B 的 `public_ref`，响应不含 email/精确坐标；
3. `POST /mobile/v1/contacts/requests {"target_public_ref": …}` → B `accept` → 双方 `GET /mobile/v1/contacts`；
4. `POST /mobile/v1/messages {"contact_id":…,"body":"你好","client_id":"c-1"}`，重复同 `client_id` 幂等；
5. 任一方 `POST /mobile/v1/blocks` 后：nearby 互相不可见、请求/消息 403。
