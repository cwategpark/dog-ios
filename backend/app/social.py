"""Nearby discovery, one-to-one contact requests, persistent messages and blocks.

Privacy rules: discovery is opt-in, positions are quantized to a fixed ~5.5km grid with a
24h TTL, and nearby responses expose only public pet fields, a coarse grid label and a
distance bucket. There is no email and no precise GPS anywhere in the response.
"""
import math
import time

from fastapi import HTTPException
from sqlalchemy import or_, select, update
from sqlalchemy.exc import IntegrityError

from .models import (Contact, ContactMessage, ContactRequest, DiscoveryProfile, Pet,
                     SocialPairLock, User, UserBlock)

GRID_DEGREES = 0.05
MAX_NEARBY_ITEMS = 50


def _validate_coordinates(lat, lon) -> tuple[float, float]:
    try:
        lat = float(lat)
        lon = float(lon)
    except (TypeError, ValueError) as error:
        raise HTTPException(422, "invalid_region") from error
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise HTTPException(422, "invalid_region")
    return lat, lon


def quantize(lat: float, lon: float) -> tuple[int, int]:
    return int(math.floor(lat / GRID_DEGREES)), int(math.floor(lon / GRID_DEGREES))


def grid_center(grid_x: int, grid_y: int) -> tuple[float, float]:
    return (grid_x + 0.5) * GRID_DEGREES, (grid_y + 0.5) * GRID_DEGREES


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius = 6371.0088
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = phi2 - phi1
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(a))


def distance_bucket(distance_km: float) -> str:
    if distance_km < 1:
        return "lt_1km"
    if distance_km < 3:
        return "1_3km"
    if distance_km < 10:
        return "3_10km"
    return "10_25km"


def blocked_between(db, first: str, second: str) -> bool:
    return db.scalar(
        select(UserBlock).where(
            or_(
                (UserBlock.blocker_id == first) & (UserBlock.blocked_id == second),
                (UserBlock.blocker_id == second) & (UserBlock.blocked_id == first),
            )
        )
    ) is not None


def _pair_key(first: str, second: str) -> str:
    a, b = sorted((first, second))
    return f"{a}:{b}"


def _lock_pair(db, first: str, second: str, hook=None) -> None:
    """Serialize all pair-state mutations on one persistent ordered pair row.

    The row is created idempotently, then a no-op UPDATE takes a write lock:
    PostgreSQL holds a row lock until commit; SQLite escalates to a write transaction, so a
    concurrent block cannot commit between this operation's block check and its write. Merely
    re-reading ``blocked_between`` would still leave that TOCTOU window open.
    """
    key = _pair_key(first, second)
    try:
        with db.begin_nested():
            db.add(SocialPairLock(pair_key=key))
            db.flush()
    except IntegrityError:
        pass
    db.execute(
        update(SocialPairLock)
        .where(SocialPairLock.pair_key == key)
        .values(created_at=SocialPairLock.created_at)
        .execution_options(synchronize_session=False)
    )
    db.flush()
    if hook is not None:
        hook("pair_locked", first, second)


def set_discovery(sessions, settings, user_id: str, enabled: bool, region: dict | None, radius_km=None) -> dict:
    now = time.time()
    with sessions() as db:
        profile = db.get(DiscoveryProfile, user_id)
        if not enabled:
            if profile:
                profile.enabled = 0
                profile.updated_at = now
                profile.expires_at = 0
                db.commit()
            return {"enabled": False, "grid": None, "expires_at": None, "radius_km": None}
        if not isinstance(region, dict):
            raise HTTPException(422, "region_required")
        lat, lon = _validate_coordinates(region.get("lat"), region.get("lon"))
        grid_x, grid_y = quantize(lat, lon)
        requested_radius = int(radius_km or settings.discovery_default_radius_km)
        if requested_radius < 1 or requested_radius > settings.discovery_max_radius_km:
            raise HTTPException(422, "invalid_radius")
        label = str(region.get("label") or "")[:120] or None
        expires_at = now + settings.discovery_location_ttl_seconds
        if profile:
            profile.enabled = 1
            profile.grid_x = grid_x
            profile.grid_y = grid_y
            profile.region_label = label
            profile.radius_km = requested_radius
            profile.updated_at = now
            profile.expires_at = expires_at
        else:
            db.add(DiscoveryProfile(user_id=user_id, enabled=1, grid_x=grid_x, grid_y=grid_y,
                                    region_label=label, radius_km=requested_radius,
                                    updated_at=now, expires_at=expires_at))
        db.commit()
        return {"enabled": True, "grid": f"{grid_x}:{grid_y}", "expires_at": expires_at, "radius_km": requested_radius}


def get_discovery(sessions, user_id: str) -> dict:
    now = time.time()
    with sessions() as db:
        profile = db.get(DiscoveryProfile, user_id)
        if not profile or not profile.enabled:
            return {"enabled": False, "grid": None, "expires_at": None, "radius_km": None}
        if profile.expires_at <= now:
            return {"enabled": False, "grid": None, "expires_at": profile.expires_at, "radius_km": profile.radius_km}
        return {"enabled": True, "grid": f"{profile.grid_x}:{profile.grid_y}", "expires_at": profile.expires_at, "radius_km": profile.radius_km}


def latest_pet(db, user_id: str) -> Pet | None:
    return db.scalar(select(Pet).where(Pet.user_id == user_id).order_by(Pet.created_at.desc()).limit(1))


def public_pet(pet: Pet | None) -> dict:
    if not pet:
        return {"name": None, "species": None, "breed": None, "age_months": None, "avatar_url": None}
    return {
        "name": pet.name,
        "species": pet.species,
        "breed": pet.breed,
        "age_months": pet.age_months,
        "avatar_url": f"/mobile/v1/assets/{pet.avatar_asset_id}/download" if pet.avatar_asset_id else None,
    }


def nearby(sessions, settings, user_id: str, radius_km=None) -> dict:
    now = time.time()
    with sessions() as db:
        mine = db.get(DiscoveryProfile, user_id)
        if not mine or not mine.enabled or mine.expires_at <= now:
            raise HTTPException(409, "discovery_not_enabled")
        radius = int(radius_km or mine.radius_km or settings.discovery_default_radius_km)
        if radius < 1 or radius > settings.discovery_max_radius_km:
            raise HTTPException(422, "invalid_radius")
        my_lat, my_lon = grid_center(mine.grid_x, mine.grid_y)
        candidates = db.scalars(
            select(DiscoveryProfile).where(
                DiscoveryProfile.enabled == 1,
                DiscoveryProfile.expires_at > now,
                DiscoveryProfile.user_id != user_id,
            )
        ).all()
        items = []
        for candidate in candidates:
            if blocked_between(db, user_id, candidate.user_id):
                continue
            lat, lon = grid_center(candidate.grid_x, candidate.grid_y)
            distance = haversine_km(my_lat, my_lon, lat, lon)
            if distance > radius:
                continue
            user = db.get(User, candidate.user_id)
            if not user:
                continue
            items.append({
                "public_ref": user.public_ref,
                "pet": public_pet(latest_pet(db, user.id)),
                "coarse_region": {"grid": f"{candidate.grid_x}:{candidate.grid_y}", "label": candidate.region_label},
                "distance_bucket": distance_bucket(distance),
                "_distance": distance,
            })
        items.sort(key=lambda item: item["_distance"])
        for item in items:
            item.pop("_distance", None)
        return {"items": items[:MAX_NEARBY_ITEMS], "radius_km": radius, "generated_at": now}


def target_user(sessions, public_ref: str) -> User:
    with sessions() as db:
        user = db.scalar(select(User).where(User.public_ref == (public_ref or "")[:32]))
        if not user or not user.email_verified_at:
            raise HTTPException(404, "user_not_found")
        return user


def _contact_between(db, first: str, second: str) -> Contact | None:
    a, b = sorted((first, second))
    return db.scalar(select(Contact).where(Contact.user_a == a, Contact.user_b == b))


def create_contact_request(sessions, user_id: str, target_public_ref: str, message: str | None,
                           hook=None) -> tuple[dict, bool]:
    target = target_user(sessions, target_public_ref)
    if target.id == user_id:
        raise HTTPException(422, "cannot_contact_self")
    now = time.time()
    with sessions() as db:
        _lock_pair(db, user_id, target.id, hook)
        # Checked under the pair lock: a concurrent add_block must wait for this transaction,
        # so it cannot commit after this check and before the pending request is inserted.
        if blocked_between(db, user_id, target.id):
            raise HTTPException(403, "blocked")
        if _contact_between(db, user_id, target.id):
            raise HTTPException(409, "already_contacts")
        existing = db.scalar(
            select(ContactRequest).where(
                ContactRequest.from_user_id == user_id, ContactRequest.to_user_id == target.id,
                ContactRequest.status == "pending",
            )
        )
        if existing:
            return serialize_request(existing, "outgoing"), False
        reverse = db.scalar(
            select(ContactRequest).where(
                ContactRequest.from_user_id == target.id, ContactRequest.to_user_id == user_id,
                ContactRequest.status == "pending",
            )
        )
        if reverse:
            # Atomic reverse auto-accept: exactly one caller flips pending -> accepted.
            flipped = db.execute(
                update(ContactRequest)
                .where(ContactRequest.id == reverse.id, ContactRequest.status == "pending")
                .values(status="accepted", updated_at=now)
                .execution_options(synchronize_session=False)
            )
            payload = {"request_id": reverse.id, "status": "accepted", "auto_accepted": True}
            if flipped.rowcount != 1:
                # Somebody else already moved it: answer with the authoritative outcome.
                db.rollback()
                current = db.scalar(select(ContactRequest).where(ContactRequest.id == reverse.id))
                if current is None or current.status != "accepted":
                    raise HTTPException(409, "contact_request_conflict")
                contact = _contact_between(db, current.from_user_id, current.to_user_id)
                if contact is None:
                    raise HTTPException(409, "contact_request_conflict")
                return {**payload, "request_id": current.id, "contact_id": contact.id}, False
            contact = _create_contact(db, user_id, target.id)
            db.commit()
            return {**payload, "contact_id": contact.id}, True
        row = ContactRequest(from_user_id=user_id, to_user_id=target.id, status="pending",
                             message=(message or "")[:500] or None)
        db.add(row)
        db.commit()
        return serialize_request(row, "outgoing"), True


def serialize_request(row: ContactRequest, direction: str) -> dict:
    return {"request_id": row.id, "direction": direction, "status": row.status,
            "message": row.message, "created_at": row.created_at}


def _create_contact(db, first: str, second: str) -> Contact:
    a, b = sorted((first, second))
    contact = db.scalar(select(Contact).where(Contact.user_a == a, Contact.user_b == b))
    if contact:
        return contact
    contact = Contact(user_a=a, user_b=b)
    try:
        with db.begin_nested():
            db.add(contact)
            db.flush()
    except IntegrityError:
        # A concurrent accept won the unique (user_a, user_b) insert: return their row.
        contact = db.scalar(select(Contact).where(Contact.user_a == a, Contact.user_b == b))
        if not contact:
            raise
    return contact


def list_contact_requests(sessions, user_id: str, direction: str = "incoming") -> dict:
    direction = "outgoing" if direction == "outgoing" else "incoming"
    with sessions() as db:
        if direction == "incoming":
            rows = db.scalars(select(ContactRequest).where(ContactRequest.to_user_id == user_id).order_by(ContactRequest.created_at.desc())).all()
        else:
            rows = db.scalars(select(ContactRequest).where(ContactRequest.from_user_id == user_id).order_by(ContactRequest.created_at.desc())).all()
        items = []
        for row in rows:
            other_id = row.from_user_id if direction == "incoming" else row.to_user_id
            # Bidirectional blocks hide the request from both listings.
            if blocked_between(db, user_id, other_id):
                continue
            other = db.get(User, other_id)
            items.append({**serialize_request(row, direction),
                          "user_public_ref": other.public_ref if other else None,
                          "pet": public_pet(latest_pet(db, other_id)) if other else None})
        return {"items": items}


def respond_to_request(sessions, user_id: str, request_id: str, accept: bool, hook=None) -> dict:
    now = time.time()
    # Read the immutable pair identifiers in a short transaction, then take the pair lock as the
    # first statement of the mutating transaction (avoids SQLite read->write upgrade deadlocks).
    with sessions() as db:
        row = db.get(ContactRequest, request_id[:32])
        if not row or row.to_user_id != user_id:
            raise HTTPException(404, "contact_request_not_found")
        from_user_id = row.from_user_id
    with sessions() as db:
        _lock_pair(db, user_id, from_user_id, hook)
        row = db.get(ContactRequest, request_id[:32])
        if not row or row.to_user_id != user_id:
            raise HTTPException(404, "contact_request_not_found")
        if blocked_between(db, user_id, row.from_user_id):
            raise HTTPException(403, "blocked")
        if not accept:
            flipped = db.execute(
                update(ContactRequest)
                .where(ContactRequest.id == row.id, ContactRequest.status == "pending")
                .values(status="declined", updated_at=now)
                .execution_options(synchronize_session=False)
            )
            if flipped.rowcount != 1:
                db.rollback()
                current = db.scalar(select(ContactRequest).where(ContactRequest.id == row.id))
                if current is not None and current.status == "declined":
                    return {"request_id": current.id, "status": "declined", "contact_id": None}
                raise HTTPException(409, "contact_request_not_pending")
            db.commit()
            return {"request_id": row.id, "status": "declined", "contact_id": None}
        # Atomic accept: only the caller whose conditional UPDATE hits the still-pending row may
        # create the contact; a racing loser re-reads and returns the same contact id.
        flipped = db.execute(
            update(ContactRequest)
            .where(ContactRequest.id == row.id, ContactRequest.status == "pending")
            .values(status="accepted", updated_at=now)
            .execution_options(synchronize_session=False)
        )
        if flipped.rowcount == 1:
            contact = _create_contact(db, row.from_user_id, row.to_user_id)
            db.commit()
            return {"request_id": row.id, "status": "accepted", "contact_id": contact.id}
        db.rollback()
        current = db.scalar(select(ContactRequest).where(ContactRequest.id == row.id))
        if current is not None and current.status == "accepted":
            contact = _contact_between(db, current.from_user_id, current.to_user_id)
            if contact is None:
                contact = _create_contact(db, current.from_user_id, current.to_user_id)
                db.commit()
            return {"request_id": current.id, "status": "accepted", "contact_id": contact.id}
        raise HTTPException(409, "contact_request_not_pending")


def list_contacts(sessions, user_id: str) -> dict:
    with sessions() as db:
        rows = db.scalars(select(Contact).where(or_(Contact.user_a == user_id, Contact.user_b == user_id))).all()
        items = []
        for row in rows:
            other_id = row.user_b if row.user_a == user_id else row.user_a
            if blocked_between(db, user_id, other_id):
                continue
            other = db.get(User, other_id)
            if not other:
                continue
            items.append({"contact_id": row.id, "user_public_ref": other.public_ref,
                          "pet": public_pet(latest_pet(db, other_id)), "since": row.created_at})
        return {"items": items}


def _require_contact(db, user_id: str, contact_id: str) -> Contact:
    row = db.get(Contact, contact_id[:32])
    if not row or user_id not in (row.user_a, row.user_b):
        raise HTTPException(404, "contact_not_found")
    other_id = row.user_b if row.user_a == user_id else row.user_a
    if blocked_between(db, user_id, other_id):
        raise HTTPException(403, "blocked")
    return row


def send_message(sessions, user_id: str, contact_id: str, body: str, client_id: str,
                 hook=None) -> tuple[dict, bool]:
    body = (body or "").strip()
    if not body or len(body) > 2000:
        raise HTTPException(422, "invalid_message")
    client_id = (client_id or "").strip()
    if not client_id or len(client_id) > 64:
        raise HTTPException(422, "invalid_client_id")
    with sessions() as db:
        contact = db.get(Contact, contact_id[:32])
        if not contact or user_id not in (contact.user_a, contact.user_b):
            raise HTTPException(404, "contact_not_found")
        other_id = contact.user_b if contact.user_a == user_id else contact.user_a
    with sessions() as db:
        _lock_pair(db, user_id, other_id, hook)
        # Re-check membership and the block fact under the pair lock; the insert below is in the
        # same transaction, so add_block cannot commit between this check and the write.
        contact = _require_contact(db, user_id, contact_id)
        existing = db.scalar(select(ContactMessage).where(ContactMessage.contact_id == contact.id, ContactMessage.client_id == client_id))
        if existing:
            if existing.sender_user_id != user_id or existing.body != body:
                raise HTTPException(409, "message_idempotency_conflict")
            return serialize_message(existing, user_id), False
        row = ContactMessage(contact_id=contact.id, sender_user_id=user_id, body=body, client_id=client_id)
        db.add(row)
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            existing = db.scalar(select(ContactMessage).where(ContactMessage.contact_id == contact.id, ContactMessage.client_id == client_id))
            if not existing:
                raise
            return serialize_message(existing, user_id), False
        return serialize_message(row, user_id), True


def serialize_message(row: ContactMessage, viewer_id: str) -> dict:
    return {"message_id": row.id, "contact_id": row.contact_id,
            "sender": "me" if row.sender_user_id == viewer_id else "them",
            "body": row.body, "created_at": row.created_at, "client_id": row.client_id}


def list_messages(sessions, user_id: str, contact_id: str, before: float | None = None,
                  limit: int = 30, before_id: str | None = None) -> dict:
    """Newest-first page with a stable (created_at, id) cursor.

    ``created_at`` alone is not unique, so two messages written in the same tick could repeat or
    be skipped across pages. The cursor is the pair ``(next_before, next_before_id)``; the legacy
    ``before``-only argument remains supported for older clients.
    """
    limit = max(1, min(int(limit), 100))
    with sessions() as db:
        contact = _require_contact(db, user_id, contact_id)
        statement = select(ContactMessage).where(ContactMessage.contact_id == contact.id)
        if before is not None and before_id:
            statement = statement.where(
                or_(
                    ContactMessage.created_at < float(before),
                    (ContactMessage.created_at == float(before)) & (ContactMessage.id < str(before_id)),
                )
            )
        elif before is not None:
            statement = statement.where(ContactMessage.created_at < float(before))
        rows = db.scalars(
            statement.order_by(ContactMessage.created_at.desc(), ContactMessage.id.desc()).limit(limit + 1)
        ).all()
        items = [serialize_message(row, user_id) for row in rows[:limit]]
        has_more = len(rows) > limit
        next_before = rows[limit - 1].created_at if has_more else None
        next_before_id = rows[limit - 1].id if has_more else None
        return {"items": items, "next_before": next_before, "next_before_id": next_before_id}


def add_block(sessions, user_id: str, target_public_ref: str, hook=None) -> dict:
    target = target_user(sessions, target_public_ref)
    if target.id == user_id:
        raise HTTPException(422, "cannot_block_self")
    now = time.time()
    with sessions() as db:
        _lock_pair(db, user_id, target.id, hook)
        try:
            with db.begin_nested():
                db.add(UserBlock(blocker_id=user_id, blocked_id=target.id))
                db.flush()
        except IntegrityError:
            pass  # already blocked: idempotent
        # A block invalidates every pending request between both parties, in both directions.
        db.execute(
            update(ContactRequest)
            .where(
                ContactRequest.status == "pending",
                ContactRequest.from_user_id.in_((user_id, target.id)),
                ContactRequest.to_user_id.in_((user_id, target.id)),
            )
            .values(status="cancelled", updated_at=now)
            .execution_options(synchronize_session=False)
        )
        db.commit()
        return {"blocked": True, "user_public_ref": target.public_ref, "created_at": now}


def remove_block(sessions, user_id: str, target_public_ref: str, hook=None) -> dict:
    with sessions() as db:
        target = db.scalar(select(User).where(User.public_ref == (target_public_ref or "")[:32]))
        if target is None:
            return {"blocked": False, "user_public_ref": None}
        target_id, public_ref = target.id, target.public_ref
    with sessions() as db:
        _lock_pair(db, user_id, target_id, hook)
        existing = db.get(UserBlock, (user_id, target_id))
        if existing:
            db.delete(existing)
            db.commit()
        return {"blocked": False, "user_public_ref": public_ref}


def list_blocks(sessions, user_id: str) -> dict:
    with sessions() as db:
        rows = db.scalars(select(UserBlock).where(UserBlock.blocker_id == user_id)).all()
        refs = []
        for row in rows:
            user = db.get(User, row.blocked_id)
            refs.append({"user_public_ref": user.public_ref if user else None, "created_at": row.created_at})
        return {"items": refs}
