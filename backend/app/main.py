import hashlib
import json
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, Literal

from fastapi import Depends, FastAPI, File, Header, HTTPException, Request, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from . import assets as asset_service
from .config import Settings, get_settings
from .db import bind_installation, check_schema, init_database, make_engine, session_factory
from .identity import get_or_create_user
from .jobs import create_job, payload_hash, serialize_job
from .mailer import delivery_mode, display_email, normalize_email
from .mobile_api import router as mobile_router
from .models import CatalogProduct, GuestSession, Job, PetProfile, WebhookEvent
from .middleware import RequestGuardMiddleware
from .security import Actor, anonymous_ip_hash, authenticated_actor, create_guest_token, limit_session_creation, source_shop, verify_webhook
from .storage import PrivateStorage, normalize_upload
from .website_claims import router as website_claims_router


class SessionInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    profile: dict
    consent: Literal[True]
    email: str | None = None
    full_name: str | None = None


class RecommendationInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    profile: dict | None = None


class JobInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["tryon", "avatar", "cat-fitting"]
    input: dict = Field(default_factory=dict)


def normalized_profile(profile):
    from .domain.recommendations import normalize_pet

    try:
        normalized = {"pet_information": normalize_pet(profile)}
    except ValueError as error:
        raise HTTPException(422, "invalid_pet_profile") from error
    raw = profile.get("pet_information", profile) if isinstance(profile, dict) else {}
    if isinstance(raw, dict):
        display = {key: str(raw[key])[:80] for key in ("name", "breed") if raw.get(key)}
        if display:
            normalized["display"] = display
    return normalized


def catalog_rows(sessions, shop):
    with sessions() as db:
        return [row.data for row in db.scalars(select(CatalogProduct).where(CatalogProduct.shop == shop))]


def create_app(settings: Settings | None = None):
    settings = settings or get_settings()
    engine = make_engine(settings.database_url)
    sessions = session_factory(engine)

    @asynccontextmanager
    async def lifespan(_app):
        if settings.environment in ("development", "test"):
            init_database(engine)
        check_schema(engine)
        bind_installation(engine, settings.local_shop)
        settings.storage_path.mkdir(parents=True, exist_ok=True)
        yield
        engine.dispose()

    app = FastAPI(title="Wagelpaw service", version="0.1.0", lifespan=lifespan,
                  docs_url="/docs" if settings.environment != "production" else None,
                  redoc_url=None, openapi_url="/openapi.json" if settings.environment != "production" else None)
    app.state.settings = settings
    app.state.engine = engine
    app.state.sessions = sessions
    if settings.allowed_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.allowed_origins, allow_credentials=False,
                           allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"], allow_headers=["Content-Type", "Idempotency-Key", "X-Wagelpaw-Session", "Authorization"])
    app.add_middleware(RequestGuardMiddleware, settings=settings)
    app.include_router(mobile_router)
    app.include_router(website_claims_router)

    @app.get("/healthz")
    def healthz():
        return {"status": "ok", "service": "wagelpaw", "environment": settings.environment}

    @app.get("/readyz")
    def readyz():
        try:
            with sessions() as db:
                db.execute(text("SELECT 1"))
                db.execute(select(GuestSession.id).limit(1))
        except SQLAlchemyError as error:
            raise HTTPException(503, "database_not_ready") from error
        return {"status": "ready",
                "generation_configured": bool(settings.ark_api_key.get_secret_value() if settings.image_provider == "ark" else settings.gemini_api_key.get_secret_value()),
                "shopify_configured": bool(settings.shopify_store_domain and settings.shopify_access_token.get_secret_value()),
                "storage": "private_filesystem", "authentication": "guest_session_after_questionnaire",
                "email_delivery": delivery_mode(settings),
                "default_model": "website-golden-master" if asset_service.default_model_metadata(settings) else "missing",
                "mobile_api": "enabled"}

    @app.get("/public-assets/website-golden-master.glb")
    def public_default_model():
        metadata = asset_service.default_model_metadata(settings)
        path = Path(settings.public_assets_dir) / asset_service.DEFAULT_MODEL_FILENAME
        if not metadata or not path.is_file():
            raise HTTPException(404, "default_model_unavailable")
        return FileResponse(path, media_type=metadata["mime"],
                            headers={"ETag": metadata["sha256"], "Cache-Control": "public, max-age=3600",
                                     "X-Content-SHA256": metadata["sha256"]})

    @app.post("/v1/sessions", status_code=201)
    def issue_session(body: SessionInput, request: Request):
        shop = source_shop(request)
        profile = normalized_profile(body.profile)
        email_normalized = None
        if body.email:
            try:
                email_normalized = normalize_email(body.email)
            except ValueError as error:
                raise HTTPException(422, "invalid_email") from error
            get_or_create_user(sessions, email_normalized, display_email(body.email))
        limit_session_creation(request, shop)
        token, fingerprint = create_guest_token()
        expires = time.time() + settings.session_ttl_seconds
        with sessions() as db:
            session = GuestSession(shop=shop, token_hash=fingerprint, expires_at=expires, ip_hash=anonymous_ip_hash(request),
                                   email_normalized=email_normalized,
                                   full_name=(str(body.full_name)[:120] if body.full_name else None))
            db.add(session)
            db.flush()
            db.add(PetProfile(owner_id=session.id, data=profile, consent={"profile_storage": True, "version": "2026-11-04", "timestamp": time.time()}))
            db.commit()
        return {"session_token": token, "expires_at": expires, "profile": profile,
                "generation_limit": settings.session_job_limit, "generation_hourly_limit": settings.jobs_per_session_hour,
                "email_saved": bool(email_normalized), "claim_required": bool(email_normalized)}

    @app.get("/v1/pet-profile")
    def get_profile(actor: Annotated[Actor, Depends(authenticated_actor)]):
        with sessions() as db:
            row = db.get(PetProfile, actor.owner_id)
            if not row:
                raise HTTPException(404, "profile_not_found")
            return {"profile": row.data, "consent": row.consent}

    @app.put("/v1/pet-profile")
    def put_profile(body: SessionInput, actor: Annotated[Actor, Depends(authenticated_actor)]):
        profile = normalized_profile(body.profile)
        with sessions() as db:
            row = db.get(PetProfile, actor.owner_id)
            row.data = profile
            row.updated_at = time.time()
            db.commit()
        return {"profile": profile}

    @app.get("/v1/catalog")
    def get_catalog(actor: Annotated[Actor, Depends(authenticated_actor)], q: str = "", pet: str = "", scene: str = "", kind: str = ""):
        rows = catalog_rows(sessions, actor.shop)
        rows = [row for row in rows if row.get("status") == "ACTIVE" and row.get("published") is True]
        for field, value in (("pet_types", pet), ("tags", scene), ("categories", kind)):
            if value:
                rows = [row for row in rows if value.lower() in row.get(field, []) or f"scene:{value.lower()}" in row.get(field, [])]
        if q:
            rows = [row for row in rows if q.casefold() in str(row.get("title", row.get("name", ""))).casefold()]
        return {"products": rows, "total": len(rows)}

    @app.post("/v1/recommendations")
    async def recommendations(body: RecommendationInput, actor: Annotated[Actor, Depends(authenticated_actor)]):
        from .domain.recommendations import recommend
        from .providers.shopify import ShopifyAdminClient

        profile = body.profile
        if profile is None:
            with sessions() as db:
                record = db.get(PetProfile, actor.owner_id)
                profile = record.data if record else {}
        try:
            candidate = recommend(profile, catalog_rows(sessions, actor.shop))
            if not candidate["product_ids"]:
                return candidate
            fresh = []
            client = ShopifyAdminClient(settings)
            for product_id in candidate["product_ids"]:
                product = await client.fetch_product(product_id)
                if product:
                    fresh.append(product)
            return recommend(profile, fresh)
        except ValueError as error:
            raise HTTPException(422, "invalid_pet_profile") from error
        except Exception as error:
            if type(error).__name__ in {"ProviderNotConfigured", "ProviderFailure"}:
                raise HTTPException(503, "shopify_catalog_temporarily_unavailable") from error
            raise

    @app.post("/v1/uploads", status_code=201)
    async def upload(actor: Annotated[Actor, Depends(authenticated_actor)], file: UploadFile = File(...)):
        data = await file.read(settings.max_upload_bytes + 1)
        clean = normalize_upload(data, file.content_type or "", settings)
        storage = PrivateStorage(settings, sessions, actor.owner_id, actor.shop)
        stored = storage.save_output(clean, "image/jpeg", "pet-photo.jpg")
        asset_service.archive_guest_upload(sessions, settings, stored["id"], actor.owner_id)
        return stored

    @app.get("/v1/uploads/{upload_id}")
    def get_upload(upload_id: str, actor: Annotated[Actor, Depends(authenticated_actor)]):
        artifact = PrivateStorage(settings, sessions, actor.owner_id, actor.shop).get_owned(upload_id)
        return Response(artifact.data, media_type=artifact.mime_type,
                        headers={"Content-Disposition": f'attachment; filename="{artifact.id}"'})

    @app.post("/v1/jobs")
    def post_job(body: JobInput, actor: Annotated[Actor, Depends(authenticated_actor)], idempotency_key: Annotated[str, Header()]):
        from .domain.service import ensure_configured

        if body.input.get("consent") is not True:
            raise HTTPException(422, "generation_consent_required")
        with sessions() as db:
            existing = db.scalar(select(Job).where(Job.shop == actor.shop, Job.owner_id == actor.owner_id, Job.idempotency_key == idempotency_key))
            if existing:
                if existing.input_hash != payload_hash(body.kind, body.input):
                    raise HTTPException(409, "idempotency_payload_conflict")
                return serialize_job(existing)
        try:
            ensure_configured(body.kind, settings)
        except Exception as error:
            if type(error).__name__ == "ProviderNotConfigured":
                raise HTTPException(503, "generation_provider_not_configured") from error
            raise
        if body.kind == "tryon":
            PrivateStorage(settings, sessions, actor.owner_id, actor.shop).get_owned(str(body.input.get("pet_upload_id", "")))
        if body.kind == "avatar":
            with sessions() as db:
                source = db.get(Job, str(body.input.get("source_job_id", "")))
                if not source or source.owner_id != actor.owner_id or source.shop != actor.shop:
                    raise HTTPException(404, "source_job_not_found")
                if source.kind != "tryon" or source.status != "succeeded":
                    raise HTTPException(409, "successful_tryon_required")
        value, created = create_job(sessions, settings, actor, body.kind, body.input, idempotency_key)
        return Response(json.dumps(value), status_code=202 if created else 200, media_type="application/json")

    @app.get("/v1/jobs/{job_id}")
    def get_job(job_id: str, actor: Annotated[Actor, Depends(authenticated_actor)]):
        with sessions() as db:
            job = db.get(Job, job_id)
            if not job or job.owner_id != actor.owner_id or job.shop != actor.shop:
                raise HTTPException(404, "job_not_found")
            return serialize_job(job)

    @app.post("/webhooks/shopify", status_code=202)
    async def shopify_webhook(request: Request):
        chunks = bytearray()
        async for chunk in request.stream():
            chunks.extend(chunk)
            if len(chunks) > 2 * 1024 * 1024:
                raise HTTPException(413, "webhook_too_large")
        raw = bytes(chunks)
        shop = request.headers.get("x-shopify-shop-domain", "").lower()
        verify_webhook(raw, request.headers.get("x-shopify-hmac-sha256", ""), shop, settings)
        event_id = request.headers.get("x-shopify-event-id") or request.headers.get("x-shopify-webhook-id", "")
        topic = request.headers.get("x-shopify-topic", "")
        if not event_id or len(event_id) > 100:
            raise HTTPException(400, "webhook_event_id_required")
        if topic not in {"products/create", "products/update", "products/delete", "inventory_levels/update", "inventory_items/update"}:
            raise HTTPException(400, "unsupported_webhook_topic")
        try:
            payload = json.loads(raw)
        except (ValueError, UnicodeDecodeError) as error:
            raise HTTPException(400, "invalid_webhook_json") from error
        if not isinstance(payload, dict):
            raise HTTPException(400, "invalid_webhook_json")
        fingerprint = hashlib.sha256(raw).hexdigest()
        with sessions() as db:
            event = WebhookEvent(shop=shop, event_id=event_id, topic=topic, payload=payload, payload_hash=fingerprint)
            db.add(event)
            try:
                db.commit()
            except IntegrityError:
                db.rollback()
                old = db.scalar(select(WebhookEvent).where(WebhookEvent.shop == shop, WebhookEvent.event_id == event_id))
                if not old or old.payload_hash != fingerprint or old.topic != topic:
                    raise HTTPException(409, "webhook_event_conflict")
                return {"accepted": True, "duplicate": True}
        return {"accepted": True, "duplicate": False}

    return app


app = create_app()
