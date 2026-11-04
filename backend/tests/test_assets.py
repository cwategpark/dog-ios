import asyncio
import hashlib
import time

import pytest
from sqlalchemy import select

from app.assets import archive_job_result, default_model_metadata
from app.models import AssetArchive, Job, Pet, Upload
from app.storage import cleanup_expired
from app.worker import run_job

from .support import (REPO_ROOT, build_settings, claim_website_session, issue_guest,
                      make_client, mobile_login, png_bytes, upload_photo)

MODEL_BYTES = b"glTF\x02\x00\x00\x00" + b"dog-ios-test-model" * 16
GOLDEN_BYTES = 46036096
GOLDEN_SHA = "96efb8f20105d2280b332a13e926966c935c8e01e5ef5843be5183352283146b"


def fake_generation(monkeypatch):
    monkeypatch.setattr("app.domain.service.ensure_configured", lambda *_: None)


def submit_tryon(client, headers, upload_id, key):
    return client.post("/v1/jobs", headers={**headers, "Idempotency-Key": key},
                       json={"kind": "tryon", "input": {"pet_upload_id": upload_id,
                             "product_id": "gid://shopify/Product/107", "consent": True}})


def make_executor(include_model=False, model_mime="model/gltf-binary"):
    async def executor(kind, payload, context):
        storage = context["storage"]
        image = storage.save_output(png_bytes("blue"), "image/png", "pet-preview.png")
        assets = [{**image, "role": "tryon"}]
        if include_model:
            model = storage.save_output(MODEL_BYTES, model_mime, "pet-character.glb")
            assets.append({**model, "role": "model"})
        return {"kind": kind, "status": "succeeded", "product_id": payload.get("product_id"),
                "variant_id": None, "assets": assets, "source_job_id": payload.get("source_job_id")}
    return executor


def run_once(client, executor):
    settings, sessions = client.app.state.settings, client.app.state.sessions
    return asyncio.run(run_job(settings, sessions, "worker-test", executor))


def archives(client):
    with client.app.state.sessions() as db:
        return db.scalars(select(AssetArchive).order_by(AssetArchive.created_at)).all()


def test_successful_job_archives_assets_with_real_hash_and_provenance(tmp_path, monkeypatch):
    fake_generation(monkeypatch)
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client)
        upload = upload_photo(client, headers)
        job_id = submit_tryon(client, headers, upload["id"], "archive-success-key").json()["id"]
        assert run_once(client, make_executor(include_model=True))
        job = client.get(f"/v1/jobs/{job_id}", headers=headers).json()
        assert job["status"] == "succeeded"
        rows = archives(client)
        by_role = {row.source_role: row for row in rows}
        assert set(by_role) == {"upload", "tryon", "model"}
        assert by_role["model"].format == "glb"
        assert by_role["model"].mime == "model/gltf-binary"
        assert by_role["model"].sha256 == hashlib.sha256(MODEL_BYTES).hexdigest()
        assert by_role["tryon"].kind == "tryon"
        assert by_role["upload"].kind == "photo"
        assert all(row.job_id == job_id for row in rows if row.source_role != "upload")
        assert by_role["model"].provenance["created_from"] == "generation"
        with client.app.state.sessions() as db:
            stored = db.get(Upload, by_role["model"].upload_id)
            assert stored.archived == 1 and len(stored.sha256) == 64
        # idempotent archive pass keeps a single row per upload
        assert archive_job_result(client.app.state.sessions, settings, job_id) is not None
        assert len(archives(client)) == 3


def test_failed_job_never_creates_success_assets(tmp_path, monkeypatch):
    fake_generation(monkeypatch)
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client)
        upload = upload_photo(client, headers)

        async def failing(kind, payload, context):
            raise RuntimeError("provider exploded")

        job_id = submit_tryon(client, headers, upload["id"], "archive-failure-key").json()["id"]
        assert run_once(client, failing)
        job = client.get(f"/v1/jobs/{job_id}", headers=headers).json()
        assert job["status"] in ("failed", "needs_review")
        kinds = {row.kind for row in archives(client)}
        assert kinds == {"photo"}  # only the input upload was archived, never a fake output


def test_claim_transfers_archive_and_protects_it_from_24h_cleanup(tmp_path, monkeypatch):
    fake_generation(monkeypatch)
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="keep@example.com", profile={"type": "dog", "age_months": 14, "dog_size": "large", "name": "Afu"})
        upload = upload_photo(client, headers)
        submit_tryon(client, headers, upload["id"], "claim-keep-key")
        assert run_once(client, make_executor(include_model=True))
        claim_website_session(client, settings, headers, "keep@example.com")
        rows = archives(client)
        assert all(row.user_id is not None for row in rows)
        assert all(row.kind in ("photo", "tryon", "model") for row in rows)
        with client.app.state.sessions() as db:
            stored_uploads = db.scalars(select(Upload)).all()
            for row in stored_uploads:
                row.expires_at = time.time() - 1
            db.commit()
        cleanup_expired(settings, client.app.state.sessions)
        with client.app.state.sessions() as db:
            assert db.scalars(select(Upload)).all() != []
            assert select(Upload).column_descriptions  # keep import used
        assert len(archives(client)) == 3
        _tokens, mobile = mobile_login(client, settings, "keep@example.com")
        items = client.get("/mobile/v1/assets", headers=mobile).json()["items"]
        assert len(items) == 3


def test_unclaimed_guest_assets_still_expire(tmp_path, monkeypatch):
    fake_generation(monkeypatch)
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client)
        upload = upload_photo(client, headers)
        with client.app.state.sessions() as db:
            for row in db.scalars(select(Upload)).all():
                row.expires_at = time.time() - 1
            db.commit()
        cleanup_expired(settings, client.app.state.sessions)
        with client.app.state.sessions() as db:
            assert db.scalars(select(Upload)).all() == []
            assert db.scalars(select(AssetArchive)).all() == []


def test_pet_home_manifest_uses_real_website_golden_master(tmp_path):
    settings = build_settings(tmp_path)
    assert default_model_metadata(settings)["bytes"] == GOLDEN_BYTES
    with make_client(settings) as client:
        _tokens, mobile = mobile_login(client, settings, "golden@example.com")
        manifest = client.get("/mobile/v1/pet-home", headers=mobile).json()
        assert manifest["selected"] == "default"
        assert manifest["personal_model"] is None
        default_model = manifest["default_model"]
        assert default_model["static"] is True and default_model["is_default"] is True
        assert default_model["format"] == "glb"
        assert default_model["mime"] == "model/gltf-binary"
        assert default_model["bytes"] == GOLDEN_BYTES
        assert default_model["sha256"] == GOLDEN_SHA
        assert default_model["url"] == "/public-assets/website-golden-master.glb"
        downloaded = client.get(default_model["url"])
        assert downloaded.status_code == 200
        assert downloaded.headers["content-type"] == "model/gltf-binary"
        assert downloaded.headers["etag"] == GOLDEN_SHA
        assert len(downloaded.content) == GOLDEN_BYTES
        assert downloaded.content[:4] == b"glTF"


def test_pet_home_prefers_personal_glb_and_explains_fallbacks(tmp_path, monkeypatch):
    fake_generation(monkeypatch)
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="model@example.com",
                                 profile={"type": "dog", "age_months": 20, "dog_size": "medium", "name": "Milo"})
        upload = upload_photo(client, headers)
        submit_tryon(client, headers, upload["id"], "personal-model-key")
        assert run_once(client, make_executor(include_model=True))
        claim_website_session(client, settings, headers, "model@example.com")
        _tokens, mobile = mobile_login(client, settings, "model@example.com")
        pets = client.get("/mobile/v1/pets", headers=mobile).json()["pets"]
        assert pets and pets[0]["name"] == "Milo"
        manifest = client.get(f"/mobile/v1/pet-home?pet_id={pets[0]['pet_id']}", headers=mobile).json()
        assert manifest["selected"] == "personal"
        assert manifest["personal_model"]["format"] == "glb"
        assert manifest["personal_model"]["sha256"] == hashlib.sha256(MODEL_BYTES).hexdigest()
        downloaded = client.get(manifest["personal_model"]["url"], headers=mobile)
        assert downloaded.status_code == 200 and downloaded.content == MODEL_BYTES
        manifest_meta = client.get(manifest["personal_model"]["manifest_url"], headers=mobile).json()
        assert manifest_meta["available"] is True and manifest_meta["format"] == "glb"

        # A formats the native viewer cannot use must fall back to the website default.
        with client.app.state.sessions() as db:
            for row in db.scalars(select(AssetArchive).where(AssetArchive.user_id.is_not(None))):
                if row.kind == "model":
                    row.format = "bin"
            db.commit()
        fallback = client.get(f"/mobile/v1/pet-home?pet_id={pets[0]['pet_id']}", headers=mobile).json()
        assert fallback["selected"] == "default"
        assert fallback["fallback_reason"] == "unsupported_personal_format:bin"


def test_assets_pagination_and_kind_filter(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="page@example.com")
        for index in range(3):
            upload_photo(client, headers)
        claim_website_session(client, settings, headers, "page@example.com")
        _tokens, mobile = mobile_login(client, settings, "page@example.com")
        first = client.get("/mobile/v1/assets?limit=2", headers=mobile).json()
        assert len(first["items"]) == 2 and first["next_cursor"]
        second = client.get(f"/mobile/v1/assets?limit=2&cursor={first['next_cursor']}", headers=mobile).json()
        assert len(second["items"]) == 1 and second["next_cursor"] is None
        photos = client.get("/mobile/v1/assets?kind=photo", headers=mobile).json()["items"]
        assert len(photos) == 3 and all(item["kind"] == "photo" for item in photos)
        models = client.get("/mobile/v1/assets?kind=model", headers=mobile).json()["items"]
        assert models == []


def test_generation_after_claim_archives_directly_to_the_user(tmp_path, monkeypatch):
    fake_generation(monkeypatch)
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="after@example.com",
                                 profile={"type": "dog", "age_months": 9, "dog_size": "small", "name": "Lucky"})
        claim_website_session(client, settings, headers, "after@example.com")
        _tokens, mobile = mobile_login(client, settings, "after@example.com")
        before = len(client.get("/mobile/v1/assets", headers=mobile).json()["items"])

        upload = upload_photo(client, headers)
        submit_tryon(client, headers, upload["id"], "after-claim-job-key")
        assert run_once(client, make_executor(include_model=True))
        with client.app.state.sessions() as db:
            rows = db.scalars(select(AssetArchive).where(AssetArchive.kind.in_(("tryon", "model")))).all()
            assert {row.kind for row in rows} == {"tryon", "model"}
            assert all(row.user_id is not None for row in rows)
        items = client.get("/mobile/v1/assets", headers=mobile).json()["items"]
        assert len(items) == before + 3  # new upload photo + tryon + model
        assert {item["kind"] for item in items} >= {"tryon", "model"}
        model = next(item for item in items if item["kind"] == "model")
        assert model["format"] == "glb"
        assert client.get(f"/mobile/v1/assets/{model['asset_id']}/download", headers=mobile).status_code == 200
