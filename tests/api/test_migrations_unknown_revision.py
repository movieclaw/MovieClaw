"""库的迁移位置本版不认识时，启动报错要说人话（用户反馈：升级后只看到 alembic 原文）。"""

from __future__ import annotations

import sqlite3

import pytest

from movieclaw_api.core.config import get_settings
from movieclaw_db import migrations


def test_unknown_revision_explains_itself(tmp_path, monkeypatch) -> None:
    """自行改过代码的部署往库里写了官方没有的迁移号，正式版启动时必须讲清原因与出路。"""
    database = tmp_path / "foreign-revision.db"
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE alembic_version (version_num VARCHAR(32) NOT NULL)")
        connection.execute("INSERT INTO alembic_version VALUES ('a3f7c2d1b8e4')")
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    try:
        with pytest.raises(migrations.UnknownRevisionError) as caught:
            migrations._upgrade_to_head()
    finally:
        get_settings.cache_clear()

    message = str(caught.value)
    assert "a3f7c2d1b8e4" in message
    assert "data/updates/backup" in message
