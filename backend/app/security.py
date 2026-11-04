import base64
import hashlib
import hmac
import ipaddress
import re
import secrets
import time
from collections import defaultdict
from dataclasses import dataclass

from fastapi import HTTPException, Request
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError

from .models import GuestSession, RateWindow


@dataclass(frozen=True)
class Actor:
    owner_id: str
    shop: str


def digest_token(token: str):
    return hashlib.sha256(token.encode()).hexdigest()


def verify_proxy(request: Request, settings) -> str:
    values = defaultdict(list)
    for key, value in request.query_params.multi_items():
        values[key].append(value)
    signatures = values.pop("signature", [])
    secret = settings.shopify_api_secret.get_secret_value()
    if not secret or len(signatures) != 1:
        raise HTTPException(401, "valid_proxy_signature_required")
    for key in ("shop", "timestamp", "logged_in_customer_id"):
        if len(values.get(key, [])) > 1:
            raise HTTPException(401, "ambiguous_proxy_parameter")
    message = "".join(sorted(f"{key}={','.join(items)}" for key, items in values.items()))
    expected = hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signatures[0], expected):
        raise HTTPException(401, "invalid_proxy_signature")
    shop = values.get("shop", [""])[0].lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.myshopify\.com", shop) or shop not in settings.allowed_shops:
        raise HTTPException(403, "shop_not_allowed")
    try:
        timestamp = int(values.get("timestamp", [""])[0])
    except ValueError as error:
        raise HTTPException(401, "invalid_proxy_timestamp") from error
    age = time.time() - timestamp
    if age < -60 or age > settings.proxy_timestamp_tolerance_seconds:
        raise HTTPException(401, "expired_proxy_signature")
    return shop


def source_shop(request: Request) -> str:
    settings = request.app.state.settings
    authorization = request.headers.get("authorization", "")
    dev_secret = settings.dev_token.get_secret_value()
    if settings.environment in ("development", "test") and dev_secret:
        if hmac.compare_digest(authorization, "Bearer " + dev_secret):
            return settings.local_shop
    return verify_proxy(request, settings)


def authenticated_actor(request: Request) -> Actor:
    shop = source_shop(request)
    token = request.headers.get("x-wagelpaw-session", "")
    if not 32 <= len(token) <= 180:
        raise HTTPException(401, "questionnaire_session_required")
    with request.app.state.sessions() as db:
        session = db.scalar(select(GuestSession).where(GuestSession.token_hash == digest_token(token)))
        if not session or session.shop != shop or session.expires_at <= time.time():
            raise HTTPException(401, "session_expired_or_invalid")
        return Actor(session.id, shop)


def verify_webhook(body: bytes, signature: str, shop: str, settings):
    secret = settings.shopify_api_secret.get_secret_value()
    if not secret:
        raise HTTPException(503, "shopify_not_configured")
    expected = base64.b64encode(hmac.new(secret.encode(), body, hashlib.sha256).digest()).decode()
    if not hmac.compare_digest(signature, expected):
        raise HTTPException(401, "invalid_webhook_signature")
    if shop not in settings.allowed_shops or not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.myshopify\.com", shop):
        raise HTTPException(403, "shop_not_allowed")


def client_ip(request: Request):
    peer = request.client.host if request.client else "unknown"
    if peer in request.app.state.settings.trusted_proxy_ips:
        forwarded = request.headers.get("x-forwarded-for", "")
        if forwarded:
            chain = [item.strip() for item in forwarded.split(",")]
            hops = request.app.state.settings.trusted_proxy_hops
            if len(chain) >= hops:
                try:
                    peer = str(ipaddress.ip_address(chain[-hops]))
                except ValueError:
                    pass
    return peer


def limit_session_creation(request: Request, shop: str):
    settings = request.app.state.settings
    hour = int(time.time() // 3600)
    ip_hash = anonymous_ip_hash(request)
    key = f"session:{hour}:{ip_hash}:{hashlib.sha256(shop.encode()).hexdigest()[:12]}"
    with request.app.state.sessions() as db:
        try:
            with db.begin_nested():
                db.add(RateWindow(key=key, count=0, expires_at=(hour + 1) * 3600))
                db.flush()
        except IntegrityError:
            pass
        result = db.execute(update(RateWindow).where(RateWindow.key == key, RateWindow.count < settings.sessions_per_ip_hour).values(count=RateWindow.count + 1))
        if result.rowcount != 1:
            raise HTTPException(429, "session_rate_limit")
        db.commit()


def anonymous_ip_hash(request: Request):
    settings = request.app.state.settings
    salt = settings.rate_limit_salt.get_secret_value() or settings.dev_token.get_secret_value()
    return hmac.new(salt.encode(), client_ip(request).encode(), hashlib.sha256).hexdigest()


def create_guest_token():
    token = secrets.token_urlsafe(48)
    return token, digest_token(token)
