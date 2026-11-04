"""Identity, mobile sessions, asset archive, discovery and contact tables.

Revision 0001 stays untouched; this migration only adds tables/columns needed by
the dog-ios shared backend (stable email identity, mobile auth, archived assets,
pet home data, nearby discovery and one-to-one contact messaging).
"""
from alembic import op
import sqlalchemy as sa


revision = '0002_identity_assets_social'
down_revision = '0001_initial'
branch_labels = None
depends_on = None


def upgrade():
    # ---- website guest sessions gain stable email identity / claim ownership ----
    with op.batch_alter_table('guest_sessions') as batch:
        batch.add_column(sa.Column('user_id', sa.String(length=32), nullable=True))
        batch.add_column(sa.Column('email_normalized', sa.String(length=254), nullable=True))
        batch.add_column(sa.Column('full_name', sa.String(length=120), nullable=True))
        batch.add_column(sa.Column('claimed_at', sa.Float(), nullable=True))
    op.create_index(op.f('ix_guest_sessions_user_id'), 'guest_sessions', ['user_id'], unique=False)

    # ---- uploads gain archive/durability markers ----
    with op.batch_alter_table('uploads') as batch:
        batch.add_column(sa.Column('archived', sa.Integer(), nullable=False, server_default='0'))
        batch.add_column(sa.Column('sha256', sa.String(length=64), nullable=True))

    op.create_table(
        'users',
        sa.Column('id', sa.String(length=32), nullable=False),
        sa.Column('public_ref', sa.String(length=32), nullable=False),
        sa.Column('email_normalized', sa.String(length=254), nullable=False),
        sa.Column('email_display', sa.String(length=254), nullable=False),
        sa.Column('full_name', sa.String(length=120), nullable=True),
        sa.Column('email_verified_at', sa.Float(), nullable=True),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.Column('updated_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('public_ref'),
        sa.UniqueConstraint('email_normalized'),
    )
    op.create_index(op.f('ix_users_email_normalized'), 'users', ['email_normalized'], unique=True)

    op.create_table(
        'email_challenges',
        sa.Column('id', sa.String(length=32), nullable=False),
        sa.Column('purpose', sa.String(length=40), nullable=False),
        sa.Column('user_id', sa.String(length=32), nullable=False),
        sa.Column('guest_session_id', sa.String(length=32), nullable=True),
        sa.Column('email_normalized', sa.String(length=254), nullable=False),
        sa.Column('code_hash', sa.String(length=64), nullable=True),
        sa.Column('link_token_hash', sa.String(length=64), nullable=True),
        sa.Column('attempts', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('max_attempts', sa.Integer(), nullable=False, server_default='5'),
        sa.Column('consumed_at', sa.Float(), nullable=True),
        sa.Column('expires_at', sa.Float(), nullable=False),
        sa.Column('ip_hash', sa.String(length=64), nullable=False, server_default=''),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_email_challenges_user_id'), 'email_challenges', ['user_id'], unique=False)
    op.create_index(op.f('ix_email_challenges_guest_session_id'), 'email_challenges', ['guest_session_id'], unique=False)
    op.create_index(op.f('ix_email_challenges_email_normalized'), 'email_challenges', ['email_normalized'], unique=False)
    op.create_index(op.f('ix_email_challenges_expires_at'), 'email_challenges', ['expires_at'], unique=False)

    op.create_table(
        'mobile_sessions',
        sa.Column('id', sa.String(length=32), nullable=False),
        sa.Column('user_id', sa.String(length=32), nullable=False),
        sa.Column('shop', sa.String(length=255), nullable=False),
        sa.Column('family_id', sa.String(length=32), nullable=False),
        sa.Column('access_hash', sa.String(length=64), nullable=True),
        sa.Column('refresh_hash', sa.String(length=64), nullable=True),
        sa.Column('access_expires_at', sa.Float(), nullable=False),
        sa.Column('refresh_expires_at', sa.Float(), nullable=False),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.Column('revoked_at', sa.Float(), nullable=True),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('access_hash'),
        sa.UniqueConstraint('refresh_hash'),
    )
    op.create_index(op.f('ix_mobile_sessions_user_id'), 'mobile_sessions', ['user_id'], unique=False)
    op.create_index(op.f('ix_mobile_sessions_family_id'), 'mobile_sessions', ['family_id'], unique=False)
    op.create_index(op.f('ix_mobile_sessions_shop'), 'mobile_sessions', ['shop'], unique=False)
    op.create_index(op.f('ix_mobile_sessions_refresh_expires_at'), 'mobile_sessions', ['refresh_expires_at'], unique=False)

    op.create_table(
        'pets',
        sa.Column('id', sa.String(length=32), nullable=False),
        sa.Column('user_id', sa.String(length=32), nullable=False),
        sa.Column('name', sa.String(length=80), nullable=True),
        sa.Column('species', sa.String(length=20), nullable=False),
        sa.Column('breed', sa.String(length=80), nullable=True),
        sa.Column('age_months', sa.Integer(), nullable=True),
        sa.Column('dog_size', sa.String(length=20), nullable=True),
        sa.Column('avatar_asset_id', sa.String(length=32), nullable=True),
        sa.Column('source_session_id', sa.String(length=32), nullable=True),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.Column('updated_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_pets_user_id'), 'pets', ['user_id'], unique=False)
    op.create_index(op.f('ix_pets_source_session_id'), 'pets', ['source_session_id'], unique=False)

    op.create_table(
        'asset_archive',
        sa.Column('id', sa.String(length=32), nullable=False),
        sa.Column('user_id', sa.String(length=32), nullable=True),
        sa.Column('guest_session_id', sa.String(length=32), nullable=True),
        sa.Column('job_id', sa.String(length=32), nullable=True),
        sa.Column('upload_id', sa.String(length=32), nullable=False),
        sa.Column('pet_id', sa.String(length=32), nullable=True),
        sa.Column('kind', sa.String(length=30), nullable=False),
        sa.Column('format', sa.String(length=20), nullable=False),
        sa.Column('mime', sa.String(length=80), nullable=False),
        sa.Column('bytes', sa.Integer(), nullable=False),
        sa.Column('sha256', sa.String(length=64), nullable=False),
        sa.Column('source_role', sa.String(length=30), nullable=True),
        sa.Column('product_id', sa.String(length=100), nullable=True),
        sa.Column('variant_id', sa.String(length=100), nullable=True),
        sa.Column('provenance', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('upload_id'),
    )
    op.create_index(op.f('ix_asset_archive_user_id'), 'asset_archive', ['user_id'], unique=False)
    op.create_index(op.f('ix_asset_archive_guest_session_id'), 'asset_archive', ['guest_session_id'], unique=False)
    op.create_index(op.f('ix_asset_archive_job_id'), 'asset_archive', ['job_id'], unique=False)
    op.create_index(op.f('ix_asset_archive_pet_id'), 'asset_archive', ['pet_id'], unique=False)

    op.create_table(
        'discovery_profiles',
        sa.Column('user_id', sa.String(length=32), nullable=False),
        sa.Column('enabled', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('grid_x', sa.Integer(), nullable=False),
        sa.Column('grid_y', sa.Integer(), nullable=False),
        sa.Column('region_label', sa.String(length=120), nullable=True),
        sa.Column('radius_km', sa.Integer(), nullable=False, server_default='5'),
        sa.Column('updated_at', sa.Float(), nullable=False),
        sa.Column('expires_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('user_id'),
    )
    op.create_index(op.f('ix_discovery_profiles_expires_at'), 'discovery_profiles', ['expires_at'], unique=False)
    op.create_index(op.f('ix_discovery_profiles_grid'), 'discovery_profiles', ['grid_x', 'grid_y'], unique=False)

    op.create_table(
        'contact_requests',
        sa.Column('id', sa.String(length=32), nullable=False),
        sa.Column('from_user_id', sa.String(length=32), nullable=False),
        sa.Column('to_user_id', sa.String(length=32), nullable=False),
        sa.Column('status', sa.String(length=20), nullable=False, server_default='pending'),
        sa.Column('message', sa.String(length=500), nullable=True),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.Column('updated_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_contact_requests_from_user_id'), 'contact_requests', ['from_user_id'], unique=False)
    op.create_index(op.f('ix_contact_requests_to_user_id'), 'contact_requests', ['to_user_id'], unique=False)
    op.create_index(op.f('ix_contact_requests_status'), 'contact_requests', ['status'], unique=False)

    op.create_table(
        'contacts',
        sa.Column('id', sa.String(length=32), nullable=False),
        sa.Column('user_a', sa.String(length=32), nullable=False),
        sa.Column('user_b', sa.String(length=32), nullable=False),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('user_a', 'user_b'),
    )
    op.create_index(op.f('ix_contacts_user_a'), 'contacts', ['user_a'], unique=False)
    op.create_index(op.f('ix_contacts_user_b'), 'contacts', ['user_b'], unique=False)

    op.create_table(
        'contact_messages',
        sa.Column('id', sa.String(length=32), nullable=False),
        sa.Column('contact_id', sa.String(length=32), nullable=False),
        sa.Column('sender_user_id', sa.String(length=32), nullable=False),
        sa.Column('body', sa.String(length=2000), nullable=False),
        sa.Column('client_id', sa.String(length=64), nullable=False),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('contact_id', 'client_id'),
    )
    op.create_index(op.f('ix_contact_messages_contact_id'), 'contact_messages', ['contact_id'], unique=False)
    op.create_index(op.f('ix_contact_messages_created_at'), 'contact_messages', ['created_at'], unique=False)

    op.create_table(
        'user_blocks',
        sa.Column('blocker_id', sa.String(length=32), nullable=False),
        sa.Column('blocked_id', sa.String(length=32), nullable=False),
        sa.Column('created_at', sa.Float(), nullable=False),
        sa.PrimaryKeyConstraint('blocker_id', 'blocked_id'),
    )
    op.create_index(op.f('ix_user_blocks_blocked_id'), 'user_blocks', ['blocked_id'], unique=False)


def downgrade():
    op.drop_index(op.f('ix_user_blocks_blocked_id'), table_name='user_blocks')
    op.drop_table('user_blocks')
    op.drop_index(op.f('ix_contact_messages_created_at'), table_name='contact_messages')
    op.drop_index(op.f('ix_contact_messages_contact_id'), table_name='contact_messages')
    op.drop_table('contact_messages')
    op.drop_index(op.f('ix_contacts_user_b'), table_name='contacts')
    op.drop_index(op.f('ix_contacts_user_a'), table_name='contacts')
    op.drop_table('contacts')
    op.drop_index(op.f('ix_contact_requests_status'), table_name='contact_requests')
    op.drop_index(op.f('ix_contact_requests_to_user_id'), table_name='contact_requests')
    op.drop_index(op.f('ix_contact_requests_from_user_id'), table_name='contact_requests')
    op.drop_table('contact_requests')
    op.drop_index(op.f('ix_discovery_profiles_grid'), table_name='discovery_profiles')
    op.drop_index(op.f('ix_discovery_profiles_expires_at'), table_name='discovery_profiles')
    op.drop_table('discovery_profiles')
    op.drop_index(op.f('ix_asset_archive_pet_id'), table_name='asset_archive')
    op.drop_index(op.f('ix_asset_archive_job_id'), table_name='asset_archive')
    op.drop_index(op.f('ix_asset_archive_guest_session_id'), table_name='asset_archive')
    op.drop_index(op.f('ix_asset_archive_user_id'), table_name='asset_archive')
    op.drop_table('asset_archive')
    op.drop_index(op.f('ix_pets_source_session_id'), table_name='pets')
    op.drop_index(op.f('ix_pets_user_id'), table_name='pets')
    op.drop_table('pets')
    op.drop_index(op.f('ix_mobile_sessions_refresh_expires_at'), table_name='mobile_sessions')
    op.drop_index(op.f('ix_mobile_sessions_shop'), table_name='mobile_sessions')
    op.drop_index(op.f('ix_mobile_sessions_family_id'), table_name='mobile_sessions')
    op.drop_index(op.f('ix_mobile_sessions_user_id'), table_name='mobile_sessions')
    op.drop_table('mobile_sessions')
    op.drop_index(op.f('ix_email_challenges_expires_at'), table_name='email_challenges')
    op.drop_index(op.f('ix_email_challenges_email_normalized'), table_name='email_challenges')
    op.drop_index(op.f('ix_email_challenges_guest_session_id'), table_name='email_challenges')
    op.drop_index(op.f('ix_email_challenges_user_id'), table_name='email_challenges')
    op.drop_table('email_challenges')
    op.drop_index(op.f('ix_users_email_normalized'), table_name='users')
    op.drop_table('users')
    with op.batch_alter_table('uploads') as batch:
        batch.drop_column('sha256')
        batch.drop_column('archived')
    op.drop_index(op.f('ix_guest_sessions_user_id'), table_name='guest_sessions')
    with op.batch_alter_table('guest_sessions') as batch:
        batch.drop_column('claimed_at')
        batch.drop_column('full_name')
        batch.drop_column('email_normalized')
        batch.drop_column('user_id')
