"""守护：业务代码只经 ``movieclaw_api.events.publish*`` 产生事件（domain-events.md §4）。

通知、Webhook、插件都是事件的订阅方。业务代码直接调它们的出口（推送的产生函数、Webhook 投递、
插件实时事件、可靠事件写入）就又回到了「同一件事在一处连调好几个出口」。

``LEGACY`` 是迁移中还没改完的调用点，每迁完一个域就从这里删掉；收口（P5）时它应当为空。
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
    r"|domain_events\.(record|deletion_recorder)"
    r"|durable_events\.record\("
)

#: 出口自己、以及唯一入口：它们本来就要碰这些
OWNERS = {
    "movieclaw_api/events.py",
    "movieclaw_api/domain_events.py",
    "movieclaw_api/services/durable_events.py",
}
OWNER_PACKAGES = ("movieclaw_api/services/push/", "movieclaw_api/services/webhook/")

#: 迁移中还没改完的调用点（每期收紧，P5 清空）
LEGACY = {
    "movieclaw_api/api/routes/auth.py",
    "movieclaw_api/api/routes/libraries.py",
    "movieclaw_api/services/app_update.py",
    "movieclaw_api/services/download_progress.py",
    "movieclaw_api/services/library/ingest.py",
    "movieclaw_api/services/library/recycle.py",
    "movieclaw_api/services/library/scan.py",
    "movieclaw_api/services/login_devices.py",
    "movieclaw_api/services/playback/marks.py",
    "movieclaw_api/services/playback/watch.py",
    "movieclaw_api/services/reels/clip_tip.py",
    "movieclaw_api/services/subscription/core.py",
    "movieclaw_api/services/subscription/dispatch.py",
    "movieclaw_api/services/subscription/twins.py",
    "movieclaw_api/services/subscription/upgrade.py",
    "movieclaw_api/services/subscription/wanted_fulfillment.py",
    "movieclaw_api/services/system_notice.py",
    "movieclaw_jellyfin/routes/library.py",
    "movieclaw_jellyfin/routes/users.py",
}


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
    offenders = _offenders() - LEGACY
    assert not offenders, (
        "这些文件直接调了通知 / Webhook / 插件事件的出口，改用 movieclaw_api.events.publish："
        + "、".join(sorted(offenders))
    )


def test_legacy_list_only_shrinks() -> None:
    # 迁完的文件要从 LEGACY 里删掉，免得它又悄悄长回去
    stale = LEGACY - _offenders()
    assert not stale, "这些文件已经不直接调出口了，从 LEGACY 里删掉：" + "、".join(sorted(stale))
