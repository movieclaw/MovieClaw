"""Upgrading legacy identification records adds references without changing their text."""

import sqlite3

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config


def test_existing_failure_text_survives_upgrade_and_downgrade(tmp_path, monkeypatch):
    database = tmp_path / "legacy-identification.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    reason = "旧版中文原因与用户标题「Original title」"
    # Only this table is affected by the migration; no unrelated schema is needed.
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY)")
        connection.execute("INSERT INTO alembic_version VALUES ('b7d0f3a582c1')")
        connection.execute(
            "CREATE TABLE library_file (id INTEGER PRIMARY KEY, unidentified_reason TEXT)"
        )
        connection.execute("INSERT INTO library_file VALUES (1, ?)", (reason,))
    config = _build_config()
    try:
        command.upgrade(config, "c8e1a4b693d2")
        with sqlite3.connect(database) as connection:
            assert connection.execute(
                "SELECT unidentified_reason, unidentified_message FROM library_file"
            ).fetchone() == (reason, None)
        command.downgrade(config, "b7d0f3a582c1")
        with sqlite3.connect(database) as connection:
            assert connection.execute(
                "SELECT unidentified_reason FROM library_file"
            ).fetchone() == (reason,)
    finally:
        get_settings.cache_clear()
