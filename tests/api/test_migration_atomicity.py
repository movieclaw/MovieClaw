"""迁移被强杀后不留半截状态的回归测试。

真实事故：慢盘首装迁移跑到 f3c5d7e9a102（一次建 job 等四张表）时被入口脚本的启动
超时 SIGKILL。SQLite 的 DDL 原本不进事务，job 表已落盘而版本号没前进，此后每次启动
都报 ``table job already exists``，容器永久起不来。
"""

from __future__ import annotations

import os
import signal
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

from alembic import command

from movieclaw_api.core.config import get_settings
from movieclaw_db.migrations import _build_config

_BEFORE = "e2b4c6d8f901"  # 事故迁移的前一版
_REVISION = "f3c5d7e9a102"  # add persistent jobs：建完 job 表后还要建索引和另外三张表
_SRC = Path(__file__).resolve().parents[2] / "src"

# 子进程里跑事故迁移：job 表建好、第一个索引还没建时直接 SIGKILL 自己，
# 与入口脚本超时后强杀后端是同一种中断（不走任何 Python 异常/回滚路径）
_KILL_MID_MIGRATION = f"""
import os, signal
from alembic import command, op
from movieclaw_db.migrations import _build_config

def _die(*_args, **_kwargs):
    os.kill(os.getpid(), signal.SIGKILL)

op.create_index = _die
command.upgrade(_build_config(), {_REVISION!r})
"""


def _tables(database: Path) -> set[str]:
    with sqlite3.connect(database) as connection:
        rows = connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
        return {name for (name,) in rows}


def _version(database: Path) -> str:
    with sqlite3.connect(database) as connection:
        return connection.execute("SELECT version_num FROM alembic_version").fetchone()[0]


def test_killed_migration_rolls_back_and_reruns(tmp_path, monkeypatch) -> None:
    """迁移中途被杀：已建的表随事务作废、版本号停在上一版，重启后能从这里接着升到 head。"""
    database = tmp_path / "killed.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, _BEFORE)

    result = subprocess.run(
        [sys.executable, "-c", _KILL_MID_MIGRATION],
        env={**os.environ, "PYTHONPATH": str(_SRC)},
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == -signal.SIGKILL, result.stderr

    assert "job" not in _tables(database)
    assert _version(database) == _BEFORE

    command.upgrade(config, "head")
    assert "job" in _tables(database)
    get_settings.cache_clear()


def test_each_migration_reports_progress(tmp_path, monkeypatch) -> None:
    """入口脚本靠心跳文件判断迁移仍在推进：每完成一个迁移刷新一次时间戳。"""
    database = tmp_path / "progress.db"
    progress = tmp_path / "migration-progress"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    monkeypatch.setenv("MOVIECLAW_MIGRATION_PROGRESS_FILE", str(progress))
    get_settings.cache_clear()
    started = int(time.time())

    command.upgrade(_build_config(), _BEFORE)

    assert started <= int(progress.read_text(encoding="utf-8")) <= int(time.time())
    get_settings.cache_clear()
