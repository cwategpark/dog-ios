"""Direct mobile API (/mobile/v1). Auth does not depend on Shopify App Proxy."""
import json

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field

from . import assets, identity, social
from .mailer import delivery_mode, display_email, normalize_email
from .models import User
from .security import anonymous_ip_hash

router = APIRouter(prefix="/mobile/v1")


class EmailStartInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str
    purpose: str = "login"


class EmailVerifyInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    challenge_id: str
    code: str


class RefreshInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    refresh_token: str


class LogoutInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    refresh_token: str | None = None


class RedeemInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    token: str


class DiscoveryInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    enabled: bool
    region: dict | None = None
    radius_km: int | None = Field(default=None, ge=1, le=25)


class ContactRequestBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    target_public_ref: str
    message: str | None = None


class MessageInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    contact_id: str
    body: str
    client_id: str


class BlockInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    target_public_ref: str


def _settings(request: Request):
    return request.app.state.settings


def _sessions(request: Request):
    return request.app.state.sessions


def _user_or_401(sessions, user_id: str) -> User:
    user = identity.user_by_id(sessions, user_id)
    if not user or not user.email_verified_at:
        raise HTTPException(401, "email_verification_required")
    return user


def _token_payload(sessions, settings, user: User, tokens: dict, claimed: list[str] | None = None) -> dict:
    return {
        "user_id": user.id,
        "email": user.email_display,
        "email_verified_at": user.email_verified_at,
        "full_name": user.full_name,
        **tokens,
        "claimed_session_ids": claimed or [],
    }


@router.post("/auth/email/start", status_code=202)
def start_email_login(body: EmailStartInput, request: Request):
    settings, sessions = _settings(request), _sessions(request)
    if body.purpose not in ("login",):
        raise HTTPException(422, "unsupported_purpose")
    try:
        normalized = normalize_email(body.email)
    except ValueError as error:
        raise HTTPException(422, "invalid_email") from error
    if delivery_mode(settings) == "unavailable":
        raise HTTPException(503, "email_delivery_unavailable")
    user = identity.get_or_create_user(sessions, normalized, display_email(body.email))
    challenge, code = identity.issue_code_challenge(
        sessions, settings, user, identity.PURPOSE_LOGIN, None, anonymous_ip_hash(request)
    )
    delivery = identity.send_challenge(settings, challenge, code)
    return identity.serialize_challenge(settings, challenge, delivery, code)


@router.post("/auth/email/verify")
def verify_email_login(body: EmailVerifyInput, request: Request):
    settings, sessions = _settings(request), _sessions(request)
    # Mobile login only redeems mobile_login challenges; website claim challenges are rejected
    # before they are consumed or any token is issued.
    challenge, user = identity.verify_code(
        sessions, settings, body.challenge_id, body.code,
        expected_purpose=identity.PURPOSE_LOGIN,
    )
    tokens = identity.issue_mobile_tokens(sessions, settings, user.id, settings.local_shop)
    return _token_payload(sessions, settings, user, tokens)


@router.post("/auth/refresh")
def refresh(body: RefreshInput, request: Request):
    settings, sessions = _settings(request), _sessions(request)
    return identity.refresh_mobile_tokens(sessions, settings, body.refresh_token)


@router.post("/auth/logout", status_code=204)
def logout(body: LogoutInput, request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    identity.revoke_family(_sessions(request), actor.family_id)
    return Response(status_code=204)


@router.get("/me")
def me(request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    settings, sessions = _settings(request), _sessions(request)
    user = _user_or_401(sessions, actor.user_id)
    return {
        "user_id": user.id,
        "public_ref": user.public_ref,
        "email": user.email_display,
        "full_name": user.full_name,
        "email_verified_at": user.email_verified_at,
        "created_at": user.created_at,
        "pets": assets.list_pets(sessions, user.id),
    }


@router.get("/pets")
def pets(request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return {"pets": assets.list_pets(sessions, actor.user_id)}


@router.get("/pet-home")
def pet_home(request: Request, pet_id: str | None = Query(default=None),
             actor: identity.MobileActor = Depends(identity.mobile_actor)):
    settings, sessions = _settings(request), _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return assets.pet_home_manifest(sessions, settings, actor.user_id, pet_id)


@router.get("/assets")
def list_assets(request: Request, kind: str | None = Query(default=None),
                cursor: str | None = Query(default=None), limit: int = Query(default=20, ge=1, le=50),
                actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return assets.list_user_assets(sessions, actor.user_id, kind=kind, cursor=cursor, limit=limit)


@router.get("/assets/{asset_id}/download")
def download_asset(asset_id: str, request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    settings, sessions = _settings(request), _sessions(request)
    _user_or_401(sessions, actor.user_id)
    row, data = assets.get_owned_asset(sessions, settings, actor.user_id, asset_id)
    filename = f"asset-{row.id}.{row.format}"
    return Response(data, media_type=row.mime,
                    headers={"Content-Disposition": f'attachment; filename="{filename}"'})


@router.get("/assets/{asset_id}/manifest")
def asset_manifest(asset_id: str, request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    settings, sessions = _settings(request), _sessions(request)
    _user_or_401(sessions, actor.user_id)
    row, _data = assets.get_owned_asset(sessions, settings, actor.user_id, asset_id)
    return {"asset_id": row.id, "kind": row.kind, "format": row.format, "mime": row.mime,
            "bytes": row.bytes, "sha256": row.sha256, "source_job_id": row.job_id, "available": True}


@router.post("/claims/link/redeem")
def redeem_link(body: RedeemInput, request: Request):
    settings, sessions = _settings(request), _sessions(request)
    user, challenge = identity.redeem_claim_link(sessions, settings, body.token)
    claimed = identity.claim_guest_session(sessions, settings, user, challenge.guest_session_id)
    tokens = identity.issue_mobile_tokens(sessions, settings, user.id, settings.local_shop)
    return _token_payload(sessions, settings, user, tokens, claimed)


@router.post("/discovery", status_code=202)
def set_discovery(body: DiscoveryInput, request: Request,
                  actor: identity.MobileActor = Depends(identity.mobile_actor)):
    settings, sessions = _settings(request), _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.set_discovery(sessions, settings, actor.user_id, body.enabled, body.region, body.radius_km)


@router.get("/discovery")
def get_discovery(request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.get_discovery(sessions, actor.user_id)


@router.get("/nearby")
def nearby(request: Request, radius_km: int | None = Query(default=None, ge=1, le=25),
           actor: identity.MobileActor = Depends(identity.mobile_actor)):
    settings, sessions = _settings(request), _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.nearby(sessions, settings, actor.user_id, radius_km)


@router.post("/contacts/requests")
def create_contact_request(body: ContactRequestBody, request: Request,
                           actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    payload, created = social.create_contact_request(sessions, actor.user_id, body.target_public_ref, body.message)
    return Response(json.dumps(payload), status_code=201 if created else 200,
                    media_type="application/json")


@router.get("/contacts/requests")
def list_contact_requests(request: Request, direction: str = Query(default="incoming"),
                          actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.list_contact_requests(sessions, actor.user_id, direction)


@router.post("/contacts/requests/{request_id}/accept")
def accept_request(request_id: str, request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.respond_to_request(sessions, actor.user_id, request_id, True)


@router.post("/contacts/requests/{request_id}/decline")
def decline_request(request_id: str, request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.respond_to_request(sessions, actor.user_id, request_id, False)


@router.get("/contacts")
def list_contacts(request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.list_contacts(sessions, actor.user_id)


@router.post("/messages")
def send_message(body: MessageInput, request: Request,
                 actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    payload, created = social.send_message(sessions, actor.user_id, body.contact_id, body.body, body.client_id)
    return Response(json.dumps(payload), status_code=201 if created else 200,
                    media_type="application/json")


@router.get("/messages")
def list_messages(request: Request, contact_id: str = Query(...),
                  before: float | None = Query(default=None),
                  before_id: str | None = Query(default=None),
                  limit: int = Query(default=30, ge=1, le=100),
                  actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.list_messages(sessions, actor.user_id, contact_id, before, limit, before_id)


@router.post("/blocks", status_code=201)
def add_block(body: BlockInput, request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.add_block(sessions, actor.user_id, body.target_public_ref)


@router.get("/blocks")
def list_blocks(request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.list_blocks(sessions, actor.user_id)


@router.delete("/blocks/{public_ref}")
def remove_block(public_ref: str, request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    sessions = _sessions(request)
    _user_or_401(sessions, actor.user_id)
    return social.remove_block(sessions, actor.user_id, public_ref)
