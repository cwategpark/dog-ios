#!/usr/bin/env python3
"""Seed reproducible UI-QA fixtures into the isolated loopback development backend.

Safety:
- refuses to run unless WAGELPAW_ENVIRONMENT is development/test and the base URL is loopback;
- talks to the running dev server over HTTP for questionnaire -> guest OTP claim -> mobile OTP;
- only creates the three dedicated @example.test QA accounts;
- uses repo sample images and one generated minimal-GLB test model (never private orphan images,
  real SMTP, paid providers, or production data);
- is re-entrant: existing pets/assets/contacts/pending requests/messages are detected and reused;
- never prints access/refresh tokens or OTP codes.

Run:
    backend/.venv/bin/python scripts/seed_ui_fixtures.py
    scripts/run_ui_backend.sh status
"""
from __future__ import annotations

import hashlib
import json
import os
import struct
import sys
import time
from pathlib import Path
from typing import Any

import httpx

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
WORK = Path(os.environ.get("WAGELPAW_UI_WORKDIR", ROOT / "var" / "ui-backend"))
ENV_FILE = WORK / "ui.env"
BASE = os.environ.get("WAGELPAW_UI_URL", "http://127.0.0.1:18766")

OWNER = "ios-ui-owner@example.test"
NEIGHBOR = "ios-ui-neighbor@example.test"
FRIEND = "ios-ui-friend@example.test"
SAMPLE_PHOTOS = [
    (ROOT / "ios" / "PawlyDemo" / "Resources" / "Samples" / "photo-dog.jpg", "image/jpeg"),
    (ROOT / "ios" / "PawlyDemo" / "Resources" / "Samples" / "photo-cat.jpg", "image/jpeg"),
]
QA_REGION = {"lat": 22.543096, "lon": 114.057865, "label": "UI QA same coarse grid"}


def load_env() -> dict[str, str]:
    if not ENV_FILE.exists():
        raise SystemExit(f"missing {ENV_FILE}; run scripts/run_ui_backend.sh start first")
    values: dict[str, str] = {}
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key] = value
    if values.get("WAGELPAW_ENVIRONMENT") not in ("development", "test"):
        raise SystemExit("refusing: fixture seed is development/test only")
    if not BASE.startswith("http://127.0.0.1:"):
        raise SystemExit("refusing: fixtures may only be seeded on a loopback dev server")
    return values


class Api:
    def __init__(self, env: dict[str, str]) -> None:
        self.client = httpx.Client(base_url=BASE, timeout=30.0)
        self.dev = {"Authorization": "Bearer " + env["WAGELPAW_DEV_TOKEN"]}
        self.shop = env.get("WAGELPAW_SHOPIFY_STORE_DOMAIN", "ui-qa.myshopify.com")

    def close(self) -> None:
        self.client.close()

    def req(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        response = self.client.request(method, path, **kwargs)
        if response.status_code >= 400:
            raise RuntimeError(f"{method} {path} -> {response.status_code}: {response.text[:300]}")
        return response

    def otp_login(self, email: str) -> dict[str, Any]:
        start = self.req("POST", "/mobile/v1/auth/email/start", json={"email": email}).json()
        verify = self.req("POST", "/mobile/v1/auth/email/verify",
                          json={"challenge_id": start["challenge_id"], "code": start["dev_code"]}).json()
        return {"Authorization": "Bearer " + verify["access_token"]}, verify

    def me(self, headers: dict[str, str]) -> dict[str, Any]:
        return self.req("GET", "/mobile/v1/me", headers=headers).json()

    def pets(self, headers: dict[str, str]) -> list[dict[str, Any]]:
        return self.req("GET", "/mobile/v1/pets", headers=headers).json()["pets"]

    def assets(self, headers: dict[str, str]) -> list[dict[str, Any]]:
        return self.req("GET", "/mobile/v1/assets?limit=50", headers=headers).json()["items"]

    def website_claim(self, email: str, full_name: str, profile: dict[str, Any],
                      uploads: list[tuple[Path, str]]) -> str:
        session = self.req("POST", "/v1/sessions", headers=self.dev,
                           json={"profile": profile, "consent": True, "email": email,
                                 "full_name": full_name}).json()
        guest = {**self.dev, "X-Wagelpaw-Session": session["session_token"]}
        for path, content_type in uploads:
            with path.open("rb") as handle:
                self.req("POST", "/v1/uploads", headers=guest,
                         files={"file": (path.name, handle.read(), content_type)})
        challenge = self.req("POST", "/v1/claims", headers=guest, json={"email": email}).json()
        verified = self.req("POST", f"/v1/claims/{challenge['challenge_id']}/verify",
                            headers=guest, json={"code": challenge["dev_code"]}).json()
        if not verified.get("claimed"):
            raise RuntimeError("website claim did not complete")
        return verified["claimed_session_ids"][0]

    def ensure_owner(self) -> tuple[dict[str, str], dict[str, Any]]:
        headers, _ = self.otp_login(OWNER)
        pets = self.pets(headers)
        photos = [item for item in self.assets(headers) if item.get("kind") == "photo"]
        if not pets or len(photos) < len(SAMPLE_PHOTOS):
            missing = SAMPLE_PHOTOS[len(photos):] if pets else SAMPLE_PHOTOS
            profile = {"type": "dog", "age_months": 26, "dog_size": "large",
                       "name": "UI Golden", "breed": "Golden Retriever"}
            self.website_claim(OWNER, "UI QA Owner", profile, missing)
            headers, _ = self.otp_login(OWNER)
        return headers, self.me(headers)

    def ensure_basic_profile(self, email: str, full_name: str, profile: dict[str, Any]) -> tuple[dict[str, str], dict[str, Any]]:
        headers, _ = self.otp_login(email)
        if not self.pets(headers):
            self.website_claim(email, full_name, profile, [])
            headers, _ = self.otp_login(email)
        return headers, self.me(headers)

    def set_discovery(self, headers: dict[str, str]) -> dict[str, Any]:
        return self.req("POST", "/mobile/v1/discovery", headers=headers,
                        json={"enabled": True, "region": QA_REGION, "radius_km": 5}).json()

    def ensure_accepted_contact(self, owner_headers: dict[str, str], owner_me: dict[str, Any],
                                neighbor_headers: dict[str, str], neighbor_me: dict[str, Any]) -> str | None:
        neighbor_ref = neighbor_me["public_ref"]
        contacts = self.req("GET", "/mobile/v1/contacts", headers=owner_headers).json()["items"]
        for item in contacts:
            if item.get("user_public_ref") == neighbor_ref:
                return item["contact_id"]
        outgoing = self.req("GET", "/mobile/v1/contacts/requests?direction=outgoing", headers=owner_headers).json()["items"]
        pending = next((item for item in outgoing if item.get("user_public_ref") == neighbor_ref and item.get("status") == "pending"), None)
        if pending is None:
            self.req("POST", "/mobile/v1/contacts/requests", headers=owner_headers,
                     json={"target_public_ref": neighbor_ref, "message": "UI QA accepted neighbour"})
        incoming = self.req("GET", "/mobile/v1/contacts/requests?direction=incoming", headers=neighbor_headers).json()["items"]
        request = next((item for item in incoming if item.get("user_public_ref") == owner_me["public_ref"] and item.get("status") == "pending"), None)
        if request is not None:
            self.req("POST", f"/mobile/v1/contacts/requests/{request['request_id']}/accept", headers=neighbor_headers)
        contacts = self.req("GET", "/mobile/v1/contacts", headers=owner_headers).json()["items"]
        for item in contacts:
            if item.get("user_public_ref") == neighbor_ref:
                return item["contact_id"]
        return None

    def ensure_pending_request(self, owner_headers: dict[str, str], owner_me: dict[str, Any],
                               friend_headers: dict[str, str], friend_me: dict[str, Any]) -> str | None:
        owner_ref, friend_ref = owner_me["public_ref"], friend_me["public_ref"]
        contacts = self.req("GET", "/mobile/v1/contacts", headers=owner_headers).json()["items"]
        if any(item.get("user_public_ref") == friend_ref for item in contacts):
            return None
        incoming = self.req("GET", "/mobile/v1/contacts/requests?direction=incoming", headers=owner_headers).json()["items"]
        pending = next((item for item in incoming if item.get("user_public_ref") == friend_ref and item.get("status") == "pending"), None)
        if pending is not None:
            return pending["request_id"]
        self.req("POST", "/mobile/v1/contacts/requests", headers=friend_headers,
                 json={"target_public_ref": owner_ref, "message": "UI QA pending friend request"})
        incoming = self.req("GET", "/mobile/v1/contacts/requests?direction=incoming", headers=owner_headers).json()["items"]
        pending = next((item for item in incoming if item.get("user_public_ref") == friend_ref and item.get("status") == "pending"), None)
        return pending["request_id"] if pending else None

    def ensure_messages(self, owner_headers: dict[str, str], neighbor_headers: dict[str, str],
                        contact_id: str | None) -> int:
        if not contact_id:
            return 0
        existing = self.req("GET", f"/mobile/v1/messages?contact_id={contact_id}", headers=owner_headers).json()["items"]
        if existing:
            return len(existing)
        self.req("POST", "/mobile/v1/messages", headers=owner_headers,
                 json={"contact_id": contact_id, "body": "Hi from the UI QA owner", "client_id": "ui-fixture-msg-owner-1"})
        self.req("POST", "/mobile/v1/messages", headers=neighbor_headers,
                 json={"contact_id": contact_id, "body": "Hi from the UI QA neighbour", "client_id": "ui-fixture-msg-neighbor-1"})
        return len(self.req("GET", f"/mobile/v1/messages?contact_id={contact_id}", headers=owner_headers).json()["items"])


def _minimal_glb() -> bytes:
    """A valid minimal glTF 2.0 binary container (one empty node), for UI fixture purposes."""
    body = {
        "asset": {"version": "2.0", "generator": "dog-ios-ui-qa-fixture"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "UI QA fixture pet"}],
    }
    raw = json.dumps(body, separators=(",", ":")).encode("utf-8")
    raw += b" " * ((4 - len(raw) % 4) % 4)
    total = 12 + 8 + len(raw)
    return b"glTF" + struct.pack("<II", 2, total) + struct.pack("<II", len(raw), 0x4E4F534A) + raw


def seed_model_asset(env: dict[str, str], owner_email: str) -> dict[str, Any] | None:
    """Test-fixture model archive through the real storage/archive code (no paid provider).

    Run only inside this dev DB. If a model already exists for the owner it is reused.
    """
    sys.path.insert(0, str(BACKEND))
    os.environ.update(env)
    from sqlalchemy import select

    from app import assets as asset_service
    from app.config import Settings
    from app.db import make_engine, session_factory
    from app.models import AssetArchive, GuestSession, GuestSessionPet, Job, Pet, User
    from app.storage import PrivateStorage

    settings = Settings()
    engine = make_engine(settings.database_url)
    sessions = session_factory(engine)
    try:
        with sessions() as db:
            user = db.scalar(select(User).where(User.email_normalized == owner_email))
            if user is None:
                raise RuntimeError("owner user missing after website claim")
            existing = db.scalar(select(AssetArchive).where(
                AssetArchive.user_id == user.id, AssetArchive.kind == "model"))
            if existing is not None:
                return {"asset_id": existing.id, "reused": True}
            guest = db.scalar(select(GuestSession).where(GuestSession.user_id == user.id,
                                                         GuestSession.claimed_at.is_not(None)).order_by(GuestSession.claimed_at.desc()))
            mapping = db.scalar(select(GuestSessionPet).where(GuestSessionPet.user_id == user.id))
            pet = db.get(Pet, mapping.pet_id) if mapping else None
            if guest is None or pet is None:
                raise RuntimeError("owner has no claimed guest session/pet mapping for model fixture")
            job = Job(shop=settings.local_shop, owner_id=guest.id, kind="cat-fitting", input={},
                      input_hash="ui-qa-fixture-model", idempotency_key=f"ui-fixture-model-{user.id[:16]}-{int(time.time())}",
                      status="succeeded")
            db.add(job)
            db.flush()
            job_id = job.id
            db.commit()
        storage = PrivateStorage(settings, sessions, guest.id, settings.local_shop, job_id)
        stored = storage.save_output(_minimal_glb(), "model/gltf-binary", "ui-fixture-pet.glb")
        with sessions() as db:
            row = db.get(Job, job_id)
            row.result = {"assets": [{**stored, "role": "model"}], "ui_qa_fixture": True}
            db.commit()
        records = asset_service.archive_job_result(sessions, settings, job_id)
        model = next((record for record in records if record.get("kind") == "model"), None)
        if not model:
            raise RuntimeError("model fixture archive did not produce a model asset")
        return {"asset_id": model["asset_id"], "reused": False, "pet_id": model.get("pet_id")}
    finally:
        engine.dispose()


def write_manifest(summary: dict[str, Any]) -> Path:
    path = WORK / "fixtures.json"
    path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    path.chmod(0o600)
    return path


def main() -> int:
    env = load_env()
    api = Api(env)
    try:
        health = api.req("GET", "/healthz").json()
        if health.get("environment") not in ("development", "test"):
            raise SystemExit("refusing: server is not a development/test instance")
        owner_headers, owner_me = api.ensure_owner()
        neighbor_headers, neighbor_me = api.ensure_basic_profile(
            NEIGHBOR, "UI QA Neighbour",
            {"type": "cat", "age_months": 14, "name": "UI Neighbor Cat"})
        friend_headers, friend_me = api.ensure_basic_profile(
            FRIEND, "UI QA Friend",
            {"type": "dog", "age_months": 18, "dog_size": "small", "name": "UI Friend Dog"})

        for headers in (owner_headers, neighbor_headers, friend_headers):
            api.set_discovery(headers)

        contact_id = api.ensure_accepted_contact(owner_headers, owner_me, neighbor_headers, neighbor_me)
        pending_id = api.ensure_pending_request(owner_headers, owner_me, friend_headers, friend_me)
        message_count = api.ensure_messages(owner_headers, neighbor_headers, contact_id)
        model = seed_model_asset(env, OWNER)

        owner_headers, _ = api.otp_login(OWNER)
        assets = api.assets(owner_headers)
        pets = api.pets(owner_headers)
        pet_home = api.req("GET", f"/mobile/v1/pet-home?pet_id={pets[0]['pet_id']}", headers=owner_headers).json() if pets else {}
        nearby = api.req("GET", "/mobile/v1/nearby?radius_km=5", headers=owner_headers).json()
        downloads_ok = 0
        for item in assets:
            download = api.client.get(item["download_url"], headers=owner_headers)
            if download.status_code != 200 or not download.content:
                raise RuntimeError(f"fixture asset download failed: {item.get('asset_id')} -> {download.status_code}")
            downloads_ok += 1
        golden = api.client.get("/public-assets/website-golden-master.glb")
        golden_sha = hashlib.sha256(golden.content).hexdigest()
        outbox_path = Path(env.get("WAGELPAW_EMAIL_OUTBOX_PATH", ""))
        outbox_entries = len(outbox_path.read_text().splitlines()) if outbox_path.is_file() else 0

        summary = {
            "generated_at": time.strftime("%Y-%m-%d %H:%M:%S %z"),
            "purpose": "isolated development backend fixtures for SwiftUI UI QA only",
            "base_url": BASE,
            "environment": health.get("environment"),
            "users": {
                "owner": {"email": OWNER, "full_name": owner_me.get("full_name"),
                          "pet_id": pets[0]["pet_id"] if pets else None,
                          "pet_name": pets[0].get("name") if pets else None},
                "neighbor": {"email": NEIGHBOR, "full_name": neighbor_me.get("full_name")},
                "friend": {"email": FRIEND, "full_name": friend_me.get("full_name")},
            },
            "assets": {
                "count": len(assets),
                "kinds": sorted({item.get("kind") for item in assets}),
                "model_asset_id": model["asset_id"] if model else None,
                "model_reused": model.get("reused") if model else None,
                "downloads_ok": downloads_ok,
            },
            "pet_home": {"selected": pet_home.get("selected"),
                         "personal_format": (pet_home.get("personal_model") or {}).get("format")},
            "discovery": {"grid": QA_REGION, "nearby_count": len(nearby.get("items", [])),
                          "nearby_refs": [item.get("public_ref") for item in nearby.get("items", [])]},
            "contacts": {"accepted_contact_id": contact_id, "pending_request_id": pending_id,
                         "message_count": message_count},
            "golden": {"status": golden.status_code, "bytes": len(golden.content), "sha256": golden_sha},
            "dev_outbox_entries": outbox_entries,
            "notes": [
                "All accounts/assets are synthetic UI-QA fixtures; emails use example.test.",
                "Model asset is a generated minimal GLB test fixture, not a paid provider result.",
                "Mobile login must use the OTP endpoints; no token is injected into the app.",
                "Private WordPress orphan images were not read or copied.",
            ],
        }
        manifest = write_manifest(summary)
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        print(f"manifest={manifest}")
        return 0
    finally:
        api.close()


if __name__ == "__main__":
    raise SystemExit(main())
