"""内核生命周期（plugin-kernel.md §12.1）。

依赖等待、失败回滚、关键插件、超时、静态校验、契约、补丁、关闭顺序。
"""

from __future__ import annotations

import asyncio
import time

import pytest

from movieclaw_kernel import (
    Entry,
    Kernel,
    KernelConfigError,
    KernelStartupError,
    Patch,
    ServiceKey,
    Stability,
    State,
    plugin,
)
from movieclaw_kernel.testing import KernelHarness

DB = ServiceKey("test/db")
CACHE = ServiceKey("test/cache")
EXP = ServiceKey("test/exp", version="1.3", stability=Stability.EXPERIMENTAL)


def make_provider(name: str, key: ServiceKey, value: object, log: list[str] | None = None, **kw):
    @plugin(name, title=name, provides=(key,), **kw)
    async def apply(ctx) -> None:
        if log is not None:
            log.append(f"start:{name}")
            ctx.effect(lambda: log.append(f"stop:{name}"))
        ctx.provide(key, value)

    return apply


def make_consumer(name: str, *keys: ServiceKey, log: list[str] | None = None, **kw):
    @plugin(name, title=name, inject=keys, **kw)
    async def apply(ctx) -> None:
        for key in keys:
            ctx.use(key)
        if log is not None:
            log.append(f"start:{name}")
            ctx.effect(lambda: log.append(f"stop:{name}"))

    return apply


async def test_dependency_order_independent_of_manifest_order() -> None:
    log: list[str] = []
    kernel = Kernel()
    await kernel.start(
        [
            Entry("consumer", make_consumer("consumer", DB, log=log)),
            Entry("db", make_provider("db", DB, "conn", log)),
        ]
    )
    assert log == ["start:db", "start:consumer"]
    assert kernel.fiber("consumer").state is State.ACTIVE
    await kernel.stop()
    assert log[-2:] == ["stop:consumer", "stop:db"]
    assert kernel.dispose_log == ["consumer", "db"]


async def test_same_level_follows_manifest_order() -> None:
    log: list[str] = []
    kernel = Kernel()
    await kernel.start(
        [
            Entry("a", make_consumer("a", log=log)),
            Entry("b", make_consumer("b", log=log)),
            Entry("c", make_consumer("c", log=log)),
        ]
    )
    await kernel.stop()
    assert log == ["start:a", "start:b", "start:c", "stop:c", "stop:b", "stop:a"]


async def test_missing_provider_stays_pending_with_reason() -> None:
    kernel = Kernel()
    await kernel.start([Entry("lonely", make_consumer("lonely", CACHE))])
    fiber = kernel.fiber("lonely")
    assert fiber.state is State.PENDING
    info = kernel.describe(fiber)
    assert info["blocked_by"] == [{"key": "test/cache", "reason": "没有插件提供"}]
    await kernel.stop()


async def test_failed_provider_reason_is_reported() -> None:
    @plugin("bad-db", title="bad", provides=(DB,))
    async def bad(ctx) -> None:
        raise RuntimeError("boom")

    kernel = Kernel()
    await kernel.start([Entry("bad-db", bad), Entry("user", make_consumer("user", DB))])
    assert kernel.fiber("bad-db").state is State.FAILED
    assert kernel.fiber("bad-db").error == "RuntimeError: boom"
    info = kernel.describe(kernel.fiber("user"))
    assert info["state"] == "pending"
    assert info["blocked_by"][0]["reason"] == "提供方 bad-db 状态为 failed"
    await kernel.stop()


async def test_withdrawn_provider_cascades_and_recovers() -> None:
    starts: list[str] = []
    stops: list[str] = []

    @plugin("user", title="user", inject=(DB,))
    async def user(ctx) -> None:
        starts.append(ctx.use(DB))
        ctx.effect(lambda: stops.append("user"))

    async with KernelHarness() as h:
        h.provide(DB, "v1")
        fiber = await h.mount(user)
        assert fiber.state is State.ACTIVE
        await h.withdraw(DB)
        assert fiber.state is State.PENDING
        assert stops == ["user"]
        h.provide(DB, "v2")
        await h.settle()
        assert fiber.state is State.ACTIVE
        assert starts == ["v1", "v2"]


async def test_apply_failure_rolls_back_registered_effects() -> None:
    undone: list[str] = []

    @plugin("half", title="half")
    async def half(ctx) -> None:
        ctx.effect(lambda: undone.append("first"))
        ctx.effect(lambda: undone.append("second"))
        ctx.task(asyncio.sleep(3600), name="sleeper")
        raise ValueError("half way")

    async with KernelHarness() as h:
        fiber = await h.mount(half)
        assert fiber.state is State.FAILED
        assert undone == ["second", "first"]
        assert not fiber.tasks
        assert "ValueError" in fiber.stats.last_error


async def test_critical_failure_aborts_and_releases_started() -> None:
    log: list[str] = []

    @plugin("settings", title="settings", critical=True, inject=(DB,))
    async def settings(ctx) -> None:
        raise RuntimeError("no settings")

    kernel = Kernel()
    with pytest.raises(KernelStartupError, match="settings"):
        await kernel.start(
            [
                Entry("db", make_provider("db", DB, 1, log, critical=True)),
                Entry("settings", settings),
                Entry("later", make_consumer("later", log=log)),
            ]
        )
    assert log == ["start:db", "stop:db"]
    assert kernel.fiber("later").state is State.PENDING


async def test_non_critical_timeout_fails_fast_and_startup_continues() -> None:
    @plugin("stuck", title="stuck", apply_timeout=0.05)
    async def stuck(ctx) -> None:
        await asyncio.sleep(10)

    log: list[str] = []
    kernel = Kernel()
    started = time.perf_counter()
    await kernel.start([Entry("stuck", stuck), Entry("ok", make_consumer("ok", log=log))])
    assert time.perf_counter() - started < 2
    assert kernel.fiber("stuck").state is State.FAILED
    assert kernel.fiber("stuck").error == "启动超时"
    assert log == ["start:ok"]
    await kernel.stop()


async def test_critical_plugins_have_no_timeout() -> None:
    @plugin("migrate", title="migrate", critical=True, apply_timeout=0.01)
    async def migrate(ctx) -> None:
        await asyncio.sleep(0.05)

    assert migrate.apply_timeout is None
    kernel = Kernel()
    await kernel.start([Entry("migrate", migrate)])
    assert kernel.fiber("migrate").state is State.ACTIVE
    await kernel.stop()


@pytest.mark.parametrize(
    ("manifest", "message"),
    [
        (
            lambda: [Entry("x", make_consumer("x")), Entry("x", make_consumer("x2"))],
            "条目 id 重复",
        ),
        (
            lambda: [
                Entry("a", make_provider("a", DB, 1)),
                Entry("b", make_provider("b", DB, 2)),
            ],
            "同时由",
        ),
    ],
)
async def test_static_errors(manifest, message) -> None:
    with pytest.raises(KernelConfigError, match=message):
        await Kernel().start(manifest())


async def test_dependency_cycle_rejected() -> None:
    @plugin("a", title="a", inject=(CACHE,), provides=(DB,))
    async def a(ctx) -> None: ...

    @plugin("b", title="b", inject=(DB,), provides=(CACHE,))
    async def b(ctx) -> None: ...

    with pytest.raises(KernelConfigError, match="成环"):
        await Kernel().start([Entry("a", a), Entry("b", b)])


async def test_declared_but_not_provided_fails() -> None:
    @plugin("liar", title="liar", provides=(DB,))
    async def liar(ctx) -> None:
        return None

    async with KernelHarness() as h:
        fiber = await h.mount(liar)
        assert fiber.state is State.FAILED
        assert "test/db" in fiber.error


async def test_undeclared_provide_fails() -> None:
    @plugin("sneaky", title="sneaky")
    async def sneaky(ctx) -> None:
        ctx.provide(DB, 1)

    async with KernelHarness() as h:
        fiber = await h.mount(sneaky)
        assert fiber.state is State.FAILED
        assert "provides" in fiber.error


async def test_use_requires_inject_declaration() -> None:
    @plugin("peek", title="peek")
    async def peek(ctx) -> None:
        assert ctx.get(DB) == "conn"
        ctx.use(DB)

    async with KernelHarness() as h:
        h.provide(DB, "conn")
        fiber = await h.mount(peek)
        assert fiber.state is State.FAILED
        assert "inject" in fiber.error


async def test_requires_version_checked_before_apply() -> None:
    ran: list[str] = []

    def needs(requirement: str, source: str = "builtin"):
        @plugin(f"needs-{requirement}-{source}", title="n", requires={"test/exp": requirement})
        async def apply(ctx) -> None:
            ran.append(requirement)

        return Entry(f"needs-{requirement}-{source}", apply, source=source)

    kernel = Kernel()
    await kernel.start([needs("^1.2"), needs("^1.4"), needs("^2.0"), needs("^1.0", source="acme")])
    assert ran == ["^1.2", "^1.0"]
    assert kernel.fiber("needs-^1.4-builtin").state is State.INCOMPATIBLE
    assert "要求 ^1.4" in kernel.fiber("needs-^1.4-builtin").incompatible
    assert kernel.fiber("needs-^2.0-builtin").state is State.INCOMPATIBLE
    await kernel.stop()


async def test_third_party_cannot_require_internal_contract() -> None:
    @plugin("peeker", title="p", requires={"test/db": "^1.0"})
    async def peeker(ctx) -> None: ...

    kernel = Kernel()
    await kernel.start([Entry("builtin", peeker), Entry("acme.peeker", peeker, source="acme")])
    assert kernel.fiber("builtin").state is State.ACTIVE
    assert kernel.fiber("acme.peeker").state is State.INCOMPATIBLE
    assert "仅供内置" in kernel.fiber("acme.peeker").incompatible
    await kernel.stop()


async def test_third_party_cannot_inject_or_provide_internal_services() -> None:
    # 内部服务随时可改：第三方插件即使没写 requires，注入或提供它们也直接判不兼容
    kernel = Kernel()
    await kernel.start(
        [
            Entry("db", make_provider("db", DB, "conn")),
            Entry("exp", make_provider("exp", EXP, "x")),
            Entry("acme.reader", make_consumer("acme.reader", DB), source="acme"),
            Entry("acme.hijack", make_provider("acme.hijack", CACHE, "c"), source="acme"),
            Entry("acme.ok", make_consumer("acme.ok", EXP), source="acme"),
            Entry("builtin.reader", make_consumer("builtin.reader", DB)),
        ]
    )
    assert kernel.fiber("acme.reader").state is State.INCOMPATIBLE
    assert "test/db 仅供内置" in kernel.fiber("acme.reader").incompatible
    assert kernel.fiber("acme.hijack").state is State.INCOMPATIBLE
    assert kernel.fiber("acme.ok").state is State.ACTIVE
    assert kernel.fiber("builtin.reader").state is State.ACTIVE
    await kernel.stop()


async def test_runtime_mount_runs_compat_checks() -> None:
    async with KernelHarness() as h:
        h.provide(DB, "conn")
        fiber = await h.mount(make_consumer("acme.late", DB), source="acme")
        assert fiber.state is State.INCOMPATIBLE
        needs_new = make_consumer("needs-new", requires={"test/exp": "^9.0"})
        assert (await h.mount(needs_new)).state is State.INCOMPATIBLE
        await h.unmount(fiber)
        await h.unmount("needs-new")


async def test_permissions_are_declared_and_described() -> None:
    @plugin("asker", title="a", permissions=("subscriptions.create", "search.*"))
    async def asker(ctx) -> None: ...

    async with KernelHarness() as h:
        fiber = await h.mount(asker)
        assert fiber.plugin.permissions == ("subscriptions.create", "search.*")
        assert h.kernel.describe(fiber)["permissions"] == ["subscriptions.create", "search.*"]
        await h.unmount(fiber)


async def test_patch_disables_only_disableable_entries(caplog) -> None:
    log: list[str] = []
    kernel = Kernel()
    await kernel.start(
        [
            Entry("opt", make_consumer("opt", log=log, disableable=True)),
            Entry("fixed", make_consumer("fixed", log=log)),
            Entry("core", make_provider("core", DB, 1, log, critical=True, disableable=True)),
        ],
        patches=[
            Patch("opt", disabled=True, source="env:OPT"),
            Patch("fixed", disabled=True),
            Patch("core", disabled=True),
            Patch("ghost", disabled=True),
        ],
    )
    assert kernel.fiber("opt").state is State.DISABLED
    assert kernel.fiber("opt").disabled_by == "env:OPT"
    assert kernel.fiber("fixed").state is State.ACTIVE
    assert kernel.fiber("core").state is State.ACTIVE
    assert "ghost" in caplog.text
    await kernel.stop()


async def test_disposers_run_in_reverse_and_sequentially() -> None:
    order: list[str] = []

    @plugin("seq", title="seq")
    async def seq(ctx) -> None:
        async def slow_first() -> None:
            await asyncio.sleep(0.02)
            order.append("registered-first")

        ctx.effect(slow_first)
        ctx.effect(lambda: order.append("registered-second"))

    async with KernelHarness() as h:
        await h.mount(seq)
    assert order == ["registered-second", "registered-first"]


async def test_dispose_timeout_gives_up_and_continues() -> None:
    log: list[str] = []

    @plugin("hang", title="hang")
    async def hang(ctx) -> None:
        ctx.effect(lambda: asyncio.sleep(5))

    kernel = Kernel(dispose_timeout=0.05)
    await kernel.start([Entry("first", make_consumer("first", log=log)), Entry("hang", hang)])
    started = time.perf_counter()
    await kernel.stop()
    assert time.perf_counter() - started < 1
    assert kernel.fiber("hang").stats.unsettled is True
    assert log[-1] == "stop:first"


async def test_tasks_are_cancelled_and_awaited_on_dispose() -> None:
    finished: list[str] = []

    @plugin("worker", title="worker")
    async def worker(ctx) -> None:
        async def loop() -> None:
            try:
                await asyncio.sleep(3600)
            finally:
                await asyncio.sleep(0)
                finished.append("cleanup")

        task = ctx.task(loop(), name="loop")
        assert task.get_name() == "plugin:worker:loop"

    async with KernelHarness() as h:
        fiber = await h.mount(worker)
        await asyncio.sleep(0)
        await h.unmount(fiber)
        assert finished == ["cleanup"]


async def test_child_plugin_waits_for_its_own_dependency() -> None:
    log: list[str] = []

    @plugin("parent.part", title="part", inject=(CACHE,))
    async def part(ctx) -> None:
        log.append("start:part")
        ctx.effect(lambda: log.append("stop:part"))

    @plugin("parent", title="parent")
    async def parent(ctx) -> None:
        log.append("start:parent")
        ctx.plugin(part)
        ctx.effect(lambda: log.append("stop:parent"))

    async with KernelHarness() as h:
        fiber = await h.mount(parent)
        child = h.kernel.fiber("parent.part")
        assert fiber.state is State.ACTIVE
        assert child.state is State.PENDING
        h.provide(CACHE, "c")
        await h.settle()
        assert child.state is State.ACTIVE
        await h.unmount(fiber)
        assert h.kernel.fiber("parent.part") is None
    assert log == ["start:parent", "start:part", "stop:part", "stop:parent"]


async def test_failed_parent_never_mounts_child() -> None:
    @plugin("orphan", title="orphan")
    async def orphan(ctx) -> None: ...

    @plugin("broken-parent", title="bp")
    async def broken_parent(ctx) -> None:
        ctx.plugin(orphan)
        raise RuntimeError("nope")

    async with KernelHarness() as h:
        await h.mount(broken_parent)
        assert h.kernel.fiber("orphan") is None


async def test_runtime_disable_and_enable_cascade() -> None:
    log: list[str] = []
    kernel = Kernel()
    await kernel.start(
        [
            Entry("db", make_provider("db", DB, 1, log, disableable=True)),
            Entry("user", make_consumer("user", DB, log=log)),
        ]
    )
    await kernel.disable("db")
    assert kernel.fiber("db").state is State.DISABLED
    assert kernel.fiber("user").state is State.PENDING
    assert log == ["start:db", "start:user", "stop:user", "stop:db"]
    await kernel.enable("db")
    assert kernel.fiber("user").state is State.ACTIVE
    assert log[-2:] == ["start:db", "start:user"]
    await kernel.stop()


async def test_structural_change_inside_apply_must_be_scheduled() -> None:
    errors: list[str] = []

    @plugin("meddler", title="meddler")
    async def meddler(ctx) -> None:
        try:
            await ctx._kernel.disable("victim")
        except RuntimeError as exc:
            errors.append(str(exc))

    kernel = Kernel()
    await kernel.start(
        [Entry("victim", make_consumer("victim", disableable=True)), Entry("meddler", meddler)]
    )
    assert errors and "schedule" in errors[0]
    task = kernel.schedule(lambda: kernel.disable("victim"))
    await task
    assert kernel.fiber("victim").state is State.DISABLED
    await kernel.stop()


async def test_startup_overhead_for_many_plugins_is_small() -> None:
    manifest = [Entry(f"p{i}", make_consumer(f"p{i}")) for i in range(60)]
    kernel = Kernel()
    started = time.perf_counter()
    await kernel.start(manifest)
    elapsed = time.perf_counter() - started
    await kernel.stop()
    # 设计预算 50 毫秒；CI 机器抖动大，断言放宽到 0.5 秒，实测值见 PR 描述
    assert elapsed < 0.5


async def test_providing_none_is_rejected() -> None:
    @plugin("nothing", title="nothing", provides=(DB,))
    async def nothing(ctx) -> None:
        ctx.provide(DB, None)

    async with KernelHarness() as h:
        fiber = await h.mount(nothing)
        assert fiber.state is State.FAILED
        assert "None" in fiber.error
