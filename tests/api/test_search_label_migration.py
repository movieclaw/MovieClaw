"""An old search scope name is preserved verbatim through migration and rollback."""

import sqlite3

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config


def test_existing_scope_name_survives_upgrade_and_downgrade(tmp_path, monkeypatch):
    database = tmp_path / "legacy-search.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    name = "电影"  # Could be a custom name; the migration must not infer a built-in key.
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY)")
        connection.execute("INSERT INTO alembic_version VALUES ('c8e1a4b693d2')")
        connection.execute("CREATE TABLE search_history (id INTEGER PRIMARY KEY, label TEXT)")
        connection.execute("INSERT INTO search_history VALUES (1, ?)", (name,))
    config = _build_config()
    try:
        command.upgrade(config, "d9f2b5c704e3")
        with sqlite3.connect(database) as connection:
            assert connection.execute("SELECT label, label_key FROM search_history").fetchone() == (
                name,
                None,
            )
        command.downgrade(config, "c8e1a4b693d2")
        with sqlite3.connect(database) as connection:
            assert connection.execute("SELECT label FROM search_history").fetchone() == (name,)
    finally:
        get_settings.cache_clear()
