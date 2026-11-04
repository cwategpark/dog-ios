"""Shared helpers for the dog-ios backend test-suite."""
import hashlib
import hmac
import io
import json
import time
from pathlib import Path

from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.main import create_app

DEV_HEADERS = {"Authorization": "Bearer test-development-token"}
REPO_ROOT = Path(__file__).resolve().parents[2]


def build_settings(tmp_path, **overrides):
    defaults = dict(
        environment="test",
        database_url=f"sqlite:///{tmp_path / 'test.db'}",
        storage_path=tmp_path / "media",
        dev_token="test-development-token",
        rate_limit_salt="test-salt",
        sessions_per_ip_hour=100,
        otp_per_email_hour=100,
        otp_per_ip_hour=100,
        otp_resend_cooldown_seconds=0,
        shopify_api_secret="test-shopify-secret",
        allowed_shops=["example.myshopify.com"],
        dev_email_outbox=True,
        email_outbox_path=tmp_path / "email-outbox.jsonl",
        expose_dev_otp=True,
        public_base_url="https://app.example.test",
        public_assets_dir=REPO_ROOT / "public-assets",
        access_token_ttl_seconds=900,
        refresh_token_ttl_seconds=2592000,
    )
    defaults.update(overrides)
    return Settings(**defaults)


def make_client(settings):
    return TestClient(create_app(settings))


def proxy_query(secret, **overrides):
    values = {"shop": "example.myshopify.com", "timestamp": str(int(time.time())),
              "logged_in_customer_id": "", "path_prefix": "/apps/wagelpaw", **overrides}
    message = "".join(sorted(f"{key}={value}" for key, value in values.items()))
    return {**values, "signature": hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()}


def issue_guest(client, profile=None, email=None, full_name=None, shop="example.myshopify.com"):
    body = {"profile": profile or {"type": "cat", "age_months": 24, "name": "Milo"}, "consent": True}
    if email:
        body["email"] = email
    if full_name:
        body["full_name"] = full_name
    response = client.post("/v1/sessions", headers=DEV_HEADERS, json=body)
    assert response.status_code == 201, response.text
    return {"Authorization": "Bearer test-development-token",
            "X-Wagelpaw-Session": response.json()["session_token"]}, response.json()


def png_bytes(color="red"):
    output = io.BytesIO()
    Image.new("RGB", (12, 12), color).save(output, "PNG")
    return output.getvalue()


def upload_photo(client, headers):
    response = client.post("/v1/uploads", headers=headers,
                           files={"file": ("photo.png", png_bytes(), "image/png")})
    assert response.status_code == 201, response.text
    return response.json()


def read_outbox(settings, kind="otp", email=None):
    path = Path(settings.email_outbox_path)
    if not path.exists():
        return []
    entries = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        if entry.get("kind") != kind:
            continue
        if email and entry.get("to") != email:
            continue
        entries.append(entry)
    return entries


def start_mobile_login(client, settings, email):
    response = client.post("/mobile/v1/auth/email/start", json={"email": email, "purpose": "login"})
    assert response.status_code == 202, response.text
    payload = response.json()
    code = payload.get("dev_code")
    if not code:
        entries = read_outbox(settings, "otp", email.strip().lower())
        assert entries, "no OTP delivered"
        code = entries[-1]["code"]
    return payload, code


def mobile_login(client, settings, email):
    payload, code = start_mobile_login(client, settings, email)
    response = client.post("/mobile/v1/auth/email/verify", json={"challenge_id": payload["challenge_id"], "code": code})
    assert response.status_code == 200, response.text
    tokens = response.json()
    return tokens, {"Authorization": f"Bearer {tokens['access_token']}"}


def claim_website_session(client, settings, headers, email):
    response = client.post("/v1/claims", headers=headers, json={"email": email})
    assert response.status_code == 202, response.text
    payload = response.json()
    code = payload.get("dev_code")
    if not code:
        entries = read_outbox(settings, "otp", email.strip().lower())
        assert entries, "no claim OTP delivered"
        code = entries[-1]["code"]
    verify = client.post(f"/v1/claims/{payload['challenge_id']}/verify", headers=headers, json={"code": code})
    assert verify.status_code == 200, verify.text
    return payload, verify.json()
