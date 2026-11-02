"""Ledger of sidecar files (artwork, NFO, subtitles) uploaded next to cloud videos.

Revision ID: c5f1a8e3b724
Revises: f3b8d15c7a29
"""

import sqlalchemy as sa
from alembic import op

revision = "c5f1a8e3b724"
down_revision = "f3b8d15c7a29"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "library_cloud_sidecar",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "folder_id",
            sa.Integer(),
            sa.ForeignKey("library_cloud_folder.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("local_path", sa.Text(), nullable=False),
        sa.Column("remote_id", sa.String(), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("file_mtime_ns", sa.BigInteger(), nullable=False),
        sa.Column("sha1", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    )
    op.create_index(
        "uq_library_cloud_sidecar_path",
        "library_cloud_sidecar",
        ["folder_id", "local_path"],
        unique=True,
    )


def downgrade():
    op.drop_table("library_cloud_sidecar")
