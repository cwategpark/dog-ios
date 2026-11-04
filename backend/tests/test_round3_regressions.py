"""Round-3 regression tests: archive pet backfill, archive compensation, cleanup protection."""
import asyncio
import time
from pathlib import Path

from sqlalchemy import select

from app import assets as asset_service
from app import identity, jobs as job_service, worker
from app.mailer import normalize_email
from app.models import (AssetArchive, GuestSession, GuestSessionPet, Job, Pet,
                        Upload)
from app.storage import PrivateStorage, cleanup_expired

from .support import (build_settings, claim_website_session, issue_guest,
                      make_client, mobile_login, png_bytes)


def _guest_id(client):
    with client.app.state.sessions() as db:
        return db.scalar(select(GuestSession)).id


def _claim(client, email, guest_id):
    sessions = client.app.state.sessions
    user = identity.get_or_create_user(sessions, normalize_email(email), email)
    identity.claim_guest_session(sessions, client.app.state.settings, user, guest_id)
    return user


def _model_job(sessions, settings, guest_id, key="round3-model"):
    with sessions() as db:
        job = Job(shop=settings.local_shop, owner_id=guest_id, kind="tryon",
                  input={}, input_hash="h", idempotency_key=key, status="succeeded")
        db.add(job)
        db.flush()
        job_id = job.id
        db.commit()
    storage = PrivateStorage(settings, sessions, guest_id, settings.local_shop, job_id)
    upload = storage.save_output(b"glTF\x02\x00\x00\x00round3", "model/gltf-binary", "round3.glb")
    with sessions() as db:
        job = db.get(Job, job_id)
        job.result = {"assets": [{**upload, "role": "model"}]}
        db.commit()
    return job_id, upload


def _checkpoint_job(sessions, settings, guest_id, key="round3-partial"):
    with sessions() as db:
        job = Job(shop=settings.local_shop, owner_id=guest_id, kind="tryon",
                  input={}, input_hash="h", idempotency_key=key, status="running",
                  dispatched_at=time.time() - 5, lease_until=time.time() - 1,
                  lease_owner="dead-worker")
        db.add(job)
        db.flush()
        job_id = job.id
        db.commit()
    storage = PrivateStorage(settings, sessions, guest_id, settings.local_shop, job_id)
    upload = storage.save_output(png_bytes("purple"), "image/png", "cartoon.png")
    with sessions() as db:
        job = db.get(Job, job_id)
        job.result = {"stage": "cartoon_ready", "assets": [{**upload, "role": "cartoon"}]}
        db.commit()
    return job_id, upload


# --------------------------------------------------------------------- 1: pet backfill
def test_archive_backfill_re_resolves_pet_mapping_in_new_transaction(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="round3-pet@example.com", full_name="Round 3 Owner",
                                 profile={"type": "dog", "age_months": 20, "dog_size": "large",
                                          "name": "Round3 Golden"})
        guest_id = _guest_id(client)
        sessions = client.app.state.sessions
        user = identity.get_or_create_user(sessions, normalize_email("round3-pet@example.com"),
                                           "round3-pet@example.com")
        job_id, upload = _model_job(sessions, settings, guest_id)
        events = []

        def hook(stage, _context=None, **_kwargs):
            events.append(stage)
            if stage == "ownership_read":
                # Claim after the archive transaction's pre-claim snapshot; this creates the
                # GuestSessionPet mapping only after archive_job_result cached pet_id=None.
                identity.claim_guest_session(sessions, settings, user, guest_id)

        records = asset_service.archive_job_result(sessions, settings, job_id, hook=hook)
        assert records and "ownership_read" in events
        with sessions() as db:
            archive = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            mapping = db.scalar(select(GuestSessionPet).where(GuestSessionPet.session_id == guest_id))
            pet = db.get(Pet, mapping.pet_id) if mapping else None
            assert archive.user_id == user.id
            assert archive.pet_id == pet.id
            assert pet is not None and pet.name == "Round3 Golden"

        _tokens, mobile = mobile_login(client, settings, "round3-pet@example.com")
        home = client.get(f"/mobile/v1/pet-home?pet_id={archive.pet_id}", headers=mobile).json()
        assert home["selected"] == "personal"
        assert home["personal_model"]["format"] == "glb"

        # Re-archive idempotently; user/pet must stay attached and only one archive row exists.
        asset_service.archive_job_result(sessions, settings, job_id)
        with sessions() as db:
            rows = db.scalars(select(AssetArchive).where(AssetArchive.upload_id == upload["id"])).all()
            assert len(rows) == 1 and rows[0].user_id == user.id and rows[0].pet_id == pet.id


def test_archive_commit_then_claim_backfills_user_and_pet(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="round3-after@example.com", full_name="After Owner",
                                 profile={"type": "cat", "age_months": 14, "name": "After Cat"})
        guest_id = _guest_id(client)
        sessions = client.app.state.sessions
        job_id, upload = _model_job(sessions, settings, guest_id, key="round3-after")
        asset_service.archive_job_result(sessions, settings, job_id)
        with sessions() as db:
            archive = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            assert archive.user_id is None and archive.pet_id is None
        user = _claim(client, "round3-after@example.com", guest_id)
        # transfer_guest_assets or the next archive call must backfill both columns.
        asset_service.archive_job_result(sessions, settings, job_id)
        with sessions() as db:
            fresh = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            pet_id = db.scalar(select(GuestSessionPet.pet_id).where(GuestSessionPet.session_id == guest_id))
            assert fresh.user_id == user.id and fresh.pet_id == pet_id
            assert db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"])).id == fresh.id


# --------------------------------------------------------------------- 2: compensation
def test_success_crash_before_archive_is_repaired_by_worker_loop(tmp_path, monkeypatch):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="round3-crash@example.com",
                                 profile={"type": "dog", "age_months": 22, "dog_size": "medium",
                                          "name": "Crash Golden"})
        guest_id = _guest_id(client)
        claim_website_session(client, settings, headers, "round3-crash@example.com")
        _tokens, mobile = mobile_login(client, settings, "round3-crash@example.com")
        sessions = client.app.state.sessions
        job_id, upload = _model_job(sessions, settings, guest_id, key="round3-crash")
        with sessions() as db:
            upload_path = Path(settings.storage_path, db.get(Upload, upload["id"]).storage_key)
        with sessions() as db:
            db.get(Upload, upload["id"]).expires_at = time.time() - 1
            db.commit()

        # cleanup must protect a claimed owner's source file even before any archive row exists.
        cleanup_expired(settings, sessions)
        with sessions() as db:
            kept = db.get(Upload, upload["id"])
            assert kept is not None and kept.expires_at > time.time()
            assert db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"])) is None
        assert upload_path.exists()

        provider_calls = []
        monkeypatch.setattr("app.domain.service.execute_job",
                            lambda *args, **kwargs: provider_calls.append(1))
        asyncio.run(worker.serve(settings, sessions, once=True))
        assert provider_calls == []
        with sessions() as db:
            archive = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            assert archive is not None and archive.user_id is not None and archive.pet_id is not None
            assert db.get(Job, job_id).archived_at is not None
            assert len(db.scalars(select(AssetArchive).where(AssetArchive.upload_id == upload["id"])).all()) == 1
        listing = client.get("/mobile/v1/assets?limit=50", headers=mobile).json()["items"]
        item = next(entry for entry in listing if entry["asset_id"] == archive.id)
        assert client.get(item["download_url"], headers=mobile).status_code == 200
        # A second loop is idempotent: no duplicate archive, no provider call.
        assert asset_service.archive_pending_jobs(sessions, settings) == 0
        with sessions() as db:
            assert len(db.scalars(select(AssetArchive).where(AssetArchive.upload_id == upload["id"])).all()) == 1
        assert provider_calls == []


def test_first_success_archive_failure_is_retried_by_compensation(tmp_path, monkeypatch):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="round3-retry@example.com",
                                 profile={"type": "dog", "age_months": 22, "dog_size": "medium",
                                          "name": "Retry Golden"})
        guest_id = _guest_id(client)
        claim_website_session(client, settings, headers, "round3-retry@example.com")
        sessions = client.app.state.sessions
        job_id, upload = _model_job(sessions, settings, guest_id, key="round3-retry")
        original = asset_service.archive_upload
        attempts = {"n": 0}

        def flaky(*args, **kwargs):
            attempts["n"] += 1
            if attempts["n"] == 1:
                raise RuntimeError("transient archive failure")
            return original(*args, **kwargs)

        monkeypatch.setattr(asset_service, "archive_upload", flaky)
        assert asset_service.archive_pending_jobs(sessions, settings) == 0
        with sessions() as db:
            job = db.get(Job, job_id)
            assert job.archived_at is None and job.archive_attempts == 1 and job.archive_retry_at
            assert db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"])) is None
        repaired = asset_service.archive_pending_jobs(sessions, settings, now=time.time() + 3600)
        assert repaired == 1
        assert attempts["n"] == 2
        with sessions() as db:
            job = db.get(Job, job_id)
            archive = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            assert job.archived_at is not None and job.archive_retry_at is None
            assert archive is not None and archive.user_id is not None and archive.pet_id is not None
        assert asset_service.archive_pending_jobs(sessions, settings, now=time.time() + 7200) == 0


def test_partial_recovery_archive_failure_is_retried(tmp_path, monkeypatch):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="round3-partial@example.com",
                                 profile={"type": "dog", "age_months": 19, "dog_size": "small",
                                          "name": "Partial Golden"})
        guest_id = _guest_id(client)
        claim_website_session(client, settings, headers, "round3-partial@example.com")
        sessions = client.app.state.sessions
        job_id, upload = _checkpoint_job(sessions, settings, guest_id)
        original = asset_service.archive_upload
        attempts = {"n": 0}

        def flaky(*args, **kwargs):
            attempts["n"] += 1
            if attempts["n"] == 1:
                raise RuntimeError("transient partial archive failure")
            return original(*args, **kwargs)

        monkeypatch.setattr(asset_service, "archive_upload", flaky)
        recovered = job_service.recover_expired(sessions, settings)
        assert job_id in recovered
        with sessions() as db:
            job = db.get(Job, job_id)
            assert job.status == "needs_review" and job.archived_at is None
            assert db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"])) is None
        repaired = asset_service.archive_pending_jobs(sessions, settings, now=time.time() + 3600)
        assert repaired == 1
        with sessions() as db:
            job = db.get(Job, job_id)
            archive = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            assert job.status == "needs_review" and job.archived_at is not None
            assert archive is not None and archive.user_id is not None and archive.pet_id is not None
            assert archive.provenance.get("partial") is True
            assert not db.scalars(select(AssetArchive).where(AssetArchive.kind == "model")).all()


def test_unclaimed_expired_upload_is_still_deleted(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="round3-unclaimed@example.com")
        upload = client.post("/v1/uploads", headers=headers,
                             files={"file": ("u.png", png_bytes(), "image/png")}).json()
        sessions = client.app.state.sessions
        with sessions() as db:
            row = db.get(Upload, upload["id"])
            storage_path = Path(settings.storage_path, row.storage_key)
            row.expires_at = time.time() - 1
            db.commit()
        cleanup_expired(settings, sessions)
        with sessions() as db:
            assert db.get(Upload, upload["id"]) is None
            assert not db.scalars(select(AssetArchive).where(AssetArchive.upload_id == upload["id"])).all()
        assert not storage_path.exists()
