"""Archive compensation state + persistent social pair mutex.

Revision 0004 is forward-only for existing installs:
- jobs gain ``archived_at`` / ``archive_attempts`` / ``archive_retry_at`` so the worker can
  persistently retry terminal-job archive compensation without re-calling a provider;
- ``social_pair_locks`` is a per ordered user-pair mutex row used by block/create/accept/send
  to close the check-then-act TOCTOU race on both PostgreSQL (row lock) and SQLite (write lock).

0001-0003 are untouched. Downgrade drops only these additions.
"""
from alembic import op
import sqlalchemy as sa


revision = '0004_archive_compensation_pair_locks'
down_revision = '0003_guest_session_pets'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('jobs') as batch:
        batch.add_column(sa.Column('archived_at', sa.Float(), nullable=True))
        batch.add_column(sa.Column('archive_attempts', sa.Integer(), nullable=False, server_default='0'))
        batch.add_column(sa.Column('archive_retry_at', sa.Float(), nullable=True))
    op.create_index(op.f('ix_jobs_archived_at'), 'jobs', ['archived_at'], unique=False)

    op.create_table(
        'social_pair_locks',
        sa.Column('pair_key', sa.String(length=65), nullable=False),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('pair_key'),
    )


def downgrade():
    op.drop_table('social_pair_locks')
    op.drop_index(op.f('ix_jobs_archived_at'), table_name='jobs')
    with op.batch_alter_table('jobs') as batch:
        batch.drop_column('archive_retry_at')
        batch.drop_column('archive_attempts')
        batch.drop_column('archived_at')
