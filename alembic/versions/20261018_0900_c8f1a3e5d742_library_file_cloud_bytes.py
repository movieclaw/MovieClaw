"""library_file cloud bytes: local_bytes flag and library_file_replica.

A library file's bytes may live only on a cloud drive (released after
upload, or imported from a drive folder) - docs/design/cloud-storage.md
section 3.3/3.5. local_bytes says whether file_path holds bytes locally;
library_file_replica records the cloud copy by remote file id.

Revision ID: c8f1a3e5d742
Revises: b5e2d8a4c731
Create Date: 2026-10-18 09:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c8f1a3e5d742"
down_revision: str | None = "b5e2d8a4c731"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("library_file") as batch:
        batch.add_column(
            sa.Column("local_bytes", sa.Boolean(), nullable=False, server_default=sa.true())
        )
        batch.add_column(sa.Column("local_released_at", sa.DateTime(), nullable=True))
    op.create_table(
        "library_file_replica",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("library_file_id", sa.Integer(), nullable=False),
        sa.Column("account_id", sa.Integer(), nullable=False),
        sa.Column("remote_id", sa.String(), nullable=False),
        sa.Column("remote_path", sa.Text(), nullable=True),
        sa.Column("origin", sa.String(), nullable=False),
        sa.Column("state", sa.String(), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=True),
        sa.Column("sha1", sa.String(), nullable=True),
        sa.Column("verified_at", sa.DateTime(), nullable=True),
        sa.Column("checked_at", sa.DateTime(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    )
    op.create_index(
        "uq_library_file_replica_file", "library_file_replica", ["library_file_id"], unique=True
    )
    op.create_index(
        "ix_library_file_replica_account_remote",
        "library_file_replica",
        ["account_id", "remote_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_library_file_replica_account_remote", table_name="library_file_replica")
    op.drop_index("uq_library_file_replica_file", table_name="library_file_replica")
    op.drop_table("library_file_replica")
    with op.batch_alter_table("library_file") as batch:
        batch.drop_column("local_released_at")
        batch.drop_column("local_bytes")
