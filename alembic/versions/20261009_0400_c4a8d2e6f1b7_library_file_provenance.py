"""library_file: record the source torrent; manual_download_intent: record the owner.

Plugins that clean up after a deletion need to know which downloader task a
file came from. Ingest now writes the info hash and downloader; existing rows
are backfilled from the subscription download attempts of the same item that
match the recorded site and torrent id. Manual intents are deleted after
ingest, so manually downloaded history cannot be recovered and stays NULL.

manual_download_intent.owner says who started the download (``manual`` or
``plugin:<entry id>``). See docs/design/plugin-phase2a.md §5.
"""

import sqlalchemy as sa
from alembic import op

revision = "c4a8d2e6f1b7"
down_revision = "b3f1c7a9e2d4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("library_file") as batch:
        batch.add_column(sa.Column("info_hash", sa.Text(), nullable=True))
        batch.add_column(sa.Column("downloader_id", sa.Integer(), nullable=True))
        batch.create_foreign_key(
            "fk_library_file_downloader_id",
            "downloader_client",
            ["downloader_id"],
            ["id"],
            ondelete="SET NULL",
        )
        batch.create_index("ix_library_file_info_hash", ["info_hash"], unique=False)
        batch.create_index("ix_library_file_downloader_id", ["downloader_id"], unique=False)

    with op.batch_alter_table("manual_download_intent") as batch:
        batch.add_column(sa.Column("owner", sa.Text(), nullable=False, server_default="manual"))

    # 回填：同一条目的订阅投递过、站点与种子编号对得上的下载记录（取最近一次）
    match = """
        FROM subscription_download_attempt a
        JOIN subscription s ON s.id = a.subscription_id
        WHERE s.media_item_id = library_file.media_item_id
          AND a.site_id = library_file.site_id
          AND a.torrent_id = library_file.torrent_id
        ORDER BY a.id DESC LIMIT 1
    """
    op.execute(
        f"""
        UPDATE library_file
        SET info_hash = (SELECT lower(a.info_hash) {match}),
            downloader_id = (
                SELECT a.downloader_id {match}
            )
        WHERE info_hash IS NULL
          AND site_id IS NOT NULL
          AND torrent_id IS NOT NULL
          AND media_item_id IS NOT NULL
        """
    )


def downgrade() -> None:
    with op.batch_alter_table("manual_download_intent") as batch:
        batch.drop_column("owner")
    with op.batch_alter_table("library_file") as batch:
        batch.drop_index("ix_library_file_downloader_id")
        batch.drop_index("ix_library_file_info_hash")
        batch.drop_constraint("fk_library_file_downloader_id", type_="foreignkey")
        batch.drop_column("downloader_id")
        batch.drop_column("info_hash")
