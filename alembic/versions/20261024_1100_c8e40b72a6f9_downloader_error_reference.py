"""Keep downloader error references beside their original rollback-compatible text."""

import sqlalchemy as sa
from alembic import op

revision = "c8e40b72a6f9"
down_revision = "b7d29a60c3e1"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("downloader_client", sa.Column("last_error_ref", sa.JSON(), nullable=True))


def downgrade():
    with op.batch_alter_table("downloader_client") as batch:
        batch.drop_column("last_error_ref")
