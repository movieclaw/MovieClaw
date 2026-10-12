"""守护：业务代码只经 ``movieclaw_api.events.publish*`` 产生事件（domain-events.md §4）。

通知、Webhook、插件都是事件的订阅方。业务代码直接调它们的出口（推送的产生函数、Webhook 投递、
插件实时事件、可靠事件写入）就又回到了「同一件事在一处连调好几个出口」。
"""

from __future__ import annotations

import re
from pathlib import Path

SRC = Path(__file__).resolve().parents[2] / "src"

#: 直接调用某个出口的写法
OUTLETS = re.compile(
    r"services\.push import events"
    r"|push\.events import"
    r"|push\.hub import"
    r"|push\.notify import"
    r"|emit_events\("
    r"|hooks\.emit\("
    r"|durable_events\.record\("
    r"|\.events\.emit\("
    r"|bus\.emit\("
)

#: 出口自己、唯一入口、总线本身（内核自己的生命周期事件）：它们本来就要碰这些
OWNERS = {
    "movieclaw_api/events.py",
    "movieclaw_api/services/durable_events.py",
}
OWNER_PACKAGES = (
    "movieclaw_api/services/push/",
    "movieclaw_api/services/webhook/",
    "movieclaw_kernel/",
)


def _offenders() -> set[str]:
    found: set[str] = set()
    for path in SRC.rglob("*.py"):
        rel = path.relative_to(SRC).as_posix()
        if rel in OWNERS or rel.startswith(OWNER_PACKAGES):
            continue
        if OUTLETS.search(path.read_text(encoding="utf-8")):
            found.add(rel)
    return found


def test_business_code_only_publishes_events() -> None:
    offenders = _offenders()
    assert not offenders, (
        "这些文件直接调了通知 / Webhook / 插件事件的出口，改用 movieclaw_api.events.publish："
        + "、".join(sorted(offenders))
    )
