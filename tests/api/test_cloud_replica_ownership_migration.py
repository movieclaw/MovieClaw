"""历史双账先安全收敛，唯一索引才能在用户库上落地（#1122）。"""

import sqlite3

import pytest
from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config

_BEFORE = "b8f21c4a90d3"
_REVISION = "e2a7c4d91f63"


def test_existing_aliases_converge_without_deleting_local_files(tmp_path, monkeypatch):
    database = tmp_path / "ownership.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, _BEFORE)
    with sqlite3.connect(database) as connection:
        connection.execute("""
            INSERT INTO library (id, created_at, updated_at, name, kind, root_paths, is_default)
            VALUES (1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '电影', 'movie', '[]', 0)
        """)
        for file_id, local, state, origin, remote, account in [
            (1, 0, "IN_PLACE", "imported", "shared", 1),
            (2, 0, "IN_PLACE", "uploaded", "shared", 1),  # 来源更完整，保留
            (3, 0, "TRASHED", "imported", "shared", 1),  # 已经待清理的虚拟双账
            (4, 1, "IN_PLACE", "uploaded", "local-shared", 1),
            (5, 1, "IN_PLACE", "uploaded", "local-shared", 1),  # 真本地文件保留
            (6, 0, "IN_PLACE", "imported", "shared", 2),  # 不同账号各自独立
            (7, 1, "IN_PLACE", "uploaded", "", 1),
            (8, 1, "IN_PLACE", "uploaded", "", 1),  # 多个上传中空 id 合法
            (9, 0, "MISSING", "uploaded", "returned", 1),
            (10, 0, "IN_PLACE", "imported", "returned", 1),  # 在位优先于失联
        ]:
            connection.execute(
                """
                INSERT INTO library_file (id, created_at, updated_at, library_id, season_number,
                    episode_number, file_path, size_bytes, source, state, local_bytes)
                VALUES (?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1, 0, 0, ?, 100,
                    'SCANNED', ?, ?)
            """,
                (file_id, f"/media/{file_id}.mkv", state, local),
            )
            connection.execute(
                """
                INSERT INTO library_file_replica (library_file_id, account_id, remote_id,
                    origin, state, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """,
                (file_id, account, remote, origin, "lost" if state == "MISSING" else "verified"),
            )
        for file_id in (1, 5):
            connection.execute(
                """
                INSERT INTO media_segment (library_file_id, created_at, updated_at)
                VALUES (?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """,
                (file_id,),
            )
            connection.execute(
                """
                INSERT INTO strm_probe_state (file_id, failures, created_at, updated_at)
                VALUES (?, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """,
                (file_id,),
            )
            connection.execute(
                """
                INSERT INTO subtitle_auto_mute
                    (library_file_id, target_language, created_at, updated_at)
                VALUES (?, 'chs', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """,
                (file_id,),
            )
            connection.execute(
                """
                INSERT INTO library_file_fingerprint (library_file_id, size_bytes, sha1,
                    source, computed_at, created_at, updated_at)
                VALUES (?, 100, 'SHA1', 'local', CURRENT_TIMESTAMP,
                    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """,
                (file_id,),
            )
        connection.commit()

    command.upgrade(config, _REVISION)
    with sqlite3.connect(database) as connection:
        assert [r[0] for r in connection.execute("SELECT id FROM library_file ORDER BY id")] == [
            2,
            4,
            5,
            6,
            7,
            8,
            10,
        ]
        assert [
            r[0]
            for r in connection.execute(
                "SELECT library_file_id FROM library_file_replica ORDER BY library_file_id"
            )
        ] == [2, 4, 6, 7, 8, 10]
        assert connection.execute(
            "SELECT stats_file_count, stats_total_size_bytes FROM library"
        ).fetchone() == (7, 700)
        assert connection.execute("PRAGMA foreign_key_check").fetchall() == []
        for table, column in (
            ("media_segment", "library_file_id"),
            ("strm_probe_state", "file_id"),
            ("subtitle_auto_mute", "library_file_id"),
            ("library_file_fingerprint", "library_file_id"),
        ):
            assert connection.execute(f"SELECT {column} FROM {table}").fetchall() == [(5,)]
        with pytest.raises(sqlite3.IntegrityError, match="UNIQUE constraint"):
            connection.execute("""
                UPDATE library_file_replica SET remote_id = 'shared', state = 'lost'
                WHERE library_file_id = 7
            """)
        connection.rollback()
        # 原有删行触发器仍生效，避免旧副本挂到 SQLite 复用的 id 上。
        connection.execute("DELETE FROM library_file WHERE id = 2")
        assert connection.execute(
            "SELECT count(*) FROM library_file_replica WHERE library_file_id = 2"
        ).fetchone() == (0,)
        connection.commit()
    command.downgrade(config, _BEFORE)
    command.upgrade(config, _REVISION)
    get_settings.cache_clear()
