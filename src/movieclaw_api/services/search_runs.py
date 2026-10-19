"""进程内站点搜索运行注册表：搜索在后台跑完，页面只是它的显示屏（#920）。

流式搜索原先把站点请求挂在 SSE 响应上：页面一离开（切页、刷新、关标签）生成器
被关，未返回的站点请求全被取消，回来只能从头再打一遍站。这里把一次搜索变成
后台运行：

- 运行由注册表持有强引用，订阅连接断开不影响它跑完（快照照常回写）；
- 每次运行维护一份只追加的事件日志（已序列化的 SSE 载荷），订阅者各持游标，
  新接上的从头回放、断线续传的从 ``Last-Event-ID`` 之后接着读；
- 同一个搜索（``SearchRunKey`` 相同）在跑或刚跑完时直接接上，不重复打站——
  对 PT 站来说每次重搜都是真实请求、消耗站点配额。

与 Agent 运行注册表同构但更简单：搜索是有界的一次性扇出（单站有超时），没有
取消/补配对/心跳这些会话语义。仅在单个 API 进程内有效，重启即清空：一次搜索
十几秒就结束，为重启续搜引入持久化不值得，重启后重搜即可。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field

logger = logging.getLogger("movieclaw_api.search_runs")

#: 跑完的搜索在内存里留多久可被直接接上（秒）；过期后同样的搜索重新打站
RETENTION_SECONDS = 10 * 60
#: 跑完的搜索最多留几份（结果含富化属性，多站时一份可达数 MB，NAS 内存敏感）；超出先丢最早跑完的
MAX_FINISHED = 8


@dataclass(frozen=True, slots=True)
class SearchRunKey:
    """「同一个搜索」的判据：这些都相同，结果就该相同，可以直接复用。

    ``owner``（历史归属）与 ``allowed``（成员可用站点白名单）都参与：不同成员
    能搜的站点不同，快照也写进各自的历史行。``record_history`` 参与是因为
    无痕搜索的运行不写快照，不能顶替一次要留快照的搜索。
    """

    owner: int
    allowed: frozenset[str] | None
    keyword: str
    also_keywords: tuple[str, ...]
    categories: tuple[str, ...]
    site_ids: tuple[str, ...]
    label: str | None
    page: int
    record_history: bool


@dataclass(eq=False, slots=True)
class SearchRun:
    """一次搜索运行；events 是 ``(事件名, JSON 载荷)``，下标 + 1 即 SSE ``id``。"""

    key: SearchRunKey
    condition: asyncio.Condition = field(default_factory=asyncio.Condition)
    events: list[tuple[str, str]] = field(default_factory=list)
    task: asyncio.Task[None] | None = None
    terminal: bool = False
    completed_at: float | None = None


class SearchRunRegistry:
    """持有后台搜索运行，按 ``SearchRunKey`` 复用，并给订阅者回放/续传事件。"""

    def __init__(
        self,
        *,
        retention_seconds: float = RETENTION_SECONDS,
        max_finished: int = MAX_FINISHED,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._retention_seconds = retention_seconds
        self._max_finished = max_finished
        self._clock = clock
        self._runs: dict[SearchRunKey, SearchRun] = {}

    def find(self, key: SearchRunKey, *, fresh: bool = False) -> SearchRun | None:
        """可直接接上的运行：在跑的一律接上；跑完的在保留期内且没要求 ``fresh`` 才接。

        ``fresh`` 是「明确要新结果」（重新搜索、单站重试），但正在跑的搜索本身就是
        最新的，再并发打一轮站没有意义，所以照样接上。
        """
        self._prune()
        run = self._runs.get(key)
        if run is None or (run.terminal and fresh):
            return None
        return run

    def start(self, key: SearchRunKey, source: AsyncIterator[tuple[str, str]]) -> SearchRun:
        """登记并在后台跑一次搜索；同 key 的旧运行（已跑完）被顶替。

        与 ``find`` 之间不能有 await：两者在同一事件循环里连续执行，并发的同一个
        搜索才不会各起一轮。
        """
        run = SearchRun(key=key)
        self._runs[key] = run
        run.task = asyncio.create_task(self._execute(run, source), name="site-search-run")
        return run

    async def read(
        self, run: SearchRun, after: int, *, timeout_seconds: float
    ) -> tuple[list[tuple[str, str]], bool]:
        """返回游标后的事件与「运行是否已结束」；暂无新事件时最多等 ``timeout_seconds``。

        结束标志在最后一个事件追加之后才置位，所以拿到 ``True`` 时本批就是全部剩余事件。
        """
        async with run.condition:
            if after >= len(run.events) and not run.terminal:
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(
                        run.condition.wait_for(lambda: after < len(run.events) or run.terminal),
                        timeout=timeout_seconds,
                    )
            return run.events[after:], run.terminal

    async def close(self) -> None:
        """停机：取消在跑的搜索（站点客户端随后关闭），清空注册表。"""
        tasks = [run.task for run in self._runs.values() if run.task and not run.task.done()]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._runs.clear()

    async def _execute(self, run: SearchRun, source: AsyncIterator[tuple[str, str]]) -> None:
        completed = False
        try:
            async for event, data in source:
                async with run.condition:
                    run.events.append((event, data))
                    run.condition.notify_all()
            completed = True
        except Exception:  # noqa: BLE001 —— 后台运行没有调用方可抛，记日志后收尾
            logger.exception("站点搜索后台运行异常结束")
        finally:
            async with run.condition:
                run.terminal = True
                run.completed_at = self._clock()
                run.condition.notify_all()
            # 没走完的运行（异常/停机取消）不留着复用：下次同样的搜索应重新打站
            if not completed and self._runs.get(run.key) is run:
                del self._runs[run.key]

    def _prune(self) -> None:
        """丢掉过了保留期的、以及超出份数上限的（最早跑完的先丢）已结束运行。"""
        now = self._clock()
        finished = sorted(
            (run for run in self._runs.values() if run.completed_at is not None),
            key=lambda run: run.completed_at or 0.0,
        )
        overflow = len(finished) - self._max_finished
        for index, run in enumerate(finished):
            assert run.completed_at is not None
            if index < overflow or now - run.completed_at > self._retention_seconds:
                del self._runs[run.key]


_registry: SearchRunRegistry | None = None


def init_search_run_registry() -> SearchRunRegistry:
    """为当前应用生命周期初始化唯一的搜索运行注册表。"""
    global _registry
    _registry = SearchRunRegistry()
    return _registry


def get_search_run_registry() -> SearchRunRegistry:
    """取得搜索运行注册表；仅供应用启动后的请求使用。"""
    if _registry is None:
        raise RuntimeError("站点搜索运行注册表尚未初始化")
    return _registry


async def close_search_run_registry() -> None:
    """关闭并清空当前生命周期的注册表。"""
    global _registry
    if _registry is not None:
        await _registry.close()
        _registry = None
