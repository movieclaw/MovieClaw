"""内容语言的两列译文是可空旁路：老库升级后原列不动、译文为 NULL，回滚干净。"""

import sqlite3

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config


def test_existing_titles_survive_upgrade_and_rollback(tmp_path, monkeypatch):
    database = tmp_path / "legacy-content.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY)")
        connection.execute("INSERT INTO alembic_version VALUES ('c6f14d3a9b72')")
        connection.execute("CREATE TABLE media_item (id INTEGER PRIMARY KEY, title TEXT)")
        connection.execute(
            "CREATE TABLE media_metadata (id INTEGER PRIMARY KEY, media_item_id INTEGER, "
            "overview TEXT)"
        )
        connection.execute("INSERT INTO media_item VALUES (1, '人生切割术')")
        connection.execute("INSERT INTO media_metadata VALUES (1, 1, '马克领导着一个团队。')")
    config = _build_config()
    try:
        command.upgrade(config, "d7a25e81c4f0")
        with sqlite3.connect(database) as connection:
            assert connection.execute(
                "SELECT title, title_translations FROM media_item"
            ).fetchone() == ("人生切割术", None)
            assert connection.execute(
                "SELECT overview, overview_translations FROM media_metadata"
            ).fetchone() == ("马克领导着一个团队。", None)
        command.downgrade(config, "c6f14d3a9b72")
        with sqlite3.connect(database) as connection:
            assert connection.execute("SELECT * FROM media_item").fetchone() == (1, "人生切割术")
            assert connection.execute("SELECT * FROM media_metadata").fetchone() == (
                1,
                1,
                "马克领导着一个团队。",
            )
    finally:
        get_settings.cache_clear()
