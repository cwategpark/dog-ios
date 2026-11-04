"""Start a real uvicorn process on loopback and exercise the whole demo over HTTP.

This is not a replacement for pytest unit/integration coverage: it proves the ASGI app,
Alembic migrations, private storage and the mobile/website claim flow work in a real
multi-process HTTP deployment (still bound to 127.0.0.1 only).
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx

REPO = Path(__file__).resolve().parents[1]
BACKEND = REPO / "backend"


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def wait_ready(base_url, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            response = httpx.get(f"{base_url}/healthz", timeout=2)
            if response.status_code == 200:
                return True
        except httpx.HTTPError:
            pass
        time.sleep(0.3)
    return False


def main():
    work = Path(tempfile.mkdtemp(prefix="dogios-live-"))
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    env = os.environ.copy()
    env.update({
        "WAGELPAW_ENVIRONMENT": "test",
        "WAGELPAW_DATABASE_URL": f"sqlite:///{work / 'live.db'}",
        "WAGELPAW_STORAGE_PATH": str(work / "media"),
        "WAGELPAW_DEV_TOKEN": "live-smoke-token",
        "WAGELPAW_RATE_LIMIT_SALT": "live-smoke-salt",
        "WAGELPAW_ALLOWED_SHOPS": '["example.myshopify.com"]',
        "WAGELPAW_SHOPIFY_API_SECRET": "live-shopify-secret",
        "WAGELPAW_SESSIONS_PER_IP_HOUR": "100",
        "WAGELPAW_OTP_PER_EMAIL_HOUR": "100",
        "WAGELPAW_OTP_PER_IP_HOUR": "100",
        "WAGELPAW_OTP_RESEND_COOLDOWN_SECONDS": "0",
        "WAGELPAW_DEV_EMAIL_OUTBOX": "1",
        "WAGELPAW_EXPOSE_DEV_OTP": "1",
        "WAGELPAW_EMAIL_OUTBOX_PATH": str(work / "outbox.jsonl"),
        "WAGELPAW_PUBLIC_BASE_URL": base,
        "WAGELPAW_PUBLIC_ASSETS_DIR": str(REPO / "public-assets"),
    })
    log = open(work / "uvicorn.log", "w", encoding="utf-8")
    process = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", str(port)],
        cwd=BACKEND, env=env, stdout=log, stderr=subprocess.STDOUT,
    )
    summary = {}
    try:
        if not wait_ready(base):
            raise SystemExit("server did not become ready")
        dev = {"Authorization": "Bearer live-smoke-token"}
        session = httpx.post(f"{base}/v1/sessions", headers=dev, json={
            "profile": {"type": "dog", "age_months": 18, "dog_size": "large", "name": "直播金毛"},
            "consent": True, "email": "live@example.com", "full_name": "Live Tester",
        }, timeout=10)
        session.raise_for_status()
        session_data = session.json()
        summary["session_created"] = bool(session_data["session_token"])

        png = b"\x89PNG\r\n\x1a\n"  # placeholder; backend re-encodes real PNGs
        from PIL import Image
        import io
        buffer = io.BytesIO()
        Image.new("RGB", (16, 16), "orange").save(buffer, "PNG")
        upload = httpx.post(f"{base}/v1/uploads", headers={**dev, "X-Wagelpaw-Session": session_data["session_token"]},
                            files={"file": ("live.png", buffer.getvalue(), "image/png")}, timeout=20)
        upload.raise_for_status()
        summary["upload_id"] = upload.json()["id"]

        claim = httpx.post(f"{base}/v1/claims", headers={**dev, "X-Wagelpaw-Session": session_data["session_token"]},
                           json={"email": "live@example.com"}, timeout=10)
        claim.raise_for_status()
        claim_data = claim.json()
        verified = httpx.post(f"{base}/v1/claims/{claim_data['challenge_id']}/verify",
                              headers={**dev, "X-Wagelpaw-Session": session_data["session_token"]},
                              json={"code": claim_data["dev_code"]}, timeout=10)
        verified.raise_for_status()
        summary["claimed_session_ids"] = verified.json()["claimed_session_ids"]

        start = httpx.post(f"{base}/mobile/v1/auth/email/start", json={"email": "live@example.com"}, timeout=10)
        start.raise_for_status()
        otp = httpx.post(f"{base}/mobile/v1/auth/email/verify",
                         json={"challenge_id": start.json()["challenge_id"], "code": start.json()["dev_code"]}, timeout=10)
        otp.raise_for_status()
        mobile = {"Authorization": f"Bearer {otp.json()['access_token']}"}
        me = httpx.get(f"{base}/mobile/v1/me", headers=mobile, timeout=10)
        me.raise_for_status()
        summary["me_pets"] = [pet["name"] for pet in me.json()["pets"]]
        assets = httpx.get(f"{base}/mobile/v1/assets", headers=mobile, timeout=10)
        assets.raise_for_status()
        summary["asset_count"] = len(assets.json()["items"])
        first = assets.json()["items"][0]
        downloaded = httpx.get(f"{base}{first['download_url']}", headers=mobile, timeout=20)
        downloaded.raise_for_status()
        summary["downloaded_bytes"] = len(downloaded.content)
        home = httpx.get(f"{base}/mobile/v1/pet-home", headers=mobile, timeout=10)
        home.raise_for_status()
        default_model = home.json()["default_model"]
        summary["default_model"] = {key: default_model[key] for key in ("format", "bytes", "sha256", "static")}
        golden = httpx.get(f"{base}/public-assets/website-golden-master.glb", timeout=60)
        golden.raise_for_status()
        summary["golden_bytes"] = len(golden.content)
        summary["golden_gltf"] = golden.content[:4].decode()
        discovery = httpx.post(f"{base}/mobile/v1/discovery", headers=mobile,
                               json={"enabled": True, "region": {"lat": 31.23, "lon": 121.47}}, timeout=10)
        discovery.raise_for_status()
        nearby = httpx.get(f"{base}/mobile/v1/nearby", headers=mobile, timeout=10)
        nearby.raise_for_status()
        summary["nearby_items"] = len(nearby.json()["items"])
        print(json.dumps({"ok": True, "base_url": base, "summary": summary}, ensure_ascii=False, indent=2))
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
        log.close()
        log_text = (work / "uvicorn.log").read_text(encoding="utf-8", errors="replace") if (work / "uvicorn.log").exists() else ""
        if "Traceback" in log_text or "ERROR" in log_text:
            print("---- uvicorn log tail ----")
            print("\n".join(log_text.splitlines()[-40:]))
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
