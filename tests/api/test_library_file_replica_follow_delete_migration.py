"""副本记录随台账行一起删的迁移回归测试（#909）。"""

from __future__ import annotations

import sqlite3

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config

_BEFORE = "f7d2b4e8a139"  # 本迁移的前一版
_REVISION = "a3e9c5d2b814"


def _insert_file(connection: sqlite3.Connection, file_id: int, created_at: str) -> None:
    connection.execute(
        "INSERT INTO library_file (id, created_at, updated_at, library_id, season_number,"
        " episode_number, file_path, size_bytes, source)"
        " VALUES (?, ?, ?, 1, 0, 0, ?, 1, 'SCANNED')",
        (file_id, created_at, created_at, f"/media/{file_id}.mkv"),
    )


def _insert_replica(connection: sqlite3.Connection, file_id: int, created_at: str) -> None:
    connection.execute(
        "INSERT INTO library_file_replica (library_file_id, account_id, remote_id, origin, state,"
        " created_at, updated_at) VALUES (?, 1, ?, 'imported', 'verified', ?, ?)",
        (file_id, f"r-{file_id}", created_at, created_at),
    )


def _replicas(connection: sqlite3.Connection) -> list[int]:
    rows = connection.execute("SELECT library_file_id FROM library_file_replica ORDER BY 1")
    return [row[0] for row in rows]


def test_leftover_replicas_are_dropped_and_new_deletes_take_the_replica(
    tmp_path, monkeypatch
) -> None:
    database = tmp_path / "replica-follow-delete.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, _BEFORE)

    with sqlite3.connect(database) as connection:
        connection.execute(
            "INSERT INTO library (id, created_at, updated_at, name, kind, root_paths, is_default)"
            " VALUES (1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '动漫', 'tv', '[]', 0)"
        )
        _insert_file(connection, 1, "2026-10-18 10:00:00.000000")
        _insert_file(connection, 2, "2026-10-18 14:44:04.000000")
        _insert_file(connection, 3, "2026-10-18 15:00:00.000000")
        _insert_replica(connection, 1, "2026-10-18 10:00:01.000000")  # 正常
        _insert_replica(connection, 2, "2026-10-18 13:03:57.000000")  # 早于台账行：复用 id 挂上的
        _insert_replica(connection, 3, "2026-10-18 15:00:01.000000")  # 正常
        _insert_replica(connection, 99, "2026-10-18 09:00:00.000000")  # 台账行已经没了
        connection.commit()

    command.upgrade(config, _REVISION)

    with sqlite3.connect(database) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        assert _replicas(connection) == [1, 3]
        # 直接删台账行、删库级联删台账行，副本记录都跟着走
        connection.execute("DELETE FROM library_file WHERE id = 1")
        assert _replicas(connection) == [3]
        connection.execute("DELETE FROM library WHERE id = 1")
        assert connection.execute("SELECT count(*) FROM library_file").fetchone() == (0,)
        assert _replicas(connection) == []
    get_settings.cache_clear()
