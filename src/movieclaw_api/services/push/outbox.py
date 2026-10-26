"""自托管实时通知：每台设备一个发件箱 + 一条 SSE 长连接（cloud-push.md §4.1）。

不依赖苹果、谷歌或手机厂商的推送：开了「实时通知（保持连接）」的 Android App 在前台服务里
一直连着 ``GET /push/me/stream``。

- **写**：推送分发（notify.prepare）给这类设备每台写一行发件箱，并唤醒它在线的连接；
- **读**：连上时先补发游标之后、还没送达的，再实时送新的；每 25 秒一行心跳注释，
  防止反向代理、运营商 NAT 把空闲连接掐掉；
- **确认**：App 显示后 ``POST /push/me/ack``，标记送达，之后重连不再补发；
- **状态**：同一条连接上还发 ``event: status``（下载概况、今天入库，见 status.py），
  不进发件箱、不要确认，供 App 的常驻通知显示；
- **清理**：写入时顺手清掉已送达的、超过 7 天的，每台设备最多留 200 条未送达的。

唤醒只在本进程内（asyncio.Event）；连接同时每几秒查一次库兜底，漏了唤醒也只是晚几秒。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from datetime import timedelta

from sqlalchemy import delete, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.push import status
from movieclaw_db.engine import get_database
from movieclaw_db.models import PushOutbox, utcnow

logger = logging.getLogger("movieclaw_api.push.outbox")

#: 每台设备最多留多少条未送达的（再多就丢最旧的：一周没连上的手机不需要一百多条旧通知）
MAX_PENDING = 200
#: 多久之前的不再补发
RETENTION = timedelta(days=7)
#: 心跳间隔（秒）：比常见反向代理 / NAT 的 60 秒空闲超时短得多
HEARTBEAT_S = 25.0
#: 没被唤醒时多久查一次库兜底（秒）
POLL_S = 5.0
#: 单条连接最长保持多久（秒）：到点由服务器正常结束，App 立刻带游标重连，
#: 顺带清掉代理、休眠网络留下的「半死」连接
MAX_CONNECTION_S = 3600.0
#: 一次补发最多几条
_BATCH = 100

#: 设备 id → 在等新通知的连接
_waiters: dict[int, set[asyncio.Event]] = {}


def connected(device_id: int) -> bool:
    """这台设备此刻有没有连着实时通知。"""
    return bool(_waiters.get(device_id))


def wake(device_id: int) -> None:
    """有新通知了：叫醒这台设备在线的连接（必须在事件循环线程里调）。"""
    for event in _waiters.get(device_id, ()):
        event.set()


async def enqueue(session: AsyncSession, device_id: int, payload: dict) -> int:
    """给一台设备写一条（随调用方的会话提交；提交后调 ``wake``）。"""
    row = PushOutbox(login_device_id=device_id, payload=payload)
    session.add(row)
    await session.flush()
    await _prune(session, device_id)
    assert row.id is not None
    return row.id


async def _prune(session: AsyncSession, device_id: int) -> None:
    # 已送达的、过期的（所有设备一起清：一直没连上的设备不会再有别的机会被清）
    await session.execute(
        delete(PushOutbox).where(
            (PushOutbox.delivered_at.is_not(None))  # type: ignore[union-attr]
            | (PushOutbox.created_at < utcnow() - RETENTION)
        )
    )
    # 这台设备未送达的超过上限：丢最旧的
    keep_from = (
        await session.execute(
            select(PushOutbox.id)
            .where(PushOutbox.login_device_id == device_id)
            .order_by(PushOutbox.id.desc())  # type: ignore[union-attr]
            .offset(MAX_PENDING - 1)
            .limit(1)
        )
    ).scalar_one_or_none()
    if keep_from is not None:
        await session.execute(
            delete(PushOutbox).where(
                PushOutbox.login_device_id == device_id,
                PushOutbox.id < keep_from,  # type: ignore[operator]
            )
        )


async def pending(session: AsyncSession, device_id: int, *, after: int) -> list[PushOutbox]:
    """游标之后、还没送达、没过期的（按 id 升序）。"""
    rows = await session.execute(
        select(PushOutbox)
        .where(
            PushOutbox.login_device_id == device_id,
            PushOutbox.id > after,  # type: ignore[operator]
            PushOutbox.delivered_at.is_(None),  # type: ignore[union-attr]
            PushOutbox.created_at >= utcnow() - RETENTION,
        )
        .order_by(PushOutbox.id)  # type: ignore[arg-type]
        .limit(_BATCH)
    )
    return list(rows.scalars())


async def ack(session: AsyncSession, device_id: int, up_to: int) -> int:
    """App 确认收到了 ``up_to`` 及之前的：标记送达，返回标记了几条。"""
    result = await session.execute(
        update(PushOutbox)
        .where(
            PushOutbox.login_device_id == device_id,
            PushOutbox.id <= up_to,  # type: ignore[operator]
            PushOutbox.delivered_at.is_(None),  # type: ignore[union-attr]
        )
        .values(delivered_at=utcnow())
    )
    await session.commit()
    return int(result.rowcount or 0)  # type: ignore[attr-defined]


async def clear(session: AsyncSession, device_id: int) -> None:
    """设备关掉了实时通知：发件箱一起清掉（随调用方的会话提交）。"""
    await session.execute(delete(PushOutbox).where(PushOutbox.login_device_id == device_id))


def format_event(row: PushOutbox) -> str:
    """SSE 帧：``id`` 是发件箱 id（App 存成游标），``data`` 是通知内容 + ``id``。"""
    data = json.dumps({"id": row.id, **row.payload}, ensure_ascii=False, separators=(",", ":"))
    return f"id: {row.id}\nevent: notification\ndata: {data}\n\n"


async def stream(
    device_id: int,
    *,
    since: int,
    is_disconnected: Callable[[], Awaitable[bool]],
    viewer: status.Viewer,
) -> AsyncIterator[str]:
    """一条实时连接：先发状态快照、补发 ``since`` 之后未送达的，再实时送新的，空闲时发心跳。"""
    event = asyncio.Event()
    _waiters.setdefault(device_id, set()).add(event)
    cursor = since
    started = time.monotonic()
    last_sent = started
    throttle = status.Throttle()
    try:
        # 连上就先发一行注释：代理和 App 都能立刻确认连接已建立（不推进游标）
        yield ": connected\n\n"
        first = True
        while True:
            event.clear()
            frame = throttle.frame(await status.current(viewer, wait=first), time.monotonic())
            first = False
            if frame is not None:
                yield frame
                last_sent = time.monotonic()
            async with get_database().session() as session:
                rows = await pending(session, device_id, after=cursor)
            for row in rows:
                assert row.id is not None
                cursor = row.id
                yield format_event(row)
                last_sent = time.monotonic()
            if len(rows) == _BATCH:
                continue
            now = time.monotonic()
            if now - started >= MAX_CONNECTION_S or await is_disconnected():
                return
            if now - last_sent >= HEARTBEAT_S:
                yield ": heartbeat\n\n"
                last_sent = now
            timeout = min(POLL_S, max(0.05, HEARTBEAT_S - (now - last_sent)))
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(event.wait(), timeout=timeout)
    finally:
        waiters = _waiters.get(device_id)
        if waiters is not None:
            waiters.discard(event)
            if not waiters:
                _waiters.pop(device_id, None)
