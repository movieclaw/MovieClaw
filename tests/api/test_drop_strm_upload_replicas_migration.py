"""清掉 .strm 占位文件留下的上传副本记录的迁移回归测试（#921）。"""

from __future__ import annotations

import sqlite3

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config

_BEFORE = "a3e9c5d2b814"  # 本迁移的前一版
_REVISION = "b8d4f1a6c372"


def _insert(connection: sqlite3.Connection, file_id: int, path: str, origin: str, state: str):
    connection.execute(
        "INSERT INTO library_file (id, created_at, updated_at, library_id, season_number,"
        " episode_number, file_path, size_bytes, source, container)"
        " VALUES (?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1, 0, 0, ?, 1, 'SCANNED', 'mkv')",
        (file_id, path),
    )
    connection.execute(
        "INSERT INTO library_file_replica (library_file_id, account_id, remote_id, origin, state,"
        " created_at, updated_at)"
        " VALUES (?, 1, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
        (file_id, f"r-{file_id}", origin, state),
    )


def test_failed_and_pending_strm_uploads_are_dropped(tmp_path, monkeypatch) -> None:
    database = tmp_path / "strm-replicas.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, _BEFORE)

    with sqlite3.connect(database) as connection:
        connection.execute(
            "INSERT INTO library (id, created_at, updated_at, name, kind, root_paths, is_default)"
            " VALUES (1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '纪录片', 'tv', '[]', 0)"
        )
        _insert(connection, 1, "/media/a.strm", "uploaded", "failed")
        _insert(connection, 2, "/media/b.STRM", "uploaded", "uploading")
        _insert(connection, 3, "/media/c.strm", "uploaded", "verified")  # 已传上去的不动
        _insert(connection, 4, "/media/d.mkv", "uploaded", "failed")  # 真视频照旧重试
        _insert(connection, 5, "/media/e.strm", "imported", "failed")
        connection.commit()

    command.upgrade(config, _REVISION)

    with sqlite3.connect(database) as connection:
        rows = connection.execute("SELECT library_file_id FROM library_file_replica ORDER BY 1")
        assert [row[0] for row in rows] == [3, 4, 5]
    get_settings.cache_clear()
