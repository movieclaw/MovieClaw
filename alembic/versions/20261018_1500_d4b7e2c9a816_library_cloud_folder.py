"""library_cloud_folder: drive folders mounted on a library (import).

A library's roots can include cloud drive folders; mounting one imports
its videos by filename (docs/design/cloud-storage.md section 3.2/4).
Imported replicas remember their folder, and drive accounts keep the
change-feed cursor.

Revision ID: d4b7e2c9a816
Revises: c8f1a3e5d742
Create Date: 2026-10-18 15:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d4b7e2c9a816"
down_revision: str | None = "c8f1a3e5d742"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "library_cloud_folder",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "library_id",
            sa.Integer(),
            sa.ForeignKey("library.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("account_id", sa.Integer(), sa.ForeignKey("drive_account.id"), nullable=False),
        sa.Column("remote_dir_id", sa.String(), nullable=False),
        sa.Column("display_path", sa.Text(), nullable=False),
        sa.Column("local_dir", sa.Text(), nullable=False),
        sa.Column("is_primary", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("listed_at", sa.DateTime(), nullable=True),
        sa.Column("dir_ids", sa.JSON(), nullable=False, server_default="[]"),
        sa.Column("report", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    )
    op.create_index("ix_library_cloud_folder_library_id", "library_cloud_folder", ["library_id"])
    op.create_index(
        "uq_library_cloud_folder_remote",
        "library_cloud_folder",
        ["account_id", "remote_dir_id"],
        unique=True,
    )
    with op.batch_alter_table("library_file_replica") as batch:
        batch.add_column(sa.Column("folder_id", sa.Integer(), nullable=True))
        batch.create_index("ix_library_file_replica_folder_id", ["folder_id"])
    with op.batch_alter_table("drive_account") as batch:
        batch.add_column(sa.Column("change_cursor", sa.String(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("drive_account") as batch:
        batch.drop_column("change_cursor")
    with op.batch_alter_table("library_file_replica") as batch:
        batch.drop_index("ix_library_file_replica_folder_id")
        batch.drop_column("folder_id")
    op.drop_index("uq_library_cloud_folder_remote", table_name="library_cloud_folder")
    op.drop_index("ix_library_cloud_folder_library_id", table_name="library_cloud_folder")
    op.drop_table("library_cloud_folder")
