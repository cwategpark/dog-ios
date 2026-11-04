import time
from pathlib import Path

import pytest
from sqlalchemy import select

from app.mailer import mask_email, normalize_email
from app.models import EmailChallenge, GuestSession, MobileSession, User

from .support import (build_settings, claim_website_session, issue_guest, make_client,
                      mobile_login, proxy_query, read_outbox, start_mobile_login, upload_photo)


def _db_first(settings, model):
    from app.db import make_engine, session_factory
    engine = make_engine(settings.database_url)
    sessions = session_factory(engine)
    with sessions() as db:
        row = db.scalar(select(model))
    engine.dispose()
    return row


def test_email_normalization_keeps_dots_and_tags_but_normalizes_case():
    assert normalize_email("  A.B+tag@Example.COM ") == "a.b+tag@example.com"
    assert normalize_email("a.b@x.com") != normalize_email("ab@x.com")
    assert mask_email("alice@example.com").endswith("@example.com")
    with pytest.raises(ValueError):
        normalize_email("not-an-email")
    with pytest.raises(ValueError):
        normalize_email("a@b")


def test_stable_user_id_for_duplicate_questionnaire_same_email(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        for name in ("Milo", "Milo"):
            issue_guest(client, profile={"type": "cat", "age_months": 24, "name": name}, email="Owner@Example.com")
        tokens_a, _ = mobile_login(client, settings, "owner@example.com")
        tokens_b, _ = mobile_login(client, settings, "OWNER@EXAMPLE.COM")
        assert tokens_a["user_id"] == tokens_b["user_id"]
        with client.app.state.sessions() as db:
            users = db.scalars(select(User)).all()
            assert len(users) == 1
            session_rows = db.scalars(select(GuestSession)).all()
            assert len(session_rows) == 2
            # questionnaire email never auto-assigns ownership
            assert all(row.user_id is None for row in session_rows)


def test_spoofed_email_is_not_auto_claimed_and_other_data_stays_private(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers_a, _ = issue_guest(client, profile={"type": "dog", "age_months": 12, "dog_size": "large", "name": "Afu"}, email="owner@example.com")
        claim_website_session(client, settings, headers_a, "owner@example.com")
        tokens_a, headers_mobile_a = mobile_login(client, settings, "owner@example.com")
        pets = client.get("/mobile/v1/pets", headers=headers_mobile_a).json()["pets"]
        assert [pet["name"] for pet in pets] == ["Afu"]

        # A second visitor uses the same email but is never claimed automatically.
        headers_b, _ = issue_guest(client, profile={"type": "cat", "age_months": 30, "name": "Stray"}, email="owner@example.com")
        with client.app.state.sessions() as db:
            guest_b = db.scalar(select(GuestSession).where(GuestSession.full_name.is_(None), GuestSession.email_normalized == "owner@example.com"))
            assert guest_b is not None
        tokens_b, headers_mobile_b = mobile_login(client, settings, "owner@example.com")
        assert tokens_a["user_id"] == tokens_b["user_id"]
        pets_after = client.get("/mobile/v1/pets", headers=headers_mobile_b).json()["pets"]
        assert [pet["name"] for pet in pets_after] == ["Afu"]
        assert client.get("/v1/pet-profile", headers=headers_b).json()["profile"]["pet_information"]["type"] == "cat"


def test_otp_is_hashed_short_lived_and_single_use(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        payload, code = start_mobile_login(client, settings, "otp@example.com")
        with client.app.state.sessions() as db:
            challenge = db.get(EmailChallenge, payload["challenge_id"])
            assert challenge.code_hash != code
            assert len(challenge.code_hash) == 64
            assert challenge.expires_at - time.time() <= settings.otp_ttl_seconds + 1
        verified = client.post("/mobile/v1/auth/email/verify", json={"challenge_id": payload["challenge_id"], "code": code})
        assert verified.status_code == 200
        replay = client.post("/mobile/v1/auth/email/verify", json={"challenge_id": payload["challenge_id"], "code": code})
        assert replay.status_code == 410


def test_otp_expiry_attempt_limit_and_rate_limits(tmp_path):
    settings = build_settings(tmp_path, otp_max_attempts=2, otp_per_email_hour=50)
    with make_client(settings) as client:
        payload, code = start_mobile_login(client, settings, "limits@example.com")
        with client.app.state.sessions() as db:
            challenge = db.get(EmailChallenge, payload["challenge_id"])
            challenge.expires_at = time.time() - 1
            db.commit()
        expired = client.post("/mobile/v1/auth/email/verify", json={"challenge_id": payload["challenge_id"], "code": code})
        assert expired.status_code == 410

        payload2, code2 = start_mobile_login(client, settings, "limits2@example.com")
        for _ in range(2):
            wrong = client.post("/mobile/v1/auth/email/verify", json={"challenge_id": payload2["challenge_id"], "code": "000000" if code2 != "000000" else "111111"})
            assert wrong.status_code == 401
        blocked = client.post("/mobile/v1/auth/email/verify", json={"challenge_id": payload2["challenge_id"], "code": code2})
        assert blocked.status_code in (401, 429)

        cooldown_settings = build_settings(tmp_path / "cooldown", otp_resend_cooldown_seconds=60)
        with make_client(cooldown_settings) as client2:
            start_mobile_login(client2, cooldown_settings, "cooldown@example.com")
            second = client2.post("/mobile/v1/auth/email/start", json={"email": "cooldown@example.com", "purpose": "login"})
            assert second.status_code == 429

        rate_settings = build_settings(tmp_path / "rate", otp_per_email_hour=1)
        with make_client(rate_settings) as client3:
            start_mobile_login(client3, rate_settings, "rate@example.com")
            for index in range(2):
                response = client3.post("/mobile/v1/auth/email/start", json={"email": "rate@example.com", "purpose": "login"})
                assert response.status_code in (429, 202)


def test_mobile_token_rotation_reuse_and_logout(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        tokens, headers = mobile_login(client, settings, "tokens@example.com")
        assert client.get("/mobile/v1/me", headers=headers).status_code == 200
        refreshed = client.post("/mobile/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
        assert refreshed.status_code == 200
        new_tokens = refreshed.json()
        assert new_tokens["access_token"] != tokens["access_token"]
        # old access token is now revoked with its rotated family member
        assert client.get("/mobile/v1/me", headers=headers).status_code == 401
        headers2 = {"Authorization": f"Bearer {new_tokens['access_token']}"}
        assert client.get("/mobile/v1/me", headers=headers2).status_code == 200
        reuse = client.post("/mobile/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
        assert reuse.status_code == 401
        assert client.get("/mobile/v1/me", headers=headers2).status_code == 401
        tokens3, headers3 = mobile_login(client, settings, "tokens@example.com")
        assert client.post("/mobile/v1/auth/logout", headers=headers3, json={}).status_code == 204
        assert client.get("/mobile/v1/me", headers=headers3).status_code == 401


def test_mobile_access_token_expiry(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        tokens, headers = mobile_login(client, settings, "expiry@example.com")
        with client.app.state.sessions() as db:
            row = db.scalar(select(MobileSession).where(MobileSession.user_id == tokens["user_id"]))
            row.access_expires_at = time.time() - 1
            db.commit()
        assert client.get("/mobile/v1/me", headers=headers).status_code == 401


def test_cross_account_asset_download_is_denied(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers_a, _ = issue_guest(client, email="alice@example.com")
        upload = upload_photo(client, headers_a)
        challenge, _ = claim_website_session(client, settings, headers_a, "alice@example.com")
        tokens_a, mobile_a = mobile_login(client, settings, "alice@example.com")
        assets = client.get("/mobile/v1/assets", headers=mobile_a).json()["items"]
        assert assets and assets[0]["kind"] == "photo"
        asset_id = assets[0]["asset_id"]
        assert client.get(f"/mobile/v1/assets/{asset_id}/download", headers=mobile_a).status_code == 200

        headers_b, _ = issue_guest(client, email="bob@example.com")
        claim_website_session(client, settings, headers_b, "bob@example.com")
        tokens_b, mobile_b = mobile_login(client, settings, "bob@example.com")
        assert client.get(f"/mobile/v1/assets/{asset_id}/download", headers=mobile_b).status_code == 404
        assert client.get(f"/mobile/v1/assets/{asset_id}/manifest", headers=mobile_b).status_code == 404
        assert client.get("/mobile/v1/assets", headers=mobile_b).json()["items"] == []


def test_claim_is_bound_to_the_concrete_guest_session(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers_b, _ = issue_guest(client, email="bound@example.com")
        other_headers, _ = issue_guest(client, profile={"type": "cat", "age_months": 10, "name": "Coco"})
        response = client.post("/v1/claims", headers=headers_b, json={"email": "bound@example.com"})
        payload = response.json()
        code = payload.get("dev_code") or read_outbox(settings, "otp", "bound@example.com")[-1]["code"]
        cross = client.post(f"/v1/claims/{payload['challenge_id']}/verify", headers=other_headers, json={"code": code})
        assert cross.status_code in (403, 404)
        assert client.post(f"/v1/claims/{payload['challenge_id']}/verify", headers=headers_b, json={"code": code}).status_code == 200


def test_mobile_login_challenge_is_not_usable_as_website_claim(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="mobileonly@example.com")
        payload, code = start_mobile_login(client, settings, "mobileonly@example.com")
        response = client.post(f"/v1/claims/{payload['challenge_id']}/verify", headers=headers, json={"code": code})
        assert response.status_code in (403, 404)
        with client.app.state.sessions() as db:
            challenge = db.get(EmailChallenge, payload["challenge_id"])
            assert challenge.consumed_at is None and challenge.attempts == 0
        # the mobile login itself is unaffected
        verified = client.post("/mobile/v1/auth/email/verify",
                               json={"challenge_id": payload["challenge_id"], "code": code})
        assert verified.status_code == 200


def test_unverified_questionnaire_never_rewrites_account_name(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="stable@example.com", full_name="Real Name")
        with client.app.state.sessions() as db:
            user = db.scalar(select(User).where(User.email_normalized == "stable@example.com"))
            assert user.full_name is None  # unverified input lives on the guest row only
            guest = db.scalar(select(GuestSession).where(GuestSession.full_name == "Real Name"))
            assert guest is not None and guest.user_id is None
        claim_website_session(client, settings, headers, "stable@example.com")
        with client.app.state.sessions() as db:
            user = db.scalar(select(User).where(User.email_normalized == "stable@example.com"))
            assert user.full_name == "Real Name"  # filled on the verified claim path
            assert user.email_verified_at is not None

        # a fresh guest reusing the email with another display name must not touch the account
        attacker_headers, _ = issue_guest(client, email="STABLE@example.com", full_name="Impostor")
        tokens, mobile = mobile_login(client, settings, "stable@example.com")
        me = client.get("/mobile/v1/me", headers=mobile).json()
        assert me["full_name"] == "Real Name"
        with client.app.state.sessions() as db:
            user = db.scalar(select(User).where(User.email_normalized == "stable@example.com"))
            assert user.full_name == "Real Name"
            fresh = db.scalar(select(GuestSession).where(GuestSession.full_name == "Impostor"))
            assert fresh is not None and fresh.user_id is None


def test_verified_claim_fills_empty_account_name_only_once(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        first_headers, _ = issue_guest(client, email="fill@example.com")
        claim_website_session(client, settings, first_headers, "fill@example.com")
        with client.app.state.sessions() as db:
            user = db.scalar(select(User).where(User.email_normalized == "fill@example.com"))
            assert user.full_name is None  # nothing invented when the guest provided no name

        second_headers, _ = issue_guest(client, email="fill@example.com", full_name="Later Name")
        claim_website_session(client, settings, second_headers, "fill@example.com")
        with client.app.state.sessions() as db:
            user = db.scalar(select(User).where(User.email_normalized == "fill@example.com"))
            assert user.full_name == "Later Name"

        third_headers, _ = issue_guest(client, email="fill@example.com", full_name="Third Name")
        claim_website_session(client, settings, third_headers, "fill@example.com")
        with client.app.state.sessions() as db:
            user = db.scalar(select(User).where(User.email_normalized == "fill@example.com"))
            assert user.full_name == "Later Name"  # never overwritten


def test_repeated_same_account_claim_is_idempotent(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, profile={"type": "dog", "age_months": 8, "dog_size": "small", "name": "Afu"},
                                email="again@example.com")
        upload_photo(client, headers)
        _, first = claim_website_session(client, settings, headers, "again@example.com")
        _, second = claim_website_session(client, settings, headers, "again@example.com")
        assert first["claimed_session_ids"] == second["claimed_session_ids"]
        tokens, mobile = mobile_login(client, settings, "again@example.com")
        me = client.get("/mobile/v1/me", headers=mobile).json()
        assert [pet["name"] for pet in me["pets"]] == ["Afu"]
        assets = client.get("/mobile/v1/assets", headers=mobile).json()["items"]
        assert len(assets) == 1
        with client.app.state.sessions() as db:
            guest = db.get(GuestSession, first["claimed_session_ids"][0])
            assert guest.user_id == tokens["user_id"]
            assert guest.claimed_at is not None


def test_claim_link_flow_is_disabled_by_default(tmp_path):
    settings = build_settings(tmp_path)
    assert settings.claim_link_enabled is False
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="link@example.com")
        start = client.post("/v1/claims", headers=headers, json={"email": "link@example.com"})
        assert start.status_code == 202
        payload = start.json()
        # no redeemable token/URL is ever present in an API response
        assert "token" not in start.text.lower()
        assert "url" not in payload and "claim?token" not in start.text
        challenge_id = payload["challenge_id"]

        link = client.post(f"/v1/claims/{challenge_id}/link", headers=headers)
        assert link.status_code == 503
        assert link.json()["detail"] == "claim_link_disabled"
        assert "token" not in link.text.lower()

        status = client.get("/v1/claims/link/anything.signed")
        assert status.status_code == 503
        assert status.json()["detail"] == "claim_link_disabled"

        redeem = client.post("/v1/claims/link/redeem", json={"token": "anything.signed"})
        assert redeem.status_code == 503
        assert redeem.json()["detail"] == "claim_link_disabled"

        mobile_redeem = client.post("/mobile/v1/claims/link/redeem", json={"token": "anything.signed"})
        assert mobile_redeem.status_code == 503
        assert mobile_redeem.json()["detail"] == "claim_link_disabled"

        # no link email was ever produced while the flow is closed
        assert read_outbox(settings, "claim_link", "link@example.com") == []
        with client.app.state.sessions() as db:
            challenge = db.get(EmailChallenge, challenge_id)
            assert challenge.link_token_hash is None


def test_claim_link_opt_in_delivers_url_by_email_only(tmp_path):
    settings = build_settings(tmp_path, claim_link_enabled=True)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="optin@example.com")
        start = client.post("/v1/claims", headers=headers, json={"email": "optin@example.com"})
        assert start.status_code == 202, start.text
        link = client.post(f"/v1/claims/{start.json()['challenge_id']}/link", headers=headers)
        assert link.status_code == 200, link.text
        body = link.json()
        # the token is delivered out-of-band only; it is never echoed by the API
        assert "url" not in body and "token" not in body
        assert "claim?token" not in link.text
        entries = read_outbox(settings, "claim_link", "optin@example.com")
        assert entries and "token=" in entries[-1]["url"]
        token = entries[-1]["url"].split("token=", 1)[1]
        assert client.get(f"/v1/claims/link/{token}").json()["status"] == "pending"
        redeemed = client.post("/mobile/v1/claims/link/redeem", json={"token": token})
        assert redeemed.status_code == 200, redeemed.text
        assert redeemed.json()["claimed_session_ids"]
        assert client.post("/mobile/v1/claims/link/redeem", json={"token": token}).status_code == 410


def test_claim_link_opt_in_is_rate_limited_per_email_and_ip(tmp_path):
    """Even opt-in magic-link delivery must not be usable as an unauthenticated email bomb."""
    settings = build_settings(tmp_path, claim_link_enabled=True,
                              otp_per_email_hour=2, otp_per_ip_hour=2)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="optin-limit@example.com")
        start = client.post("/v1/claims", headers=headers, json={"email": "optin-limit@example.com"})
        assert start.status_code == 202, start.text
        url = f"/v1/claims/{start.json()['challenge_id']}/link"
        statuses = [client.post(url, headers=headers).status_code for _ in range(3)]
        assert statuses == [200, 200, 429], statuses
        denied = client.post(url, headers=headers)
        assert denied.status_code == 429
        assert denied.json()["detail"] == "claim_link_rate_limited"


def test_account_takeover_via_email_claim_is_blocked(tmp_path):
    """Full HTTP regression for the magic-link account takeover.

    victim proves ownership and claims their asset; an attacker who only knows/typed the
    victim's email creates a guest session, starts a claim and tries the link flow. The attacker
    must obtain no token/URL, both redeem endpoints must fail, and the victim account/assets must
    be untouched.
    """
    settings = build_settings(tmp_path)
    assert settings.claim_link_enabled is False
    with make_client(settings) as client:
        victim_headers, victim_session = issue_guest(
            client, profile={"type": "dog", "age_months": 12, "dog_size": "large", "name": "Afu"},
            email="Victim@Example.com", full_name="Victim Real")
        upload_photo(client, victim_headers)
        claim_website_session(client, settings, victim_headers, "victim@example.com")
        victim_tokens, victim_mobile = mobile_login(client, settings, "victim@example.com")
        victim_me = client.get("/mobile/v1/me", headers=victim_mobile).json()
        victim_assets = client.get("/mobile/v1/assets", headers=victim_mobile).json()["items"]
        assert victim_me["full_name"] == "Victim Real"
        assert [pet["name"] for pet in victim_me["pets"]] == ["Afu"]
        assert victim_assets and victim_assets[0]["kind"] == "photo"

        # attacker only fills the victim email in a fresh questionnaire guest session
        attacker_headers, attacker_session = issue_guest(
            client, profile={"type": "cat", "age_months": 30, "name": "Stray"},
            email="victim@example.com", full_name="Attacker Name")
        assert attacker_session["session_token"] != victim_session["session_token"]
        with client.app.state.sessions() as db:
            user = db.scalar(select(User).where(User.email_normalized == "victim@example.com"))
            assert user.full_name == "Victim Real"  # unverified input does not rewrite the account
            attacker_guest = db.scalar(select(GuestSession).where(GuestSession.full_name == "Attacker Name"))
            assert attacker_guest is not None and attacker_guest.user_id is None
            assert attacker_guest.email_normalized == "victim@example.com"
            users = db.scalars(select(User)).all()
            assert len(users) == 1
            verified_at_before = user.email_verified_at

        start = client.post("/v1/claims", headers=attacker_headers, json={"email": "victim@example.com"})
        assert start.status_code == 202, start.text
        assert "token" not in start.text.lower() and "url" not in start.text
        challenge_id = start.json()["challenge_id"]

        link = client.post(f"/v1/claims/{challenge_id}/link", headers=attacker_headers)
        assert link.status_code == 503 and link.json()["detail"] == "claim_link_disabled"
        assert "token" not in link.text.lower()
        for path, kwargs in (("/v1/claims/link/redeem", {"token": "forged.token"}),
                             ("/mobile/v1/claims/link/redeem", {"token": "forged.token"})):
            response = client.post(path, json=kwargs)
            assert response.status_code == 503, response.text
            assert response.json()["detail"] == "claim_link_disabled"

        # even guessing the OTP is refused: the attacker cannot complete the claim
        wrong = client.post(f"/v1/claims/{challenge_id}/verify", headers=attacker_headers, json={"code": "000000"})
        assert wrong.status_code == 401

        # victim account and assets are unchanged
        with client.app.state.sessions() as db:
            user = db.scalar(select(User).where(User.email_normalized == "victim@example.com"))
            assert user.id == victim_tokens["user_id"]
            assert user.full_name == "Victim Real"
            assert user.email_verified_at == verified_at_before
            attacker_guest = db.scalar(select(GuestSession).where(GuestSession.full_name == "Attacker Name"))
            assert attacker_guest.user_id is None  # never attached to the victim account
        victim_me_after = client.get("/mobile/v1/me", headers=victim_mobile).json()
        assert victim_me_after["user_id"] == victim_me["user_id"]
        assert victim_me_after["full_name"] == "Victim Real"
        assert [pet["name"] for pet in victim_me_after["pets"]] == ["Afu"]
        after_assets = client.get("/mobile/v1/assets", headers=victim_mobile).json()["items"]
        assert [asset["asset_id"] for asset in after_assets] == [asset["asset_id"] for asset in victim_assets]
        assert client.get("/mobile/v1/me", headers=victim_mobile).status_code == 200


def test_website_claim_challenge_cannot_be_used_for_mobile_login(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        headers, _ = issue_guest(client, email="purpose@example.com")
        start = client.post("/v1/claims", headers=headers, json={"email": "purpose@example.com"}).json()
        code = start.get("dev_code") or read_outbox(settings, "otp", "purpose@example.com")[-1]["code"]
        cross = client.post("/mobile/v1/auth/email/verify",
                            json={"challenge_id": start["challenge_id"], "code": code})
        assert cross.status_code == 403
        assert cross.json()["detail"] == "challenge_purpose_mismatch"
        assert "access_token" not in cross.text
        with client.app.state.sessions() as db:
            challenge = db.get(EmailChallenge, start["challenge_id"])
            assert challenge.consumed_at is None and challenge.attempts == 0
        # the unspent code still works on the correct website flow
        verified = client.post(f"/v1/claims/{start['challenge_id']}/verify", headers=headers, json={"code": code})
        assert verified.status_code == 200, verified.text


def test_verify_code_rejects_wrong_purpose_and_guest_without_consuming(tmp_path):
    from fastapi import HTTPException

    from app import identity

    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        sessions = client.app.state.sessions
        headers, _ = issue_guest(client, email="binding@example.com")
        start = client.post("/v1/claims", headers=headers, json={"email": "binding@example.com"}).json()
        code = start.get("dev_code") or read_outbox(settings, "otp", "binding@example.com")[-1]["code"]
        with pytest.raises(HTTPException) as wrong_purpose:
            identity.verify_code(sessions, settings, start["challenge_id"], code,
                                 expected_purpose=identity.PURPOSE_LOGIN)
        assert wrong_purpose.value.status_code == 403
        with pytest.raises(HTTPException) as wrong_guest:
            identity.verify_code(sessions, settings, start["challenge_id"], code,
                                 expected_purpose=identity.PURPOSE_CLAIM,
                                 expected_guest_session_id="some-other-guest")
        assert wrong_guest.value.status_code == 403
        with sessions() as db:
            challenge = db.get(EmailChallenge, start["challenge_id"])
            assert challenge.consumed_at is None and challenge.attempts == 0
        correct = identity.verify_code(sessions, settings, start["challenge_id"], code,
                                       expected_purpose=identity.PURPOSE_CLAIM,
                                       expected_guest_session_id=challenge_id_guest(sessions, start["challenge_id"]))
        assert correct[1].email_verified_at is not None


def challenge_id_guest(sessions, challenge_id):
    with sessions() as db:
        return db.get(EmailChallenge, challenge_id).guest_session_id


def test_delivery_unavailable_returns_503_without_creating_challenge(tmp_path):
    settings = build_settings(tmp_path, dev_email_outbox=False)
    with make_client(settings) as client:
        response = client.post("/mobile/v1/auth/email/start", json={"email": "smtp@example.com", "purpose": "login"})
        assert response.status_code == 503
        assert response.json()["detail"] == "email_delivery_unavailable"
        with client.app.state.sessions() as db:
            assert db.scalar(select(EmailChallenge)) is None


def test_production_rejects_development_otp_exposure(tmp_path):
    from pydantic import ValidationError
    with pytest.raises(ValidationError):
        build_settings(tmp_path, environment="production", expose_dev_otp=True,
                       database_url="postgresql+psycopg://x:x@localhost/x",
                       shopify_api_secret="secret", allowed_shops=["store.myshopify.com"],
                       shopify_store_domain="store.myshopify.com")


def test_website_claim_can_complete_through_app_proxy_signature(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        query = proxy_query("test-shopify-secret")
        session = client.post("/v1/sessions", params=query, json={
            "profile": {"type": "cat", "age_months": 5, "name": "ProxyCat"},
            "consent": True, "email": "proxy@example.com",
        })
        assert session.status_code == 201, session.text
        token = session.json()["session_token"]
        claim = client.post("/v1/claims", params=query, headers={"X-Wagelpaw-Session": token},
                            json={"email": "proxy@example.com"})
        assert claim.status_code == 202, claim.text
        code = claim.json()["dev_code"]
        verified = client.post(f"/v1/claims/{claim.json()['challenge_id']}/verify", params=query,
                               headers={"X-Wagelpaw-Session": token}, json={"code": code})
        assert verified.status_code == 200, verified.text
        assert verified.json()["claimed"] is True
        # a different (not allowlisted) shop is rejected at the proxy boundary
        evil = client.post("/v1/claims", params=proxy_query("test-shopify-secret", shop="evil.myshopify.com"),
                           headers={"X-Wagelpaw-Session": token}, json={"email": "proxy@example.com"})
        assert evil.status_code in (401, 403)
