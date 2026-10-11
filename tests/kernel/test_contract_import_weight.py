"""进程外插件导入开放契约要轻（docs/design/plugin-ipc-http.md §8 压测发现）。

运行器握手时按名字查开放事件（``protocol.known_events``），会导入钩子与领域事件模块。领域事件模块曾在
顶层导入宿主的写库辅助（``durable_events``、sqlalchemy），每个订阅事件的插件进程因此多背约 70 MB 的
数据库层与 numpy。契约模块只能依赖内核与 pydantic，宿主侧辅助一律在函数里导入。
"""

from __future__ import annotations

import subprocess
import sys

HEAVY = ("sqlalchemy", "sqlmodel", "movieclaw_db", "numpy", "cryptography")


def test_open_contracts_import_without_the_database_layer() -> None:
    probe = (
        "import sys\n"
        "from movieclaw_sdk.protocol import known_events\n"
        "assert known_events()\n"
        f"print(','.join(m for m in {HEAVY!r} if m in sys.modules))\n"
    )
    loaded = subprocess.run(
        [sys.executable, "-c", probe], capture_output=True, text=True, check=True
    ).stdout.strip()
    assert loaded == "", f"开放契约的导入链带进了 {loaded}"
