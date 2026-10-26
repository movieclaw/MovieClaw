"""library_file_fingerprint and replica upload errors.

Uploading a library file to a cloud drive reads it once to fingerprint
it (SHA1, MD5, head SHA1) for rapid upload and verification
(docs/design/cloud-storage.md section 3.4/5); replicas remember why an
upload failed.

Revision ID: e6c3a9d1f527
Revises: d4b7e2c9a816
Create Date: 2026-10-18 21:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "e6c3a9d1f527"
down_revision: str | None = "d4b7e2c9a816"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "library_file_fingerprint",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("library_file_id", sa.Integer(), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("file_mtime_ns", sa.BigInteger(), nullable=True),
        sa.Column("sha1", sa.String(), nullable=False),
        sa.Column("md5", sa.String(), nullable=True),
        sa.Column("head_sha1", sa.String(), nullable=True),
        sa.Column("source", sa.String(), nullable=False),
        sa.Column("computed_at", sa.DateTime(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    )
    op.create_index(
        "uq_library_file_fingerprint_file",
        "library_file_fingerprint",
        ["library_file_id"],
        unique=True,
    )
    with op.batch_alter_table("library_file_replica") as batch:
        batch.add_column(sa.Column("error", sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("library_file_replica") as batch:
        batch.drop_column("error")
    op.drop_index("uq_library_file_fingerprint_file", table_name="library_file_fingerprint")
    op.drop_table("library_file_fingerprint")
