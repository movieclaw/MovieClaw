"""测试工具与严格模式（docs/design/plugin-kernel.md §4.9）。

内置插件的测试和将来第三方插件的测试用同一套::

    async with KernelHarness() as h:
        h.provide(DB, fake_db)
        fiber = await h.mount(library_watch)
        assert fiber.state is State.ACTIVE
        await h.unmount(fiber)
    # 退出时严格模式检查：任务、监听器、贡献、释放函数是否全部撤回
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Callable
from typing import Any, TypeVar

from movieclaw_kernel.contracts import RegistryKey, ServiceKey
from movieclaw_kernel.events import EventBus
from movieclaw_kernel.kernel import _HARNESS_SOURCE, Fiber, Kernel, State
from movieclaw_kernel.plugin import Entry, Plugin
from movieclaw_kernel.registry import Registry

T = TypeVar("T")


async def _noop(ctx: Any) -> None:
    return None


class LeakError(AssertionError):
    pass


class KernelHarness:
    def __init__(
        self,
        *,
        strict: bool = True,
        settings: Any = None,
        clock: Callable[[], float] = time.monotonic,
        dispose_timeout: float = 5.0,
    ) -> None:
        self.strict = strict
        self.kernel = Kernel(settings=settings, clock=clock, dispose_timeout=dispose_timeout)

    async def __aenter__(self) -> KernelHarness:
        await self.kernel.start([])
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        await self.kernel.stop()
        if self.strict and exc_type is None:
            # 让被取消的任务有机会跑完收尾
            await asyncio.sleep(0)
            self.assert_no_leaks()

    # ------------------------------------------------------------------ 组装
    def provide(self, key: ServiceKey[T], value: T) -> Fiber:
        """用一个假的提供方顶上 ``key``。之后挂载的插件可以注入它。"""
        kernel = self.kernel
        stub = Plugin(
            name=f"harness:{key.name}", title=f"测试替身 {key.name}", apply=_noop, provides=(key,)
        )
        fiber = kernel._new_fiber(
            Entry(id=stub.name, plugin=stub, source=_HARNESS_SOURCE), (next(kernel._order),)
        )
        fiber.state = State.ACTIVE
        fiber.activated_seq = next(kernel._activation)
        kernel._provide(fiber, key, value)
        return fiber

    async def withdraw(self, key: ServiceKey[Any]) -> None:
        """模拟提供方消失：注入了它的插件会被释放并回到 PENDING。"""
        await self.kernel.unmount(f"harness:{key.name}")

    async def mount(
        self,
        plugin: Plugin,
        *,
        config: dict[str, Any] | None = None,
        id: str | None = None,
        source: str = "builtin",
    ) -> Fiber:
        return await self.kernel.mount(
            Entry(id=id or plugin.name, plugin=plugin, config=config, source=source)
        )

    async def unmount(self, target: Fiber | str) -> None:
        await self.kernel.unmount(target if isinstance(target, str) else target.id)

    async def settle(self) -> None:
        """重新检查等待依赖的插件（例如 ``provide`` 之后）。"""
        await self.kernel._locked(self.kernel._reconcile)

    @property
    def events(self) -> EventBus:
        return self.kernel.bus

    def registry(self, key: RegistryKey[T]) -> Registry[T]:
        return self.kernel.registry(key)

    async def drain(self) -> None:
        """等所有 EMIT 监听器把已入队的事件处理完。"""
        await self.kernel.bus.drain()

    # ------------------------------------------------------------------ 严格模式
    def leaks(self) -> list[str]:
        kernel = self.kernel
        problems: list[str] = []
        for task in asyncio.all_tasks():
            if task.get_name().startswith("plugin:") and not task.done():
                problems.append(f"后台任务未结束：{task.get_name()}")
        for fiber in kernel.fibers:
            if fiber.state is State.ACTIVE:
                continue
            if fiber.tasks:
                problems.append(f"{fiber.id} 已释放但仍有后台任务 {len(fiber.tasks)} 个")
            if fiber.disposers:
                problems.append(f"{fiber.id} 已释放但仍有未执行的释放函数")
            listeners = kernel.bus.owned_by(fiber.id)
            if listeners:
                problems.append(
                    f"{fiber.id} 已释放但仍有事件监听器：{[item.label for item in listeners]}"
                )
        active = {f.id for f in kernel.fibers if f.state is State.ACTIVE}
        for name, reg in kernel._registries.items():
            for contribution in reg.contributions():
                if contribution.entry_id not in active:
                    problems.append(
                        f"注册表 {name} 仍有已释放条目 {contribution.entry_id} "
                        f"的贡献 {contribution.id}"
                    )
        return problems

    def assert_no_leaks(self) -> None:
        problems = self.leaks()
        if problems:
            raise LeakError("插件资源未撤回：\n" + "\n".join(problems))
