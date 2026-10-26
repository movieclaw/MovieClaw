"""Presentation references never enter the strict state JSON consumed by old servers."""

import json
import sqlite3

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config


def test_selection_messages_upgrade_and_downgrade_preserve_legacy_state_bytes(
    tmp_path, monkeypatch
):
    database = tmp_path / "legacy-selection.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    state = json.dumps(
        {"anchor": "2026-10-24T00:00:00", "wait_explanation": "原始等待解释"}, ensure_ascii=False
    )
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY)")
        connection.execute("INSERT INTO alembic_version VALUES ('e1a4c7f903b2')")
        connection.execute(
            "CREATE TABLE wanted_item (id INTEGER PRIMARY KEY, selection_state JSON)"
        )
        connection.execute("INSERT INTO wanted_item VALUES (1, ?)", (state,))
    config = _build_config()
    try:
        command.upgrade(config, "f2b5d8a014c3")
        with sqlite3.connect(database) as connection:
            assert connection.execute(
                "SELECT selection_state, selection_messages FROM wanted_item"
            ).fetchone() == (state, None)
            connection.execute(
                "UPDATE wanted_item SET selection_messages = ?",
                ('{"wait_explanation":{"message_key":"subscription.selection.publishedAnchor"}}',),
            )
        command.downgrade(config, "e1a4c7f903b2")
        with sqlite3.connect(database) as connection:
            assert (
                connection.execute("SELECT selection_state FROM wanted_item").fetchone()[0] == state
            )
            assert "selection_messages" not in {
                column[1] for column in connection.execute("PRAGMA table_info(wanted_item)")
            }
        command.upgrade(config, "f2b5d8a014c3")
        with sqlite3.connect(database) as connection:
            assert connection.execute(
                "SELECT selection_state, selection_messages FROM wanted_item"
            ).fetchone() == (state, None)
    finally:
        get_settings.cache_clear()
