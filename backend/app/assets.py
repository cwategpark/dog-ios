"""Asset archive, pet home manifest and the public golden-master model metadata.

Generated media is archived only after a real successful job/upload. The archive row is
idempotent per upload, survives the 24h guest TTL once claimed, and never invents outputs
for failed jobs.
"""
import base64
import hashlib
import json
import logging
import time
from pathlib import Path

from fastapi import HTTPException
from sqlalchemy import or_, select, update
from sqlalchemy.exc import IntegrityError

from .models import AssetArchive, GuestSession, GuestSessionPet, Job, Pet, PetProfile, Upload
from .storage import PrivateStorage

DEFAULT_MODEL_FILENAME = "website-golden-master.glb"
DEFAULT_MODEL_MIME = "model/gltf-binary"
logger = logging.getLogger("wagelpaw.assets")

MIME_TO_FORMAT = {
    "image/jpeg": "jpeg",
    "image/png": "png",
    "image/webp": "webp",
    "model/gltf-binary": "glb",
    "application/json": "json",
}
ROLE_TO_KIND = {
    "tryon": "tryon",
    "cartoon": "cartoon",
    "model": "model",
    "outfit": "outfit",
    "photo": "photo",
}
SUPPORTED_PERSONAL_FORMATS = {"glb"}
_DEFAULT_MODEL_CACHE: dict[tuple, dict] = {}


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def default_model_metadata(settings) -> dict | None:
    path = Path(settings.public_assets_dir) / DEFAULT_MODEL_FILENAME
    try:
        stat = path.stat()
    except OSError:
        return None
    key = (str(path), stat.st_mtime, stat.st_size)
    cached = _DEFAULT_MODEL_CACHE.get(key)
    if cached is None:
        cached = {
            "role": "default",
            "static": True,
            "is_default": True,
            "format": "glb",
            "mime": DEFAULT_MODEL_MIME,
            "bytes": stat.st_size,
            "sha256": file_sha256(path),
            "url": f"/public-assets/{DEFAULT_MODEL_FILENAME}",
            "filename": DEFAULT_MODEL_FILENAME,
            "source": "website-golden-master",
        }
        _DEFAULT_MODEL_CACHE.clear()
        _DEFAULT_MODEL_CACHE[key] = cached
    return dict(cached)


def _storage_path(settings, storage_key: str) -> Path:
    root = Path(settings.storage_path).resolve()
    path = (root / storage_key).resolve()
    if path.parent != root:
        raise HTTPException(404, "asset_not_found")
    return path


def _archive_hook(hook, stage: str, **context) -> None:
    """Test-only observation point for the archive/claim interleavings.

    Production callers pass no hook. Concurrency tests use it to let an independent
    session/thread complete a claim at the exact step where the old code could persist a
    stale ``user_id=None`` (before the archive transaction commits) or where a claim's
    transfer scan ran before the archive row existed.
    """
    if hook is not None:
        hook(stage, context)


def _guest_user_id(db, guest_session_id: str | None) -> str | None:
    """Read the authoritative claim fact for a session.

    A column query is used on purpose: the ORM identity map (``expire_on_commit=False``)
    can still hold the pre-claim ``GuestSession.user_id`` loaded by the archive
    transaction, and reading such a cached object again would not re-validate ownership.
    """
    if not guest_session_id:
        return None
    return db.execute(
        select(GuestSession.user_id).where(GuestSession.id == guest_session_id)
    ).scalar_one_or_none()


def _pet_id_for_session(db, guest_session_id: str | None) -> str | None:
    """Resolve the pet of a questionnaire: explicit mapping first, then legacy session.

    Same-name pets entered through several questionnaires share one ``Pet`` row whose
    ``source_session_id`` is the first questionnaire only, so the mapping table is the
    authoritative answer. The legacy column stays as a fallback for rows created before
    migration 0003.
    """
    if not guest_session_id:
        return None
    mapping = db.get(GuestSessionPet, guest_session_id)
    if mapping is not None and mapping.pet_id:
        return mapping.pet_id
    pet = db.scalar(select(Pet).where(Pet.source_session_id == guest_session_id))
    return pet.id if pet else None


def _reconcile_archive_ownership(sessions, settings, *, upload_id: str,
                                 guest_session_id: str | None, pet_id: str | None = None) -> dict | None:
    """Commit-then-recheck ownership repair for one already committed archive row.

    Protocol:
    1. The archive transaction commits first (best-effort ownership snapshot).
    2. A *new* transaction re-reads the authoritative claim fact and conditionally
       updates every still-unowned row (``WHERE user_id IS NULL``) plus every missing
       pet link (``WHERE pet_id IS NULL``). This is the same conditional-UPDATE lock
       protocol the claim transfer uses, so both sides are idempotent and cannot
       overwrite a different owner.
    3. If the guest is now claimed, the physical file is also marked durable and its
       expiry is extended past the 24h guest TTL.

    Returns the freshly serialized archive row (or ``None`` when no row exists).
    """
    now = time.time()
    with sessions() as db:
        user_id = _guest_user_id(db, guest_session_id)
        # Always re-resolve the authoritative session->pet mapping in this new transaction.
        # A pre-claim caller may have cached pet_id=None (or an older pet); using it here leaves
        # a permanently unassociated archive even though the claim created GuestSessionPet.
        fresh_pet_id = _pet_id_for_session(db, guest_session_id)
        if fresh_pet_id is None and pet_id:
            # Legacy/explicit association only when no mapping exists; never override the map.
            fresh_pet_id = pet_id
        if user_id is None and fresh_pet_id is None:
            fresh = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload_id))
            return serialize_archive(fresh, settings) if fresh is not None else None
        if user_id is not None:
            db.execute(
                update(AssetArchive)
                .where(AssetArchive.upload_id == upload_id, AssetArchive.user_id.is_(None))
                .values(user_id=user_id)
            )
        if fresh_pet_id:
            db.execute(
                update(AssetArchive)
                .where(AssetArchive.upload_id == upload_id, AssetArchive.pet_id.is_(None))
                .values(pet_id=fresh_pet_id)
            )
        if user_id is not None:
            upload = db.get(Upload, upload_id)
            if upload is not None:
                upload.archived = 1
                target = now + settings.archived_upload_retention_seconds
                if upload.expires_at < target:
                    upload.expires_at = target
        db.commit()
        fresh = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload_id))
        return serialize_archive(fresh, settings) if fresh is not None else None


def _upload_is_really_stored(settings, upload: Upload | None, job: Job) -> bool:
    """True only when a checkpoint's upload row *and* its real bytes both still exist.

    Used for partial results (worker failed after a checkpoint): a result JSON entry is not
    proof that a generated file exists, so we require the upload to belong to this job's
    owner/shop, a positive recorded size, a file of exactly that size and (when known) a
    matching sha256.
    """
    if upload is None or upload.owner_id != job.owner_id or upload.shop != job.shop:
        return False
    # A checkpoint entry may only reference an upload that was really produced for this job;
    # otherwise a tampered/foreign result JSON could archive someone else's upload. Legacy
    # rows written before upload.job_id existed (NULL) remain readable.
    if upload.job_id is not None and upload.job_id != job.id:
        return False
    if not upload.size_bytes or upload.size_bytes <= 0:
        return False
    try:
        path = _storage_path(settings, upload.storage_key)
        stat = path.stat()
    except OSError:
        return False
    if stat.st_size != upload.size_bytes:
        return False
    if upload.sha256:
        try:
            return file_sha256(path) == upload.sha256
        except OSError:
            return False
    return True


def archive_upload(sessions, settings, upload_id: str, *, guest_session_id: str, kind: str,
                   source_role: str | None = None, job_id: str | None = None,
                   product_id: str | None = None, variant_id: str | None = None,
                   provenance: dict | None = None, pet_id: str | None = None,
                   hook=None) -> dict:
    """Idempotently archive one stored upload; safe to call more than once.

    Race protocol vs. a concurrent website claim (``claim_guest_session`` ->
    ``transfer_guest_assets``), using DB transactions / conditional UPDATEs as the only
    lock protocol (never a Python thread lock):

    1. Read a short ownership snapshot in its own read-only transaction and close it. A
       concurrent claim can commit between this snapshot and the archive insert - that is
       exactly where the old code persisted a stale ``user_id=None``.
    2. Insert the archive row and commit (idempotent on ``upload_id``).
    3. **After** the commit, re-read the authoritative ``guest_sessions.user_id`` in a new
       transaction and conditionally backfill every archive row still at
       ``user_id IS NULL`` - including the existing-row early-return and IntegrityError
       paths. If the claim happened before our commit, step 3 repairs the stale value; if
       it happens after, the claim's ``transfer_guest_assets`` scan/backfill repairs it.
       The two sides are idempotent and meet in the middle, so neither ordering can leave
       a permanently unowned archive.

    ``hook`` is a test-only observation point (see ``_archive_hook``); production callers
    omit it.
    """
    owner_guest_session_id = guest_session_id or None
    existing: AssetArchive | None = None
    snapshot = None
    # Phase 1: read-only snapshot. Closing the transaction before the hook keeps no
    # SQLite writer lock, so an independent session/thread can really commit the competing
    # claim at "ownership_read".
    with sessions() as db:
        upload = db.get(Upload, upload_id)
        if not upload:
            raise HTTPException(404, "asset_not_found")
        existing = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload_id))
        if existing is None:
            with db.no_autoflush:
                user_id = _guest_user_id(db, owner_guest_session_id)
            snapshot = {"sha256": upload.sha256, "storage_key": upload.storage_key}
    if existing is not None:
        # Existing-row early return must still repair ownership: the row can have been
        # created while the session was still unclaimed and the claim may have completed
        # since. No stale return is allowed to skip step 3.
        return _reconcile_archive_ownership(
            sessions, settings, upload_id=upload_id,
            guest_session_id=owner_guest_session_id, pet_id=pet_id,
        ) or serialize_archive(existing, settings)

    _archive_hook(hook, "ownership_read", upload_id=upload_id,
                  guest_session_id=owner_guest_session_id, user_id=user_id)

    # Phase 2: insert + commit the archive row from the (possibly now stale) snapshot.
    with sessions() as db:
        upload = db.get(Upload, upload_id)
        if not upload:
            raise HTTPException(404, "asset_not_found")
        existing = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload_id))
        if existing is None:
            sha256 = upload.sha256 or snapshot["sha256"]
            if not sha256:
                try:
                    sha256 = file_sha256(_storage_path(settings, upload.storage_key))
                except OSError as error:
                    raise HTTPException(404, "asset_not_found") from error
                upload.sha256 = sha256
            # Re-read the authoritative facts after the observation hook. A claim may have
            # committed between phase 1 and here; do not insert the stale pre-claim user/pet.
            fresh_user_id = _guest_user_id(db, owner_guest_session_id)
            fresh_pet_id = _pet_id_for_session(db, owner_guest_session_id)
            insert_user_id = fresh_user_id if fresh_user_id is not None else user_id
            insert_pet_id = fresh_pet_id if fresh_pet_id is not None else pet_id
            row = AssetArchive(
                user_id=insert_user_id,
                guest_session_id=owner_guest_session_id,
                job_id=job_id,
                upload_id=upload.id,
                pet_id=insert_pet_id,
                kind=kind,
                format=MIME_TO_FORMAT.get(upload.mime_type, "bin"),
                mime=upload.mime_type,
                bytes=upload.size_bytes,
                sha256=sha256,
                source_role=source_role,
                product_id=str(product_id)[:100] if product_id else None,
                variant_id=str(variant_id)[:100] if variant_id else None,
                provenance=provenance or {},
            )
            db.add(row)
            upload.archived = 1
            if insert_user_id:
                upload.expires_at = time.time() + settings.archived_upload_retention_seconds
            _archive_hook(hook, "before_commit", upload_id=upload_id,
                          guest_session_id=owner_guest_session_id, user_id=insert_user_id)
            try:
                db.commit()
            except IntegrityError:
                db.rollback()
                existing = db.scalar(select(AssetArchive).where(AssetArchive.upload_id == upload_id))
                if not existing:
                    raise
            else:
                serialized = serialize_archive(row, settings)
    if existing is not None:
        return _reconcile_archive_ownership(
            sessions, settings, upload_id=upload_id,
            guest_session_id=owner_guest_session_id, pet_id=pet_id,
        ) or serialize_archive(existing, settings)

    _archive_hook(hook, "after_commit", upload_id=upload_id,
                  guest_session_id=owner_guest_session_id, user_id=insert_user_id)
    # Phase 3: commit-then-recheck ownership repair (conditional UPDATE only).
    reconciled = _reconcile_archive_ownership(
        sessions, settings, upload_id=upload_id,
        guest_session_id=owner_guest_session_id, pet_id=pet_id,
    )
    return reconciled or serialized


def archive_job_result(sessions, settings, job_id: str, allow_partial: bool = False,
                       hook=None) -> list[dict]:
    """Archive the assets of a job that really exist on disk.

    A succeeded job archives every output. A failed/needs_review job may still carry a
    trusted checkpoint written after a real provider success (for example the cartoon PNG
    persisted at ``cartoon_ready`` before the 3D step failed); with ``allow_partial=True``
    those verified uploads are archived too and tagged ``partial`` while the job itself stays
    failed. Missing, zero-byte, foreign or checksum-mismatched uploads are skipped, so a failed
    model is never presented as a success.
    """
    with sessions() as db:
        job = db.get(Job, job_id)
        if not job:
            return []
        partial = job.status != "succeeded"
        if partial and not allow_partial:
            return []
        result = job.result or {}
        if isinstance(result, str):
            try:
                result = json.loads(result)
            except ValueError:
                return []
        guest_session_id = job.owner_id
        pet_id = _pet_id_for_session(db, guest_session_id)
        job_kind, job_shop, job_status = job.kind, job.shop, job.status
        source_job_id = result.get("source_job_id")
        product_id, variant_id = result.get("product_id"), result.get("variant_id")
        asset_entries = [a for a in (result.get("assets") or []) if isinstance(a, dict) and a.get("id")]
        manifest = result.get("manifest") if job_status == "succeeded" and job_kind.startswith("cat-fitting") else None
        stage = result.get("stage")

    provenance = {"job_kind": job_kind, "shop": job_shop, "source_job_id": source_job_id,
                  "created_from": "generation"}
    if partial:
        provenance.update({"partial": True, "job_status": job_status, "stage": stage})
    archived = []
    for asset in asset_entries:
        with sessions() as db:
            upload = db.get(Upload, str(asset["id"]))
            really_stored = _upload_is_really_stored(settings, upload, db.get(Job, job_id))
        if not really_stored:
            continue
        role = str(asset.get("role") or "")
        archived.append(archive_upload(
            sessions, settings, str(asset["id"]),
            guest_session_id=guest_session_id,
            kind=ROLE_TO_KIND.get(role, "photo"),
            source_role=role or None,
            job_id=job_id,
            product_id=product_id,
            variant_id=variant_id,
            provenance=provenance,
            pet_id=pet_id,
            hook=hook,
        ))
    if manifest is not None:
        with sessions() as db:
            existing_manifest = db.scalar(select(AssetArchive).where(
                AssetArchive.job_id == job_id, AssetArchive.kind == "manifest"))
        if existing_manifest is not None:
            archived.append(serialize_archive(existing_manifest, settings))
        else:
            storage = PrivateStorage(settings, sessions, guest_session_id, job_shop, job_id)
            payload = json.dumps(manifest, ensure_ascii=False, sort_keys=True).encode()
            stored = storage.save_output(payload, "application/json", "fitting-manifest.json")
            archived.append(archive_upload(
                sessions, settings, stored["id"],
                guest_session_id=guest_session_id, kind="manifest", source_role="manifest",
                job_id=job_id, provenance=provenance, pet_id=pet_id, hook=hook,
            ))
    if partial and archived:
        # keep the failure stage but record that real checkpoint outputs were preserved
        with sessions() as db:
            job = db.get(Job, job_id)
            if job is not None:
                current = job.result if isinstance(job.result, dict) else {}
                job.result = {**current, "partial": True,
                              "archived_assets": [item["asset_id"] for item in archived]}
                db.commit()
    with sessions() as db:
        job = db.get(Job, job_id)
        if job is not None:
            job.archived_at = time.time()
            job.archive_retry_at = None
            db.commit()
    return archived


def archive_pending_jobs(sessions, settings, limit: int = 20, now: float | None = None) -> int:
    """Bounded, persistent archive compensation for terminal jobs.

    The worker calls this every loop. It only touches the private archive path; it never calls
    an image/3D provider. Jobs are selected from persisted state (``archived_at IS NULL`` and
    ``archive_retry_at`` backoff), so a crash between ``finish_job(succeeded)`` and the first
    archive attempt is repaired after restart. A first transient archive failure on a succeeded
    job or on a recovered partial checkpoint is retried on a later loop with bounded batch size.
    """
    now = time.time() if now is None else now
    with sessions() as db:
        job_ids = db.scalars(
            select(Job.id)
            .where(
                Job.status.in_(("succeeded", "failed", "needs_review")),
                Job.archived_at.is_(None),
                or_(Job.archive_retry_at.is_(None), Job.archive_retry_at <= now),
            )
            .order_by(Job.updated_at)
            .limit(limit)
        ).all()
    repaired = 0
    for job_id in job_ids:
        with sessions() as db:
            job = db.get(Job, job_id)
            if job is None or job.archived_at is not None:
                continue
            job.archive_attempts = (job.archive_attempts or 0) + 1
            attempt = job.archive_attempts
            db.commit()
        try:
            archive_job_result(sessions, settings, job_id,
                               allow_partial=True)
        except Exception as error:  # noqa: BLE001 - retried by later worker loops
            logger.warning("archive_compensation_failed job_id=%s attempt=%s error_type=%s",
                           job_id, attempt, type(error).__name__)
            with sessions() as db:
                job = db.get(Job, job_id)
                if job is not None:
                    delay = min(300.0, float(2 ** min(attempt, 8)))
                    job.archive_retry_at = time.time() + delay
                    db.commit()
        else:
            with sessions() as db:
                job = db.get(Job, job_id)
                if job is not None and job.archived_at is None:
                    job.archived_at = time.time()
                    job.archive_retry_at = None
                    db.commit()
            repaired += 1
    return repaired


def archive_guest_upload(sessions, settings, upload_id: str, guest_session_id: str) -> dict:
    return archive_upload(sessions, settings, upload_id, guest_session_id=guest_session_id,
                          kind="photo", source_role="upload", provenance={"created_from": "upload"})


def upsert_pets_for_session(db, user_id: str, guest_session_id: str) -> Pet | None:
    profile = db.get(PetProfile, guest_session_id)
    data = profile.data if profile and isinstance(profile.data, dict) else {}
    pet_info = data.get("pet_information") if isinstance(data, dict) else None
    if not isinstance(pet_info, dict):
        return None
    display = data.get("display") if isinstance(data.get("display"), dict) else {}
    species = str(pet_info.get("type") or "dog")
    existing = db.scalar(select(Pet).where(Pet.user_id == user_id, Pet.source_session_id == guest_session_id))
    if not existing and display.get("name"):
        existing = db.scalar(select(Pet).where(Pet.user_id == user_id, Pet.name == str(display["name"])[:80], Pet.species == species))
    if existing:
        existing.source_session_id = existing.source_session_id or guest_session_id
        existing.updated_at = time.time()
        pet = existing
    else:
        pet = Pet(
            user_id=user_id,
            name=(str(display["name"])[:80] if display.get("name") else None),
            species=species,
            breed=(str(display["breed"])[:80] if display.get("breed") else None),
            age_months=pet_info.get("age_months"),
            dog_size=pet_info.get("dog_size"),
            source_session_id=guest_session_id,
        )
        db.add(pet)
        db.flush()
    # Persist the per-questionnaire mapping so a second same-name questionnaire resolves to
    # the same Pet even though Pet.source_session_id only records the first one.
    mapping = db.get(GuestSessionPet, guest_session_id)
    if mapping is None:
        db.add(GuestSessionPet(session_id=guest_session_id, pet_id=pet.id, user_id=user_id))
    else:
        mapping.pet_id = pet.id
        mapping.user_id = user_id
    return pet


def transfer_guest_assets(sessions, settings, guest_session_id: str, user_id: str) -> int:
    """Idempotently attach every archived asset of one claimed session to the user.

    Uses conditional UPDATEs (``user_id IS NULL`` / ``pet_id IS NULL``) as the cross-process
    lock protocol and is safe to run concurrently with :func:`archive_upload`: whichever side
    commits second repairs the other via the same predicate. The physical uploads are marked
    durable and their expiry is extended past the guest TTL.
    """
    now = time.time()
    with sessions() as db:
        pet_id = _pet_id_for_session(db, guest_session_id)
        db.execute(
            update(AssetArchive)
            .where(AssetArchive.guest_session_id == guest_session_id, AssetArchive.user_id.is_(None))
            .values(user_id=user_id)
        )
        if pet_id:
            db.execute(
                update(AssetArchive)
                .where(AssetArchive.guest_session_id == guest_session_id, AssetArchive.pet_id.is_(None))
                .values(pet_id=pet_id)
            )
        rows = db.scalars(select(AssetArchive).where(AssetArchive.guest_session_id == guest_session_id)).all()
        target = now + settings.archived_upload_retention_seconds
        for row in rows:
            upload = db.get(Upload, row.upload_id)
            if upload:
                upload.archived = 1
                if upload.expires_at < target:
                    upload.expires_at = target
        db.commit()
        return len(rows)

def _encode_cursor(row: AssetArchive) -> str:
    raw = json.dumps({"t": row.created_at, "id": row.id}, sort_keys=True).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _decode_cursor(cursor: str) -> tuple[float, str] | None:
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4))
        data = json.loads(raw)
        return float(data["t"]), str(data["id"])
    except (ValueError, KeyError, TypeError):
        return None


def serialize_archive(row: AssetArchive, settings) -> dict:
    return {
        "asset_id": row.id,
        "kind": row.kind,
        "format": row.format,
        "mime": row.mime,
        "bytes": row.bytes,
        "sha256": row.sha256,
        "source_job_id": row.job_id,
        "pet_id": row.pet_id,
        "created_at": row.created_at,
        "download_url": f"/mobile/v1/assets/{row.id}/download",
        "manifest_url": f"/mobile/v1/assets/{row.id}/manifest",
        "kind_role": row.source_role,
        "product_id": row.product_id,
        "variant_id": row.variant_id,
    }


def list_user_assets(sessions, user_id: str, kind: str | None = None, cursor: str | None = None, limit: int = 20) -> dict:
    limit = max(1, min(int(limit), 50))
    with sessions() as db:
        statement = select(AssetArchive).where(AssetArchive.user_id == user_id)
        if kind:
            statement = statement.where(AssetArchive.kind == kind)
        if cursor:
            decoded = _decode_cursor(cursor)
            if not decoded:
                raise HTTPException(422, "invalid_cursor")
            ts, ident = decoded
            statement = statement.where((AssetArchive.created_at < ts) | ((AssetArchive.created_at == ts) & (AssetArchive.id < ident)))
        rows = db.scalars(statement.order_by(AssetArchive.created_at.desc(), AssetArchive.id.desc()).limit(limit + 1)).all()
        items = [serialize_archive(row, None) for row in rows[:limit]]
        next_cursor = _encode_cursor(rows[limit - 1]) if len(rows) > limit else None
        return {"items": items, "next_cursor": next_cursor}


def list_user_models(sessions, user_id: str, pet_id: str | None = None) -> list[AssetArchive]:
    with sessions() as db:
        statement = select(AssetArchive).where(AssetArchive.user_id == user_id, AssetArchive.kind == "model")
        if pet_id:
            statement = statement.where(AssetArchive.pet_id == pet_id)
        return db.scalars(statement.order_by(AssetArchive.created_at.desc())).all()


def asset_records(sessions, user_id: str) -> list[AssetArchive]:
    with sessions() as db:
        return db.scalars(select(AssetArchive).where(AssetArchive.user_id == user_id)).all()


def get_owned_asset(sessions, settings, user_id: str, asset_id: str) -> tuple[AssetArchive, bytes]:
    with sessions() as db:
        row = db.get(AssetArchive, asset_id[:64])
        if not row or row.user_id != user_id:
            raise HTTPException(404, "asset_not_found")
        upload = db.get(Upload, row.upload_id)
        if not upload:
            raise HTTPException(404, "asset_not_found")
        try:
            data = _storage_path(settings, upload.storage_key).read_bytes()
        except OSError as error:
            raise HTTPException(404, "asset_not_found") from error
        return row, data


def list_pets(sessions, user_id: str) -> list[dict]:
    with sessions() as db:
        rows = db.scalars(select(Pet).where(Pet.user_id == user_id).order_by(Pet.created_at)).all()
        return [serialize_pet(row) for row in rows]


def serialize_pet(pet: Pet | None) -> dict | None:
    if pet is None:
        return None
    return {
        "pet_id": pet.id,
        "name": pet.name,
        "species": pet.species,
        "breed": pet.breed,
        "age_months": pet.age_months,
        "dog_size": pet.dog_size,
        "avatar_url": f"/mobile/v1/assets/{pet.avatar_asset_id}/download" if pet.avatar_asset_id else None,
    }


def pet_home_manifest(sessions, settings, user_id: str, pet_id: str | None = None) -> dict:
    default_model = default_model_metadata(settings)
    if default_model is None:
        default_model = {
            "role": "default", "static": True, "is_default": True, "available": False,
            "format": "glb", "mime": DEFAULT_MODEL_MIME, "url": f"/public-assets/{DEFAULT_MODEL_FILENAME}",
            "source": "website-golden-master",
        }
    pet = None
    if pet_id:
        with sessions() as db:
            pet = db.get(Pet, pet_id[:64])
        if not pet or pet.user_id != user_id:
            raise HTTPException(404, "pet_not_found")
    models = list_user_models(sessions, user_id, pet_id)
    personal_model = None
    fallback_reason = None
    for model in models:
        if model.format in SUPPORTED_PERSONAL_FORMATS:
            personal_model = {
                "role": "personal",
                "is_default": False,
                "asset_id": model.id,
                "format": model.format,
                "mime": model.mime,
                "bytes": model.bytes,
                "sha256": model.sha256,
                "url": f"/mobile/v1/assets/{model.id}/download",
                "manifest_url": f"/mobile/v1/assets/{model.id}/manifest",
                "created_at": model.created_at,
            }
            break
        fallback_reason = f"unsupported_personal_format:{model.format}"
    selected = "personal" if personal_model else "default"
    return {
        "pet_id": pet.id if pet else None,
        "manifest_version": 1,
        "selected": selected,
        "fallback_reason": fallback_reason,
        "avatar_url": f"/mobile/v1/assets/{pet.avatar_asset_id}/download" if pet and pet.avatar_asset_id else None,
        "default_model": default_model,
        "personal_model": personal_model,
    }
