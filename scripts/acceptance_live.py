"""Cross-language acceptance: real FastAPI (uvicorn) + real Swift data layer over HTTP.

Steps:
1. start uvicorn with a test/development configuration (local email outbox, real public assets)
2. seed a verified website visitor (guest session + upload + OTP claim) for the Swift A user
3. HTTP regression: website OTP wrong-code keeps the guest session, correct code claims it,
   magic-link endpoint is disabled and returns no capability token
4. run Swift live acceptance tests (LiveBackendAcceptanceTests) against that server
5. stop everything and print a machine-readable summary
"""
import io
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
LOG = REPO / "var" / "logs"
SHOPIFY_SECRET = "acceptance-shopify-secret"
DEV_TOKEN = "acceptance-dev-token"


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def wait_ready(base, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if httpx.get(f"{base}/healthz", timeout=2).status_code == 200:
                return True
        except httpx.HTTPError:
            pass
        time.sleep(0.3)
    return False


def read_dev_code(response):
    payload = response.json()
    code = payload.get("dev_code")
    if not code:
        raise SystemExit(f"test config must expose dev_code, got {payload}")
    return payload["challenge_id"], code


def main():
    work = Path(tempfile.mkdtemp(prefix="dogios-acceptance-"))
    LOG.mkdir(parents=True, exist_ok=True)
    log_path = LOG / "acceptance-live.log"
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    outbox = work / "outbox.jsonl"
    env = os.environ.copy()
    env.update({
        "WAGELPAW_ENVIRONMENT": "test",
        "WAGELPAW_DATABASE_URL": f"sqlite:///{work / 'acceptance.db'}",
        "WAGELPAW_STORAGE_PATH": str(work / "media"),
        "WAGELPAW_DEV_TOKEN": DEV_TOKEN,
        "WAGELPAW_RATE_LIMIT_SALT": "acceptance-salt",
        "WAGELPAW_ALLOWED_SHOPS": '["example.myshopify.com"]',
        "WAGELPAW_SHOPIFY_API_SECRET": SHOPIFY_SECRET,
        "WAGELPAW_SESSIONS_PER_IP_HOUR": "200",
        "WAGELPAW_OTP_PER_EMAIL_HOUR": "200",
        "WAGELPAW_OTP_PER_IP_HOUR": "200",
        "WAGELPAW_OTP_RESEND_COOLDOWN_SECONDS": "0",
        "WAGELPAW_DEV_EMAIL_OUTBOX": "1",
        "WAGELPAW_EXPOSE_DEV_OTP": "1",
        "WAGELPAW_EMAIL_OUTBOX_PATH": str(outbox),
        "WAGELPAW_PUBLIC_BASE_URL": base,
        "WAGELPAW_PUBLIC_ASSETS_DIR": str(REPO / "public-assets"),
    })
    server_log = open(work / "uvicorn.log", "w", encoding="utf-8")
    process = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", str(port)],
        cwd=BACKEND, env=env, stdout=server_log, stderr=subprocess.STDOUT,
    )
    summary = {}
    failures = []
    try:
        if not wait_ready(base):
            raise SystemExit("backend did not become ready")
        dev = {"Authorization": f"Bearer {DEV_TOKEN}"}
        email_a, email_b = "live-a@example.com", "live-b@example.com"

        # seed user A: website guest session -> upload -> OTP claim (assets exist for mobile download)
        session = httpx.post(f"{base}/v1/sessions", headers=dev, json={
            "profile": {"type": "dog", "age_months": 18, "dog_size": "large", "name": "AcceptanceDog"},
            "consent": True, "email": email_a,
        }, timeout=15)
        session.raise_for_status()
        session_token = session.json()["session_token"]
        guest = {**dev, "X-Wagelpaw-Session": session_token}
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", (16, 16), "green").save(buf, "PNG")
        upload = httpx.post(f"{base}/v1/uploads", headers=guest,
                            files={"file": ("acceptance.png", buf.getvalue(), "image/png")}, timeout=30)
        upload.raise_for_status()
        claim = httpx.post(f"{base}/v1/claims", headers=guest, json={"email": email_a}, timeout=15)
        claim.raise_for_status()
        challenge_id, code = read_dev_code(claim)
        verify = httpx.post(f"{base}/v1/claims/{challenge_id}/verify", headers=guest, json={"code": code}, timeout=15)
        verify.raise_for_status()
        summary["seeded_claimed_sessions"] = verify.json()["claimed_session_ids"]

        # website OTP regression: wrong code must not destroy the guest session
        guest_c = httpx.post(f"{base}/v1/sessions", headers=dev, json={
            "profile": {"type": "cat", "age_months": 9, "name": "RegressionCat"},
            "consent": True, "email": "live-c@example.com",
        }, timeout=15).json()
        headers_c = {**dev, "X-Wagelpaw-Session": guest_c["session_token"]}
        claim_c = httpx.post(f"{base}/v1/claims", headers=headers_c, json={"email": "live-c@example.com"}, timeout=15)
        claim_c.raise_for_status()
        cid, ccode = read_dev_code(claim_c)
        wrong = httpx.post(f"{base}/v1/claims/{cid}/verify", headers=headers_c, json={"code": "000000" if ccode != "000000" else "111111"}, timeout=15)
        summary["wrong_otp_status"] = wrong.status_code
        if wrong.status_code != 401:
            failures.append(f"wrong OTP expected 401, got {wrong.status_code}")
        still_valid = httpx.get(f"{base}/v1/pet-profile", headers=headers_c, timeout=15)
        summary["guest_session_survives_wrong_otp"] = still_valid.status_code == 200
        if still_valid.status_code != 200:
            failures.append("wrong OTP cleared/blocked the guest session")
        right = httpx.post(f"{base}/v1/claims/{cid}/verify", headers=headers_c, json={"code": ccode}, timeout=15)
        summary["claimed_after_correct_otp"] = right.status_code == 200
        if right.status_code != 200:
            failures.append(f"correct OTP failed: {right.status_code} {right.text[:120]}")

        # magic-link must be disabled and must not return capability token/url
        link = httpx.post(f"{base}/v1/claims/{cid}/link", headers=headers_c, timeout=15)
        summary["claim_link_status"] = link.status_code
        if link.status_code != 503 or "token" in link.text.lower() or "http" in link.text.lower():
            failures.append(f"claim link not safely disabled: {link.status_code} {link.text[:120]}")
        redeem = httpx.post(f"{base}/mobile/v1/claims/link/redeem", json={"token": "forged.token"}, timeout=15)
        summary["claim_link_redeem_status"] = redeem.status_code
        if redeem.status_code != 503:
            failures.append(f"claim link redeem not disabled: {redeem.status_code}")

        # run the Swift live acceptance tests against the same server
        swift_env = os.environ.copy()
        swift_env.update({
            "DOGIOS_LIVE_BASE_URL": base,
            "DOGIOS_LIVE_EMAIL_A": email_a,
            "DOGIOS_LIVE_EMAIL_B": email_b,
        })
        swift = subprocess.run(
            ["swift", "test", "--disable-sandbox", "--package-path", "ios", "--filter", "LiveBackend"],
            cwd=REPO, env=swift_env, capture_output=True, text=True, timeout=900,
        )
        (LOG / "acceptance-live-swift.log").write_text(swift.stdout + swift.stderr, encoding="utf-8")
        summary["swift_live_exit"] = swift.returncode
        if swift.returncode != 0:
            failures.append(f"swift live tests failed (exit {swift.returncode}); see var/logs/acceptance-live-swift.log")
        summary["swift_executed"] = [line.strip() for line in swift.stdout.splitlines() if "Executed" in line][-1:] or []
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
        server_log.close()
        log_text = (work / "uvicorn.log").read_text(encoding="utf-8", errors="replace")
        if "Traceback" in log_text:
            failures.append("uvicorn log contains traceback")
        shutil.rmtree(work, ignore_errors=True)
    summary["failures"] = failures
    summary["ok"] = not failures
    text = json.dumps(summary, ensure_ascii=False, indent=2)
    log_path.write_text(text, encoding="utf-8")
    print(text)
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
