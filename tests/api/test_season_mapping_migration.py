"""media_item.season_mapping 是纯加的可空列：老库升级后原列不动、映射为 NULL，回滚干净。

三态语义（docs/design/subscription-season-split.md §6）：NULL = 没算过、
[] = 算过且无需映射、非空 = 有映射。迁移只负责加列，存量条目一律 NULL。
"""

import sqlite3

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config


def test_existing_items_survive_upgrade_and_rollback(tmp_path, monkeypatch):
    database = tmp_path / "legacy-season-mapping.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE alembic_version (version_num VARCHAR(32) PRIMARY KEY)")
        connection.execute("INSERT INTO alembic_version VALUES ('e2a7c4d91f63')")
        connection.execute(
            "CREATE TABLE media_item (id INTEGER PRIMARY KEY, title TEXT, aliases TEXT)"
        )
        connection.execute("INSERT INTO media_item VALUES (1, '我独自升级', '[\"Solo Leveling\"]')")
    config = _build_config()
    try:
        command.upgrade(config, "f3b8d15c7a29")
        with sqlite3.connect(database) as connection:
            row = connection.execute("SELECT * FROM media_item").fetchone()
        # 新列排在末尾、值为 NULL（= 没算过，下一次刷新补齐）
        assert row == (1, "我独自升级", '["Solo Leveling"]', None)

        command.downgrade(config, "e2a7c4d91f63")
        with sqlite3.connect(database) as connection:
            assert connection.execute("SELECT * FROM media_item").fetchone() == (
                1,
                "我独自升级",
                '["Solo Leveling"]',
            )
    finally:
        get_settings.cache_clear()
