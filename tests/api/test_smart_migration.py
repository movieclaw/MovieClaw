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
        ignore=shutil.ignore_patterns(
            "__pycache__", "20261007_1200_e7f4a1c9b203_smart_subscription.py",
            "20261007_1800_f8316ab24d90_smart_lab.py",
            "20261007_1900_c9a72e4d6b10_remove_smart_lab.py",
        ),
    )
    config.set_main_option("script_location", str(old_scripts))
    with pytest.raises(CommandError, match="c9a72e4d6b10"):
        command.upgrade(config, "head")
    # 回退恢复完整备份，不删除模式字段或把智能订阅塞进默认规则。
    shutil.copy2(backup, path)
    command.upgrade(config, "head")
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT rule_set_id FROM subscription").fetchone() == (1,)
    get_settings.cache_clear()
