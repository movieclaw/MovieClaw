"""drive_account: logged-in cloud drive accounts.

The cloud storage layer (docs/design/cloud-storage.md section 3.1) lets a
library live on a cloud drive such as 115. Each row is one logged-in user of
one drive backend; credentials are stored encrypted.

Revision ID: b5e2d8a4c731
Revises: c4a7e9d2f613
Create Date: 2026-10-17 16:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b5e2d8a4c731"
down_revision: str | None = "c4a7e9d2f613"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "drive_account",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("backend", sa.String(), nullable=False),
        sa.Column("remote_user_id", sa.String(), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("credentials", sa.Text(), nullable=False),
        sa.Column("login_method", sa.String(), nullable=False, server_default="scan"),
        sa.Column("login_detail", sa.String(), nullable=True),
        sa.Column("status", sa.String(), nullable=False, server_default="ok"),
        sa.Column("status_message", sa.String(), nullable=True),
        sa.Column("status_until", sa.DateTime(), nullable=True),
        sa.Column("qps", sa.Float(), nullable=True),
        sa.Column("daily_budget", sa.Integer(), nullable=True),
        sa.Column("read_slots", sa.Integer(), nullable=True),
        sa.Column("vip", sa.String(), nullable=True),
        sa.Column("quota_total", sa.BigInteger(), nullable=True),
        sa.Column("quota_used", sa.BigInteger(), nullable=True),
        sa.Column("profile_at", sa.DateTime(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    )
    op.create_index(
        "uq_drive_account_backend_user",
        "drive_account",
        ["backend", "remote_user_id"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("uq_drive_account_backend_user", table_name="drive_account")
    op.drop_table("drive_account")
