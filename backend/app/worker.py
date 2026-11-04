import argparse
import asyncio
import contextlib
import logging
import time
import uuid

from sqlalchemy import delete, select, update

from .config import get_settings
from .assets import archive_job_result, archive_pending_jobs
from .db import bind_installation, check_schema, make_engine, session_factory
from .jobs import checkpoint, claim_job, finish_job, heartbeat, mark_dispatched
from .main import catalog_rows
from .models import CatalogProduct, GuestSession, Job, PetProfile, RateWindow, WebhookEvent
from .storage import PrivateStorage, cleanup_expired

logger = logging.getLogger("wagelpaw.worker")


async def run_job(settings, sessions, worker_id, executor=None):
    from .domain.service import execute_job

    row = claim_job(sessions, settings, worker_id)
    if row is None:
        return False

    async def keep_lease():
        while True:
            await asyncio.sleep(settings.heartbeat_seconds)
            if not heartbeat(sessions, settings, row.id, worker_id):
                return

    pulse = asyncio.create_task(keep_lease())
    try:
        with sessions() as db:
            owner = db.get(GuestSession, row.owner_id)
            if not owner or owner.expires_at <= time.time():
                finish_job(sessions, row.id, worker_id, "failed", error_code="session_expired")
                return True
            source_job = None
            if row.kind == "avatar":
                source = db.get(Job, row.input.get("source_job_id", ""))
                if not source or source.owner_id != row.owner_id or source.shop != row.shop or source.status != "succeeded":
                    finish_job(sessions, row.id, worker_id, "failed", error_code="source_job_unavailable")
                    return True
                source_job = {"id": source.id, "kind": source.kind, "status": source.status, "result": source.result}
        context = {"settings": settings, "catalog": catalog_rows(sessions, row.shop),
                   "storage": PrivateStorage(settings, sessions, row.owner_id, row.shop, row.id),
                   "source_job": source_job,
                   "checkpoint": lambda stage, partial: checkpoint(sessions, row.id, worker_id, stage, partial)}
        if not mark_dispatched(sessions, row.id, worker_id):
            return True
        timeout = settings.provider_timeout_seconds + (960 if row.kind == "avatar" else 120)
        result = await asyncio.wait_for((executor or execute_job)(row.kind, row.input, context), timeout=timeout)
        if not isinstance(result, dict) or result.get("status") != "succeeded":
            raise ValueError("invalid_job_result")
        finish_job(sessions, row.id, worker_id, "succeeded", result=result)
        try:
            archive_job_result(sessions, settings, row.id)
        except Exception as archive_error:  # archive must never turn a paid success into a retry
            logger.warning("archive_failed job_id=%s error_type=%s", row.id, type(archive_error).__name__)
    except BaseException as error:
        name = type(error).__name__
        known_failure = name in {"ProviderNotConfigured", "DomainValidationError", "ProviderFailure", "HTTPException"}
        uncertain = name in {"GenerationUncertain", "TimeoutError", "CancelledError", "KeyboardInterrupt", "SystemExit"} or (row.kind in {"tryon", "avatar"} and not known_failure)
        codes = {"ProviderNotConfigured": "provider_not_configured", "DomainValidationError": "invalid_job_input",
                 "ProviderFailure": "provider_failed", "HTTPException": "source_asset_unavailable"}
        finish_job(sessions, row.id, worker_id, "needs_review" if uncertain else "failed",
                   error_code="provider_completion_unknown" if uncertain else codes.get(name, "job_failed"))
        # A real checkpoint (e.g. cartoon_ready) may already exist on disk even though the
        # later step failed; archive those verified files as partial, never as success.
        try:
            archive_job_result(sessions, settings, row.id, allow_partial=True)
        except Exception as archive_error:
            logger.warning("partial_archive_failed job_id=%s error_type=%s", row.id, type(archive_error).__name__)
        if isinstance(error, (KeyboardInterrupt, SystemExit, asyncio.CancelledError)):
            raise
        logger.warning("job_failed job_id=%s error_type=%s", row.id, name)
    finally:
        pulse.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await pulse
    return True


def save_catalog(sessions, shop, products, full=False):
    with sessions() as db:
        if full:
            ids = [product["id"] for product in products]
            statement = delete(CatalogProduct).where(CatalogProduct.shop == shop)
            if ids:
                statement = statement.where(CatalogProduct.product_id.not_in(ids))
            db.execute(statement)
        for product in products:
            row = db.get(CatalogProduct, (shop, product["id"]))
            if row:
                row.data = product
                row.updated_at = time.time()
            else:
                db.add(CatalogProduct(shop=shop, product_id=product["id"], data=product))
        db.commit()


async def sync_catalog(settings, sessions):
    from .providers.shopify import ShopifyAdminClient

    products = await ShopifyAdminClient(settings).fetch_catalog()
    save_catalog(sessions, settings.shopify_store_domain, products, full=True)
    return len(products)


async def run_webhook(settings, sessions, worker_id):
    from .providers.shopify import ShopifyAdminClient

    now = time.time()
    with sessions() as db:
        db.execute(update(WebhookEvent).where(WebhookEvent.status == "processing", WebhookEvent.lease_until < now).values(status="queued", lease_owner=None))
        event = db.scalar(select(WebhookEvent).where(WebhookEvent.status == "queued", WebhookEvent.available_at <= now).order_by(WebhookEvent.created_at).with_for_update(skip_locked=True).limit(1))
        if not event:
            db.commit()
            return False
        claimed = db.execute(update(WebhookEvent).where(WebhookEvent.id == event.id, WebhookEvent.status == "queued").values(
            status="processing", lease_owner=worker_id, lease_until=now + settings.lease_seconds, attempts=WebhookEvent.attempts + 1))
        db.commit()
        if claimed.rowcount != 1:
            return False
        event = db.get(WebhookEvent, event.id)
    try:
        if event.shop != settings.shopify_store_domain:
            raise ValueError("single_shop_configuration_mismatch")
        if event.topic.startswith("inventory_"):
            await sync_catalog(settings, sessions)
        else:
            raw_id = event.payload.get("admin_graphql_api_id") or f"gid://shopify/Product/{event.payload.get('id', '')}"
            # Always read current Shopify state: webhook deliveries can arrive out of order.
            product = await ShopifyAdminClient(settings).fetch_product(raw_id)
            if product:
                save_catalog(sessions, event.shop, [product])
            else:
                with sessions() as db:
                    db.execute(delete(CatalogProduct).where(CatalogProduct.shop == event.shop, CatalogProduct.product_id == raw_id))
                    db.commit()
        state, code = "processed", None
    except Exception as error:
        state = "failed" if event.attempts >= 5 else "queued"
        code = "catalog_sync_failed"
        logger.warning("webhook_sync_failed event_id=%s error_type=%s", event.id, type(error).__name__)
    with sessions() as db:
        db.execute(update(WebhookEvent).where(WebhookEvent.id == event.id, WebhookEvent.status == "processing", WebhookEvent.lease_owner == worker_id).values(
            status=state, error_code=code, lease_owner=None, lease_until=None, available_at=time.time() + min(300, 2 ** event.attempts)))
        db.commit()
    return True


def cleanup(settings, sessions):
    cleanup_expired(settings, sessions)
    now = time.time()
    with sessions() as db:
        db.execute(delete(RateWindow).where(RateWindow.expires_at < now))
        expired_ids = select(GuestSession.id).where(GuestSession.expires_at < now - settings.media_retention_seconds)
        db.execute(delete(PetProfile).where(PetProfile.owner_id.in_(expired_ids)))
        db.execute(delete(Job).where(Job.owner_id.in_(expired_ids), Job.status.not_in(["queued", "running"])))
        db.execute(delete(GuestSession).where(GuestSession.expires_at < now - settings.media_retention_seconds))
        db.commit()


async def serve(settings, sessions, once=False):
    worker_id = uuid.uuid4().hex
    last_cleanup = 0.0
    last_reconcile = 0.0
    while True:
        worked = await run_job(settings, sessions, worker_id)
        worked = await run_webhook(settings, sessions, worker_id) or worked
        # Persistent terminal-job archive compensation: repairs a crash between
        # finish_job(succeeded) and archive, and retries a first transient archive failure.
        try:
            repaired = archive_pending_jobs(sessions, settings)
        except Exception as error:  # noqa: BLE001 - keep the worker alive; next loop retries
            logger.warning("archive_compensation_scan_failed error_type=%s", type(error).__name__)
        else:
            worked = repaired > 0 or worked
        if time.time() - last_cleanup > 60:
            cleanup(settings, sessions)
            last_cleanup = time.time()
        if settings.catalog_reconcile_seconds > 0 and settings.shopify_store_domain and settings.shopify_access_token.get_secret_value() and time.time() - last_reconcile >= settings.catalog_reconcile_seconds:
            try:
                await sync_catalog(settings, sessions)
            except Exception as error:
                logger.warning("catalog_reconcile_failed error_type=%s", type(error).__name__)
                last_reconcile = time.time() - settings.catalog_reconcile_seconds + min(300, settings.catalog_reconcile_seconds)
            else:
                last_reconcile = time.time()
        if once:
            return
        if not worked:
            await asyncio.sleep(settings.worker_poll_seconds)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--sync-catalog", action="store_true", help="Read-only Shopify catalog import; requires configured server credentials")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    settings = get_settings()
    engine = make_engine(settings.database_url)
    check_schema(engine)
    bind_installation(engine, settings.local_shop)
    sessions = session_factory(engine)
    try:
        if args.sync_catalog:
            count = asyncio.run(sync_catalog(settings, sessions))
            print(f"Synchronized {count} products")
        else:
            asyncio.run(serve(settings, sessions, once=args.once))
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
