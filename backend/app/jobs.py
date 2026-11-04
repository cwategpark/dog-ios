import hashlib
import json
import logging
import time

from fastapi import HTTPException
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError

from .models import GuestSession, Job, RateWindow


def payload_hash(kind: str, payload: dict):
    encoded = json.dumps({"kind": kind, "input": payload}, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(encoded.encode()).hexdigest()


def serialize_job(row: Job):
    return {"id": row.id, "kind": row.kind, "status": row.status, "result": row.result,
            "error_code": row.error_code, "created_at": row.created_at, "updated_at": row.updated_at}


def create_job(sessions, settings, actor, kind: str, payload: dict, key: str):
    if not 8 <= len(key) <= 120 or any(ord(char) < 33 or ord(char) > 126 for char in key):
        raise HTTPException(400, "invalid_idempotency_key")
    fingerprint = payload_hash(kind, payload)
    with sessions() as db:
        existing = db.scalar(select(Job).where(Job.shop == actor.shop, Job.owner_id == actor.owner_id, Job.idempotency_key == key))
        if existing:
            if existing.input_hash != fingerprint:
                raise HTTPException(409, "idempotency_payload_conflict")
            return serialize_job(existing), False
        pending = db.scalar(select(func.count()).select_from(Job).where(Job.status.in_(["queued", "running"])))
        if pending >= settings.max_pending_jobs:
            raise HTTPException(429, "generation_queue_full")
        quota = db.execute(update(GuestSession).where(
            GuestSession.id == actor.owner_id, GuestSession.shop == actor.shop,
            GuestSession.expires_at > time.time(), GuestSession.jobs_submitted < settings.session_job_limit
        ).values(jobs_submitted=GuestSession.jobs_submitted + 1))
        if quota.rowcount != 1:
            raise HTTPException(429, "session_generation_limit")
        owner = db.get(GuestSession, actor.owner_id)
        hour = int(time.time() // 3600)
        for scope, value, limit in (("owner", actor.owner_id, settings.jobs_per_session_hour), ("ip", owner.ip_hash, settings.jobs_per_ip_hour)):
            rate_key = f"jobs:{hour}:{scope}:{value}"
            try:
                with db.begin_nested():
                    db.add(RateWindow(key=rate_key, count=0, expires_at=(hour + 1) * 3600))
                    db.flush()
            except IntegrityError:
                pass
            limited = db.execute(update(RateWindow).where(RateWindow.key == rate_key, RateWindow.count < limit).values(count=RateWindow.count + 1))
            if limited.rowcount != 1:
                raise HTTPException(429, "hourly_generation_limit")
        row = Job(shop=actor.shop, owner_id=actor.owner_id, kind=kind, input=payload,
                  input_hash=fingerprint, idempotency_key=key)
        db.add(row)
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            existing = db.scalar(select(Job).where(Job.shop == actor.shop, Job.owner_id == actor.owner_id, Job.idempotency_key == key))
            if not existing or existing.input_hash != fingerprint:
                raise HTTPException(409, "idempotency_payload_conflict")
            return serialize_job(existing), False
        return serialize_job(row), True


def recover_expired(sessions, settings=None):
    """Requeue or mark expired leases, then archive trusted partial checkpoints.

    A worker can die (OOM/SIGKILL) after a provider checkpoint such as ``cartoon_ready`` but
    before the in-process except handler runs. Recovery is the only other place that observes
    such a job, so it must also run the partial-archive pass; otherwise the real cartoon file
    stays unowned and is deleted with the 24h guest TTL.
    """
    now = time.time()
    recovered: list[str] = []
    with sessions() as db:
        for job in db.scalars(select(Job).where(Job.status == "running", Job.lease_until < now).with_for_update(skip_locked=True)):
            uncertain = job.dispatched_at is not None and job.kind in {"tryon", "avatar"}
            job.status = "needs_review" if uncertain else "queued"
            job.error_code = "provider_completion_unknown" if uncertain else None
            job.lease_owner = None
            job.lease_until = None
            job.updated_at = now
            if uncertain:
                recovered.append(job.id)
        db.commit()
    if settings is not None:
        from .assets import archive_job_result

        for job_id in recovered:
            try:
                archive_job_result(sessions, settings, job_id, allow_partial=True)
            except Exception:  # noqa: BLE001 - recovery must not kill the worker loop
                logging.getLogger("wagelpaw.jobs").warning(
                    "recovered_partial_archive_failed job_id=%s", job_id, exc_info=False)
    return recovered


def claim_job(sessions, settings, worker_id: str):
    recover_expired(sessions, settings)
    with sessions() as db:
        candidate = db.scalar(select(Job.id).where(Job.status == "queued").order_by(Job.created_at).with_for_update(skip_locked=True).limit(1))
        if not candidate:
            return None
        claimed = db.execute(update(Job).where(Job.id == candidate, Job.status == "queued").values(
            status="running", lease_owner=worker_id, lease_until=time.time() + settings.lease_seconds,
            updated_at=time.time(), attempts=Job.attempts + 1))
        db.commit()
        if claimed.rowcount != 1:
            return None
        return db.get(Job, candidate)


def heartbeat(sessions, settings, job_id: str, worker_id: str):
    with sessions() as db:
        updated = db.execute(update(Job).where(Job.id == job_id, Job.status == "running", Job.lease_owner == worker_id).values(
            lease_until=time.time() + settings.lease_seconds, updated_at=time.time()))
        db.commit()
        return updated.rowcount == 1


def mark_dispatched(sessions, job_id: str, worker_id: str):
    with sessions() as db:
        updated = db.execute(update(Job).where(Job.id == job_id, Job.status == "running", Job.lease_owner == worker_id).values(dispatched_at=time.time()))
        db.commit()
        return updated.rowcount == 1


def finish_job(sessions, job_id: str, worker_id: str, status: str, result=None, error_code=None):
    with sessions() as db:
        values = dict(status=status, error_code=error_code, lease_owner=None, lease_until=None, updated_at=time.time())
        if result is not None:
            values["result"] = result
        updated = db.execute(update(Job).where(Job.id == job_id, Job.status == "running", Job.lease_owner == worker_id).values(**values))
        db.commit()
        return updated.rowcount == 1


def checkpoint(sessions, job_id: str, worker_id: str, stage: str, result: dict):
    with sessions() as db:
        updated = db.execute(update(Job).where(Job.id == job_id, Job.status == "running", Job.lease_owner == worker_id).values(
            result={**result, "stage": stage}, updated_at=time.time()))
        db.commit()
        return updated.rowcount == 1
