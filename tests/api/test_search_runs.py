"""SearchRunRegistry：后台运行不随订阅者断开、同一搜索复用、fresh、过期与份数上限（#920）。"""

from __future__ import annotations

import asyncio

from movieclaw_api.services.search_runs import SearchRunKey, SearchRunRegistry


def _key(keyword: str = "沙丘", **overrides) -> SearchRunKey:
    fields = dict(
        owner=0,
        allowed=None,
        keyword=keyword,
        also_keywords=(),
        categories=(),
        site_ids=(),
        label=None,
        page=1,
        record_history=True,
    )
    fields.update(overrides)
    return SearchRunKey(**fields)


class _Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


async def _gated(release: asyncio.Event, error: Exception | None = None):
    """先发 start，等放行再发 done；可在放行后抛错模拟运行异常。"""
    yield "start", "{}"
    await release.wait()
    if error is not None:
        raise error
    yield "done", "{}"


async def _finished():
    yield "start", "{}"
    yield "done", "{}"


async def _drain(registry: SearchRunRegistry, run, after: int = 0) -> list[str]:
    names: list[str] = []
    while True:
        batch, terminal = await registry.read(run, after, timeout_seconds=1)
        names += [name for name, _ in batch]
        after += len(batch)
        if terminal:
            return names


async def test_running_search_is_shared_and_replayed_from_start() -> None:
    registry = SearchRunRegistry()
    release = asyncio.Event()
    run = registry.start(_key(), _gated(release))
    first, terminal = await registry.read(run, 0, timeout_seconds=1)
    assert [name for name, _ in first] == ["start"] and not terminal

    # 第一个订阅者「断开」（不再读），同一个搜索再来：接上同一运行，fresh 也不另起一轮
    assert registry.find(_key()) is run
    assert registry.find(_key(), fresh=True) is run
    release.set()
    assert await _drain(registry, run) == ["start", "done"]  # 新订阅者从头回放完整序列
    await registry.close()


async def test_finished_search_reused_until_fresh_or_expired() -> None:
    clock = _Clock()
    registry = SearchRunRegistry(retention_seconds=600, clock=clock)
    run = registry.start(_key(), _finished())
    await _drain(registry, run)

    assert registry.find(_key()) is run
    assert registry.find(_key(), fresh=True) is None  # 明确要新结果
    assert registry.find(_key("奥本海默")) is None  # 不同搜索互不相干
    assert registry.find(_key(page=2)) is None

    clock.now += 601
    assert registry.find(_key()) is None  # 过了保留期，重新打站


async def test_finished_runs_capped_oldest_dropped_first() -> None:
    clock = _Clock()
    registry = SearchRunRegistry(max_finished=2, clock=clock)
    runs = []
    for keyword in ("a", "b", "c"):
        clock.now += 1
        run = registry.start(_key(keyword), _finished())
        await _drain(registry, run)
        runs.append(run)

    assert registry.find(_key("a")) is None
    assert registry.find(_key("b")) is runs[1]
    assert registry.find(_key("c")) is runs[2]


async def test_failed_run_ends_subscribers_and_is_not_reused() -> None:
    registry = SearchRunRegistry()
    release = asyncio.Event()
    run = registry.start(_key(), _gated(release, error=RuntimeError("boom")))
    release.set()
    assert await _drain(registry, run) == ["start"]  # 订阅者收尾，不会永远等
    assert registry.find(_key()) is None


async def test_close_cancels_running_searches() -> None:
    registry = SearchRunRegistry()
    release = asyncio.Event()
    run = registry.start(_key(), _gated(release))
    await registry.read(run, 0, timeout_seconds=1)
    await registry.close()
    assert run.task is not None and run.task.cancelled()
    assert run.terminal
    assert registry.find(_key()) is None
