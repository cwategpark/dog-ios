import asyncio
import base64
import hashlib
import hmac
import io
import json
import time

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from pydantic import SecretStr, ValidationError
from sqlalchemy import select

from app.config import Settings
from app.db import bind_installation, check_schema, init_database, make_engine
from app.jobs import claim_job, finish_job, recover_expired
from app.main import create_app
from app.models import GuestSession, Job, Upload, WebhookEvent
from app.providers.errors import GenerationUncertain
from app.worker import run_job, serve


@pytest.fixture
def client(tmp_path):
    settings = Settings(environment="test", database_url=f"sqlite:///{tmp_path / 'test.db'}",
                        storage_path=tmp_path / "media", dev_token="test-development-token",
                        rate_limit_salt="test-salt", sessions_per_ip_hour=100,
                        shopify_api_secret="test-shopify-secret", allowed_shops=["example.myshopify.com"])
    app = create_app(settings)
    with TestClient(app) as client:
        yield client


def issue(client, profile=None):
    response = client.post("/v1/sessions", json={"profile": profile or {"type": "cat", "age_months": 24}, "consent": True},
                           headers={"Authorization": "Bearer test-development-token"})
    assert response.status_code == 201, response.text
    return {"Authorization": "Bearer test-development-token", "X-Wagelpaw-Session": response.json()["session_token"]}


def image_bytes():
    output = io.BytesIO()
    Image.new("RGB", (10, 10), "red").save(output, "PNG")
    return output.getvalue()


def new_upload(client, headers):
    response = client.post("/v1/uploads", files={"file": ("../../photo.png", image_bytes(), "image/png")}, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


def fake_generation(monkeypatch):
    monkeypatch.setattr("app.domain.service.ensure_configured", lambda *_: None)


def submit(client, headers, upload_id, key="stable-request-key"):
    return client.post("/v1/jobs", headers={**headers, "Idempotency-Key": key},
                       json={"kind": "tryon", "input": {"pet_upload_id": upload_id,
                             "product_id": "gid://shopify/Product/107", "consent": True}})


def test_guest_questionnaire_validation_and_hashed_sessions(client):
    response = client.post("/v1/sessions", json={"profile": {"type": "dog", "age_months": 3}, "consent": True},
                           headers={"Authorization": "Bearer test-development-token"})
    assert response.status_code == 422
    headers = issue(client)
    with client.app.state.sessions() as db:
        row = db.scalar(select(GuestSession))
        assert row.token_hash != headers["X-Wagelpaw-Session"]
        assert len(row.token_hash) == 64
    assert client.get("/v1/pet-profile", headers=headers).json()["profile"]["pet_information"]["type"] == "cat"
    assert client.get("/v1/pet-profile", headers={"Authorization": headers["Authorization"]}).status_code == 401


def test_expired_session_fails_closed(client):
    headers = issue(client)
    with client.app.state.sessions() as db:
        row = db.scalar(select(GuestSession))
        row.expires_at = time.time() - 1
        db.commit()
    assert client.get("/v1/pet-profile", headers=headers).status_code == 401


def test_upload_validation_and_owner_isolation(client):
    first, second = issue(client), issue(client)
    asset = new_upload(client, first)
    response = client.get(asset["url"], headers=first)
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/jpeg")
    assert response.headers["cache-control"] == "no-store"
    assert client.get(asset["url"], headers=second).status_code == 404
    assert client.post("/v1/uploads", headers=first, files={"file": ("x.png", b"not-image", "image/png")}).status_code == 415
    assert client.post("/v1/uploads", headers=first, files={"file": ("x.jpg", image_bytes(), "image/jpeg")}).status_code == 415
    with client.app.state.sessions() as db:
        stored = db.get(Upload, asset["id"])
        assert "/" not in stored.storage_key and ".." not in stored.filename


def test_generation_missing_provider_is_503_never_fake_success(client):
    headers = issue(client)
    asset = new_upload(client, headers)
    response = submit(client, headers, asset["id"])
    assert response.status_code == 503
    with client.app.state.sessions() as db:
        assert db.scalar(select(Job)) is None


def test_idempotency_conflict_and_job_owner_isolation(client, monkeypatch):
    fake_generation(monkeypatch)
    first, second = issue(client), issue(client)
    asset = new_upload(client, first)
    created = submit(client, first, asset["id"])
    assert created.status_code == 202
    repeated = submit(client, first, asset["id"])
    assert repeated.status_code == 200
    assert repeated.json()["id"] == created.json()["id"]
    other = new_upload(client, first)
    assert submit(client, first, other["id"]).status_code == 409
    assert client.get("/v1/jobs/" + created.json()["id"], headers=second).status_code == 404
    assert submit(client, second, asset["id"], "other-request-key").status_code == 404
    with client.app.state.sessions() as db:
        owner = db.scalar(select(GuestSession).where(GuestSession.jobs_submitted > 0))
        assert owner.jobs_submitted == 1


def test_generation_hourly_ip_quota_cannot_be_bypassed_with_new_session(client, monkeypatch):
    fake_generation(monkeypatch)
    for index in range(3):
        headers = issue(client)
        asset = new_upload(client, headers)
        assert submit(client, headers, asset["id"], f"request-key-{index}").status_code == 202
    headers = issue(client)
    asset = new_upload(client, headers)
    assert submit(client, headers, asset["id"], "request-key-4").status_code == 429


def proxy_query(secret, **overrides):
    values = {"shop": "example.myshopify.com", "timestamp": str(int(time.time())), "logged_in_customer_id": "", "path_prefix": "/apps/wagelpaw", **overrides}
    message = "".join(sorted(f"{key}={value}" for key, value in values.items()))
    return {**values, "signature": hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()}


def test_app_proxy_signature_guest_access_timestamp_and_shop_allowlist(client):
    body = {"profile": {"type": "cat", "age_months": 3}, "consent": True}
    query = proxy_query("test-shopify-secret")
    response = client.post("/v1/sessions", params=query, json=body)
    assert response.status_code == 201
    token = response.json()["session_token"]
    assert client.get("/v1/pet-profile", params=query, headers={"X-Wagelpaw-Session": token}).status_code == 200
    assert client.get("/v1/pet-profile", params={**query, "shop": "evil.myshopify.com"}, headers={"X-Wagelpaw-Session": token}).status_code == 401
    assert client.post("/v1/sessions", params=proxy_query("test-shopify-secret", timestamp=str(int(time.time()) - 1000)), json=body).status_code == 401
    assert client.post("/v1/sessions", params=proxy_query("test-shopify-secret", shop="evil.myshopify.com"), json=body).status_code == 403


def test_webhook_raw_hmac_dedupe_and_conflicting_replay(client):
    raw = b'{"id":107, "title":"Example"}'
    def headers_for(data):
        signature = base64.b64encode(hmac.new(b"test-shopify-secret", data, hashlib.sha256).digest()).decode()
        return {"X-Shopify-Shop-Domain": "example.myshopify.com", "X-Shopify-Hmac-Sha256": signature,
                "X-Shopify-Topic": "products/update", "X-Shopify-Event-Id": "event-123", "Content-Type": "application/json"}
    first = client.post("/webhooks/shopify", content=raw, headers=headers_for(raw))
    assert first.status_code == 202
    assert first.json()["duplicate"] is False
    assert client.post("/webhooks/shopify", content=raw, headers=headers_for(raw)).json()["duplicate"] is True
    assert client.post("/webhooks/shopify", content=raw.replace(b" ", b""), headers=headers_for(raw)).status_code == 401
    changed = b'{"id":108}'
    assert client.post("/webhooks/shopify", content=changed, headers=headers_for(changed)).status_code == 409
    with client.app.state.sessions() as db:
        assert len(db.scalars(select(WebhookEvent)).all()) == 1


def test_lease_recovery_never_retries_unknown_paid_dispatch(client, monkeypatch):
    fake_generation(monkeypatch)
    headers = issue(client)
    asset = new_upload(client, headers)
    job_id = submit(client, headers, asset["id"]).json()["id"]
    sessions = client.app.state.sessions
    claimed = claim_job(sessions, client.app.state.settings, "dead-worker")
    assert claimed.id == job_id
    with sessions() as db:
        row = db.get(Job, job_id)
        row.lease_until = time.time() - 1
        row.dispatched_at = time.time() - 100
        db.commit()
    recover_expired(sessions)
    with sessions() as db:
        assert db.get(Job, job_id).status == "needs_review"
    assert not finish_job(sessions, job_id, "dead-worker", "succeeded", result={})
    assert claim_job(sessions, client.app.state.settings, "other-worker") is None


def test_worker_persists_success_and_uncertain_outcome(client, monkeypatch):
    fake_generation(monkeypatch)
    headers = issue(client)
    asset = new_upload(client, headers)
    one = submit(client, headers, asset["id"], "successful-job-key").json()["id"]
    async def success(kind, payload, context):
        artifact = context["storage"].get_owned(payload["pet_upload_id"])
        output = context["storage"].save_output(artifact.data, artifact.mime_type, "result.jpg")
        return {"kind": kind, "status": "succeeded", "assets": [{**output, "role": "tryon"}]}
    assert asyncio.run(run_job(client.app.state.settings, client.app.state.sessions, "worker-1", success))
    result = client.get(f"/v1/jobs/{one}", headers=headers).json()
    assert result["status"] == "succeeded"
    assert client.get(result["result"]["assets"][0]["url"], headers=headers).status_code == 200
    two = submit(client, headers, asset["id"], "uncertain-job-key").json()["id"]
    calls = []
    async def uncertain(*args):
        calls.append(1)
        raise GenerationUncertain("remote accepted but response lost")
    asyncio.run(run_job(client.app.state.settings, client.app.state.sessions, "worker-2", uncertain))
    assert client.get(f"/v1/jobs/{two}", headers=headers).json()["status"] == "needs_review"
    assert not asyncio.run(run_job(client.app.state.settings, client.app.state.sessions, "worker-3", uncertain))
    assert len(calls) == 1


def test_production_cannot_use_sqlite_or_development_auth():
    with pytest.raises(ValidationError):
        Settings(environment="production")
    with pytest.raises(ValidationError):
        Settings(environment="production", database_url="postgresql+psycopg://x:x@localhost/x", dev_token="unsafe")


def test_schema_revision_is_repeatable_and_installation_cannot_change_store(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'migration.db'}")
    with pytest.raises(RuntimeError, match="database_schema_upgrade_required"):
        check_schema(engine)
    init_database(engine)
    init_database(engine)
    check_schema(engine)
    bind_installation(engine, "first.myshopify.com")
    bind_installation(engine, "first.myshopify.com")
    with pytest.raises(RuntimeError, match="another_store"):
        bind_installation(engine, "second.myshopify.com")
    engine.dispose()


def test_partial_stage_remains_visible_when_later_generation_is_uncertain(client, monkeypatch):
    fake_generation(monkeypatch)
    headers = issue(client)
    asset = new_upload(client, headers)
    job_id = submit(client, headers, asset["id"], "partial-stage-job").json()["id"]
    async def execute_with_checkpoint(kind, payload, context):
        context["checkpoint"]("cartoon_ready", {"status": "running", "assets": [{"id": asset["id"], "role": "cartoon"}]})
        raise GenerationUncertain("3D outcome unknown")
    asyncio.run(run_job(client.app.state.settings, client.app.state.sessions, "worker", execute_with_checkpoint))
    row = client.get(f"/v1/jobs/{job_id}", headers=headers).json()
    assert row["status"] == "needs_review"
    assert row["result"]["stage"] == "cartoon_ready"
    assert row["result"]["assets"][0]["role"] == "cartoon"


def test_proxy_signature_merges_duplicate_values_before_sorting(client):
    pairs = [("shop", "example.myshopify.com"), ("timestamp", str(int(time.time()))),
             ("logged_in_customer_id", ""), ("extra", "one"), ("extra", "two"), ("path_prefix", "/apps/wagelpaw")]
    values = {}
    for key, value in pairs:
        values.setdefault(key, []).append(value)
    message = "".join(sorted(key + "=" + ",".join(items) for key, items in values.items()))
    signature = hmac.new(b"test-shopify-secret", message.encode(), hashlib.sha256).hexdigest()
    response = client.post("/v1/sessions", params=[*pairs, ("signature", signature)],
                           json={"profile": {"type": "cat", "age_months": 4}, "consent": True})
    assert response.status_code == 201


@pytest.mark.parametrize("declared_length", [None, "1"])
def test_streamed_upload_limit_cannot_be_bypassed_with_missing_or_false_length(client, declared_length):
    client.app.state.settings.max_upload_bytes = 10
    headers = {"Content-Type": "multipart/form-data; boundary=x"}
    if declared_length is not None:
        headers["Content-Length"] = declared_length
    response = client.post("/v1/uploads", content=iter([b"x" * 65536, b"y" * 65536, b"z" * 65536]), headers=headers)
    assert response.status_code == 413


def test_idempotency_can_read_completed_result_when_provider_is_now_unconfigured(client, monkeypatch):
    fake_generation(monkeypatch)
    headers = issue(client)
    asset = new_upload(client, headers)
    job_id = submit(client, headers, asset["id"]).json()["id"]
    with client.app.state.sessions() as db:
        row = db.get(Job, job_id)
        row.status = "succeeded"
        row.result = {"kind": "tryon", "status": "succeeded", "assets": []}
        db.commit()
    def not_configured(*args):
        from app.providers.errors import ProviderNotConfigured
        raise ProviderNotConfigured("removed")
    monkeypatch.setattr("app.domain.service.ensure_configured", not_configured)
    response = submit(client, headers, asset["id"])
    assert response.status_code == 200
    assert response.json()["id"] == job_id
    assert response.json()["status"] == "succeeded"


def test_worker_reconciles_without_any_webhook_delivery(client, monkeypatch):
    settings = client.app.state.settings
    settings.shopify_store_domain = "example.myshopify.com"
    settings.shopify_access_token = SecretStr("not-a-real-token")
    calls = []
    async def fake_sync(*args):
        calls.append(1)
        return 0
    monkeypatch.setattr("app.worker.sync_catalog", fake_sync)
    asyncio.run(serve(settings, client.app.state.sessions, once=True))
    assert calls == [1]
    settings.catalog_reconcile_seconds = 0
    asyncio.run(serve(settings, client.app.state.sessions, once=True))
    assert calls == [1]


def test_settings_repr_and_json_do_not_reveal_credentials():
    settings = Settings(ark_api_key="ark-secret-test", gemini_api_key="gemini-secret-test",
                        shopify_access_token="shopify-secret-test", database_url="postgresql+psycopg://u:password-secret-test@host/db")
    for output in (repr(settings), settings.model_dump_json()):
        for value in ("ark-secret-test", "gemini-secret-test", "shopify-secret-test", "password-secret-test"):
            assert value not in output
