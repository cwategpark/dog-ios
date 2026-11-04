"""Stable email identity, one-time email challenges, mobile sessions and claim links.

Security properties:
- user_id is a random opaque id; it is never derived from the email and never a credential.
- OTP codes and link tokens are stored only as hashes.
- Challenges are consumed atomically, bound to a purpose and (for website claims) to one
  concrete guest session.
- Email login never auto-claims guest sessions that merely used the same email.
"""
import base64
import hashlib
import hmac
import json
import secrets
import time
from dataclasses import dataclass

from fastapi import HTTPException, Request
from sqlalchemy import func, or_, select, update
from sqlalchemy.exc import IntegrityError

from .mailer import deliver_claim_link, deliver_otp, mask_email
from .models import EmailChallenge, GuestSession, MobileSession, PetProfile, RateWindow, User

PURPOSE_LOGIN = "mobile_login"
PURPOSE_CLAIM = "website_claim"


@dataclass(frozen=True)
class MobileActor:
    user_id: str
    session_id: str
    shop: str
    family_id: str


def _hmac(secret: str, message: str) -> str:
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


def digest_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _rate_limit(sessions, key: str, limit: int, window_end: float) -> bool:
    with sessions() as db:
        try:
            with db.begin_nested():
                db.add(RateWindow(key=key, count=0, expires_at=window_end))
                db.flush()
        except IntegrityError:
            pass
        bumped = db.execute(update(RateWindow).where(RateWindow.key == key, RateWindow.count < limit).values(count=RateWindow.count + 1))
        db.commit()
        return bumped.rowcount == 1


def get_or_create_user(sessions, email_normalized: str, email_display: str) -> User:
    """Map a normalized email to one stable user row.

    Account fields are deliberately NOT derived from unverified questionnaire input: a visitor
    who merely types someone else's email half-open must never rewrite that account. The only
    writer of ``users.full_name`` is :func:`_apply_verified_full_name`, which runs on the
    explicit claim/verify success path and only fills an empty value.
    """
    with sessions() as db:
        row = db.scalar(select(User).where(User.email_normalized == email_normalized))
        if row:
            return row
        row = User(email_normalized=email_normalized, email_display=email_display[:254], full_name=None)
        db.add(row)
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            existing = db.scalar(select(User).where(User.email_normalized == email_normalized))
            if not existing:
                raise
            return existing
        return row


def _apply_verified_full_name(db, user_id: str, full_name: str | None) -> bool:
    """Fill an empty display name once email ownership has been proven; never overwrite."""
    name = str(full_name).strip()[:120] if full_name else ""
    if not name:
        return False
    updated = db.execute(
        update(User)
        .where(User.id == user_id, or_(User.full_name.is_(None), User.full_name == ""))
        .values(full_name=name, updated_at=time.time())
        .execution_options(synchronize_session=False)
    )
    return updated.rowcount == 1



def issue_code_challenge(sessions, settings, user: User, purpose: str, guest_session_id: str | None, ip_hash: str):
    now = time.time()
    hour = int(now // 3600)
    email_key = f"otp:email:{hour}:{hashlib.sha256(user.email_normalized.encode()).hexdigest()[:16]}"
    if not _rate_limit(sessions, email_key, settings.otp_per_email_hour, (hour + 1) * 3600):
        raise HTTPException(429, "email_rate_limited")
    ip_key = f"otp:ip:{hour}:{ip_hash[:16]}"
    if not _rate_limit(sessions, ip_key, settings.otp_per_ip_hour, (hour + 1) * 3600):
        raise HTTPException(429, "ip_rate_limited")
    with sessions() as db:
        recent = db.scalar(
            select(EmailChallenge)
            .where(EmailChallenge.email_normalized == user.email_normalized, EmailChallenge.created_at > now - settings.otp_resend_cooldown_seconds)
            .order_by(EmailChallenge.created_at.desc())
        )
        if recent:
            raise HTTPException(429, "otp_resend_cooldown")
        code = f"{secrets.randbelow(1_000_000):06d}"
        challenge_id = secrets.token_hex(16)
        challenge = EmailChallenge(
            id=challenge_id,
            purpose=purpose,
            user_id=user.id,
            guest_session_id=guest_session_id,
            email_normalized=user.email_normalized,
            code_hash=_hmac(settings.rate_limit_salt.get_secret_value() or settings.dev_token.get_secret_value() or "dev-otp", f"{challenge_id}:{code}"),
            max_attempts=settings.otp_max_attempts,
            expires_at=now + settings.otp_ttl_seconds,
            ip_hash=ip_hash,
        )
        db.add(challenge)
        db.commit()
    return challenge, code


def send_challenge(settings, challenge: EmailChallenge, code: str) -> str:
    mode = deliver_otp(settings, challenge.email_normalized, code, challenge.purpose)
    return mode


def serialize_challenge(settings, challenge: EmailChallenge, delivery: str, code: str | None = None) -> dict:
    payload = {
        "challenge_id": challenge.id,
        "purpose": challenge.purpose,
        "email_masked": mask_email(challenge.email_normalized),
        "expires_at": challenge.expires_at,
        "delivery": delivery,
    }
    if settings.expose_dev_otp and settings.environment in ("development", "test") and code is not None:
        payload["dev_code"] = code
    return payload


def _code_hmac(settings, challenge_id: str, code: str) -> str:
    return _hmac(
        settings.rate_limit_salt.get_secret_value() or settings.dev_token.get_secret_value() or "dev-otp",
        f"{challenge_id}:{code}",
    )


def _verify_race_error(sessions, challenge_id: str) -> HTTPException:
    """Classify a lost optimistic race without ever issuing a token."""
    with sessions() as db:
        challenge = db.get(EmailChallenge, challenge_id)
        if not challenge:
            return HTTPException(404, "challenge_not_found")
        if challenge.consumed_at is not None:
            return HTTPException(410, "challenge_already_consumed")
        if challenge.expires_at <= time.time():
            return HTTPException(410, "challenge_expired")
        if challenge.attempts >= challenge.max_attempts:
            return HTTPException(429, "challenge_attempts_exceeded")
        return HTTPException(401, "invalid_otp")


def verify_code(sessions, settings, challenge_id: str, code: str,
                expected_purpose: str,
                expected_guest_session_id: str | None = None) -> tuple[EmailChallenge, User]:
    """Verify one OTP with purpose/session binding and fully atomic accounting.

    Ordering matters: purpose and guest-session binding are checked *before* any attempt is
    counted or the challenge is consumed, so a challenge from another flow can neither spend
    the victim's attempts nor be redeemed. Wrong-code attempts use a single conditional
    ``UPDATE ... WHERE attempts < max_attempts`` (no read-modify-write), and a correct code is
    consumed by one conditional ``UPDATE ... WHERE consumed_at IS NULL``; exactly one caller
    can win either race. Validation and consumption share one transaction/session.
    """
    now = time.time()
    if not isinstance(code, str) or not code.strip().isdigit() or len(code.strip()) != 6:
        raise HTTPException(422, "invalid_otp_format")
    challenge_id = (challenge_id or "")[:32]
    with sessions() as db:
        challenge = db.get(EmailChallenge, challenge_id)
        if not challenge:
            raise HTTPException(404, "challenge_not_found")
        # Binding checks happen before consumption and before attempt accounting. The
        # expected purpose is a required argument so no future caller can silently skip it.
        if challenge.purpose != expected_purpose:
            raise HTTPException(403, "challenge_purpose_mismatch")
        if expected_guest_session_id is not None and challenge.guest_session_id != expected_guest_session_id:
            raise HTTPException(403, "challenge_session_mismatch")
        if challenge.consumed_at is not None:
            raise HTTPException(410, "challenge_already_consumed")
        if challenge.expires_at <= now:
            raise HTTPException(410, "challenge_expired")
        if challenge.attempts >= challenge.max_attempts:
            raise HTTPException(429, "challenge_attempts_exceeded")
        expected = _code_hmac(settings, challenge.id, code.strip())
        if not hmac.compare_digest(expected, challenge.code_hash or ""):
            bumped = db.execute(
                update(EmailChallenge)
                .where(
                    EmailChallenge.id == challenge.id,
                    EmailChallenge.consumed_at.is_(None),
                    EmailChallenge.expires_at > now,
                    EmailChallenge.attempts < EmailChallenge.max_attempts,
                )
                .values(attempts=EmailChallenge.attempts + 1)
                .execution_options(synchronize_session=False)
            )
            if bumped.rowcount != 1:
                db.rollback()
                raise _verify_race_error(sessions, challenge.id)
            db.commit()
            raise HTTPException(401, "invalid_otp")
        consumed = db.execute(
            update(EmailChallenge)
            .where(
                EmailChallenge.id == challenge.id,
                EmailChallenge.consumed_at.is_(None),
                EmailChallenge.expires_at > now,
                EmailChallenge.attempts < EmailChallenge.max_attempts,
            )
            .values(consumed_at=now)
            .execution_options(synchronize_session=False)
        )
        if consumed.rowcount != 1:
            db.rollback()
            raise _verify_race_error(sessions, challenge.id)
        user = db.get(User, challenge.user_id)
        if not user:
            raise HTTPException(404, "user_not_found")
        user.email_verified_at = user.email_verified_at or now
        user.updated_at = now
        db.commit()
        return challenge, user


# --------------------------------------------------------------------------- tokens
def _new_token() -> tuple[str, str]:
    token = secrets.token_urlsafe(48)
    return token, digest_token(token)


def _add_mobile_session(db, settings, user_id: str, shop: str, family: str) -> tuple[MobileSession, str, str]:
    now = time.time()
    access, access_hash = _new_token()
    refresh, refresh_hash = _new_token()
    row = MobileSession(
        user_id=user_id,
        shop=shop,
        family_id=family,
        access_hash=access_hash,
        refresh_hash=refresh_hash,
        access_expires_at=now + settings.access_token_ttl_seconds,
        refresh_expires_at=now + settings.refresh_token_ttl_seconds,
    )
    db.add(row)
    return row, access, refresh


def _token_payload(row: MobileSession, access: str, refresh: str) -> dict:
    return {
        "access_token": access,
        "refresh_token": refresh,
        "access_expires_at": row.access_expires_at,
        "refresh_expires_at": row.refresh_expires_at,
    }


def issue_mobile_tokens(sessions, settings, user_id: str, shop: str, family_id: str | None = None) -> dict:
    family = family_id or secrets.token_hex(16)
    with sessions() as db:
        row, access, refresh = _add_mobile_session(db, settings, user_id, shop, family)
        db.commit()
        return _token_payload(row, access, refresh)


def _find_access(sessions, settings, token: str) -> MobileSession | None:
    if not isinstance(token, str) or len(token) < 20:
        return None
    digest = digest_token(token)
    with sessions() as db:
        row = db.scalar(select(MobileSession).where(MobileSession.access_hash == digest))
        if not row or row.revoked_at is not None or row.access_expires_at <= time.time():
            return None
        if row.shop != settings.local_shop:
            return None
        return row


def mobile_actor(request: Request) -> MobileActor:
    settings = request.app.state.settings
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        raise HTTPException(401, "mobile_token_required")
    token = header[7:].strip()
    row = _find_access(request.app.state.sessions, settings, token)
    if not row:
        raise HTTPException(401, "mobile_token_invalid_or_expired")
    return MobileActor(user_id=row.user_id, session_id=row.id, shop=row.shop, family_id=row.family_id)


def refresh_mobile_tokens(sessions, settings, refresh_token: str) -> dict:
    """Rotate one refresh token with a single conditional UPDATE inside one transaction.

    The old member is revoked by ``UPDATE ... WHERE id=:id AND revoked_at IS NULL``; only a
    ``rowcount == 1`` winner inserts the new access/refresh pair (same family) and commits once,
    so a rotated pair can never be observed before the old one is dead. Any loser - a concurrent
    rotation or a replay of an already-rotated token - persists a family-wide revoke in the same
    transaction and gets 401, which guarantees the family never keeps a usable member after a
    replay.
    """
    digest = digest_token(refresh_token or "")
    with sessions() as db:
        row = db.scalar(select(MobileSession).where(MobileSession.refresh_hash == digest))
        if not row:
            raise HTTPException(401, "refresh_token_invalid")
        now = time.time()
        if row.revoked_at is not None:
            _revoke_family_in(db, row.family_id, now)
            db.commit()
            raise HTTPException(401, "refresh_token_reused")
        if row.refresh_expires_at <= now:
            _revoke_family_in(db, row.family_id, now)
            db.commit()
            raise HTTPException(401, "refresh_token_expired")
        revoked = db.execute(
            update(MobileSession)
            .where(
                MobileSession.id == row.id,
                MobileSession.revoked_at.is_(None),
                MobileSession.refresh_expires_at > now,
            )
            .values(revoked_at=now)
            .execution_options(synchronize_session=False)
        )
        if revoked.rowcount != 1:
            # Lost the race or the row was revoked a moment ago: kill the whole family and 401.
            _revoke_family_in(db, row.family_id, now)
            db.commit()
            raise HTTPException(401, "refresh_token_reused")
        new_row, access, refresh = _add_mobile_session(db, settings, row.user_id, row.shop, row.family_id)
        db.commit()
        return _token_payload(new_row, access, refresh)


def _revoke_family_in(db, family_id: str, now: float) -> None:
    db.execute(
        update(MobileSession)
        .where(MobileSession.family_id == family_id, MobileSession.revoked_at.is_(None))
        .values(revoked_at=now)
        .execution_options(synchronize_session=False)
    )


def revoke_family(sessions, family_id: str) -> None:
    with sessions() as db:
        db.execute(update(MobileSession).where(MobileSession.family_id == family_id, MobileSession.revoked_at.is_(None)).values(revoked_at=time.time()))
        db.commit()


def user_by_id(sessions, user_id: str) -> User | None:
    with sessions() as db:
        return db.get(User, user_id)


# --------------------------------------------------------------------------- claim
def claim_guest_session(sessions, settings, user: User, guest_session_id: str | None) -> list[str]:
    """Attach one concrete guest session (and only that one) to a verified user via CAS.

    ``UPDATE guest_sessions SET user_id=:uid ... WHERE id=:sid AND (user_id IS NULL OR
    user_id=:uid)`` is the whole ownership decision: ``rowcount == 1`` means we won (or it was
    already ours, which makes a repeated same-account claim idempotent) and ``rowcount == 0``
    means another account won the race -> 409 without touching their row. Pet upsert and the
    verified-name fill happen in the same transaction as the CAS so concurrent same-account
    claims cannot duplicate pets.
    """
    from .assets import transfer_guest_assets, upsert_pets_for_session

    if not guest_session_id:
        raise HTTPException(409, "guest_session_already_claimed")
    now = time.time()
    with sessions() as db:
        guest = db.get(GuestSession, guest_session_id)
        claimed = db.execute(
            update(GuestSession)
            .where(
                GuestSession.id == guest_session_id,
                or_(GuestSession.user_id.is_(None), GuestSession.user_id == user.id),
            )
            .values(
                user_id=user.id,
                claimed_at=func.coalesce(GuestSession.claimed_at, now),
                expires_at=now + settings.session_ttl_seconds,
            )
            .execution_options(synchronize_session=False)
        )
        if claimed.rowcount != 1:
            db.rollback()
            raise HTTPException(409, "guest_session_already_claimed")
        # Unverified questionnaire input only lives on the guest row; once ownership is proven
        # the empty account display name may be filled from it (never overwritten).
        if guest is not None:
            _apply_verified_full_name(db, user.id, guest.full_name)
        upsert_pets_for_session(db, user.id, guest_session_id)
        db.commit()
    transfer_guest_assets(sessions, settings, guest_session_id, user.id)
    return [guest_session_id]


def claim_sessions_for_guest(sessions, settings, user: User, guest_session_id: str) -> list[str]:
    return claim_guest_session(sessions, settings, user, guest_session_id)


# --------------------------------------------------------------------------- claim link
def _link_secret(settings) -> str:
    return (settings.claim_link_secret.get_secret_value() or settings.rate_limit_salt.get_secret_value()
            or settings.dev_token.get_secret_value() or "dev-claim-link-secret")


def create_claim_link(sessions, settings, challenge: EmailChallenge, ip_hash: str | None = None) -> dict:
    """Issue an email claim link.

    Disabled by default (``claim_link_enabled=False``): no token is generated and the caller
    gets 503 instead of a redeemable secret. Even when an operator opts in, the URL/token is
    only ever delivered out-of-band by email - it is never part of an API response, so an
    unverified visitor who typed a victim's email can obtain nothing by calling this endpoint.

    Opt-in delivery is rate limited per target address and (when available) per client IP with
    the same one-hour atomic counters as OTP start, so the API cannot be used as an email bomb
    even by an unverified guest.
    """
    if not settings.claim_link_enabled:
        raise HTTPException(503, "claim_link_disabled")
    if not settings.public_base_url:
        raise HTTPException(503, "claim_link_unavailable")
    now = time.time()
    hour = int(now // 3600)
    email_digest = hashlib.sha256(challenge.email_normalized.encode()).hexdigest()[:16]
    if not _rate_limit(sessions, f"claim_link:email:{hour}:{email_digest}",
                       settings.otp_per_email_hour, (hour + 1) * 3600):
        raise HTTPException(429, "claim_link_rate_limited")
    if ip_hash:
        if not _rate_limit(sessions, f"claim_link:ip:{hour}:{ip_hash[:16]}",
                           settings.otp_per_ip_hour, (hour + 1) * 3600):
            raise HTTPException(429, "claim_link_rate_limited")
    expires_at = now + settings.claim_link_ttl_seconds
    payload = base64.urlsafe_b64encode(json.dumps({"c": challenge.id, "e": expires_at}, sort_keys=True).encode()).decode().rstrip("=")
    signature = _hmac(_link_secret(settings), payload)
    token = f"{payload}.{signature}"
    with sessions() as db:
        row = db.get(EmailChallenge, challenge.id)
        if not row or row.consumed_at is not None:
            raise HTTPException(410, "challenge_already_consumed")
        row.link_token_hash = digest_token(token)
        db.commit()
    delivery = deliver_claim_link(settings, challenge.email_normalized,
                                  f"{settings.public_base_url.rstrip('/')}/claim?token={token}", expires_at)
    return {"expires_at": expires_at, "delivery": delivery, "sent": True}


def parse_claim_link(settings, token: str) -> tuple[EmailChallenge, dict]:
    try:
        payload, signature = token.split(".", 1)
    except ValueError as error:
        raise HTTPException(404, "claim_link_invalid") from error
    if not hmac.compare_digest(_hmac(_link_secret(settings), payload), signature):
        raise HTTPException(404, "claim_link_invalid")
    try:
        data = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (ValueError, TypeError) as error:
        raise HTTPException(404, "claim_link_invalid") from error
    if not isinstance(data, dict) or not data.get("c") or not data.get("e"):
        raise HTTPException(404, "claim_link_invalid")
    return data["c"], data


def redeem_claim_link(sessions, settings, token: str) -> tuple[User, EmailChallenge]:
    if not settings.claim_link_enabled:
        raise HTTPException(503, "claim_link_disabled")
    challenge_id, data = parse_claim_link(settings, token)
    now = time.time()
    if float(data.get("e", 0)) <= now:
        raise HTTPException(410, "claim_link_expired")
    expected_hash = digest_token(token)
    with sessions() as db:
        challenge = db.get(EmailChallenge, challenge_id[:32])
        if not challenge:
            raise HTTPException(404, "claim_link_invalid")
        if challenge.consumed_at is not None:
            raise HTTPException(410, "claim_link_already_redeemed")
        if challenge.link_token_hash != expected_hash:
            raise HTTPException(404, "claim_link_invalid")
        if challenge.expires_at <= now:
            raise HTTPException(410, "challenge_expired")
        consumed = db.execute(
            update(EmailChallenge)
            .where(EmailChallenge.id == challenge.id, EmailChallenge.consumed_at.is_(None))
            .values(consumed_at=now)
        )
        if consumed.rowcount != 1:
            raise HTTPException(410, "claim_link_already_redeemed")
        user = db.get(User, challenge.user_id)
        if not user:
            raise HTTPException(404, "user_not_found")
        user.email_verified_at = user.email_verified_at or now
        user.updated_at = now
        db.commit()
    return user, challenge


def email_verified(user: User) -> bool:
    return user.email_verified_at is not None


# --------------------------------------------------------------------------- pet upsert helper
def pet_display_from_profile(profile: dict) -> dict:
    """Best-effort display fields kept from the original questionnaire payload."""
    pet = profile.get("pet_information", profile) if isinstance(profile, dict) else {}
    display = profile.get("display") if isinstance(profile, dict) else None
    name = None
    breed = None
    if isinstance(display, dict):
        name, breed = display.get("name"), display.get("breed")
    if isinstance(pet, dict):
        name = name or pet.get("name")
        breed = breed or pet.get("breed")
    return {"name": str(name)[:80] if name else None, "breed": str(breed)[:80] if breed else None}


def load_pet_profile(sessions, guest_session_id: str) -> dict:
    with sessions() as db:
        row = db.get(PetProfile, guest_session_id)
        return row.data if row and isinstance(row.data, dict) else {}


def issue_login_tokens_for_challenge(sessions, settings, challenge: EmailChallenge) -> dict:
    user = user_by_id(sessions, challenge.user_id)
    if not user:
        raise HTTPException(404, "user_not_found")
    return issue_mobile_tokens(sessions, settings, user.id, settings.local_shop)
