"""注册表与测试工具的严格模式（plugin-kernel.md §4.2、§4.9）。

冲突、覆盖栈、顺序、观察者、前缀；泄漏检查；可观测。
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass

import pytest

from movieclaw_kernel import (
    PLUGIN_STATE,
    EntryLogFilter,
    RegistryKey,
    Stability,
    State,
    plugin,
)
from movieclaw_kernel.testing import KernelHarness, LeakError


@dataclass(frozen=True)
class Adapter:
    name: str


# 第三方插件也要往里贡献，所以是开放给第三方的实验级注册表
ADAPTERS = RegistryKey("test/adapters", schema=Adapter, stability=Stability.EXPERIMENTAL)


def contributor(name: str, cid: str, item: Adapter, **kw):
    @plugin(name, title=name)
    async def apply(ctx) -> None:
        ctx.contribute(ADAPTERS, cid, item, **kw)

    return apply


async def test_duplicate_contribution_fails_without_override() -> None:
    async with KernelHarness() as h:
        await h.mount(contributor("a", "qb", Adapter("a")))
        fiber = await h.mount(contributor("b", "qb", Adapter("b")))
        assert fiber.state is State.FAILED
        assert "已由 a 贡献" in fiber.error
        assert h.registry(ADAPTERS).get("qb") == Adapter("a")


async def test_override_stack_restores_shadowed_item() -> None:
    changes: list[tuple[str, str]] = []

    @plugin("watcher", title="watcher")
    async def watcher(ctx) -> None:
        ctx.watch(ADAPTERS, lambda c: changes.append((c.kind, c.item.name)))

    async with KernelHarness() as h:
        await h.mount(watcher)
        await h.mount(contributor("builtin-qb", "qb", Adapter("builtin")))
        custom = await h.mount(contributor("user-qb", "qb", Adapter("custom"), override=True))
        assert h.registry(ADAPTERS).get("qb") == Adapter("custom")
        assert h.registry(ADAPTERS).describe()[0]["shadows"] == ["builtin-qb"]
        await h.unmount(custom)
        assert h.registry(ADAPTERS).get("qb") == Adapter("builtin")
    assert changes == [
        ("added", "builtin"),
        ("removed", "builtin"),
        ("added", "custom"),
        ("removed", "custom"),
        ("added", "builtin"),
        ("removed", "builtin"),
    ]


async def test_iteration_order_is_priority_then_tier_then_order() -> None:
    async with KernelHarness() as h:
        await h.mount(contributor("third", "x", Adapter("third"), priority=5), source="acme")
        await h.mount(contributor("low", "y", Adapter("low"), priority=0))
        await h.mount(contributor("high", "z", Adapter("high"), priority=5))
        names = [item.name for item in h.registry(ADAPTERS)]
    assert names == ["high", "third", "low"]


async def test_third_party_ids_are_prefixed() -> None:
    async with KernelHarness() as h:
        await h.mount(contributor("acme.dl", "aria2", Adapter("aria2")), source="acme")
        assert "acme.dl:aria2" in h.registry(ADAPTERS)
        assert "aria2" not in h.registry(ADAPTERS)


async def test_third_party_cannot_touch_internal_registries_or_events() -> None:
    internal = RegistryKey("test/internal-reg")
    from movieclaw_kernel import Event, Mode

    hidden = Event("test/internal-event", Mode.EMIT, payload=int)

    @plugin("acme.contrib", title="c")
    async def contrib(ctx) -> None:
        ctx.contribute(internal, "x", 1)

    @plugin("acme.listen", title="l")
    async def listen(ctx) -> None:
        ctx.on(hidden, lambda v: None)

    async with KernelHarness() as h:
        for p in (contrib, listen):
            fiber = await h.mount(p, source="acme")
            assert fiber.state is State.FAILED
            assert "仅供内置插件使用" in fiber.error
            await h.unmount(fiber)
        # 内置插件不受限
        builtin = await h.mount(contributor("builtin.contrib", "y", Adapter("y")))
        assert builtin.state is State.ACTIVE
        await h.unmount(builtin)
        assert "x" not in h.registry(internal)


async def test_schema_enforced() -> None:
    @plugin("wrong", title="wrong")
    async def wrong(ctx) -> None:
        ctx.contribute(ADAPTERS, "bad", "not an adapter")

    async with KernelHarness() as h:
        fiber = await h.mount(wrong)
        assert fiber.state is State.FAILED
        assert "Adapter" in fiber.error


async def test_watcher_error_does_not_block_contribution(caplog) -> None:
    @plugin("angry", title="angry")
    async def angry(ctx) -> None:
        def explode(change) -> None:
            raise RuntimeError("watcher bug")

        ctx.watch(ADAPTERS, explode)

    async with KernelHarness() as h:
        await h.mount(angry)
        fiber = await h.mount(contributor("fine", "ok", Adapter("ok")))
        assert fiber.state is State.ACTIVE
    assert "watcher bug" in caplog.text


# ---------------------------------------------------------------- 严格模式
async def test_strict_mode_reports_leaked_task() -> None:
    holder: list[asyncio.Task] = []

    @plugin("leaky", title="leaky")
    async def leaky(ctx) -> None:
        # 绕过 ctx.task 直接起任务：卸载时不会被收回
        holder.append(
            asyncio.get_running_loop().create_task(asyncio.sleep(3600), name="plugin:leaky:raw")
        )

    with pytest.raises(LeakError, match="plugin:leaky:raw"):
        async with KernelHarness() as h:
            await h.mount(leaky)
    holder[0].cancel()


async def test_strict_mode_reports_leaked_contribution() -> None:
    @plugin("sly", title="sly")
    async def sly(ctx) -> None:
        # 绕过 ctx.contribute：不会登记撤销函数
        ctx.registry(ADAPTERS).add("sly", Adapter("sly"), entry_id="sly")

    with pytest.raises(LeakError, match="sly"):
        async with KernelHarness() as h:
            await h.mount(sly)


async def test_clean_plugin_passes_strict_mode() -> None:
    @plugin("tidy", title="tidy")
    async def tidy(ctx) -> None:
        ctx.task(asyncio.sleep(3600), name="sleep")
        ctx.contribute(ADAPTERS, "tidy", Adapter("tidy"))
        ctx.on(PLUGIN_STATE, lambda e: None)

    async with KernelHarness() as h:
        await h.mount(tidy)


# ---------------------------------------------------------------- 可观测
async def test_log_records_carry_entry_id(caplog) -> None:
    caplog.handler.addFilter(EntryLogFilter())
    caplog.set_level(logging.INFO)

    @plugin("talker", title="talker")
    async def talker(ctx) -> None:
        logging.getLogger("movieclaw_api.deep.domain").info("from deep code")

    async with KernelHarness() as h:
        await h.mount(talker)
    record = next(r for r in caplog.records if r.getMessage() == "from deep code")
    assert record.plugin == "talker"


async def test_plugin_state_events_and_snapshot() -> None:
    states: list[tuple[str, str]] = []

    @plugin("monitor", title="monitor")
    async def monitor(ctx) -> None:
        ctx.on(PLUGIN_STATE, lambda e: states.append((e.entry_id, e.state)))

    @plugin("boom", title="boom")
    async def boom(ctx) -> None:
        raise RuntimeError("x")

    async with KernelHarness() as h:
        await h.mount(monitor)
        await h.mount(boom)
        await h.drain()
        snap = {item["id"]: item for item in h.kernel.snapshot()}
        assert snap["boom"]["state"] == "failed"
        assert snap["boom"]["error"] == "RuntimeError: x"
        assert snap["monitor"]["stats"]["listeners"] == 1
        assert snap["monitor"]["apply_ms"] is not None
        contracts = h.kernel.contracts()
        assert any(e["name"] == "kernel/plugin-state" for e in contracts["events"])
    assert ("boom", "loading") in states
    assert ("boom", "failed") in states
