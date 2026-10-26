"""LLM localization adds a nullable sidecar without altering old error text."""

import sqlite3

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config


def test_legacy_llm_error_survives_upgrade_and_rollback(tmp_path, monkeypatch):
    database = tmp_path / "legacy-llm.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    original = "旧供应商原文：Connection refused"
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY)")
        connection.execute("INSERT INTO alembic_version VALUES ('f2b5d8a014c3')")
        connection.execute("CREATE TABLE llm_provider (id INTEGER PRIMARY KEY, last_error TEXT)")
        connection.execute("INSERT INTO llm_provider VALUES (1, ?)", (original,))
    config = _build_config()
    try:
        command.upgrade(config, "a3c6f9b217d4")
        with sqlite3.connect(database) as connection:
            assert connection.execute(
                "SELECT last_error, last_error_ref FROM llm_provider"
            ).fetchone() == (original, None)
        command.downgrade(config, "f2b5d8a014c3")
        with sqlite3.connect(database) as connection:
            assert connection.execute("SELECT last_error FROM llm_provider").fetchone() == (
                original,
            )
    finally:
        get_settings.cache_clear()
