import time
import uuid

from sqlalchemy import JSON, Float, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base


def new_id():
    return uuid.uuid4().hex


def new_public_ref():
    return uuid.uuid4().hex


class Installation(Base):
    __tablename__ = "installation"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    shop: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[float] = mapped_column(Float, default=time.time)


class GuestSession(Base):
    __tablename__ = "guest_sessions"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    shop: Mapped[str] = mapped_column(String(255), index=True)
    ip_hash: Mapped[str] = mapped_column(String(64), default="")
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    expires_at: Mapped[float] = mapped_column(Float, index=True)
    jobs_submitted: Mapped[int] = mapped_column(Integer, default=0)
    user_id: Mapped[str | None] = mapped_column(String(32), nullable=True, index=True)
    email_normalized: Mapped[str | None] = mapped_column(String(254), nullable=True)
    full_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    claimed_at: Mapped[float | None] = mapped_column(Float, nullable=True)


class PetProfile(Base):
    __tablename__ = "pet_profiles"
    owner_id: Mapped[str] = mapped_column(String(32), primary_key=True)
    data: Mapped[dict] = mapped_column(JSON)
    consent: Mapped[dict] = mapped_column(JSON)
    updated_at: Mapped[float] = mapped_column(Float, default=time.time)


class RateWindow(Base):
    __tablename__ = "rate_windows"
    key: Mapped[str] = mapped_column(String(128), primary_key=True)
    count: Mapped[int] = mapped_column(Integer, default=0)
    expires_at: Mapped[float] = mapped_column(Float, index=True)


class Upload(Base):
    __tablename__ = "uploads"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    owner_id: Mapped[str] = mapped_column(String(32), index=True)
    shop: Mapped[str] = mapped_column(String(255), index=True)
    job_id: Mapped[str | None] = mapped_column(String(32), nullable=True)
    storage_key: Mapped[str] = mapped_column(String(64), unique=True)
    filename: Mapped[str] = mapped_column(String(120))
    mime_type: Mapped[str] = mapped_column(String(80))
    size_bytes: Mapped[int] = mapped_column(Integer)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    expires_at: Mapped[float] = mapped_column(Float, index=True)
    archived: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)


class Job(Base):
    __tablename__ = "jobs"
    __table_args__ = (UniqueConstraint("shop", "owner_id", "idempotency_key"),)
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    shop: Mapped[str] = mapped_column(String(255), index=True)
    owner_id: Mapped[str] = mapped_column(String(32), index=True)
    kind: Mapped[str] = mapped_column(String(30))
    input: Mapped[dict] = mapped_column(JSON)
    input_hash: Mapped[str] = mapped_column(String(64))
    idempotency_key: Mapped[str] = mapped_column(String(120))
    status: Mapped[str] = mapped_column(String(30), default="queued", index=True)
    result: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    error_code: Mapped[str | None] = mapped_column(String(80), nullable=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    lease_owner: Mapped[str | None] = mapped_column(String(64), nullable=True)
    lease_until: Mapped[float | None] = mapped_column(Float, nullable=True, index=True)
    dispatched_at: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    updated_at: Mapped[float] = mapped_column(Float, default=time.time)
    # Archive compensation state (worker loop retries terminal jobs without re-calling providers).
    archived_at: Mapped[float | None] = mapped_column(Float, nullable=True, index=True)
    archive_attempts: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    archive_retry_at: Mapped[float | None] = mapped_column(Float, nullable=True)


class CatalogProduct(Base):
    __tablename__ = "catalog_products"
    shop: Mapped[str] = mapped_column(String(255), primary_key=True)
    product_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    data: Mapped[dict] = mapped_column(JSON)
    updated_at: Mapped[float] = mapped_column(Float, default=time.time)


class WebhookEvent(Base):
    __tablename__ = "webhook_events"
    __table_args__ = (UniqueConstraint("shop", "event_id"),)
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    shop: Mapped[str] = mapped_column(String(255), index=True)
    event_id: Mapped[str] = mapped_column(String(100))
    topic: Mapped[str] = mapped_column(String(80))
    payload: Mapped[dict] = mapped_column(JSON)
    status: Mapped[str] = mapped_column(String(30), default="queued", index=True)
    payload_hash: Mapped[str] = mapped_column(String(64))
    error_code: Mapped[str | None] = mapped_column(String(80), nullable=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    lease_owner: Mapped[str | None] = mapped_column(String(64), nullable=True)
    lease_until: Mapped[float | None] = mapped_column(Float, nullable=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    available_at: Mapped[float] = mapped_column(Float, default=time.time)


class User(Base):
    """Stable opaque identity mapped from a normalized email address."""

    __tablename__ = "users"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    public_ref: Mapped[str] = mapped_column(String(32), unique=True, default=new_public_ref)
    email_normalized: Mapped[str] = mapped_column(String(254), unique=True, index=True)
    email_display: Mapped[str] = mapped_column(String(254))
    full_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    email_verified_at: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    updated_at: Mapped[float] = mapped_column(Float, default=time.time)


class EmailChallenge(Base):
    __tablename__ = "email_challenges"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    purpose: Mapped[str] = mapped_column(String(40))
    user_id: Mapped[str] = mapped_column(String(32), index=True)
    guest_session_id: Mapped[str | None] = mapped_column(String(32), nullable=True, index=True)
    email_normalized: Mapped[str] = mapped_column(String(254), index=True)
    code_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    link_token_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    max_attempts: Mapped[int] = mapped_column(Integer, default=5, server_default="5")
    consumed_at: Mapped[float | None] = mapped_column(Float, nullable=True)
    expires_at: Mapped[float] = mapped_column(Float, index=True)
    ip_hash: Mapped[str] = mapped_column(String(64), default="", server_default="")
    created_at: Mapped[float] = mapped_column(Float, default=time.time)


class MobileSession(Base):
    __tablename__ = "mobile_sessions"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(String(32), index=True)
    shop: Mapped[str] = mapped_column(String(255), index=True)
    family_id: Mapped[str] = mapped_column(String(32), index=True)
    access_hash: Mapped[str | None] = mapped_column(String(64), unique=True, nullable=True)
    refresh_hash: Mapped[str | None] = mapped_column(String(64), unique=True, nullable=True)
    access_expires_at: Mapped[float] = mapped_column(Float)
    refresh_expires_at: Mapped[float] = mapped_column(Float, index=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    revoked_at: Mapped[float | None] = mapped_column(Float, nullable=True)


class Pet(Base):
    __tablename__ = "pets"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(String(32), index=True)
    name: Mapped[str | None] = mapped_column(String(80), nullable=True)
    species: Mapped[str] = mapped_column(String(20))
    breed: Mapped[str | None] = mapped_column(String(80), nullable=True)
    age_months: Mapped[int | None] = mapped_column(Integer, nullable=True)
    dog_size: Mapped[str | None] = mapped_column(String(20), nullable=True)
    avatar_asset_id: Mapped[str | None] = mapped_column(String(32), nullable=True)
    source_session_id: Mapped[str | None] = mapped_column(String(32), nullable=True, index=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    updated_at: Mapped[float] = mapped_column(Float, default=time.time)


class AssetArchive(Base):
    __tablename__ = "asset_archive"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    user_id: Mapped[str | None] = mapped_column(String(32), nullable=True, index=True)
    guest_session_id: Mapped[str | None] = mapped_column(String(32), nullable=True, index=True)
    job_id: Mapped[str | None] = mapped_column(String(32), nullable=True, index=True)
    upload_id: Mapped[str] = mapped_column(String(32), unique=True)
    pet_id: Mapped[str | None] = mapped_column(String(32), nullable=True, index=True)
    kind: Mapped[str] = mapped_column(String(30))
    format: Mapped[str] = mapped_column(String(20))
    mime: Mapped[str] = mapped_column(String(80))
    bytes: Mapped[int] = mapped_column(Integer)
    sha256: Mapped[str] = mapped_column(String(64))
    source_role: Mapped[str | None] = mapped_column(String(30), nullable=True)
    product_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    variant_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    provenance: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)


class DiscoveryProfile(Base):
    __tablename__ = "discovery_profiles"
    user_id: Mapped[str] = mapped_column(String(32), primary_key=True)
    enabled: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    grid_x: Mapped[int] = mapped_column(Integer)
    grid_y: Mapped[int] = mapped_column(Integer)
    region_label: Mapped[str | None] = mapped_column(String(120), nullable=True)
    radius_km: Mapped[int] = mapped_column(Integer, default=5, server_default="5")
    updated_at: Mapped[float] = mapped_column(Float, default=time.time)
    expires_at: Mapped[float] = mapped_column(Float, index=True)


class ContactRequest(Base):
    __tablename__ = "contact_requests"
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    from_user_id: Mapped[str] = mapped_column(String(32), index=True)
    to_user_id: Mapped[str] = mapped_column(String(32), index=True)
    status: Mapped[str] = mapped_column(String(20), default="pending", server_default="pending", index=True)
    message: Mapped[str | None] = mapped_column(String(500), nullable=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
    updated_at: Mapped[float] = mapped_column(Float, default=time.time)


class Contact(Base):
    __tablename__ = "contacts"
    __table_args__ = (UniqueConstraint("user_a", "user_b"),)
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    user_a: Mapped[str] = mapped_column(String(32), index=True)
    user_b: Mapped[str] = mapped_column(String(32), index=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)


class ContactMessage(Base):
    __tablename__ = "contact_messages"
    __table_args__ = (UniqueConstraint("contact_id", "client_id"),)
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    contact_id: Mapped[str] = mapped_column(String(32), index=True)
    sender_user_id: Mapped[str] = mapped_column(String(32))
    body: Mapped[str] = mapped_column(String(2000))
    client_id: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[float] = mapped_column(Float, default=time.time, index=True)


class UserBlock(Base):
    __tablename__ = "user_blocks"
    blocker_id: Mapped[str] = mapped_column(String(32), primary_key=True)
    blocked_id: Mapped[str] = mapped_column(String(32), primary_key=True, index=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)


class SocialPairLock(Base):
    """Persistent per-user-pair mutex row for block/create/accept/send ordering.

    Every mutation that depends on the between-users block fact first takes a write lock on
    the same ordered pair row. On PostgreSQL that is a row lock held until commit; on SQLite
    the no-op UPDATE starts a write transaction (``BEGIN IMMEDIATE``-like serialization).
    The row itself is only a lock token; its values carry no business meaning.
    """

    __tablename__ = "social_pair_locks"
    pair_key: Mapped[str] = mapped_column(String(65), primary_key=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)


class GuestSessionPet(Base):
    """Mapping from one questionnaire (guest session) to the pet it resolved to.

    The same physical pet can be entered through several questionnaires (same owner, same
    name); ``Pet.source_session_id`` only records the first session. This table keeps one
    row per session so archive/transfer can resolve the pet deterministically.
    """

    __tablename__ = "guest_session_pets"
    __table_args__ = (UniqueConstraint("session_id"),)
    session_id: Mapped[str] = mapped_column(String(32), primary_key=True)
    pet_id: Mapped[str] = mapped_column(String(32), index=True)
    user_id: Mapped[str] = mapped_column(String(32), index=True)
    created_at: Mapped[float] = mapped_column(Float, default=time.time)
