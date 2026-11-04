"""Website claim bridge (/v1/claims): explicit email ownership proof for one guest session."""
import time

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict

from . import identity
from .mailer import delivery_mode, display_email, mask_email, normalize_email
from .models import EmailChallenge
from .security import Actor, anonymous_ip_hash, authenticated_actor

router = APIRouter(prefix="/v1")


class ClaimStartInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str
    full_name: str | None = None


class ClaimVerifyInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    code: str


class LinkRedeemInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    token: str


def _settings(request: Request):
    return request.app.state.settings


def _sessions(request: Request):
    return request.app.state.sessions


def _owned_challenge(sessions, claim_id: str, actor: Actor) -> EmailChallenge:
    with sessions() as db:
        challenge = db.get(EmailChallenge, (claim_id or "")[:32])
    if not challenge or challenge.guest_session_id != actor.owner_id:
        raise HTTPException(404, "claim_not_found")
    return challenge


@router.post("/claims", status_code=202)
def start_claim(body: ClaimStartInput, request: Request, actor: Actor = Depends(authenticated_actor)):
    settings, sessions = _settings(request), _sessions(request)
    if delivery_mode(settings) == "unavailable":
        raise HTTPException(503, "email_delivery_unavailable")
    try:
        normalized = normalize_email(body.email)
    except ValueError as error:
        raise HTTPException(422, "invalid_email") from error
    user = identity.get_or_create_user(sessions, normalized, display_email(body.email))
    challenge, code = identity.issue_code_challenge(
        sessions, settings, user, identity.PURPOSE_CLAIM, actor.owner_id, anonymous_ip_hash(request)
    )
    delivery = identity.send_challenge(settings, challenge, code)
    payload = identity.serialize_challenge(settings, challenge, delivery, code)
    payload["link_available"] = bool(settings.claim_link_enabled and settings.public_base_url)
    return payload


@router.post("/claims/{claim_id}/verify")
def verify_claim(claim_id: str, body: ClaimVerifyInput, request: Request, actor: Actor = Depends(authenticated_actor)):
    settings, sessions = _settings(request), _sessions(request)
    _owned_challenge(sessions, claim_id, actor)
    # The OTP must be a website_claim challenge bound to this exact guest session; any other
    # purpose/session is rejected before the attempt counter or the consumed flag move.
    challenge, user = identity.verify_code(
        sessions, settings, claim_id, body.code,
        expected_purpose=identity.PURPOSE_CLAIM,
        expected_guest_session_id=actor.owner_id,
    )
    claimed = identity.claim_guest_session(sessions, settings, user, challenge.guest_session_id)
    return {"claimed": True, "email_verified": True, "email_masked": mask_email(user.email_normalized),
            "claimed_session_ids": claimed}


@router.post("/claims/{claim_id}/link")
def create_link(claim_id: str, request: Request, actor: Actor = Depends(authenticated_actor)):
    settings, sessions = _settings(request), _sessions(request)
    if not settings.claim_link_enabled:
        raise HTTPException(503, "claim_link_disabled")
    challenge = _owned_challenge(sessions, claim_id, actor)
    return identity.create_claim_link(sessions, settings, challenge, anonymous_ip_hash(request))


@router.get("/claims/link/{token}")
def claim_link_status(token: str, request: Request):
    settings, sessions = _settings(request), _sessions(request)
    if not settings.claim_link_enabled:
        raise HTTPException(503, "claim_link_disabled")
    challenge_id, data = identity.parse_claim_link(settings, token)
    with sessions() as db:
        challenge = db.get(EmailChallenge, challenge_id[:32])
    if not challenge:
        raise HTTPException(404, "claim_link_invalid")
    now = time.time()
    status = "redeemed" if challenge.consumed_at is not None else ("expired" if challenge.expires_at <= now else "pending")
    return {"email_masked": mask_email(challenge.email_normalized), "expires_at": challenge.expires_at, "status": status}


@router.post("/claims/link/redeem")
def redeem_link(body: LinkRedeemInput, request: Request):
    settings, sessions = _settings(request), _sessions(request)
    user, challenge = identity.redeem_claim_link(sessions, settings, body.token)
    claimed = identity.claim_guest_session(sessions, settings, user, challenge.guest_session_id)
    return {"claimed": True, "email_verified": True, "email_masked": mask_email(user.email_normalized),
            "claimed_session_ids": claimed}
