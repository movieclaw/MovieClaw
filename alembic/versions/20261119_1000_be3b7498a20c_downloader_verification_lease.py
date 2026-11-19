"""Add nullable downloader verification ownership and expiry fields.

Revision ID: be3b7498a20c
Revises: a7d2e9c41b58
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "be3b7498a20c"
down_revision: str | None = "a7d2e9c41b58"
branch_labels: str | Sequence[str] | None = None
depends_on: str | None = None


def upgrade() -> None:
    op.add_column("downloader_client", sa.Column("verification_token", sa.String(), nullable=True))
    op.add_column(
        "downloader_client", sa.Column("verification_expires_at", sa.DateTime(), nullable=True)
    )


def downgrade() -> None:
    with op.batch_alter_table("downloader_client") as batch:
        batch.drop_column("verification_expires_at")
        batch.drop_column("verification_token")
