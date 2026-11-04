import argparse
from pathlib import Path

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker


class Base(DeclarativeBase):
    pass


def make_engine(url: str):
    if hasattr(url, "get_secret_value"):
        url = url.get_secret_value()
    if url.startswith("sqlite:///" ) and ":memory:" not in url:
        Path(url.removeprefix("sqlite:///")).resolve().parent.mkdir(parents=True, exist_ok=True)
    kwargs = {"connect_args": {"check_same_thread": False, "timeout": 30}} if url.startswith("sqlite") else {}
    return create_engine(url, pool_pre_ping=True, **kwargs)


def session_factory(engine):
    return sessionmaker(engine, expire_on_commit=False)


def init_database(engine):
    from alembic import command
    from alembic.config import Config

    config = Config()
    config.set_main_option("script_location", str(Path(__file__).resolve().parent / "migrations"))
    with engine.begin() as connection:
        config.attributes["connection"] = connection
        command.upgrade(config, "head")


def check_schema(engine):
    from alembic.config import Config
    from alembic.migration import MigrationContext
    from alembic.script import ScriptDirectory

    config = Config()
    config.set_main_option("script_location", str(Path(__file__).resolve().parent / "migrations"))
    expected = set(ScriptDirectory.from_config(config).get_heads())
    with engine.connect() as connection:
        current = set(MigrationContext.configure(connection).get_current_heads())
    if current != expected:
        raise RuntimeError("database_schema_upgrade_required")


def bind_installation(engine, shop):
    from .models import Installation

    sessions = session_factory(engine)
    with sessions() as db:
        row = db.get(Installation, 1)
        if row and row.shop != shop:
            raise RuntimeError("database_belongs_to_another_store_use_new_database_and_media_volume")
        if not row:
            db.add(Installation(id=1, shop=shop))
            db.commit()


if __name__ == "__main__":
    from .config import get_settings

    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["init"])
    parser.parse_args()
    settings = get_settings()
    engine = make_engine(settings.database_url)
    init_database(engine)
    bind_installation(engine, settings.local_shop)
