from alembic import context

from app.db import Base
from app import models  # noqa: F401


connection = context.config.attributes.get("connection")
if connection is None:
    raise RuntimeError("Use python -m app.db init with an explicit installation database")
context.configure(connection=connection, target_metadata=Base.metadata, compare_type=True)
with context.begin_transaction():
    context.run_migrations()
