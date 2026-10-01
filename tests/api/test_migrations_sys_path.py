"""迁移配置不能往 sys.path 里塞相对路径（应用内更新 overlay 的回归测试）。"""

from __future__ import annotations

import os
from pathlib import Path

from movieclaw_db import migrations


def test_alembic_prepends_absolute_src_of_running_code() -> None:
    """alembic.ini 里的 prepend_sys_path = src 按工作目录解析：容器里会变成 /app/src（镜像旧代码），
    压过 overlay，片头片尾识别子进程因此找不到新模块。必须锁成与本代码同版的绝对路径。"""
    paths = migrations._build_config().get_prepend_sys_paths_list()
    expected = str(Path(migrations.__file__).resolve().parents[2] / "src")
    assert paths == [expected]
    assert all(os.path.isabs(p) for p in paths)
