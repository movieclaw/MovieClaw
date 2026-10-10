"""download_file_source: which download a library file came from, owned by downloads.

Torrent provenance moves out of the media library
(docs/design/library-boundary.md section 5). The new table is keyed by the
library file id without a cascading foreign key: deleting a library file
leaves the record for the download module to act on and clean up. Existing
provenance is copied from library_file; its old columns stay for one release
so a rollback keeps working, and ingest writes both until they are dropped.
"""

import sqlalchemy as sa
from alembic import op

revision = "e12bc13203b5"
down_revision = "087d01dfcecb"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "download_file_source",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("library_file_id", sa.Integer(), nullable=False),
        sa.Column("info_hash", sa.String(), nullable=True),
        sa.Column(
            "downloader_id",
            sa.Integer(),
            sa.ForeignKey("downloader_client.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("site_id", sa.String(), nullable=True),
        sa.Column("torrent_id", sa.String(), nullable=True),
        sa.Column("orphaned_at", sa.DateTime(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    )
    op.create_index(
        "ix_download_file_source_library_file_id",
        "download_file_source",
        ["library_file_id"],
        unique=True,
    )
    op.create_index("ix_download_file_source_info_hash", "download_file_source", ["info_hash"])
    op.execute(
        """
        INSERT INTO download_file_source
            (library_file_id, info_hash, downloader_id, site_id, torrent_id,
             created_at, updated_at)
        SELECT id, lower(info_hash), downloader_id, site_id, torrent_id,
               CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM library_file
        WHERE info_hash IS NOT NULL OR site_id IS NOT NULL OR torrent_id IS NOT NULL
        """
    )


def downgrade() -> None:
    op.drop_index("ix_download_file_source_info_hash", table_name="download_file_source")
    op.drop_index("ix_download_file_source_library_file_id", table_name="download_file_source")
    op.drop_table("download_file_source")
