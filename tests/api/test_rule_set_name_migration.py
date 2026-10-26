"""An existing name cannot establish built-in provenance during migration."""

import sqlite3

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config


def test_legacy_names_survive_upgrade_and_rollback(tmp_path, monkeypatch):
    database = tmp_path / "legacy-rule-names.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY)")
        connection.execute("INSERT INTO alembic_version VALUES ('d9f2b5c704e3')")
        connection.execute("CREATE TABLE rule_set (id INTEGER PRIMARY KEY, name TEXT)")
        connection.executemany(
            "INSERT INTO rule_set VALUES (?, ?)", [(1, "默认规则组"), (2, "我的规则")]
        )
    config = _build_config()
    try:
        command.upgrade(config, "e1a4c7f903b2")
        with sqlite3.connect(database) as connection:
            assert connection.execute(
                "SELECT name, name_key FROM rule_set ORDER BY id"
            ).fetchall() == [("默认规则组", None), ("我的规则", None)]
        command.downgrade(config, "d9f2b5c704e3")
        with sqlite3.connect(database) as connection:
            assert connection.execute("SELECT name FROM rule_set ORDER BY id").fetchall() == [
                ("默认规则组",),
                ("我的规则",),
            ]
    finally:
        get_settings.cache_clear()
