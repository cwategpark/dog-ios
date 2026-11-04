"""Static deployment contract checks (no Docker/PostgreSQL runtime on this Mac).

These tests exist because the previous delivery documented `cp .env.docker.example
.env.docker && docker compose up`, while the example set production + sqlite (rejected by
Settings) and compose overrode the database URL with a sqlite default. They also guard the
Docker build context/COPY public-assets fix and removal of the broken docs/deploy duplicate.
"""
import json
from pathlib import Path

import yaml

from app.config import Settings

ROOT = Path(__file__).resolve().parents[2]


def _example_env() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in (ROOT / "deploy" / ".env.docker.example").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.startswith("WAGELPAW_"):
            values[key.removeprefix("WAGELPAW_").lower()] = value
        else:
            values[key.strip().lower()] = value
    return values


def test_deploy_env_example_is_valid_production_postgres_configuration():
    raw = _example_env()
    assert raw["environment"] == "production"
    assert raw["database_url"].startswith("postgresql+psycopg://")
    assert "sqlite" not in raw["database_url"]
    assert raw["postgres_password"] and raw["postgres_password"] in raw["database_url"]
    assert raw["shopify_api_secret"] and raw["rate_limit_salt"]
    assert raw["expose_dev_otp"] == "0" and raw["dev_email_outbox"] == "0"
    fields = dict(raw)
    for key in ("allowed_shops", "allowed_origins"):
        fields[key] = json.loads(fields[key])
    settings = Settings(**fields)  # production_guards must accept the documented template
    assert settings.environment == "production"
    assert settings.database_url.get_secret_value().startswith("postgresql+psycopg://")
    assert settings.claim_link_enabled is False


def test_compose_builds_from_repo_root_with_public_assets_and_unified_postgres_password():
    compose = yaml.safe_load((ROOT / "deploy" / "compose.yml").read_text())
    backend = compose["x-backend"]
    assert backend["build"]["context"] == ".."
    assert backend["build"]["dockerfile"] == "deploy/Dockerfile"
    assert ".env" in backend["env_file"]
    assert "postgresql+psycopg://" in backend["environment"]["WAGELPAW_DATABASE_URL"]
    compose_text = (ROOT / "deploy" / "compose.yml").read_text()
    assert "sqlite" not in compose_text
    assert "db" in compose["services"] and "migrate" in compose["services"]
    assert compose["services"]["migrate"]["depends_on"]["db"]["condition"] == "service_healthy"
    assert compose["services"]["api"]["depends_on"]["migrate"]["condition"] == "service_completed_successfully"
    assert compose["services"]["db"]["environment"]["POSTGRES_PASSWORD"].startswith("${POSTGRES_PASSWORD")
    assert compose["services"]["api"]["ports"] == ["127.0.0.1:18766:18766"]


def test_container_context_copies_backend_and_public_assets_and_ignores_local_artifacts():
    dockerfile = (ROOT / "deploy" / "Dockerfile").read_text()
    assert "COPY backend/ /app/" in dockerfile
    assert "COPY public-assets/ /app/public-assets/" in dockerfile
    assert "website-golden-master" not in dockerfile  # directory copy, not renamed file
    ignore = (ROOT / ".dockerignore").read_text().splitlines()
    assert ".venv" in ignore and ".git" in ignore and "*.db" in ignore
    assert not (ROOT / "docs" / "deploy" / "Dockerfile").exists()
    assert not (ROOT / "docs" / "deploy" / "compose.yml").exists()
    # The only canonical docker files live under deploy/ with the repo root context.
    assert (ROOT / "deploy" / "Dockerfile").exists()
    assert (ROOT / "deploy" / "compose.yml").exists()
    assert (ROOT / "public-assets" / "website-golden-master.glb").stat().st_size == 46_036_096
