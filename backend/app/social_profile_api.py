"""User social profile (public display name + controlled avatar) for iOS social features.

This module is intentionally self-contained so it can be merged into the canonical backend
without touching the existing models/migrations/main files yet. The canonical owner must:
1. import `router` in `app/main.py` and `include_router` it; and
2. add the `social_profiles` table (this file's `SocialProfile` model) to their unified
   migration lineage / model registry.

No private media path or email is ever returned. Uploaded avatars are re-encoded to a
512px JPEG thumbnail, stripped of EXIF, stored under a separate `social-avatars` directory,
and served only to the authenticated owner. A public consumer should use `avatar.public_key`
(or the explicit default key) and never a filesystem path.
"""
from __future__ import annotations

import hashlib
import io
import secrets
import time
from pathlib import Path

import math

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, Response
from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict
from sqlalchemy import Float, Integer, String, select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Mapped, mapped_column

from . import identity
from .db import Base
from .models import Contact, DiscoveryProfile, User, UserBlock

router = APIRouter(prefix="/mobile/v1")

DEFAULT_AVATAR_KEYS = ("paw", "dog", "cat", "leaf")
AVATAR_MAX_BYTES = 5 * 1024 * 1024
AVATAR_MAX_PIXELS = 24_000_000
AVATAR_EDGE = 512
AVATAR_MIME_TYPES = ("image/jpeg", "image/png", "image/webp")
DISPLAY_NAME_MAX = 40
AVATAR_DIR = "social-avatars"


class SocialProfile(Base):
    """1:1 public social profile. Kept out of `models.py` during the split merge."""

    __tablename__ = "social_profiles"
    user_id: Mapped[str] = mapped_column(String(32), primary_key=True)
    display_name: Mapped[str | None] = mapped_column(String(DISPLAY_NAME_MAX), nullable=True)
    avatar_kind: Mapped[str] = mapped_column(String(16), default="none", server_default="none")
    default_avatar_key: Mapped[str | None] = mapped_column(String(32), nullable=True)
    avatar_storage_key: Mapped[str | None] = mapped_column(String(64), nullable=True)
    avatar_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    avatar_bytes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    avatar_mime: Mapped[str | None] = mapped_column(String(32), nullable=True)
    profile_completed_at: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    updated_at: Mapped[float] = mapped_column(Float, default=time.time)


class SocialProfilePatch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    display_name: str | None = None
    default_avatar_key: str | None = None


def _sessions(request: Request):
    return request.app.state.sessions


def _settings(request: Request):
    return request.app.state.settings


def _verified_user(request: Request, actor: identity.MobileActor) -> User:
    user = identity.user_by_id(_sessions(request), actor.user_id)
    if not user or user.email_verified_at is None:
        raise HTTPException(401, "email_verification_required")
    return user


def _normalize_display_name(value: str | None) -> str | None:
    if value is None:
        return None
    name = " ".join(value.split()).strip()
    if not name or len(name) > DISPLAY_NAME_MAX:
        raise HTTPException(422, "invalid_display_name")
    if any(ord(char) < 32 or ord(char) == 127 for char in name):
        raise HTTPException(422, "invalid_display_name")
    return name


def _avatar_path(settings, key: str) -> Path:
    if not key or any(char not in "0123456789abcdef" for char in key) or len(key) != 64:
        raise HTTPException(404, "avatar_not_found")
    root = (Path(settings.storage_path) / AVATAR_DIR).resolve()
    path = (root / f"{key}.jpg").resolve()
    if path.parent != root:
        raise HTTPException(404, "avatar_not_found")
    return path


def _profile(request: Request, user_id: str) -> SocialProfile | None:
    with _sessions(request)() as db:
        return db.get(SocialProfile, user_id)


def _avatar_descriptor(settings, row: SocialProfile | None) -> dict:
    if row is None or row.avatar_kind == "none":
        return {"kind": "none", "default_key": None, "public_key": None,
                "available": False, "updated_at": None}
    if row.avatar_kind == "default":
        key = row.default_avatar_key if row.default_avatar_key in DEFAULT_AVATAR_KEYS else None
        return {"kind": "default", "default_key": key,
                "public_key": f"default:{key}" if key else None,
                "available": key is not None, "updated_at": row.updated_at}
    uploaded = bool(row.avatar_storage_key)
    if uploaded:
        try:
            uploaded = _avatar_path(settings, row.avatar_storage_key).is_file()
        except HTTPException:
            uploaded = False
    return {"kind": "upload", "default_key": None,
            "public_key": f"social:{row.avatar_sha256}" if uploaded and row.avatar_sha256 else None,
            "available": uploaded, "updated_at": row.updated_at}


def _serialize(settings, row: SocialProfile | None, user_id: str) -> dict:
    display_name = row.display_name if row and row.display_name else None
    avatar = _avatar_descriptor(settings, row)
    missing = []
    if not display_name:
        missing.append("display_name")
    if avatar["kind"] == "none" or not avatar["available"]:
        missing.append("avatar")
    completed = not missing
    return {
        "user_id": user_id,
        "display_name": display_name,
        "avatar": avatar,
        "profile_completed": completed,
        "missing": missing,
        "default_avatar_keys": list(DEFAULT_AVATAR_KEYS),
        "limits": {
            "display_name_max": DISPLAY_NAME_MAX,
            "avatar_max_bytes": AVATAR_MAX_BYTES,
            "avatar_mime_types": list(AVATAR_MIME_TYPES),
            "avatar_edge": AVATAR_EDGE,
        },
        "updated_at": row.updated_at if row else None,
    }


def _get_or_create(db, user_id: str) -> SocialProfile:
    row = db.get(SocialProfile, user_id)
    if row is None:
        row = SocialProfile(user_id=user_id)
        db.add(row)
        db.flush()
    return row


def _mark_completion(row: SocialProfile, now: float) -> None:
    complete = bool(row.display_name) and row.avatar_kind in ("default", "upload")
    if complete and row.profile_completed_at is None:
        row.profile_completed_at = now
    elif not complete:
        row.profile_completed_at = None
    row.updated_at = now


GRID_DEGREES = 0.05


def _grid_center(grid_x: int, grid_y: int) -> tuple[float, float]:
    return (grid_x + 0.5) * GRID_DEGREES, (grid_y + 0.5) * GRID_DEGREES


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius = 6371.0088
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = phi2 - phi1
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(a))


def _blocked(db, first: str, second: str) -> bool:
    return db.scalar(select(UserBlock).where(
        ((UserBlock.blocker_id == first) & (UserBlock.blocked_id == second)) |
        ((UserBlock.blocker_id == second) & (UserBlock.blocked_id == first))
    )) is not None


def _accepted_contact(db, first: str, second: str) -> bool:
    a, b = sorted((first, second))
    return db.scalar(select(Contact).where(Contact.user_a == a, Contact.user_b == b)) is not None


def _view_access(db, viewer_id: str, target_id: str) -> str | None:
    """Return self/contact/discovery/blocked/None under the same social visibility rules.

    Accepted contacts always qualify. Otherwise both discovery profiles must be enabled and
    unexpired, and the coarse-grid distance must fit inside *both* users' radius. Blocking in
    either direction denies (the resolver maps this to 403; DTO enrichment omits fields).
    """
    if viewer_id == target_id:
        return "self"
    if _blocked(db, viewer_id, target_id):
        return "blocked"
    if _accepted_contact(db, viewer_id, target_id):
        return "contact"
    now = time.time()
    mine = db.get(DiscoveryProfile, viewer_id)
    target = db.get(DiscoveryProfile, target_id)
    if not mine or not target:
        return None
    if not mine.enabled or not target.enabled or mine.expires_at <= now or target.expires_at <= now:
        return None
    my_lat, my_lon = _grid_center(mine.grid_x, mine.grid_y)
    target_lat, target_lon = _grid_center(target.grid_x, target.grid_y)
    distance = _haversine_km(my_lat, my_lon, target_lat, target_lon)
    my_radius = int(mine.radius_km or 5)
    target_radius = int(target.radius_km or 5)
    if distance <= my_radius and distance <= target_radius:
        return "discovery"
    return None


def _public_avatar_descriptor(settings, row: SocialProfile | None, public_ref: str) -> dict:
    if row is None or row.avatar_kind == "none":
        return {"kind": "none", "default_key": None, "authenticated_path": None, "available": False}
    if row.avatar_kind == "default":
        key = row.default_avatar_key if row.default_avatar_key in DEFAULT_AVATAR_KEYS else None
        return {"kind": "default", "default_key": key, "authenticated_path": None,
                "available": key is not None}
    available = bool(row.avatar_storage_key)
    if available and settings is not None:
        try:
            available = _avatar_path(settings, row.avatar_storage_key).is_file()
        except HTTPException:
            available = False
    return {"kind": "upload", "default_key": None,
            "authenticated_path": f"/mobile/v1/users/{public_ref}/avatar" if available else None,
            "available": available}


def social_fields_for_viewer(db, viewer_id: str, target_id: str, public_ref: str,
                             settings=None) -> dict:
    """Additive social DTO fields for nearby/contact/request responses.

    Unauthorized viewers get no fields (not a null display name), so a blocked or unrelated
    user cannot probe social profile existence through these lists.
    """
    try:
        if _view_access(db, viewer_id, target_id) not in ("self", "contact", "discovery"):
            return {}
        row = db.get(SocialProfile, target_id)
        return {"social_display_name": row.display_name if row else None,
                "social_avatar": _public_avatar_descriptor(settings, row, public_ref)}
    except SQLAlchemyError:
        # Before the canonical social_profiles migration runs, old deployments/tests must keep
        # serving nearby/contact responses without social fields (backward-compatible rollout).
        return {}



@router.get("/social-profile")
def get_social_profile(request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    _verified_user(request, actor)
    return _serialize(_settings(request), _profile(request, actor.user_id), actor.user_id)


@router.patch("/social-profile")
def patch_social_profile(body: SocialProfilePatch, request: Request,
                         actor: identity.MobileActor = Depends(identity.mobile_actor)):
    settings = _settings(request)
    _verified_user(request, actor)
    if body.display_name is None and body.default_avatar_key is None:
        raise HTTPException(422, "no_profile_changes")
    normalized_name = _normalize_display_name(body.display_name) if body.display_name is not None else None
    if body.default_avatar_key is not None and body.default_avatar_key not in DEFAULT_AVATAR_KEYS:
        raise HTTPException(422, "invalid_default_avatar_key")
    now = time.time()
    with _sessions(request)() as db:
        row = _get_or_create(db, actor.user_id)
        old_key = row.avatar_storage_key
        if body.display_name is not None:
            row.display_name = normalized_name
        if body.default_avatar_key is not None:
            row.avatar_kind = "default"
            row.default_avatar_key = body.default_avatar_key
            row.avatar_storage_key = None
            row.avatar_sha256 = None
            row.avatar_bytes = None
            row.avatar_mime = None
        _mark_completion(row, now)
        db.commit()
        payload = _serialize(settings, row, actor.user_id)
    if old_key and old_key != row.avatar_storage_key:
        try:
            _avatar_path(settings, old_key).unlink(missing_ok=True)
        except HTTPException:
            pass
    return payload


@router.post("/social-profile/avatar", status_code=201)
async def upload_social_avatar(request: Request, file: UploadFile = File(...),
                               actor: identity.MobileActor = Depends(identity.mobile_actor)):
    settings = _settings(request)
    _verified_user(request, actor)
    content_type = (file.content_type or "").lower().split(";", 1)[0]
    if content_type not in AVATAR_MIME_TYPES:
        raise HTTPException(415, "unsupported_avatar_type")
    data = await file.read(AVATAR_MAX_BYTES + 1)
    if len(data) > AVATAR_MAX_BYTES:
        raise HTTPException(413, "avatar_too_large")
    try:
        with Image.open(io.BytesIO(data)) as image:
            expected = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}
            if expected.get(image.format) != content_type:
                raise HTTPException(415, "avatar_type_mismatch")
            if image.width * image.height > AVATAR_MAX_PIXELS:
                raise HTTPException(413, "avatar_dimensions_too_large")
            image.load()
            clean = ImageOps.exif_transpose(image).convert("RGB")
            clean.thumbnail((AVATAR_EDGE, AVATAR_EDGE))
            output = io.BytesIO()
            clean.save(output, "JPEG", quality=88)
            clean_bytes = output.getvalue()
    except HTTPException:
        raise
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as error:
        raise HTTPException(415, "invalid_avatar") from error

    digest = hashlib.sha256(clean_bytes).hexdigest()
    # The storage key must be unique per upload, not the content digest: two users uploading
    # the same bytes must not share a file, otherwise replacing one avatar deletes the other's.
    # The digest remains the content-integrity/public-key component.
    key = secrets.token_hex(32)
    path = _avatar_path(settings, key)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(clean_bytes)
    now = time.time()
    try:
        with _sessions(request)() as db:
            row = _get_or_create(db, actor.user_id)
            old_key = row.avatar_storage_key
            row.avatar_kind = "upload"
            row.default_avatar_key = None
            row.avatar_storage_key = key
            row.avatar_sha256 = digest
            row.avatar_bytes = len(clean_bytes)
            row.avatar_mime = "image/jpeg"
            _mark_completion(row, now)
            db.commit()
            payload = _serialize(settings, row, actor.user_id)
    except Exception:
        path.unlink(missing_ok=True)
        raise
    if old_key and old_key != key:
        try:
            _avatar_path(settings, old_key).unlink(missing_ok=True)
        except HTTPException:
            pass
    return payload


@router.get("/users/{public_ref}/avatar")
def get_user_avatar(public_ref: str, request: Request,
                    actor: identity.MobileActor = Depends(identity.mobile_actor)):
    """Controlled authenticated avatar resolver: public_ref only, never user_id/public_key.

    Allowed for self, accepted contacts, or mutually-visible active discovery profiles.
    Default avatars are represented by their explicit key in nearby/contact DTOs; this
    image endpoint returns 404 + X-Default-Avatar-Key for default/none.
    """
    settings = _settings(request)
    _verified_user(request, actor)
    ref = (public_ref or "")[:32]
    with _sessions(request)() as db:
        target = db.scalar(select(User).where(User.public_ref == ref))
        if target is None or target.email_verified_at is None:
            raise HTTPException(404, "user_not_found")
        access = _view_access(db, actor.user_id, target.id)
        if access == "blocked":
            raise HTTPException(403, "blocked")
        if access is None:
            raise HTTPException(404, "social_profile_not_found")
        row = db.get(SocialProfile, target.id)
    if row is None or row.avatar_kind in (None, "none"):
        raise HTTPException(404, "avatar_not_set")
    if row.avatar_kind == "default":
        return JSONResponse({"detail": "avatar_default_selected"}, status_code=404,
                            headers={"X-Default-Avatar-Key": row.default_avatar_key or ""})
    try:
        data = _avatar_path(settings, row.avatar_storage_key or "").read_bytes()
    except (HTTPException, OSError):
        raise HTTPException(404, "avatar_not_found")
    return Response(data, media_type="image/jpeg",
                    headers={"Cache-Control": "private, no-store",
                             "X-Avatar-Public-Key": f"social:{row.avatar_sha256}"})


@router.get("/social-profile/avatar")
def get_social_avatar(request: Request, actor: identity.MobileActor = Depends(identity.mobile_actor)):
    settings = _settings(request)
    _verified_user(request, actor)
    row = _profile(request, actor.user_id)
    if row is None or row.avatar_kind == "none":
        raise HTTPException(404, "avatar_not_set")
    if row.avatar_kind == "default":
        return JSONResponse({"detail": "avatar_default_selected"}, status_code=404,
                            headers={"X-Default-Avatar-Key": row.default_avatar_key or ""})
    try:
        data = _avatar_path(settings, row.avatar_storage_key or "").read_bytes()
    except (HTTPException, OSError):
        raise HTTPException(404, "avatar_not_found")
    return Response(data, media_type="image/jpeg",
                    headers={"Cache-Control": "private, no-store",
                             "X-Avatar-Public-Key": f"social:{row.avatar_sha256}"})
