"""原库升级保持旧语义；旧迁移集合拒绝消费智能版本；备份可恢复。"""

import shutil
import sqlite3
from pathlib import Path

import pytest
from alembic import command
from alembic.util.exc import CommandError

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config


def test_legacy_upgrade_and_old_runtime_refusal_then_backup_restore(tmp_path, monkeypatch):
    path = tmp_path / "data.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{path}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, "a5c3f19d7e42")
    with sqlite3.connect(path) as db:
        db.execute(
            "INSERT INTO subscription "
            "(id,created_at,updated_at,media_item_id,kind,selected_seasons,"
            "follow_future,rule_set_id,status) "
            "VALUES (1,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,1,'tv','[1]',0,1,'active')"
        )
    backup = tmp_path / "backup.db"
    shutil.copy2(path, backup)
    command.upgrade(config, "f8316ab24d90")
    with sqlite3.connect(path) as db:
        db.execute(
            "INSERT INTO smart_lab_run (id,created_at,updated_at,report,feedback) "
            "VALUES (1,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,'{}','{}')"
        )
        db.execute(
            "INSERT INTO smart_profile (kind,created_at,updated_at,revision,preferences) "
            "VALUES ('tv',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,3,'{}')"
        )
    command.upgrade(config, "head")
    with sqlite3.connect(path) as db:
        assert db.execute(
            "SELECT name FROM sqlite_master WHERE name='smart_lab_run'"
        ).fetchone() is None
        assert db.execute("SELECT kind,revision FROM smart_profile").fetchone() == ("tv", 3)
        assert db.execute(
            "SELECT rule_set_id,selection_mode,smart_policy FROM subscription"
        ).fetchone() == (1, "rules", None)
        assert db.execute(
            "SELECT name FROM sqlite_master WHERE type='trigger' AND "
            "name='trg_subscription_activity_last_activity'"
        ).fetchone()
    old_scripts = tmp_path / "old-alembic"
    shutil.copytree(
        Path(config.get_main_option("script_location")),
        old_scripts,
        # 旧程序：智能订阅（20261007_1200）及之后的迁移都没有
        ignore=lambda _dir, names: [
            n
            for n in names
            if n == "__pycache__" or (n[:1].isdigit() and n[:13] >= "20261007_1200")
        ],
    )
    config.set_main_option("script_location", str(old_scripts))
    with pytest.raises(CommandError, match="Can't locate revision"):
        command.upgrade(config, "head")
    # 回退恢复完整备份，不删除模式字段或把智能订阅塞进默认规则。
    shutil.copy2(backup, path)
    command.upgrade(config, "head")
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT rule_set_id FROM subscription").fetchone() == (1,)
    get_settings.cache_clear()
