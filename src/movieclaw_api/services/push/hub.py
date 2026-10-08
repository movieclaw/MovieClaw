"""推送事件中枢（docs/design/cloud-push.md §5.1）：业务只投事件，推送自己慢慢算。

推送越做越细（按批合并、按观看进度写文案、查哪几集还在路上），这些都不能压到业务链路上。
所以业务侧只有一个动作：``emit(事件)``——放进内存队列就返回，不碰数据库、不起任务、不抛错，
开销是一次 ``put_nowait``。

队列只有**一个**消费者，串行处理：

- 合并状态（cards.py 的剧卡）只在这里改，不用锁，也不会两个事件同时改一张卡；
- 定时（「安静 2 分钟再发」「15 分钟发第一条」）也投回同一个队列（``Tick``），和业务事件排队；
- 消费者要查库（收件人、可见范围、还有几集在路上）时用自己的会话；真正的发送（写文案、
  加密、发给中继）再交给 ``notify`` 的后台任务，消费者不等它们。

队列有上限：真的积压到上限（推送这边卡死了）就丢新事件、记一条日志，绝不反压业务。
状态只在内存里：服务恰好在合并中重启，最坏是这一批少一条或多一条通知。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from dataclasses import dataclass

logger = logging.getLogger("movieclaw_api.push.hub")

#: 队列上限：正常情况下一批入库也就几十个事件，到上限说明消费者出了问题
QUEUE_MAX = 5000

Unit = tuple[int, int]


@dataclass(frozen=True)
class Started:
    """订阅找到资源、交给下载器了。``skip_member_id``：手动选种时点下载的人，不提醒他。"""

    subscription_id: int
    item_id: int
    units: tuple[Unit, ...]
    detail: str
    upgrade: bool
    skip_member_id: int | None = None
    #: IM 消息里的来源（「来自 hdsky 的『…』」）与规格
    source: str = ""
    spec: str = ""


@dataclass(frozen=True)
class Imported:
    """订阅的这几集整理进媒体库了（订阅对账确认）。"""

    subscription_id: int
    item_id: int
    units: tuple[Unit, ...]


@dataclass(frozen=True)
class Downloaded:
    """手动下载的一个种子入库完了（services/push/downloads.py 的 ``Finished``）。"""

    finished: object


@dataclass(frozen=True)
class LibraryArrivals:
    """「媒体库有新片」检查出一批新到的：``items`` 是 (条目, 单元们)。"""

    library_id: int
    items: tuple[tuple[int, tuple[Unit, ...]], ...]


@dataclass(frozen=True)
class Upgraded:
    """订阅的一集换成了更好的版本。"""

    subscription_id: int
    item_id: int
    unit: Unit
    old_label: str
    new_label: str


@dataclass(frozen=True)
class Tick:
    """定时到了：重新看一眼这张卡（``key`` 见 cards.py）。"""

    key: tuple


_queue: asyncio.Queue | None = None
_dropped = 0
_drop_logged_at = float("-inf")
_worker: asyncio.Task | None = None
_loop: asyncio.AbstractEventLoop | None = None


def emit(event: object) -> None:
    """投一个事件。业务链路上调用：O(1)，不抛错；没有事件循环（命令行工具）时丢弃。"""
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    try:
        _ensure(loop).put_nowait(event)
    except asyncio.QueueFull:
        global _dropped, _drop_logged_at
        _dropped += 1
        # 积压时每分钟只记一条，别让日志反过来拖慢业务
        if loop.time() - _drop_logged_at >= 60:
            logger.warning("推送事件积压到上限（%d），已丢弃 %d 个", QUEUE_MAX, _dropped)
            _drop_logged_at = loop.time()
            _dropped = 0
    except Exception:  # noqa: BLE001 -- 推送绝不能影响业务
        logger.exception("投递推送事件失败（已忽略）")


def later(delay: float, event: object) -> asyncio.TimerHandle | None:
    """``delay`` 秒后把 ``event`` 投回队列（剧卡的定时）。"""
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return None
    return loop.call_later(max(0.0, delay), emit, event)


def now() -> float:
    """合并用的时钟（事件循环的单调时钟）。"""
    return asyncio.get_running_loop().time()


def _ensure(loop: asyncio.AbstractEventLoop) -> asyncio.Queue:
    """懒启动：第一次有事件时建队列和消费者；换了事件循环（测试里重建应用）就重建。"""
    global _queue, _worker, _loop
    if _queue is None or _loop is not loop:
        _queue = asyncio.Queue(maxsize=QUEUE_MAX)
        _loop = loop
        _worker = None
    if _worker is None or _worker.done():
        _worker = loop.create_task(_run(_queue), name="push-hub")
    return _queue


async def _run(queue: asyncio.Queue) -> None:
    from movieclaw_api.services.push import cards

    while True:
        event = await queue.get()
        try:
            await cards.handle(event)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 -- 一个事件出错不能停掉整个消费者
            logger.exception("处理推送事件失败（已忽略）：%s", type(event).__name__)
        finally:
            queue.task_done()


async def drain() -> None:
    """等队列里已有的事件处理完（测试用）。"""
    if _queue is not None:
        await _queue.join()


async def stop() -> None:
    """关停：停消费者、取消所有定时。"""
    global _queue, _worker, _loop
    from movieclaw_api.services.push import cards

    cards.reset_state()
    worker, _worker = _worker, None
    _queue = None
    _loop = None
    if worker is not None and not worker.done():
        worker.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await worker


def reset_state() -> None:
    """测试用：丢掉队列和消费者（下一个事件循环里重建）。"""
    global _queue, _worker, _loop
    from movieclaw_api.services.push import cards

    cards.reset_state()
    if _worker is not None and not _worker.done():
        with contextlib.suppress(RuntimeError):
            _worker.cancel()
    _queue = None
    _worker = None
    _loop = None
