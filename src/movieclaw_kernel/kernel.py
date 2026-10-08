"""插件内核：状态机、依赖驱动的启动、逆序关闭、级联（docs/design/plugin-kernel.md §4.5、§4.6）。

排序规则一句话：声明顺序 = 激活顺序（在依赖允许的范围内）= 释放的逆序。

- 启动：反复挑「依赖都已就绪、清单顺序最靠前」的待启动条目执行 ``apply``；
- 关闭：按激活顺序的逆序逐个释放，条目内的释放函数逆序串行执行；
- 服务被撤下时，所有注入了它的条目先被释放并回到 ``PENDING``，提供方恢复后自动重新挂载；
- 一切结构变更（启动、关闭、启用、禁用、挂载、卸载）经同一把锁串行执行。
"""

from __future__ import annotations

import asyncio
import contextvars
import itertools
import logging
import time
import traceback
from collections.abc import Awaitable, Callable, Iterable, Sequence
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any, TypeVar

from movieclaw_kernel.contracts import (
    CATALOG,
    RegistryKey,
    ServiceKey,
    check_requires,
    describe,
)
from movieclaw_kernel.events import Event, EventBus, Mode
from movieclaw_kernel.observe import (
    EntryStats,
    Origin,
    current_entry,
    current_origin,
)
from movieclaw_kernel.plugin import Entry, Patch, Plugin
from movieclaw_kernel.registry import Registry

T = TypeVar("T")

logger = logging.getLogger("movieclaw_kernel")

Disposer = Callable[[], Any]


class State(StrEnum):
    DISABLED = "disabled"
    INCOMPATIBLE = "incompatible"
    PENDING = "pending"
    LOADING = "loading"
    ACTIVE = "active"
    FAILED = "failed"
    UNLOADING = "unloading"
    DISPOSED = "disposed"


class KernelConfigError(Exception):
    """清单本身有缺陷（id 重复、服务重复提供、依赖成环）：属于代码错误，直接拒绝启动。"""


class KernelStartupError(Exception):
    """关键插件启动失败：已释放全部已启动条目。"""

    def __init__(self, entry_id: str, cause: BaseException) -> None:
        super().__init__(f"关键插件 {entry_id} 启动失败：{type(cause).__name__}: {cause}")
        self.entry_id = entry_id


@dataclass(frozen=True)
class PluginStateChanged:
    entry_id: str
    state: str
    error: str | None = None
    title: str = ""
    critical: bool = False


PLUGIN_STATE: Event[PluginStateChanged, None] = Event(
    "kernel/plugin-state",
    Mode.EMIT,
    payload=PluginStateChanged,
    doc="插件条目状态变化（诊断、待处理事项消费它）",
)


@dataclass(frozen=True)
class KernelReady:
    active: int
    failed: tuple[str, ...]
    pending: tuple[str, ...]


KERNEL_READY: Event[KernelReady, None] = Event(
    "kernel/ready", Mode.EMIT, payload=KernelReady, doc="启动流程结束"
)


_HARNESS_SOURCE = "harness"


@dataclass(eq=False)
class Fiber:
    """一个条目的运行时句柄。"""

    entry: Entry
    order: tuple[int, ...]
    parent: Fiber | None = None
    state: State = State.PENDING
    disposers: list[tuple[str, Disposer]] = field(default_factory=list)
    tasks: set[asyncio.Task[Any]] = field(default_factory=set)
    children: list[Fiber] = field(default_factory=list)
    provided: list[str] = field(default_factory=list)
    blocked_by: list[str] = field(default_factory=list)
    disabled_by: str | None = None
    incompatible: str | None = None
    error: str | None = None
    activated_seq: int | None = None
    stats: EntryStats = field(default_factory=EntryStats)
    ctx: Any = None
    config: Any = None

    @property
    def id(self) -> str:
        return self.entry.id

    @property
    def plugin(self) -> Plugin:
        return self.entry.plugin

    @property
    def third_party(self) -> bool:
        return self.entry.source not in ("builtin", _HARNESS_SOURCE)

    def __repr__(self) -> str:
        return f"Fiber({self.id!r}, {self.state.value})"


_in_op: contextvars.ContextVar[bool] = contextvars.ContextVar(
    "movieclaw_kernel_in_op", default=False
)


class Kernel:
    def __init__(
        self,
        *,
        settings: Any = None,
        clock: Callable[[], float] = time.monotonic,
        dispose_timeout: float = 10.0,
        slow_apply_warning: float = 2.0,
    ) -> None:
        self.settings = settings
        self.dispose_timeout = dispose_timeout
        self.slow_apply_warning = slow_apply_warning
        self.bus = EventBus(clock)
        self.fibers: list[Fiber] = []
        self._by_id: dict[str, Fiber] = {}
        self._services: dict[str, tuple[Any, Fiber]] = {}
        self._registries: dict[str, Registry[Any]] = {}
        self._activation = itertools.count(1)
        self._order = itertools.count(10_000)
        self._lock: asyncio.Lock | None = None
        self.dispose_log: list[str] = []
        """释放顺序记录（条目 id），测试据此断言关闭顺序约束。"""
        self.started = False

    # ================================================================== 公共查询
    def fiber(self, entry_id: str) -> Fiber | None:
        return self._by_id.get(entry_id)

    def service(self, key: ServiceKey[T]) -> T | None:
        hit = self._services.get(key.name)
        return hit[0] if hit else None

    def registry(self, key: RegistryKey[T]) -> Registry[T]:
        reg = self._registries.get(key.name)
        if reg is None:
            reg = Registry(key)
            self._registries[key.name] = reg
        return reg

    # ================================================================== 结构变更
    async def _locked(self, op: Callable[[], Awaitable[T]]) -> T:
        if self._lock is None:
            self._lock = asyncio.Lock()
        if _in_op.get():
            # 插件 apply / 释放里发起的结构变更：排到当前变更之后，避免重入死锁
            raise RuntimeError("结构变更不能在另一个结构变更内同步等待；请用 schedule()")
        async with self._lock:
            token = _in_op.set(True)
            try:
                return await op()
            finally:
                _in_op.reset(token)

    def schedule(self, op: Callable[[], Awaitable[Any]]) -> asyncio.Task[Any]:
        """在当前结构变更之后执行 ``op``（在独立任务里，不继承「正在变更」标记）。"""
        ctx = contextvars.copy_context()
        ctx.run(_in_op.set, False)
        return asyncio.get_running_loop().create_task(op(), context=ctx)

    async def start(self, manifest: Sequence[Entry], patches: Iterable[Patch] = ()) -> None:
        self.bus.bind_loop(asyncio.get_running_loop())

        async def op() -> None:
            self._load(manifest, list(patches))
            try:
                await self._reconcile()
            except KernelStartupError:
                await self._dispose_all()
                raise
            self.started = True
            failed = tuple(f.id for f in self.fibers if f.state is State.FAILED)
            pending = tuple(f.id for f in self.fibers if f.state is State.PENDING)
            active = sum(1 for f in self.fibers if f.state is State.ACTIVE)
            logger.info(
                "插件内核启动完成：%d 个运行中，%d 个失败，%d 个等待依赖",
                active,
                len(failed),
                len(pending),
            )
            self.bus.emit(KERNEL_READY, KernelReady(active, failed, pending))

        await self._locked(op)

    async def stop(self) -> None:
        await self._locked(self._dispose_all)

    async def disable(self, entry_id: str, *, source: str = "runtime") -> None:
        async def op() -> None:
            fiber = self._require(entry_id)
            if fiber.state in (State.ACTIVE, State.FAILED):
                await self._dispose(fiber, State.DISABLED)
            fiber.state = State.DISABLED
            fiber.disabled_by = source
            await self._reconcile()

        await self._locked(op)

    async def enable(self, entry_id: str) -> None:
        async def op() -> None:
            fiber = self._require(entry_id)
            if fiber.state in (State.DISABLED, State.FAILED, State.DISPOSED):
                fiber.state = State.PENDING
                fiber.disabled_by = None
                fiber.error = None
            await self._reconcile()

        await self._locked(op)

    async def mount(self, entry: Entry) -> Fiber:
        """运行中追加一个顶层条目（测试工具与将来的插件管理用）。"""

        async def op() -> Fiber:
            if entry.id in self._by_id:
                raise KernelConfigError(f"条目 id 重复：{entry.id}")
            fiber = self._new_fiber(entry, (next(self._order),))
            await self._reconcile()
            return fiber

        return await self._locked(op)

    async def unmount(self, entry_id: str) -> None:
        async def op() -> None:
            fiber = self._require(entry_id)
            await self._dispose(fiber, State.DISPOSED)
            self._forget(fiber)
            await self._reconcile()

        await self._locked(op)

    # ================================================================== 装载清单
    def _load(self, manifest: Sequence[Entry], patches: list[Patch]) -> None:
        seen: set[str] = set()
        for entry in manifest:
            if entry.id in seen:
                raise KernelConfigError(f"条目 id 重复：{entry.id}")
            seen.add(entry.id)
        disabled: dict[str, str] = {}
        by_id = {entry.id: entry for entry in manifest}
        for patch in patches:
            entry = by_id.get(patch.id)
            if entry is None:
                logger.warning("补丁里的条目 %s 不存在，已忽略", patch.id)
                continue
            if not patch.disabled:
                continue
            if entry.plugin.critical or not entry.plugin.disableable:
                logger.warning("条目 %s 不允许禁用（%s），已忽略", patch.id, patch.source)
                continue
            disabled[patch.id] = patch.source

        providers: dict[str, str] = {}
        for entry in manifest:
            if entry.id in disabled:
                continue
            for key in entry.plugin.provides:
                if key.name in providers:
                    raise KernelConfigError(
                        f"服务 {key.name} 同时由 {providers[key.name]} 和 {entry.id} 提供"
                    )
                providers[key.name] = entry.id
        self._check_cycles(manifest, providers, disabled)

        for index, entry in enumerate(manifest):
            fiber = self._new_fiber(entry, (index,))
            if entry.id in disabled:
                fiber.state = State.DISABLED
                fiber.disabled_by = disabled[entry.id]
                continue
            reason = check_requires(dict(entry.plugin.requires), third_party=fiber.third_party)
            if reason is not None:
                fiber.state = State.INCOMPATIBLE
                fiber.incompatible = reason
                logger.warning("插件 %s 与当前版本不兼容：%s", entry.id, reason)

    @staticmethod
    def _check_cycles(
        manifest: Sequence[Entry], providers: dict[str, str], disabled: dict[str, str]
    ) -> None:
        edges: dict[str, list[str]] = {}
        for entry in manifest:
            if entry.id in disabled:
                continue
            edges[entry.id] = [
                providers[key.name] for key in entry.plugin.inject if key.name in providers
            ]
        visiting: set[str] = set()
        done: set[str] = set()

        def visit(node: str, path: list[str]) -> None:
            if node in done:
                return
            if node in visiting:
                cycle = path[path.index(node) :] + [node]
                raise KernelConfigError("插件依赖成环：" + " → ".join(cycle))
            visiting.add(node)
            for nxt in edges.get(node, []):
                visit(nxt, [*path, node])
            visiting.discard(node)
            done.add(node)

        for node in edges:
            visit(node, [])

    def _new_fiber(
        self, entry: Entry, order: tuple[int, ...], parent: Fiber | None = None
    ) -> Fiber:
        fiber = Fiber(entry=entry, order=order, parent=parent)
        self.fibers.append(fiber)
        self.fibers.sort(key=lambda f: f.order)
        self._by_id[entry.id] = fiber
        return fiber

    def _forget(self, fiber: Fiber) -> None:
        for child in list(fiber.children):
            self._forget(child)
        if fiber in self.fibers:
            self.fibers.remove(fiber)
        if self._by_id.get(fiber.id) is fiber:
            del self._by_id[fiber.id]
        if fiber.parent is not None and fiber in fiber.parent.children:
            fiber.parent.children.remove(fiber)

    def _require(self, entry_id: str) -> Fiber:
        fiber = self._by_id.get(entry_id)
        if fiber is None:
            raise KeyError(f"没有条目 {entry_id}")
        return fiber

    # ================================================================== 激活
    def _ready(self, fiber: Fiber) -> bool:
        if fiber.state is not State.PENDING:
            return False
        if fiber.parent is not None and fiber.parent.state is not State.ACTIVE:
            return False
        fiber.blocked_by = [
            key.name for key in fiber.plugin.inject if key.name not in self._services
        ]
        return not fiber.blocked_by

    async def _reconcile(self) -> None:
        """反复激活「依赖已就绪、顺序最靠前」的条目，直到没有可激活的。"""
        while True:
            candidate = next((f for f in self.fibers if self._ready(f)), None)
            if candidate is None:
                return
            await self._activate(candidate)

    async def _activate(self, fiber: Fiber) -> None:
        plugin = fiber.plugin
        fiber.state = State.LOADING
        fiber.error = None
        self._announce(fiber)
        from movieclaw_kernel.context import Context

        tokens = (
            current_entry.set(fiber.id),
            current_origin.set(Origin(kind="plugin", id=fiber.id)),
        )
        started = time.perf_counter()
        try:
            fiber.config = self._build_config(fiber)
            fiber.ctx = Context(self, fiber)
            async with asyncio.timeout(plugin.apply_timeout):
                await plugin.apply(fiber.ctx)
            missing = [key.name for key in plugin.provides if key.name not in fiber.provided]
            if missing:
                raise RuntimeError(f"声明提供 {', '.join(missing)} 但 apply 结束时没有提供")
        except asyncio.CancelledError:
            await self._run_disposers(fiber)
            fiber.state = State.FAILED
            fiber.error = "启动被取消"
            raise
        except Exception as exc:  # noqa: BLE001 -- 插件失败要隔离，关键插件除外
            await self._run_disposers(fiber)
            fiber.state = State.FAILED
            reason = "启动超时" if isinstance(exc, TimeoutError) else f"{type(exc).__name__}: {exc}"
            fiber.error = reason
            fiber.stats.last_error = "".join(traceback.format_exception(exc))[-4000:]
            logger.error("插件 %s 启动失败：%s", fiber.id, reason, exc_info=exc)
            self._announce(fiber)
            if plugin.critical:
                raise KernelStartupError(fiber.id, exc) from exc
            return
        finally:
            current_origin.reset(tokens[1])
            current_entry.reset(tokens[0])
            fiber.stats.apply_ms = (time.perf_counter() - started) * 1000
        fiber.state = State.ACTIVE
        fiber.activated_seq = next(self._activation)
        if fiber.stats.apply_ms / 1000 >= self.slow_apply_warning:
            logger.warning("插件 %s 启动较慢：%.0f 毫秒", fiber.id, fiber.stats.apply_ms)
        self._announce(fiber)

    @staticmethod
    def _build_config(fiber: Fiber) -> Any:
        cfg_type = fiber.plugin.config
        raw = dict(fiber.entry.config or {})
        if cfg_type is None:
            return raw or None
        validate = getattr(cfg_type, "model_validate", None)
        return validate(raw) if validate else cfg_type(**raw)

    def _announce(self, fiber: Fiber) -> None:
        if not self.bus.listeners(PLUGIN_STATE):
            return
        self.bus.emit(
            PLUGIN_STATE,
            PluginStateChanged(
                fiber.id,
                fiber.state.value,
                fiber.error,
                fiber.plugin.title,
                fiber.plugin.critical,
            ),
        )

    # ================================================================== 释放
    async def _dispose_all(self) -> None:
        active = [f for f in self.fibers if f.state is State.ACTIVE and f.activated_seq]
        for fiber in sorted(active, key=lambda f: f.activated_seq or 0, reverse=True):
            if fiber.state is State.ACTIVE:
                await self._dispose(fiber, State.DISPOSED)

    async def _dispose(self, fiber: Fiber, final: State) -> None:
        if fiber.state not in (State.ACTIVE, State.LOADING):
            if fiber.state is State.FAILED:
                fiber.state = final
            return
        fiber.state = State.UNLOADING
        self._announce(fiber)
        started = time.perf_counter()
        # 子插件总是先于父插件释放（与整体关闭时的激活逆序一致）
        for child in reversed(fiber.children):
            if child.state is State.ACTIVE:
                await self._dispose(child, State.DISPOSED)
        await self._run_disposers(fiber)
        fiber.stats.dispose_ms = (time.perf_counter() - started) * 1000
        fiber.state = final
        fiber.activated_seq = None
        self.dispose_log.append(fiber.id)
        self._announce(fiber)

    async def _run_disposers(self, fiber: Fiber) -> None:
        disposers = list(reversed(fiber.disposers))
        fiber.disposers.clear()
        if not disposers:
            return

        async def run_all() -> None:
            for label, disposer in disposers:
                try:
                    result = disposer()
                    if asyncio.iscoroutine(result) or isinstance(result, asyncio.Future):
                        await result
                except Exception:  # noqa: BLE001 -- 一个释放步骤出错不能拦住其余清理
                    logger.exception("插件 %s 释放「%s」时出错", fiber.id, label)

        task = asyncio.get_running_loop().create_task(run_all(), name=f"kernel:dispose:{fiber.id}")
        done, _ = await asyncio.wait({task}, timeout=self.dispose_timeout)
        if not done:
            fiber.stats.unsettled = True
            logger.warning(
                "插件 %s 释放超过 %.0f 秒，放弃等待、继续关闭其余插件",
                fiber.id,
                self.dispose_timeout,
            )

    # ================================================================== 供 Context 调用
    def _add_disposer(self, fiber: Fiber, label: str, disposer: Disposer) -> None:
        fiber.disposers.append((label, disposer))

    def _provide(self, fiber: Fiber, key: ServiceKey[Any], value: Any) -> None:
        if all(k.name != key.name for k in fiber.plugin.provides):
            raise ValueError(f"插件 {fiber.id} 未在 provides 中声明服务 {key.name}")
        if value is None:
            raise ValueError(f"服务 {key.name} 不能提供 None（与「没有提供方」无法区分）")
        holder = self._services.get(key.name)
        if holder is not None:
            raise RuntimeError(f"服务 {key.name} 已由 {holder[1].id} 提供")
        self._services[key.name] = (value, fiber)
        fiber.provided.append(key.name)

        async def withdraw() -> None:
            # 先释放所有注入了该服务的条目（激活逆序），再撤下服务
            dependents = [
                f
                for f in self.fibers
                if f.state is State.ACTIVE and any(k.name == key.name for k in f.plugin.inject)
            ]
            for dependent in sorted(dependents, key=lambda f: f.activated_seq or 0, reverse=True):
                if dependent.state is State.ACTIVE:
                    await self._dispose(dependent, State.PENDING)
            if self._services.get(key.name, (None, None))[1] is fiber:
                del self._services[key.name]
            if key.name in fiber.provided:
                fiber.provided.remove(key.name)

        self._add_disposer(fiber, f"provide:{key.name}", withdraw)

    def _spawn(self, fiber: Fiber, coro: Any, name: str) -> asyncio.Task[Any]:
        ctx = contextvars.copy_context()
        ctx.run(current_entry.set, fiber.id)
        origin = current_origin.get()
        if not origin.is_plugin(fiber.id):
            origin = Origin(kind="plugin", id=fiber.id)
        ctx.run(current_origin.set, origin)
        ctx.run(_in_op.set, False)
        task = asyncio.get_running_loop().create_task(
            coro, name=f"plugin:{fiber.id}:{name}", context=ctx
        )
        fiber.tasks.add(task)

        def done(t: asyncio.Task[Any]) -> None:
            fiber.tasks.discard(t)
            if not t.cancelled() and t.exception() is not None:
                fiber.stats.failures += 1
                fiber.stats.last_error = f"{type(t.exception()).__name__}: {t.exception()}"
                logger.error(
                    "插件 %s 的后台任务 %s 异常退出", fiber.id, name, exc_info=t.exception()
                )

        task.add_done_callback(done)

        async def stop() -> None:
            if task.done():
                return
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
            except Exception:  # noqa: BLE001 -- 已在 done 回调里记过
                pass

        self._add_disposer(fiber, f"task:{name}", stop)
        return task

    def _mount_child(self, parent: Fiber, plugin: Plugin) -> Fiber:
        # 父条目是多实例（条目 id ≠ 插件名）时，子条目 id 带上父条目前缀以免撞名
        child_id = plugin.name if parent.id == parent.plugin.name else f"{parent.id}/{plugin.name}"
        entry = Entry(id=child_id, plugin=plugin, source=parent.entry.source)
        if entry.id in self._by_id:
            raise KernelConfigError(f"条目 id 重复：{entry.id}")
        order = (*parent.order, len(parent.children))
        child = self._new_fiber(entry, order, parent)
        parent.children.append(child)

        async def dispose_child() -> None:
            await self._dispose(child, State.DISPOSED)
            self._forget(child)

        self._add_disposer(parent, f"child:{plugin.name}", dispose_child)
        return child

    # ================================================================== 诊断
    def snapshot(self) -> list[dict[str, Any]]:
        return [self.describe(f) for f in self.fibers]

    def describe(self, fiber: Fiber) -> dict[str, Any]:
        blocked = []
        if fiber.state is State.PENDING:
            for name in fiber.blocked_by:
                provider = next(
                    (f for f in self.fibers if any(k.name == name for k in f.plugin.provides)),
                    None,
                )
                if provider is None:
                    reason = "没有插件提供"
                else:
                    reason = f"提供方 {provider.id} 状态为 {provider.state.value}"
                blocked.append({"key": name, "reason": reason})
        breakers = [listener.breaker.state for listener in self.bus.owned_by(fiber.id)]
        return {
            "id": fiber.id,
            "plugin": fiber.plugin.name,
            "title": fiber.plugin.title,
            "state": fiber.state.value,
            "critical": fiber.plugin.critical,
            "disableable": fiber.plugin.disableable,
            "reloadable": fiber.plugin.reloadable,
            "source": fiber.entry.source,
            "parent": fiber.parent.id if fiber.parent else None,
            "provides": [k.name for k in fiber.plugin.provides],
            "inject": [k.name for k in fiber.plugin.inject],
            "blocked_by": blocked,
            "incompatible": fiber.incompatible,
            "disabled_by": fiber.disabled_by,
            "error": fiber.error,
            "apply_ms": round(fiber.stats.apply_ms, 1)
            if fiber.stats.apply_ms is not None
            else None,
            "dispose_ms": round(fiber.stats.dispose_ms, 1)
            if fiber.stats.dispose_ms is not None
            else None,
            "unsettled": fiber.stats.unsettled,
            "stats": {
                **fiber.stats.as_dict(),
                "tasks": len(fiber.tasks),
                "listeners": len(self.bus.owned_by(fiber.id)),
                "breaker": "open"
                if "open" in breakers
                else ("half-open" if "half-open" in breakers else "closed"),
            },
        }

    def contracts(self) -> dict[str, Any]:
        services = []
        registries = []
        events = []
        for contract in CATALOG.values():
            info = describe(contract)
            if isinstance(contract, Event):
                info["mode"] = contract.mode.value
                info["delivery"] = contract.delivery.value
                info["listeners"] = [item.label for item in self.bus.listeners(contract)]
                events.append(info)
            elif isinstance(contract, RegistryKey):
                reg = self._registries.get(contract.name)
                info["contributions"] = reg.describe() if reg else []
                registries.append(info)
            elif isinstance(contract, ServiceKey):
                holder = self._services.get(contract.name)
                info["provider"] = holder[1].id if holder else None
                services.append(info)
        return {"services": services, "registries": registries, "events": events}
