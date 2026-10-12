"""待处理事项推给管理员（docs/design/cloud-push.md §5、domain-events.md §6.1）。

``system.alert.raised`` 的聚合器：问题常常一冒就是一串，先攒 90 秒、收编到根因、过冷却，再推。
"""

from __future__ import annotations

import asyncio
import logging
import time

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.push.notify import AlertContent, notify

logger = logging.getLogger("movieclaw_api.push.alerts")

#: 偏好开关的键（= 事件名）
KEY = "system.alert.raised"


def notice_path(source: str, payload: dict) -> str:
    """待处理事项的跳转：能修它的页面（与网页、App 的待处理列表同一套映射）。"""
    if source == "subscription":
        subscription_id = payload.get("subscription_id")
        return f"/subscriptions/{subscription_id}" if subscription_id else "/subscriptions"
    if source == "plugin":
        # 插件可以带一个站内路径指向能修它的地方（插件包回滚 → 插件管理页）；没带就定位到
        # 插件页里它那一行（docs/design/plugin-page-tiers.md §4.1）
        href = payload.get("action_href")
        if isinstance(href, str) and href.startswith("/") and not href.startswith("//"):
            return href
        entry_id = payload.get("entry_id")
        return f"/settings/plugins?module={entry_id}" if entry_id else "/settings/plugins"
    return {
        "channel": "/settings/im-push",
        "ingest": "/settings/import-watch",
        "downloader": "/settings/downloaders",
        "site": "/settings/sites",
        "cloud": "/settings/cloud",
    }.get(source, "/settings")


#: 同一个问题多久最多推一次：下载器、站点时好时坏时，问题会反复消退又复发，每次都响
#: 就成了刷屏。只在内存里，重启后最多多推一次
_ALERT_COOLDOWN_S = 6 * 3600
_alert_pushed_at: dict[str, float] = {}
#: 新出现的问题先等这么久再推：问题常常一冒就是一串（一次挂载故障 = 一条目录级告警 +
#: 每个卡住的种子一条），等它们出齐、收编好只推根因那条；这段时间里自己好了的也不推
_ALERT_DELAY_S = 90.0
_alert_queue: list[str] = []
_alert_flush: asyncio.TimerHandle | None = None
#: 一个订阅底下按种子各亮一条的告警：按订阅算冷却，不按种子
_PER_SUBSCRIPTION_ALERTS = ("subscription.ambiguous:", "subscription.landing:")


def _alert_family(dedupe_key: str) -> str:
    for prefix in _PER_SUBSCRIPTION_ALERTS:
        if dedupe_key.startswith(prefix):
            return prefix + dedupe_key[len(prefix) :].split(":", 1)[0]
    return dedupe_key


#: 单独推过、还没消退的问题：键 → 标题（只在内存里，重启后消退就不再补「已恢复」）
_pushed_alone: dict[str, str] = {}

#: 「问题已恢复」的偏好开关
RESOLVED_KEY = "system.alert.resolved"


def resolved(dedupe_key: str) -> None:
    """推过的问题消失了：同一条通知原地改成「已恢复」，安静送达。没推过的不说。"""
    title = _pushed_alone.pop(dedupe_key, None)
    if title is None:
        return

    async def build(_session: AsyncSession, _member_id: int) -> AlertContent:
        return AlertContent(
            title=f"已恢复：{title}",
            body="问题已经自动消失，不用处理了。",
            thread="system",
            source="server",
            level="passive",
        )

    notify(RESOLVED_KEY, {0}, build, collapse=("notice", dedupe_key))


def queue(dedupe_key: str) -> None:
    """待处理事项新出现或复发：等一会儿，和同一时间冒出来的一起推给管理员。"""
    global _alert_flush
    from movieclaw_api.services.push.dispatcher import spawn

    if dedupe_key not in _alert_queue:
        _alert_queue.append(dedupe_key)
    if _alert_flush is not None:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return  # 没有事件循环（命令行工具里）：不推

    def fire() -> None:
        global _alert_flush
        _alert_flush = None
        spawn(_send_alerts())

    _alert_flush = loop.call_later(_ALERT_DELAY_S, fire)


async def _send_alerts() -> None:
    """把攒下的待处理事项推出去：只推还亮着的、不在根因底下的、冷却期外的。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeSeverity, NoticeStatus, SystemNotice

    keys = list(_alert_queue)
    _alert_queue.clear()
    if not keys:
        return
    async with get_database().session() as session:
        rows = (
            (
                await session.execute(
                    select(SystemNotice).where(
                        SystemNotice.dedupe_key.in_(keys),  # type: ignore[attr-defined]
                        SystemNotice.status == NoticeStatus.ACTIVE.value,
                    )
                )
            )
            .scalars()
            .all()
        )
        parents = {
            str(row.payload.get("grouped_under"))
            for row in rows
            if isinstance(row.payload, dict) and row.payload.get("grouped_under")
        }
        active_parents = set(
            (
                await session.execute(
                    select(SystemNotice.dedupe_key).where(  # type: ignore[call-overload]
                        SystemNotice.dedupe_key.in_(parents),  # type: ignore[attr-defined]
                        SystemNotice.status == NoticeStatus.ACTIVE.value,
                    )
                )
            ).scalars()
        )
    now = time.monotonic()
    due: list[SystemNotice] = []
    for row in rows:
        payload = row.payload if isinstance(row.payload, dict) else {}
        if payload.get("grouped_under") in active_parents:
            continue  # 收在根因底下：推根因那条就够了
        family = _alert_family(row.dedupe_key)
        last = _alert_pushed_at.get(family)
        if last is not None and now - last < _ALERT_COOLDOWN_S:
            continue
        _alert_pushed_at[family] = now
        due.append(row)
    if not due:
        return
    # 严重的在前，同样严重的按出现先后
    due.sort(key=lambda r: (r.severity != NoticeSeverity.ERROR.value, keys.index(r.dedupe_key)))
    first = due[0]
    first_payload = first.payload if isinstance(first.payload, dict) else {}
    # 有严重的（下载器、站点整个不可用这类）就用时效性：专注模式下也要让管理员知道
    level = "time-sensitive" if first.severity == NoticeSeverity.ERROR.value else "active"
    if len(due) == 1:
        content = AlertContent(
            title=first.title,
            body=first.message,
            open=notice_path(first.source, first_payload),
            thread="system",
            source="server",
            level=level,
        )
        collapse = ("notice", first.dedupe_key)
        # 单独推过的问题：消退时原地改成「已恢复」（resolved）
        _pushed_alone[first.dedupe_key] = first.title
    else:
        names = "；".join(r.title for r in due[:3])
        content = AlertContent(
            title=f"有 {len(due)} 个问题需要处理",
            body=names + ("等" if len(due) > 3 else ""),
            open=notice_path(first.source, first_payload),
            thread="system",
            source="server",
            level=level,
        )
        collapse = ("notice", "batch")

    async def build(_session: AsyncSession, _member_id: int) -> AlertContent:
        return content

    notify(KEY, {0}, build, collapse=collapse)


def reset_state() -> None:
    """测试用：清掉冷却与攒着的告警。"""
    global _alert_flush
    _alert_pushed_at.clear()
    _alert_queue.clear()
    _pushed_alone.clear()
    if _alert_flush is not None:
        _alert_flush.cancel()
        _alert_flush = None
