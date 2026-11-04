from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import inspect, text

import app.db as app_db
from app.db import check_schema, init_database, make_engine
from app.main import create_app

from .support import build_settings


def _alembic_config() -> Config:
    config = Config()
    config.set_main_option("script_location", str(Path(app_db.__file__).resolve().parent / "migrations"))
    return config


def test_upgrade_from_0001_keeps_legacy_rows_and_adds_identity_tables(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'upgrade.db'}")
    config = _alembic_config()
    with engine.begin() as connection:
        config.attributes["connection"] = connection
        command.upgrade(config, "0001_initial")
    with engine.begin() as connection:
        connection.execute(text(
            "INSERT INTO guest_sessions (id, token_hash, shop, ip_hash, created_at, expires_at, jobs_submitted) "
            "VALUES ('legacy-session', 'legacy-hash', 'example.myshopify.com', 'ip-hash', 1.0, 2.0, 3)"
        ))
        connection.execute(text(
            "INSERT INTO pet_profiles (owner_id, data, consent, updated_at) "
            "VALUES ('legacy-session', '{\"pet_information\": {\"type\": \"cat\", \"age_months\": 24}}', '{}', 1.0)"
        ))
    with engine.begin() as connection:
        config.attributes["connection"] = connection
        command.upgrade(config, "head")

    inspector = inspect(engine)
    tables = set(inspector.get_table_names())
    assert {"users", "email_challenges", "mobile_sessions", "pets", "asset_archive",
            "discovery_profiles", "contact_requests", "contacts", "contact_messages",
            "user_blocks", "guest_session_pets", "social_pair_locks"} <= tables
    guest_columns = {column["name"] for column in inspector.get_columns("guest_sessions")}
    assert {"user_id", "email_normalized", "full_name", "claimed_at"} <= guest_columns
    upload_columns = {column["name"] for column in inspector.get_columns("uploads")}
    assert {"archived", "sha256"} <= upload_columns
    job_columns = {column["name"] for column in inspector.get_columns("jobs")}
    assert {"archived_at", "archive_attempts", "archive_retry_at"} <= job_columns

    with engine.connect() as connection:
        legacy = connection.execute(text("SELECT id, token_hash, jobs_submitted FROM guest_sessions")).fetchall()
        assert legacy == [("legacy-session", "legacy-hash", 3)]
        profile = connection.execute(text("SELECT owner_id FROM pet_profiles")).fetchall()
        assert profile == [("legacy-session",)]

    check_schema(engine)
    init_database(engine)  # idempotent upgrade to head
    assert set(inspect(engine).get_table_names()) == tables
    engine.dispose()


def test_downgrade_and_reupgrade_is_safe(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'downgrade.db'}")
    config = _alembic_config()
    with engine.begin() as connection:
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
    with engine.begin() as connection:
        config.attributes["connection"] = connection
        command.downgrade(config, "0001_initial")
    tables = set(inspect(engine).get_table_names())
    assert "users" not in tables
    assert "guest_session_pets" not in tables
    assert "social_pair_locks" not in tables
    assert "guest_sessions" in tables
    with engine.begin() as connection:
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
    assert "users" in set(inspect(engine).get_table_names())
    with engine.connect() as connection:
        revision = connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one()
        assert revision == "0004_archive_compensation_pair_locks"
    engine.dispose()


def test_generated_openapi_contains_mobile_and_claim_endpoints(tmp_path):
    app = create_app(build_settings(tmp_path))
    schema = app.openapi()
    paths = schema["paths"]
    assert "/mobile/v1/auth/email/start" in paths
    assert "/mobile/v1/auth/email/verify" in paths
    assert "/mobile/v1/assets/{asset_id}/download" in paths
    assert "/mobile/v1/pet-home" in paths
    assert "/mobile/v1/nearby" in paths
    assert "/mobile/v1/contacts/requests" in paths
    assert "/v1/claims" in paths
    assert "/public-assets/website-golden-master.glb" in paths
    assert schema["info"]["title"]
