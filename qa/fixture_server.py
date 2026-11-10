#!/usr/bin/env python3
"""Explicit localhost-only UI TEST STUB. Never connects to the real website.

Run on the Mac hosting the simulator:
  python3 qa/fixture_server.py --project-root /path/to/dog-ios/project --work-dir /tmp/dogios-account-sync-qa
The app consumes the generated private login file through its existing DEBUG
simulator InMemoryTokenStore path. No Keychain or real customer data is used.
"""
from __future__ import annotations

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import struct
import threading
import time
from urllib.parse import parse_qs, urlsplit
import zlib


HOST, PORT = "127.0.0.1", 18786
USER_ID, PET_ONE, PET_TWO = "e" * 32, "a" * 32, "b" * 32
PHOTO_ID, MODEL_ID, TRYON_ID, GENERATED_ID = (digit * 32 for digit in "1234")
PRIVATE_BASENAME = ".pet-model-ui-token.private.json"
NOTICE = "ISOLATED UI TEST STUB; all account, pet and shipment records are synthetic."


def small_png() -> bytes:
    """Small deterministic RGB test image, generated without third-party packages."""
    edge = 96
    rows = bytearray()
    for y in range(edge):
        rows.append(0)
        for x in range(edge):
            spot = (x - 48) ** 2 + (y - 51) ** 2 < 22 ** 2
            rows.extend((63, 101, 79) if spot else (236, 224, 198))
    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", edge, edge, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b"")


def pets():
    return [{"pet_id": PET_ONE, "name": "团子", "species": "dog", "breed": "Golden Retriever",
             "pet_information": {"pet_name": "团子", "type": "dog", "breed": "Golden Retriever"}},
            {"pet_id": PET_TWO, "name": "麻薯", "species": "cat", "breed": "Ragdoll",
             "pet_information": {"pet_name": "麻薯", "type": "cat", "breed": "Ragdoll"}}]


class FixtureState:
    def __init__(self, project_root: Path, work_dir: Path):
        model_path = project_root / "public-assets" / "website-golden-master.glb"
        self.model = model_path.read_bytes()
        if len(self.model) < 12 or self.model[:8] != b"glTF\x02\x00\x00\x00" or struct.unpack("<I", self.model[8:12])[0] != len(self.model):
            raise ValueError("The fixture requires the existing valid website-golden-master.glb asset")
        self.model_sha = hashlib.sha256(self.model).hexdigest()
        self.photo = small_png()
        self.work_dir = work_dir.resolve()
        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.sessions = {}
        self.lock = threading.Lock()

    def reset(self, case):
        token, refresh = secrets.token_hex(32), secrets.token_hex(32)
        now = time.time()
        # Unique directories avoid replacing a file while an earlier simulator
        # process is consuming it; the exact basename is checked by MobileAppStore.
        run_dir = self.work_dir / ("run-" + secrets.token_hex(12))
        run_dir.mkdir(mode=0o700)
        fixture_path = run_dir / PRIVATE_BASENAME
        bundle = {"user_id": USER_ID, "email": "ui-fixture@example.invalid", "email_verified_at": now,
                  "access_token": token, "refresh_token": refresh,
                  "access_expires_at": now + 3600, "refresh_expires_at": now + 7200,
                  "claimed_session_ids": []}
        descriptor = os.open(str(fixture_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(bundle, stream, separators=(",", ":"))
        with self.lock:
            self.sessions[token] = {"case": case, "created_at": now}
        return {"fixture_path": str(fixture_path), "case": case, "notice": NOTICE}

    def session(self, authorization):
        if not isinstance(authorization, str) or not authorization.startswith("Bearer "):
            return None
        with self.lock:
            value = self.sessions.get(authorization[7:])
            return value if value and value["created_at"] + 3600 > time.time() else None

    def assets(self):
        now = time.time()
        def asset(asset_id, kind, role, data, mime, fmt, source=None, job=None):
            return {"asset_id": asset_id, "pet_id": PET_ONE, "kind": kind, "kind_role": role,
                    "format": fmt, "mime": mime, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                    "created_at": now, "source": source, "source_job_id": job,
                    "download_url": f"/mobile/v1/assets/{asset_id}/download", "is_reference_model": False}
        return [asset(PHOTO_ID, "photo", "upload", self.photo, "image/png", "png"),
                asset(MODEL_ID, "model", "generated", self.model, "model/gltf-binary", "glb", "text-generated", "synthetic-text-job"),
                asset(TRYON_ID, "tryon", "generated", self.photo, "image/png", "png", "tryon", "synthetic-tryon-job"),
                asset(GENERATED_ID, "photo", "generated", self.photo, "image/png", "png", "photo-generated", "synthetic-photo-job")]

    def home(self, pet_id):
        return {"pet_id": pet_id or PET_ONE, "manifest_version": 1, "selected": "personal", "fallback_reason": None,
                "default_model": {"role": "default", "static": True, "is_default": True, "format": "glb",
                                  "mime": "model/gltf-binary", "bytes": len(self.model), "sha256": self.model_sha,
                                  "url": "/public-assets/website-golden-master.glb", "source": "website-reference"},
                "personal_model": {"asset_id": MODEL_ID, "role": "personal", "static": True, "is_default": False,
                                   "format": "glb", "mime": "model/gltf-binary", "bytes": len(self.model),
                                   "sha256": self.model_sha, "url": f"/mobile/v1/assets/{MODEL_ID}/download",
                                   "source": "text-generated", "source_job_id": "synthetic-text-job", "is_reference_model": False}}


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "DogiosIsolatedUITestFixture/1"
    sys_version = ""

    def log_message(self, *_args):
        pass  # Never log Authorization, fixture file contents or synthetic token values.

    @property
    def state(self):
        return self.server.fixture_state

    def send(self, status, value=None, mime="application/json"):
        payload = (json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                   if mime == "application/json" else value or b"")
        if status == 204:
            payload = b""
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store, private")
        self.send_header("X-Dogios-Fixture", "synthetic-test-stub")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def do_POST(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/fixture/reset":
            query = parse_qs(parsed.query, keep_blank_values=True)
            case = query.get("case", ["normal"])
            if set(query) - {"case"} or len(case) != 1 or case[0] not in {"normal", "empty", "unavailable"}:
                return self.send(422, {"detail": "invalid_fixture_case"})
            return self.send(200, self.state.reset(case[0]))
        if parsed.path == "/mobile/v1/auth/logout" and self.state.session(self.headers.get("Authorization")):
            return self.send(204)
        return self.send(404, {"detail": "fixture_route_not_found"})

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urlsplit(self.path)
        path, query = parsed.path, parse_qs(parsed.query)
        if path == "/fixture/health":
            return self.send(200, {"notice": NOTICE})
        if path == "/public-assets/website-golden-master.glb":
            return self.send(200, self.state.model, "model/gltf-binary")
        session = self.state.session(self.headers.get("Authorization"))
        if not session:
            return self.send(401, {"detail": "mobile_token_invalid_or_expired"})
        if path == "/mobile/v1/me":
            return self.send(200, {"user_id": USER_ID, "public_ref": "synthetic_fixture_user", "email": "ui-fixture@example.invalid",
                                   "full_name": "隔离测试账号", "email_verified_at": time.time(), "pets": pets()})
        if path == "/mobile/v1/social-profile":
            return self.send(200, {"user_id": USER_ID, "display_name": "隔离测试家长", "profile_completed": True,
                                   "missing": [], "default_avatar_keys": ["paw", "dog", "cat", "leaf"],
                                   "avatar": {"kind": "default", "default_key": "paw", "public_key": "default:paw", "available": True}})
        if path == "/mobile/v1/pets":
            return self.send(200, {"pets": pets()})
        if path == "/mobile/v1/pet-home":
            pet_id = query.get("pet_id", [None])[0]
            if pet_id not in {None, PET_ONE, PET_TWO}:
                return self.send(404, {"detail": "pet_not_found"})
            return self.send(200, self.state.home(pet_id))
        if path == "/mobile/v1/assets":
            rows = self.state.assets()
            if query.get("kind"):
                rows = [row for row in rows if row["kind"] == query["kind"][0]]
            if query.get("pet_id"):
                rows = [row for row in rows if row["pet_id"] == query["pet_id"][0]]
            return self.send(200, {"items": rows, "next_cursor": None})
        match = re.fullmatch(r"/mobile/v1/assets/([a-f0-9]{32})/(download|manifest)", path)
        if match:
            row = next((item for item in self.state.assets() if item["asset_id"] == match[1]), None)
            if row is None:
                return self.send(404, {"detail": "asset_not_found"})
            if match[2] == "manifest":
                return self.send(200, {**row, "available": True})
            return self.send(200, self.state.model if match[1] == MODEL_ID else self.state.photo, row["mime"])
        if path == "/mobile/v1/models":
            return self.send(200, {"items": []})
        if path == "/mobile/v1/orders/logistics":
            if session["case"] == "unavailable":
                return self.send(503, {"detail": "logistics_not_configured"})
            if session["case"] == "empty":
                return self.send(200, {"items": [], "next_cursor": None})
            shipments = [{"id": f"fixture-shipment-{index}", "status": status,
                          "updated_at": "2026-11-10T02:00:00Z", "tracking": [{"company": "测试承运商",
                          "number": number, "url": f"https://tracking.example.invalid/{number}"}]}
                         for index, status, number in [(1, "IN_TRANSIT", "FIXTURE-TRACK-001"), (2, "DELIVERED", "FIXTURE-TRACK-002")]]
            return self.send(200, {"items": [{"id": "fixture-order-1", "name": "#FIXTURE-1001",
                                   "processed_at": "2026-11-10T00:00:00Z", "status": "PARTIALLY_FULFILLED",
                                   "items": [{"title": "隔离测试宠物玩具", "quantity": 2, "image_url": None}],
                                   "shipments": shipments}], "next_cursor": None})
        if path == "/mobile/v1/discovery":
            return self.send(200, {"enabled": False})
        if path in {"/mobile/v1/contacts", "/mobile/v1/contacts/requests", "/mobile/v1/blocks"}:
            return self.send(200, {"items": []})
        return self.send(404, {"detail": "fixture_route_not_found"})


def main():
    parser = argparse.ArgumentParser(description=NOTICE)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parent.parent / "project")
    parser.add_argument("--work-dir", type=Path, required=True, help="Private throwaway fixture directory on the Mac")
    args = parser.parse_args()
    server = ThreadingHTTPServer((HOST, PORT), FixtureHandler)
    server.fixture_state = FixtureState(args.project_root.resolve(), args.work_dir)
    print(f"{NOTICE}\nListening on http://{HOST}:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
