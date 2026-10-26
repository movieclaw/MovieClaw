"""实时连接上的状态快照（``event: status``），Android 常驻通知据此显示下载看板 / 自定义文字。

和通知不同：不进发件箱、不要确认、不占通知的 id 序列，只是「此刻的样子」——连上先发一帧，
之后有变化再发。

- **共享**：所有连接共用一份快照，最多每 ``REFRESH_S`` 秒算一次（读下载器 + 一条查库），
  由在线连接顺带触发；连接再多，下载器和数据库的压力也和一个人开着活动页差不多。
  只有最近有管理员连着时才读下载器。
- **可见性**：下载列表和活动页（``dl.tasks``）一样只给管理员，成员的 ``downloads`` 恒为
  ``null``；今天入库只数这个人看得到的库。
- **节流**（每条连接各自）：个数、片名、状态、今天入库变了立刻发；只有进度、速度、剩余时间
  变了，至少隔 ``PROGRESS_EVERY_S`` 秒才发一次。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
from dataclasses import dataclass
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.i18n.stored import reference, render_value
from movieclaw_api.services.auth import Principal
from movieclaw_db.engine import get_database
from movieclaw_db.models import Library, LibraryFile

logger = logging.getLogger("movieclaw_api.push.status")

#: 共享快照多久重算一次（秒）
REFRESH_S = 15.0
#: 只有进度类变化时，同一条连接最快多久发一次（秒）
PROGRESS_EVERY_S = 30.0
#: 最近这么久没有管理员连着，就不再读下载器（秒）
ADMIN_IDLE_S = 60.0
#: 连上时最多等多久首帧（秒）；等不到就先放行通知，快照好了再发
FIRST_FRAME_WAIT_S = 5.0
#: 看板最多列几条
MAX_ITEMS = 3

#: 算「进行中」的下载器状态（排序即展示顺序：在下的排前面）
_ACTIVE = ("downloading", "checking", "stalled", "queued", "paused")


@dataclass(frozen=True)
class Viewer:
    """一条连接是谁在看：管理员才看得到下载；今天入库只数看得到的库。"""

    is_admin: bool
    library_ids: frozenset[int]


@dataclass(frozen=True)
class _Snapshot:
    server: str
    #: 今天新入账的 (库, 条目, 季, 集)
    today: frozenset[tuple[int, int, int, int]]
    #: 下载概况；None = 这一轮没读下载器
    downloads: dict | None


_snapshot: _Snapshot | None = None
#: 上一次开始重算的时间，以及那次读没读下载器
_attempt: tuple[float, bool] = (float("-inf"), False)
_task: asyncio.Task | None = None
_admin_at = float("-inf")


async def viewer_for(session: AsyncSession, principal: Principal) -> Viewer:
    from movieclaw_api.services.library.access import visible_library_ids

    return Viewer(
        is_admin=principal.is_admin,
        library_ids=frozenset(await visible_library_ids(session, principal)),
    )


async def current(viewer: Viewer, *, wait: bool = False) -> dict | None:
    """这个人此刻该看到的快照（过期了顺带触发重算）；还没有可用的返回 None。

    ``wait``：连接刚建立，等一会儿这一轮重算（首帧）。
    """
    task = _ensure_fresh(viewer.is_admin)
    if wait and task is not None and not task.done():
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(asyncio.shield(task), FIRST_FRAME_WAIT_S)
    return view(_snapshot, viewer)


def view(snapshot: _Snapshot | None, viewer: Viewer) -> dict | None:
    if snapshot is None or (viewer.is_admin and snapshot.downloads is None):
        return None  # 管理员的下载还没读到：宁可晚一帧，不能先报「没有下载」
    units = {row[1:] for row in snapshot.today if row[0] in viewer.library_ids}
    return {
        "server": snapshot.server,
        "today": {"imported": len(units), "updated": len({unit[0] for unit in units})},
        "downloads": _render_downloads(snapshot.downloads) if viewer.is_admin else None,
    }


def _render_downloads(downloads: dict | None) -> dict | None:
    if downloads is None:
        return None
    items = [{**i, "episode": render_value(i["episode"])} for i in downloads["items"]]
    return {**downloads, "items": items}


def _ensure_fresh(is_admin: bool) -> asyncio.Task | None:
    global _task, _attempt, _admin_at
    now = time.monotonic()
    if is_admin:
        _admin_at = now
    with_downloads = now - _admin_at < ADMIN_IDLE_S
    at, had_downloads = _attempt
    if now - at < REFRESH_S and (had_downloads or not with_downloads):
        return _task
    if _task is None or _task.done():
        _attempt = (now, with_downloads)
        _task = asyncio.get_running_loop().create_task(_refresh(with_downloads), name="push-status")
    return _task


async def _refresh(with_downloads: bool) -> None:
    global _snapshot
    from movieclaw_api.services.push.notify import server_identity

    try:
        async with get_database().session() as session:
            today = await _today(session)
            downloads = await _downloads(session) if with_downloads else None
        server = (await server_identity())["name"]
    except Exception:  # noqa: BLE001 -- 快照失败只是常驻通知少点信息，不能影响通知
        logger.exception("刷新实时连接状态快照失败")
        return
    _snapshot = _Snapshot(server=server, today=today, downloads=downloads)


async def _today(session: AsyncSession) -> frozenset[tuple[int, int, int, int]]:
    """今天（按定时任务时区）新入账、认得出的在位文件；图片库不算。"""
    from movieclaw_api.services.library.cover import day_cutoff
    from movieclaw_api.services.push.arrivals import watchable

    libraries = {
        library.id
        for library in (await session.execute(select(Library))).scalars()
        if watchable(library)
    }
    rows = await session.execute(
        select(  # type: ignore[call-overload]
            LibraryFile.library_id,
            LibraryFile.media_item_id,
            LibraryFile.season_number,
            LibraryFile.episode_number,
        )
        .where(
            LibraryFile.created_at >= day_cutoff(),
            LibraryFile.in_place(),
            LibraryFile.media_item_id.is_not(None),  # type: ignore[union-attr]
            LibraryFile.unidentified_code.is_(None),  # type: ignore[union-attr]
        )
        .distinct()
    )
    return frozenset(tuple(row) for row in rows.all() if row[0] in libraries)


async def _downloads(session: AsyncSession) -> dict:
    from movieclaw_api.services.download_tasks import download_task_snapshot

    return summarize((await download_task_snapshot(session))["items"])


def summarize(items: list[dict[str, Any]]) -> dict:
    """活动页的任务列表 → 看板：进行中的个数、总速度、整体进度、前几条。刷流做种不算。"""
    active = [i for i in items if i["state"] in _ACTIVE and i.get("source") != "boost"]
    sized = [i for i in active if i.get("size_bytes")]
    total = sum(i["size_bytes"] for i in sized)
    done = sum(i["size_bytes"] * (i.get("progress") or 0) for i in sized)
    active.sort(key=lambda i: (_ACTIVE.index(i["state"]), -(i.get("progress") or 0)))
    return {
        "active": len(active),
        "speed": sum(i.get("dlspeed_bytes") or 0 for i in active),
        "progress": round(done / total, 3) if total else None,
        "items": [
            {
                "title": i.get("media_title") or i.get("name") or "",
                "episode": _episode_label(i),
                "progress": None if i.get("progress") is None else round(i["progress"], 3),
                "eta": i.get("eta_seconds"),
                "state": i["state"],
            }
            for i in active[:MAX_ITEMS]
        ],
    }


def _episode_label(item: dict[str, Any]) -> str | dict:
    """订阅任务覆盖的集：``E12`` / ``E12 等 3 集``；电影、手动下载、外部任务没有。"""
    units = [u for sub in item.get("subscriptions") or () for u in sub.get("units") or ()]
    episodes = sorted({u["episode_number"] for u in units if u.get("episode_number")})
    if not episodes:
        return ""
    if len(episodes) == 1:
        return f"E{episodes[0]}"
    # 共享快照里存引用，按每条连接的语言渲染（见 view）
    return reference("push.status.episodes", first=episodes[0], count=len(episodes))


def _shape(data: dict) -> tuple:
    """除进度、速度、剩余时间之外的部分：这些变了要立刻发。"""
    downloads = data["downloads"]
    return (
        data["server"],
        data["today"]["imported"],
        data["today"]["updated"],
        downloads
        and (
            downloads["active"],
            tuple((i["title"], i["episode"], i["state"]) for i in downloads["items"]),
        ),
    )


class Throttle:
    """一条连接的发送节流：返回要发的 SSE 帧，或 None（没变 / 还没到间隔）。"""

    def __init__(self) -> None:
        self._last: dict | None = None
        self._sent_at = float("-inf")

    def frame(self, data: dict | None, now: float) -> str | None:
        if data is None or data == self._last:
            return None
        if (
            self._last is not None
            and _shape(data) == _shape(self._last)
            and now - self._sent_at < PROGRESS_EVERY_S
        ):
            return None
        self._last, self._sent_at = data, now
        body = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        # 不带 id：不动 App 的通知游标（Last-Event-ID）
        return f"event: status\ndata: {body}\n\n"


def reset_state() -> None:
    """测试用：丢掉共享快照。"""
    global _snapshot, _attempt, _task, _admin_at
    if _task is not None and not _task.done():
        with contextlib.suppress(RuntimeError):
            _task.cancel()
    _snapshot, _attempt, _task, _admin_at = None, (float("-inf"), False), None, float("-inf")
