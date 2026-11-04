import io
import secrets
import time
from dataclasses import dataclass
from pathlib import Path

from fastapi import HTTPException
from PIL import Image, ImageOps, UnidentifiedImageError

from .models import Upload, new_id


@dataclass(frozen=True)
class Artifact:
    id: str
    data: bytes
    mime_type: str
    filename: str


class PrivateStorage:
    """Private filesystem adapter. One host/shared persistent volume per deployment."""

    def __init__(self, settings, sessions, owner_id: str, shop: str, job_id=None):
        self.settings = settings
        self.sessions = sessions
        self.owner_id = owner_id
        self.shop = shop
        self.job_id = job_id
        self.root = settings.storage_path.resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def location(self, key: str) -> Path:
        if len(key) != 64 or any(char not in "0123456789abcdef" for char in key):
            raise ValueError("invalid_storage_key")
        path = (self.root / key).resolve()
        if path.parent != self.root:
            raise ValueError("invalid_storage_path")
        return path

    def save_output(self, data: bytes, mime_type: str, filename: str) -> dict:
        upload_id = new_id()
        key = secrets.token_hex(32)
        safe_name = Path(filename.replace("\\", "/")).name[:120] or "asset"
        self.location(key).write_bytes(data)
        try:
            with self.sessions() as db:
                db.add(Upload(id=upload_id, owner_id=self.owner_id, shop=self.shop, job_id=self.job_id,
                              storage_key=key, filename=safe_name, mime_type=mime_type,
                              size_bytes=len(data), expires_at=time.time() + self.settings.media_retention_seconds))
                db.commit()
        except Exception:
            self.location(key).unlink(missing_ok=True)
            raise
        return {"id": upload_id, "url": f"/v1/uploads/{upload_id}", "mime_type": mime_type,
                "filename": safe_name, "size_bytes": len(data)}

    def get_owned(self, upload_id: str) -> Artifact:
        with self.sessions() as db:
            row = db.get(Upload, upload_id)
            if not row or row.owner_id != self.owner_id or row.shop != self.shop or row.expires_at <= time.time():
                raise HTTPException(404, "asset_not_found")
            try:
                return Artifact(row.id, self.location(row.storage_key).read_bytes(), row.mime_type, row.filename)
            except FileNotFoundError as error:
                raise HTTPException(404, "asset_not_found") from error


def normalize_upload(data: bytes, content_type: str, settings) -> bytes:
    if len(data) > settings.max_upload_bytes:
        raise HTTPException(413, "upload_too_large")
    if content_type not in {"image/jpeg", "image/png", "image/webp"}:
        raise HTTPException(415, "unsupported_image_type")
    try:
        with Image.open(io.BytesIO(data)) as image:
            expected = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}
            if expected.get(image.format) != content_type:
                raise HTTPException(415, "image_type_mismatch")
            if image.width * image.height > settings.max_upload_pixels:
                raise HTTPException(413, "image_dimensions_too_large")
            image.load()
            clean = ImageOps.exif_transpose(image).convert("RGB")
            clean.thumbnail((2048, 2048))
            output = io.BytesIO()
            clean.save(output, "JPEG", quality=92)
            return output.getvalue()
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as error:
        raise HTTPException(415, "invalid_image") from error


def cleanup_expired(settings, sessions, hook=None):
    """Delete expired *unclaimed* media; never race a concurrent claim into data loss.

    Protocol (DB transactions/conditional UPDATEs only, valid across processes):

    1. Snapshot expired upload ids and their owning guest sessions in a short read
       transaction, then release it so a competing claim/transfer can commit.
    2. Re-open a transaction and take a write lock on the owning guest session rows with a
       conditional no-op UPDATE (SQLite writer lock / Postgres row lock); **re-read** the
       authoritative claim and archive ownership facts under that lock.
    3. If anyone owns the asset now (archive.user_id set or guest claimed), mark it durable and
       extend its expiry; otherwise delete only guest archive rows (``user_id IS NULL``) and the
       upload row in one transaction.
    4. Only after a fresh transaction confirms nothing durable remains is the physical file
       unlinked (double-check before unlink).

    ``hook`` is a test-only observation point (``protection_snapshot`` / ``after_lock`` /
    ``protected`` / ``before_unlink``); production callers omit it.
    """
    from sqlalchemy import delete, select, update

    from .models import AssetArchive, GuestSession

    storage = PrivateStorage(settings, sessions, "", "")
    now = time.time()
    deleted = 0
    with sessions() as db:
        expired_ids = [row.id for row in db.scalars(select(Upload).where(Upload.expires_at <= now)).all()]
    for upload_id in expired_ids:
        # Phase 1: short read snapshot, then release the read transaction before the hook.
        with sessions() as db:
            upload = db.get(Upload, upload_id)
            if not upload or upload.expires_at > now:
                continue
            storage_key = upload.storage_key
            archives = db.scalars(select(AssetArchive).where(AssetArchive.upload_id == upload_id)).all()
            # The upload's owner_id is the guest session for website/generation uploads. Even
            # without any archive row yet (crash before archive, or one failed archive attempt),
            # an already-claimed owner means the source bytes are durable and must be protected
            # until the archive-compensation scan can attach them to the account.
            guest_ids = sorted({row.guest_session_id for row in archives if row.guest_session_id}
                               | ({upload.owner_id} if upload.owner_id else set()))
        if hook is not None:
            hook("protection_snapshot", upload_id=upload_id)
        # Phase 2: lock + authoritative re-read, then delete or protect.
        protected = False
        with sessions() as db:
            upload = db.get(Upload, upload_id)
            if not upload:
                continue
            if upload.expires_at > now:
                # A concurrent claim/archive already made it durable; keep the file.
                if hook is not None:
                    hook("protected", upload_id=upload_id)
                continue
            for guest_id in guest_ids:
                db.execute(
                    update(GuestSession)
                    .where(GuestSession.id == guest_id)
                    .values(claimed_at=GuestSession.claimed_at)
                )
            db.flush()
            if hook is not None:
                hook("after_lock", upload_id=upload_id)
            owners = list(db.scalars(select(AssetArchive.user_id).where(
                AssetArchive.upload_id == upload_id, AssetArchive.user_id.is_not(None))).all())
            guest_claimed = any(
                db.execute(select(GuestSession.user_id).where(GuestSession.id == guest_id)).scalar_one_or_none()
                for guest_id in guest_ids
            )
            if owners or guest_claimed:
                upload.archived = 1
                target = now + settings.archived_upload_retention_seconds
                if upload.expires_at < target:
                    upload.expires_at = target
                db.commit()
                protected = True
                if hook is not None:
                    hook("protected", upload_id=upload_id)
            else:
                db.execute(delete(AssetArchive).where(AssetArchive.upload_id == upload_id,
                                                      AssetArchive.user_id.is_(None)))
                db.delete(upload)
                db.commit()
        if protected:
            continue
        # Phase 3: fresh double-check, then unlink the physical file.
        with sessions() as db:
            still = db.get(Upload, upload_id)
            durable = db.scalar(select(AssetArchive.id).where(
                AssetArchive.upload_id == upload_id, AssetArchive.user_id.is_not(None)).limit(1))
        if still is None and durable is None:
            if hook is not None:
                hook("before_unlink", upload_id=upload_id)
            storage.location(storage_key).unlink(missing_ok=True)
            deleted += 1
    return deleted
