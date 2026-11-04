"""Controlled-concurrency and cross-flow regression tests for the dog-ios backend.

Covers the second-round review blockers:
B atomic OTP accounting / single consumption,
C single-transaction refresh rotation with persistent family revocation,
D atomic guest-session claim (one winner, same-account idempotent, no name pollution),
E archive vs claim interleavings (both orderings) and early-return backfill,
F cleanup vs claim (claim committing after the protection snapshot is honoured),
G partial cartoon checkpoint archived while the job stays failed,
H same-name pet across two questionnaires resolves through the 0003 session map,
I block revokes pending requests and concurrent accept creates one contact.
"""
import asyncio
import threading
import time

import pytest
from sqlalchemy import select

from app import assets as asset_service
from app import identity, social
from app import jobs as job_service
from app.mailer import normalize_email
from app.models import (AssetArchive, Contact, ContactRequest, EmailChallenge, GuestSession,
                        GuestSessionPet, Job, MobileSession, Pet, Upload, User)
from app.providers.errors import GenerationUncertain
from app.storage import PrivateStorage, cleanup_expired
from app.worker import run_job

from .support import (build_settings, claim_website_session, issue_guest, make_client,
                      mobile_login, png_bytes, start_mobile_login, upload_photo)


def _ensure_user(sessions, email):
    return identity.get_or_create_user(sessions, normalize_email(email), email)


def _claim(client, email, guest_session_id):
    sessions = client.app.state.sessions
    user = _ensure_user(sessions, email)
    return identity.claim_guest_session(sessions, client.app.state.settings, user, guest_session_id)


def _guest_id(client):
    with client.app.state.sessions() as db:
        return db.scalar(select(GuestSession)).id


def _run_barrier(calls):
    """Run zero-arg callables concurrently behind a barrier; return (values, errors)."""
    results, errors = [], []
    barrier = threading.Barrier(len(calls))

    def runner(fn):
        barrier.wait()
        try:
            results.append(fn())
        except Exception as error:  # noqa: BLE001 - assertions inspect the type
            errors.append(error)

    threads = [threading.Thread(target=runner, args=(fn,)) for fn in calls]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return results, errors


def _status_codes(errors):
    return sorted(getattr(error, "status_code", 0) for error in errors)


# --------------------------------------------------------------------------- B: OTP atomicity
def test_concurrent_wrong_codes_increment_attempts_without_loss(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        payload, code = start_mobile_login(client, settings, "atomic@example.com")
        challenge_id = payload["challenge_id"]
        wrong = "000000" if code != "000000" else "111111"
        sessions = client.app.state.sessions
        calls = [lambda: identity.verify_code(sessions, settings, challenge_id, wrong,
                                              expected_purpose=identity.PURPOSE_LOGIN) for _ in range(6)]
        _results, errors = _run_barrier(calls)
        with client.app.state.sessions() as db:
            challenge = db.get(EmailChallenge, challenge_id)
            assert challenge.attempts == settings.otp_max_attempts
        assert all(getattr(error, "status_code", None) in (401, 429) for error in errors)
        with pytest.raises(Exception) as blocked:
            identity.verify_code(sessions, settings, challenge_id, code, expected_purpose=identity.PURPOSE_LOGIN)
        assert getattr(blocked.value, "status_code", 0) in (429, 410)


def test_concurrent_correct_code_issues_exactly_one_session(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        payload, code = start_mobile_login(client, settings, "once@example.com")
        challenge_id = payload["challenge_id"]
        sessions = client.app.state.sessions

        def verify_and_issue():
            challenge, user = identity.verify_code(sessions, settings, challenge_id, code,
                                                   expected_purpose=identity.PURPOSE_LOGIN)
            return identity.issue_mobile_tokens(sessions, settings, user.id, settings.local_shop)

        results, errors = _run_barrier([verify_and_issue] * 4)
        assert len(results) == 1, [getattr(error, "detail", error) for error in errors]
        assert len(errors) == 3
        assert all(getattr(error, "status_code", 0) in (410, 401, 429) for error in errors)
        with client.app.state.sessions() as db:
            assert len(db.scalars(select(MobileSession)).all()) == 1
            challenge = db.get(EmailChallenge, challenge_id)
            assert challenge.consumed_at is not None
            assert challenge.attempts == 0


# --------------------------------------------------------------------------- C: refresh race
def test_concurrent_refresh_cannot_leave_a_usable_family_member(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        tokens, _headers = mobile_login(client, settings, "refresh-race@example.com")
        sessions = client.app.state.sessions
        calls = [lambda: identity.refresh_mobile_tokens(sessions, settings, tokens["refresh_token"]) for _ in range(2)]
        results, errors = _run_barrier(calls)
        assert len(results) + len(errors) == 2
        assert len(results) <= 1
        with client.app.state.sessions() as db:
            family = db.get(MobileSession, db.scalar(select(MobileSession.id)))
            rows = db.scalars(select(MobileSession).where(MobileSession.family_id == family.family_id)).all()
            assert rows and all(row.revoked_at is not None for row in rows)
        # any "winner" access token must already be dead, and replay must stay dead
        for pair in results:
            response = client.get("/mobile/v1/me", headers={"Authorization": f"Bearer {pair['access_token']}"})
            assert response.status_code == 401
            replay = client.post("/mobile/v1/auth/refresh", json={"refresh_token": pair["refresh_token"]})
            assert replay.status_code == 401


# --------------------------------------------------------------------------- D: claim race
def test_two_accounts_cannot_both_claim_the_same_guest_session(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _body = issue_guest(client, profile={"type": "dog", "age_months": 12, "dog_size": "small", "name": "Milo"})
        guest_session_id = _guest_id(client)
        sessions = client.app.state.sessions
        first = _ensure_user(sessions, "winner@example.com")
        second = _ensure_user(sessions, "loser@example.com")
        calls = [
            lambda: (first.id, identity.claim_guest_session(sessions, settings, first, guest_session_id)),
            lambda: (second.id, identity.claim_guest_session(sessions, settings, second, guest_session_id)),
        ]
        results, errors = _run_barrier(calls)
        assert len(results) == 1 and len(errors) == 1
        assert getattr(errors[0], "status_code", 0) == 409
        winner_id = results[0][0]
        winner = first if winner_id == first.id else second
        loser = second if winner is first else first
        with client.app.state.sessions() as db:
            guest = db.get(GuestSession, guest_session_id)
            assert guest.user_id == winner.id
        # same-account repeat is idempotent; the losing account keeps getting 409
        assert identity.claim_guest_session(sessions, settings, winner, guest_session_id) == [guest_session_id]
        with pytest.raises(Exception) as rejected:
            identity.claim_guest_session(sessions, settings, loser, guest_session_id)
        assert getattr(rejected.value, "status_code", 0) == 409


def test_unverified_guest_input_cannot_overwrite_an_existing_account_name(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        sessions = client.app.state.sessions
        existing = _ensure_user(sessions, "named@example.com")
        with client.app.state.sessions() as db:
            row = db.get(User, existing.id)
            row.full_name = "Real Name"
            db.commit()
        headers, _ = issue_guest(client, email="named@example.com", full_name="Attacker Name",
                                 profile={"type": "cat", "age_months": 8, "name": "Cat"})
        guest_session_id = _guest_id(client)
        claim = _claim(client, "named@example.com", guest_session_id)
        assert claim == [guest_session_id]
        with client.app.state.sessions() as db:
            assert db.get(User, existing.id).full_name == "Real Name"


# --------------------------------------------------------------------------- E: archive/claim races
def _racing_claim_hook(client, email, guest_session_id, stage_name):
    events = []

    def hook(stage, *_args, **_kwargs):
        events.append(stage)
        if stage == stage_name:
            thread = threading.Thread(target=lambda: _claim(client, email, guest_session_id))
            thread.start()
            thread.join()

    return hook, events


def test_archive_started_before_claim_still_gets_owned(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="race-e@example.com")
        guest_session_id = _guest_id(client)
        sessions = client.app.state.sessions
        user = _ensure_user(sessions, "race-e@example.com")
        storage = PrivateStorage(settings, sessions, guest_session_id, settings.local_shop)
        upload = storage.save_output(png_bytes("blue"), "image/png", "race.png")
        hook, events = _racing_claim_hook(client, "race-e@example.com", guest_session_id, "ownership_read")
        asset_service.archive_upload(sessions, settings, upload["id"],
                                     guest_session_id=guest_session_id, kind="photo", hook=hook)
        assert "ownership_read" in events
        with client.app.state.sessions() as db:
            archive = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            assert archive.user_id == user.id


def test_claim_after_archive_commit_is_reconciled(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="race-e2@example.com")
        guest_session_id = _guest_id(client)
        sessions = client.app.state.sessions
        user = _ensure_user(sessions, "race-e2@example.com")
        storage = PrivateStorage(settings, sessions, guest_session_id, settings.local_shop)
        upload = storage.save_output(png_bytes("green"), "image/png", "race2.png")
        hook, events = _racing_claim_hook(client, "race-e2@example.com", guest_session_id, "after_commit")
        asset_service.archive_upload(sessions, settings, upload["id"],
                                     guest_session_id=guest_session_id, kind="photo", hook=hook)
        assert "after_commit" in events
        with client.app.state.sessions() as db:
            archive = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            assert archive.user_id == user.id


def test_existing_archive_is_backfilled_when_claim_happened_later(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="race-e3@example.com")
        guest_session_id = _guest_id(client)
        sessions = client.app.state.sessions
        storage = PrivateStorage(settings, sessions, guest_session_id, settings.local_shop)
        upload = storage.save_output(png_bytes("red"), "image/png", "race3.png")
        asset_service.archive_upload(sessions, settings, upload["id"],
                                     guest_session_id=guest_session_id, kind="photo")
        with client.app.state.sessions() as db:
            assert db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"])).user_id is None
        user = _ensure_user(sessions, "race-e3@example.com")
        identity.claim_guest_session(sessions, settings, user, guest_session_id)
        asset_service.archive_upload(sessions, settings, upload["id"],
                                     guest_session_id=guest_session_id, kind="photo")
        with client.app.state.sessions() as db:
            fresh = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            assert fresh.user_id == user.id


# --------------------------------------------------------------------------- F: cleanup/claim race
def test_claim_committing_after_cleanup_snapshot_is_not_deleted(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="race-f@example.com")
        guest_session_id = _guest_id(client)
        upload = upload_photo(client, headers)
        sessions = client.app.state.sessions
        with client.app.state.sessions() as db:
            row = db.get(Upload, upload["id"])
            row.expires_at = time.time() - 1
            db.commit()
        hook, events = _racing_claim_hook(client, "race-f@example.com", guest_session_id, "protection_snapshot")
        cleanup_expired(settings, sessions, hook=hook)
        assert "protection_snapshot" in events and "protected" in events
        with client.app.state.sessions() as db:
            kept = db.get(Upload, upload["id"])
            assert kept is not None and kept.expires_at > time.time()
            archive = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload["id"]))
            assert archive.user_id is not None
            from pathlib import Path
            assert (Path(settings.storage_path).resolve() / kept.storage_key).exists()


def test_claimed_archive_survives_worker_cleanup_after_twenty_four_hours(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="race-f2@example.com")
        upload = upload_photo(client, headers)
        claim_website_session(client, settings, headers, "race-f2@example.com")
        _tokens, mobile = mobile_login(client, settings, "race-f2@example.com")
        with client.app.state.sessions() as db:
            row = db.get(Upload, upload["id"])
            row.expires_at = time.time() - 1
            db.commit()
        cleanup_expired(settings, client.app.state.sessions)
        with client.app.state.sessions() as db:
            kept = db.get(Upload, upload["id"])
            assert kept is not None and kept.archived == 1
        items = client.get("/mobile/v1/assets", headers=mobile).json()["items"]
        asset = next(item for item in items if item["kind"] == "photo")
        assert client.get(asset["download_url"], headers=mobile).status_code == 200


# --------------------------------------------------------------------------- G: partial cartoon
def test_partial_cartoon_checkpoint_is_archived_but_job_stays_failed(tmp_path, monkeypatch):
    monkeypatch.setattr("app.domain.service.ensure_configured", lambda *_: None)
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="partial@example.com")
        claim_website_session(client, settings, headers, "partial@example.com")
        _tokens, mobile = mobile_login(client, settings, "partial@example.com")
        upload = upload_photo(client, headers)
        job = client.post("/v1/jobs", headers={**headers, "Idempotency-Key": "partial-cartoon-key"},
                          json={"kind": "tryon", "input": {"pet_upload_id": upload["id"],
                                "product_id": "gid://shopify/Product/107", "consent": True}})
        assert job.status_code == 202, job.text
        job_id = job.json()["id"]

        async def cartoon_then_fail(kind, payload, context):
            storage = context["storage"]
            cartoon = storage.save_output(png_bytes("purple"), "image/png", "cartoon.png")
            context["checkpoint"]("cartoon_ready", {
                "kind": kind, "status": "running",
                "assets": [{**cartoon, "role": "cartoon"}],
            })
            raise GenerationUncertain("3d reconstruction failed")

        assert asyncio.run(run_job(client.app.state.settings, client.app.state.sessions, "worker-g", cartoon_then_fail))
        failed = client.get(f"/v1/jobs/{job_id}", headers=headers).json()
        assert failed["status"] in ("failed", "needs_review")
        assert failed["result"].get("stage") == "cartoon_ready"
        assert failed["result"].get("partial") is True
        with client.app.state.sessions() as db:
            cartoon_rows = db.scalars(select(AssetArchive).where(AssetArchive.kind == "cartoon")).all()
            assert len(cartoon_rows) == 1
            assert cartoon_rows[0].user_id is not None
            assert cartoon_rows[0].provenance.get("partial") is True
            assert not db.scalars(select(AssetArchive).where(AssetArchive.kind == "model")).all()
        listing = client.get("/mobile/v1/assets", headers=mobile).json()["items"]
        cartoon_item = next(item for item in listing if item["kind"] == "cartoon")
        assert client.get(cartoon_item["download_url"], headers=mobile).status_code == 200
        home = client.get("/mobile/v1/pet-home", headers=mobile).json()
        assert home["selected"] == "default"
        assert home["default_model"]["bytes"] > 40_000_000


# --------------------------------------------------------------------------- H: same-name pet mapping
def test_same_name_pet_from_two_questionnaires_shares_archived_models(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        sessions = client.app.state.sessions
        profile = {"type": "dog", "age_months": 18, "dog_size": "large", "name": "Milo"}
        first_headers, _ = issue_guest(client, email="same@example.com", profile=profile)
        first_guest = _guest_id(client)
        claim_website_session(client, settings, first_headers, "same@example.com")
        # Second questionnaire with the same pet name: the real defect ordering is an archive
        # created BEFORE the second session is claimed (pet_id must be backfilled later).
        second_headers, _ = issue_guest(client, email="same@example.com", profile=profile)
        with client.app.state.sessions() as db:
            guests = db.scalars(select(GuestSession).order_by(GuestSession.created_at)).all()
            second_guest = guests[-1].id
        second_storage = PrivateStorage(settings, sessions, second_guest, settings.local_shop)
        second_model = second_storage.save_output(b"glTF\x02\x00\x00\x00model", "model/gltf-binary", "pet.glb")
        with sessions() as db:
            second_job = Job(shop=settings.local_shop, owner_id=second_guest, kind="tryon",
                             input={}, input_hash="h", idempotency_key="pre-claim-model",
                             status="succeeded", result={"assets": [{**second_model, "role": "model"}]})
            db.add(second_job)
            db.commit()
            second_job_id = second_job.id
        pre_claim_records = asset_service.archive_job_result(sessions, settings, second_job_id)
        assert pre_claim_records and all(record["pet_id"] is None for record in pre_claim_records)

        claim_website_session(client, settings, second_headers, "same@example.com")
        with client.app.state.sessions() as db:
            mappings = db.scalars(select(GuestSessionPet)).all()
            assert len(mappings) == 2
            assert len({mapping.pet_id for mapping in mappings}) == 1
            pet_id = mappings[0].pet_id
            assert len(db.scalars(select(Pet)).all()) == 1
            # The archive created before the second claim is backfilled to the shared pet.
            second_archive = db.scalar(select(AssetArchive).where(
                AssetArchive.guest_session_id == second_guest, AssetArchive.kind == "model"))
            assert second_archive is not None and second_archive.pet_id == pet_id
            assert second_archive.user_id is not None

        # A model archived after the claim also resolves to the same pet.
        first_storage = PrivateStorage(settings, sessions, first_guest, settings.local_shop)
        first_model = first_storage.save_output(b"glTF\x02\x00\x00\x00model", "model/gltf-binary", "pet.glb")
        with sessions() as db:
            first_job = Job(shop=settings.local_shop, owner_id=first_guest, kind="tryon",
                            input={}, input_hash="h", idempotency_key="post-claim-model",
                            status="succeeded", result={"assets": [{**first_model, "role": "model"}]})
            db.add(first_job)
            db.commit()
            first_job_id = first_job.id
        post_claim_records = asset_service.archive_job_result(sessions, settings, first_job_id)
        assert post_claim_records and all(record["pet_id"] == pet_id for record in post_claim_records)

        _tokens, mobile = mobile_login(client, settings, "same@example.com")
        home = client.get(f"/mobile/v1/pet-home?pet_id={pet_id}", headers=mobile).json()
        assert home["selected"] == "personal"
        assert home["personal_model"]["format"] == "glb"


# --------------------------------------------------------------------------- I: block + concurrent accept
def _established_pair(client, settings):
    headers_a, _ = issue_guest(client, email="block-a@example.com",
                               profile={"type": "dog", "age_months": 10, "dog_size": "small", "name": "A"})
    claim_website_session(client, settings, headers_a, "block-a@example.com")
    _ta, mobile_a = mobile_login(client, settings, "block-a@example.com")
    headers_b, _ = issue_guest(client, email="block-b@example.com",
                               profile={"type": "cat", "age_months": 10, "name": "B"})
    claim_website_session(client, settings, headers_b, "block-b@example.com")
    _tb, mobile_b = mobile_login(client, settings, "block-b@example.com")
    sessions = client.app.state.sessions
    with sessions() as db:
        user_a = db.scalar(select(User).where(User.email_normalized == "block-a@example.com"))
        user_b = db.scalar(select(User).where(User.email_normalized == "block-b@example.com"))
    return user_a, user_b, mobile_a, mobile_b


def test_block_revokes_pending_request_and_hides_it_from_both_sides(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, mobile_a, mobile_b = _established_pair(client, settings)
        sessions = client.app.state.sessions
        with sessions() as db:
            row = ContactRequest(from_user_id=user_a.id, to_user_id=user_b.id, status="pending")
            db.add(row)
            db.commit()
            request_id = row.id
        social.add_block(sessions, user_b.id, user_a.public_ref)
        with client.app.state.sessions() as db:
            assert db.get(ContactRequest, request_id).status == "cancelled"
        assert client.get("/mobile/v1/contacts/requests?direction=incoming", headers=mobile_a).json()["items"] == []
        assert client.get("/mobile/v1/contacts/requests?direction=outgoing", headers=mobile_b).json()["items"] == []
        response = client.post(f"/mobile/v1/contacts/requests/{request_id}/accept", headers=mobile_b)
        assert response.status_code in (403, 409)


def test_concurrent_accept_creates_exactly_one_contact(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, mobile_a, mobile_b = _established_pair(client, settings)
        sessions = client.app.state.sessions
        with sessions() as db:
            row = ContactRequest(from_user_id=user_a.id, to_user_id=user_b.id, status="pending")
            db.add(row)
            db.commit()
            request_id = row.id
        results, errors = _run_barrier([
            lambda: social.respond_to_request(sessions, user_b.id, request_id, True),
            lambda: social.respond_to_request(sessions, user_b.id, request_id, True),
        ])
        assert not errors, [getattr(error, "detail", error) for error in errors]
        assert {result["contact_id"] for result in results} and len({result["contact_id"] for result in results}) == 1
        with client.app.state.sessions() as db:
            contacts = db.scalars(select(Contact)).all()
            assert len(contacts) == 1
            assert db.get(ContactRequest, request_id).status == "accepted"


def test_concurrent_accept_and_block_never_expose_a_contact(tmp_path):
    """Handoff item 10: accept racing a block must never expose an actionable contact."""
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, mobile_a, mobile_b = _established_pair(client, settings)
        sessions = client.app.state.sessions
        with sessions() as db:
            row = ContactRequest(from_user_id=user_a.id, to_user_id=user_b.id, status="pending")
            db.add(row)
            db.commit()
            request_id = row.id
        results, errors = _run_barrier([
            lambda: social.respond_to_request(sessions, user_b.id, request_id, True),
            lambda: social.add_block(sessions, user_a.id, user_b.public_ref),
        ])
        assert results or errors
        assert all(getattr(error, "status_code", 0) in (403, 409) for error in errors)
        # Whatever won the race, the block must hide the contact/request from both sides.
        assert client.get("/mobile/v1/contacts", headers=mobile_a).json()["items"] == []
        assert client.get("/mobile/v1/contacts", headers=mobile_b).json()["items"] == []
        assert client.get("/mobile/v1/contacts/requests?direction=incoming", headers=mobile_b).json()["items"] == []
        assert client.get("/mobile/v1/contacts/requests?direction=outgoing", headers=mobile_a).json()["items"] == []
        with sessions() as db:
            contact = db.scalar(select(Contact))
            if contact is not None:
                # A contact may have been created just before the block committed, but it must
                # not be readable or usable while either side is blocked.
                blocked_contact_id = contact.id
            else:
                blocked_contact_id = None
        if blocked_contact_id:
            read = client.get(f"/mobile/v1/messages?contact_id={blocked_contact_id}", headers=mobile_a)
            send = client.post("/mobile/v1/messages", headers=mobile_a,
                               json={"contact_id": blocked_contact_id, "body": "hi", "client_id": "race-1"})
            assert read.status_code == 403 and send.status_code == 403


def test_worker_crash_after_cartoon_checkpoint_is_archived_on_recovery(tmp_path, monkeypatch):
    """Handoff item 8: recovery (crash/OOM), not only the in-process except, must keep the cartoon."""
    monkeypatch.setattr("app.domain.service.ensure_configured", lambda *_: None)
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="crash@example.com")
        claim_website_session(client, settings, headers, "crash@example.com")
        _tokens, mobile = mobile_login(client, settings, "crash@example.com")
        upload = upload_photo(client, headers)
        job = client.post("/v1/jobs", headers={**headers, "Idempotency-Key": "crash-cartoon-key"},
                          json={"kind": "tryon", "input": {"pet_upload_id": upload["id"],
                                "product_id": "gid://shopify/Product/107", "consent": True}})
        assert job.status_code == 202, job.text
        job_id = job.json()["id"]
        guest_id = _guest_id(client)

        storage = PrivateStorage(settings, client.app.state.sessions, guest_id, settings.local_shop, job_id)
        cartoon = storage.save_output(png_bytes("purple"), "image/png", "cartoon.png")
        sessions = client.app.state.sessions
        with sessions() as db:
            row = db.get(Job, job_id)
            # Simulate a worker killed after the real cartoon checkpoint and before finish_job.
            row.status = "running"
            row.dispatched_at = time.time() - 30
            row.lease_until = time.time() - 1
            row.lease_owner = "dead-worker"
            row.result = {"stage": "cartoon_ready", "assets": [{**cartoon, "role": "cartoon"}]}
            db.commit()

        recovered = job_service.recover_expired(sessions, settings)
        assert job_id in recovered
        failed = client.get(f"/v1/jobs/{job_id}", headers=headers).json()
        assert failed["status"] == "needs_review"
        assert failed["result"].get("partial") is True
        with sessions() as db:
            rows = db.scalars(select(AssetArchive).where(AssetArchive.kind == "cartoon")).all()
            assert len(rows) == 1 and rows[0].user_id is not None
            assert rows[0].provenance.get("partial") is True
            # no fabricated model success on a recovered/failed job
            assert not db.scalars(select(AssetArchive).where(AssetArchive.kind == "model")).all()
        listing = client.get("/mobile/v1/assets", headers=mobile).json()["items"]
        item = next(entry for entry in listing if entry["kind"] == "cartoon")
        assert client.get(item["download_url"], headers=mobile).status_code == 200
        # 24h guest cleanup must not delete the now-owned cartoon.
        with sessions() as db:
            db.get(Upload, cartoon["id"]).expires_at = time.time() - 1
            db.commit()
        cleanup_expired(settings, sessions)
        with sessions() as db:
            kept = db.get(Upload, cartoon["id"])
            assert kept is not None and kept.archived == 1
