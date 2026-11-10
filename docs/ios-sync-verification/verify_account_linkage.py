"""Exercise canonical website/App APIs in a new disposable database, then clean up.

Run with the canonical project's .venv Python. No live server, credentials, email,
customer data, or real generation provider is used. Only a redacted evidence JSON
survives. --cleanup-run accepts only marked run directories below this script.
Pass --canonical-project /path/to/dog-canonical-root; the root must contain backend/.
"""
from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import uuid


CANONICAL = Path("E:/后端以及数据库设计/dog-shopify-migration/migration")
HERE = Path(__file__).resolve().parent
WORK = HERE / "work"
MARKER = ".disposable-account-linkage-run"


def cleanup_run(run: Path) -> None:
    resolved = run.resolve()
    if resolved.parent != WORK.resolve() or not resolved.name.startswith("run-"):
        raise ValueError("cleanup target must be a run directory inside this script's work directory")
    if resolved.is_symlink() or not (resolved / MARKER).is_file():
        raise ValueError("cleanup target is not a marked disposable run")
    shutil.rmtree(resolved)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cleanup-run", type=Path)
    parser.add_argument("--canonical-project", type=Path, default=CANONICAL,
                        help="Canonical website project root containing backend/ "
                             "(defaults to the original Windows environment path)")
    args = parser.parse_args()
    if args.cleanup_run:
        cleanup_run(args.cleanup_run)
        print(json.dumps({"cleaned_up": True}))
        return

    run_id = uuid.uuid4().hex
    WORK.mkdir(parents=True, exist_ok=True)
    run = WORK / ("run-" + run_id)
    run.mkdir()
    (run / MARKER).write_text(run_id, encoding="utf-8")
    previous_cwd = Path.cwd()
    # Settings reads environment and .env even with explicit test fixtures. Keep
    # all imports and global app construction inside this new private directory.
    for name in list(os.environ):
        if name.upper().startswith(("WAGELPAW_", "SHOPIFY_")):
            os.environ.pop(name)
    os.chdir(run)
    canonical = args.canonical_project.expanduser().resolve()
    sys.path.insert(0, str(canonical / "backend"))
    report = {"created_at": datetime.now(timezone.utc).isoformat(),
              "canonical_project": str(canonical), "environment": "isolated-test-database",
              "account_domain": "example.invalid", "live_email_sent": False,
              "real_generation_calls": 0, "checks": {}, "passed": False}
    patch = None
    try:
        import pytest
        from app.worker import run_job
        from tests.support import make_client, mobile_login
        from tests.test_personal_pet_models import (
            configured, personal, photo, claim, start, install_provider,
            success_handler, triangle_glb,
        )

        settings = configured(run, model_inbox=run / "model-inbox", public_assets_dir=run / "public-assets",
                              smtp_host="", smtp_from="", email_provider="smtp")
        assert settings.environment == "test"
        assert settings.storage_path.resolve().is_relative_to(run.resolve())
        assert settings.email_outbox_path.resolve().is_relative_to(run.resolve())
        assert not settings.smtp_host and settings.dev_email_outbox
        owner_email = "ios-sync-owner-" + run_id + "@example.invalid"
        stranger_email = "ios-sync-other-" + run_id + "@example.invalid"
        pet_name = "Disposable iOS linkage pet"
        patch = pytest.MonkeyPatch()
        calls = []
        install_provider(patch, settings, success_handler(calls))
        with make_client(settings) as client:
            owner, mobile = mobile_login(client, settings, owner_email)
            guest, _ = personal(client, pet_name=pet_name, breed_slug="chihuahua")
            upload_id = photo(client, guest)
            claimed = claim(client, settings, guest, email=owner_email)
            assert claimed["verified_user_id"] == owner["user_id"]
            report["checks"]["website_claim_matches_app_user"] = True

            pets = client.get("/mobile/v1/pets", headers=mobile)
            assert pets.status_code == 200
            pet = next(item for item in pets.json()["pets"] if item["name"] == pet_name)
            pet_id = pet["pet_id"]
            report["checks"]["app_pet_name_from_website"] = True

            photos = client.get("/mobile/v1/assets", params={"kind": "photo", "pet_id": pet_id}, headers=mobile)
            assert photos.status_code == 200 and len(photos.json()["items"]) == 1
            picture = photos.json()["items"][0]
            assert picture["kind_role"] == "upload" and picture["pet_id"] == pet_id
            downloaded = client.get(picture["download_url"], headers=mobile)
            # The canonical upload boundary normalizes submitted PNGs to JPEG.
            assert downloaded.status_code == 200 and downloaded.content.startswith(b"\xff\xd8")
            assert downloaded.headers["content-type"].startswith("image/jpeg")
            assert hashlib.sha256(downloaded.content).hexdigest() == picture["sha256"]
            report["checks"]["uploaded_photo_owned_list_and_authenticated_bytes"] = True

            # Reuse the actual production job/archive path with an in-memory fake
            # provider transport; no request can reach Tripo or incur a charge.
            queued = start(client, guest, upload_id)
            assert queued.status_code == 202
            assert asyncio.run(run_job(settings, client.app.state.sessions, "disposable-acceptance-worker"))
            job = client.get("/v1/pet-models/personal-jobs/" + queued.json()["id"], headers=guest)
            assert job.status_code == 200 and job.json()["status"] == "succeeded"
            report["checks"]["website_job_archives_model_to_verified_account"] = True

            models = client.get("/mobile/v1/models", params={"pet_id": pet_id}, headers=mobile)
            assert models.status_code == 200 and len(models.json()["items"]) == 1
            model = models.json()["items"][0]
            assert model["pet_id"] == pet_id and model["source"] == "photo-generated"
            model_bytes = client.get(model["download_url"], headers=mobile)
            assert model_bytes.status_code == 200 and model_bytes.content == triangle_glb()
            assert hashlib.sha256(model_bytes.content).hexdigest() == model["sha256"]
            home = client.get("/mobile/v1/pet-home", params={"pet_id": pet_id}, headers=mobile)
            assert home.status_code == 200 and home.json()["selected"] == "personal"
            assert home.json()["personal_model"]["asset_id"] == model["archive_asset_id"]
            report["checks"]["app_models_home_and_verified_model_bytes"] = True

            _, stranger = mobile_login(client, settings, stranger_email)
            for url in (picture["download_url"], model["download_url"]):
                assert client.get(url, headers=stranger).status_code == 404
                assert client.get(url).status_code == 401
            assert client.get("/mobile/v1/assets", params={"pet_id": pet_id}, headers=stranger).status_code == 404
            assert client.get("/mobile/v1/pet-home", params={"pet_id": pet_id}, headers=stranger).status_code == 404
            assert client.get("/mobile/v1/models", headers=stranger).json()["items"] == []
            report["checks"]["cross_user_assets_and_pet_home_denied"] = True
            report["checks"]["unauthenticated_private_download_denied"] = True
            report["counts"] = {"pets": 1, "uploaded_photos": 1, "models": 1,
                                "mock_provider_http_requests": len(calls)}
            report["passed"] = True
    finally:
        if patch is not None:
            patch.undo()
        os.chdir(previous_cwd)
        cleanup_run(run)
        report["cleaned_up"] = not run.exists()
        report_path = HERE / "account-linkage-evidence.json"
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
