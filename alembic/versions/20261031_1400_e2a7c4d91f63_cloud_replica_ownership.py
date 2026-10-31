"""Converge cloud aliases before enforcing one owner per remote file (#1122)."""

import sqlalchemy as sa
from alembic import op

revision = "e2a7c4d91f63"
down_revision = "b8f21c4a90d3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 非空 id 在 lost/failed 等状态下仍代表同一个物理文件；只有空 id 不参与唯一性。
    # 优先保留在位、真实本地、上传来源的行。只删虚拟双账，绝不删本地/网盘字节。
    op.execute("""
        DELETE FROM library_file_replica
        WHERE library_file_id NOT IN (SELECT id FROM library_file)
    """)
    op.execute("""
        CREATE TEMP TABLE cloud_replica_alias AS
        SELECT * FROM (
            SELECT r.id AS replica_id, f.id AS file_id, f.library_id, f.media_item_id,
                   ROW_NUMBER() OVER (
                       PARTITION BY r.account_id, r.remote_id
                       ORDER BY CASE f.state WHEN 'IN_PLACE' THEN 0
                                             WHEN 'MISSING' THEN 1 ELSE 2 END,
                                f.local_bytes DESC, (r.origin = 'uploaded') DESC, f.id
                   ) AS position
            FROM library_file_replica r JOIN library_file f ON f.id = r.library_file_id
            WHERE r.remote_id != ''
        ) WHERE position > 1
    """)
    op.execute("""
        DELETE FROM library_file_replica
        WHERE id IN (SELECT replica_id FROM cloud_replica_alias)
    """)
    # Alembic 连接未开启 foreign_keys；显式落实虚拟行的级联清理，防止 id 复用继承旧状态。
    for table, column in (
        ("media_segment", "library_file_id"),
        ("strm_probe_state", "file_id"),
        ("subtitle_auto_mute", "library_file_id"),
        ("library_file_fingerprint", "library_file_id"),
    ):
        op.execute(
            sa.text(f"""
            DELETE FROM {table} WHERE {column} IN (
                SELECT a.file_id FROM cloud_replica_alias a
                JOIN library_file f ON f.id = a.file_id WHERE f.local_bytes = 0
            )
        """)
        )
    op.execute("""
        DELETE FROM library_file
        WHERE id IN (SELECT file_id FROM cloud_replica_alias) AND local_bytes = 0
    """)
    # 删除过的虚拟行不能继续出现在重复清理的缓存结论中（含跨库单元）。
    op.execute("""
        DELETE FROM library_duplicate_unit
        WHERE media_item_id IN (SELECT media_item_id FROM cloud_replica_alias)
    """)
    # 修正受影响库的快照；不把虚拟双账留在文件数、容量和待识别计数里。
    op.execute("""
        UPDATE library SET
            stats_file_count = (SELECT COUNT(*) FROM library_file f
                WHERE f.library_id = library.id AND f.state = 'IN_PLACE'),
            stats_total_size_bytes = (SELECT COALESCE(SUM(size_bytes), 0) FROM library_file f
                WHERE f.library_id = library.id AND f.state = 'IN_PLACE'),
            stats_item_count = (SELECT COUNT(DISTINCT media_item_id) FROM library_file f
                WHERE f.library_id = library.id AND f.state != 'TRASHED'
                  AND f.unidentified_code IS NULL),
            stats_episode_count = CASE WHEN kind = 'tv' THEN (
                SELECT COUNT(*) FROM (SELECT 1 FROM library_file f
                    WHERE f.library_id = library.id AND f.state = 'IN_PLACE'
                      AND f.unidentified_code IS NULL AND f.media_item_id IS NOT NULL
                    GROUP BY media_item_id, season_number, episode_number)
                ) ELSE 0 END,
            stats_unidentified_count = (SELECT COUNT(*) FROM library_file f
                WHERE f.library_id = library.id AND f.state = 'IN_PLACE'
                  AND f.unidentified_code IS NOT NULL AND f.ignored_at IS NULL),
            stats_missing_count = (SELECT COUNT(*) FROM library_file f
                WHERE f.library_id = library.id AND f.state = 'MISSING'),
            stats_ignored_count = (SELECT COUNT(*) FROM library_file f
                WHERE f.library_id = library.id AND f.state = 'IN_PLACE'
                  AND f.ignored_at IS NOT NULL),
            stats_refreshed_at = CURRENT_TIMESTAMP
        WHERE id IN (SELECT library_id FROM cloud_replica_alias)
    """)
    op.execute("DROP TABLE cloud_replica_alias")
    op.drop_index("ix_library_file_replica_account_remote", table_name="library_file_replica")
    op.create_index(
        "uq_library_file_replica_account_remote",
        "library_file_replica",
        ["account_id", "remote_id"],
        unique=True,
        sqlite_where=sa.text("remote_id != ''"),
    )


def downgrade() -> None:
    op.drop_index("uq_library_file_replica_account_remote", table_name="library_file_replica")
    op.create_index(
        "ix_library_file_replica_account_remote",
        "library_file_replica",
        ["account_id", "remote_id"],
    )
    # 双账不复原；升级从未操作任何媒体字节。
