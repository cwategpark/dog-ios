"""Guest-session to pet mapping for same-name pets across several questionnaires.

Revision 0001 and 0002 stay untouched. ``pets.source_session_id`` only records the first
questionnaire that created a pet, so a second questionnaire reusing the same (same-name)
pet cannot be resolved from it. This forward-only migration adds a per-session mapping
table so archive/transfer code can resolve the pet deterministically for every session.

The migration is safe on an existing install: it only creates a new table, so old rows are
kept verbatim and an idempotent ``upgrade to head`` is a no-op.
"""
from alembic import op
import sqlalchemy as sa


revision = '0003_guest_session_pets'
down_revision = '0002_identity_assets_social'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'guest_session_pets',
        sa.Column('session_id', sa.String(length=32), nullable=False),
        sa.Column('pet_id', sa.String(length=32), nullable=False),
        sa.Column('user_id', sa.String(length=32), nullable=False),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('session_id'),
        sa.UniqueConstraint('session_id'),
    )
    op.create_index(op.f('ix_guest_session_pets_pet_id'), 'guest_session_pets', ['pet_id'], unique=False)
    op.create_index(op.f('ix_guest_session_pets_user_id'), 'guest_session_pets', ['user_id'], unique=False)


def downgrade():
    op.drop_index(op.f('ix_guest_session_pets_user_id'), table_name='guest_session_pets')
    op.drop_index(op.f('ix_guest_session_pets_pet_id'), table_name='guest_session_pets')
    op.drop_table('guest_session_pets')
