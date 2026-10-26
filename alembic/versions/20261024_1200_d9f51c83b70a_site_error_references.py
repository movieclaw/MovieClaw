"""Preserve site verification and synchronization error provenance."""

import sqlalchemy as sa
from alembic import op

revision = "d9f51c83b70a"
down_revision = "c8e40b72a6f9"
branch_labels = None
depends_on = None


def upgrade():
    for table in ("site_credential", "site_sync_cursor"):
        op.add_column(table, sa.Column("last_error_ref", sa.JSON(), nullable=True))


def downgrade():
    for table in ("site_sync_cursor", "site_credential"):
        with op.batch_alter_table(table) as batch:
            batch.drop_column("last_error_ref")
