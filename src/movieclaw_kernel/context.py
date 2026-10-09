"""插件上下文（docs/design/plugin-kernel.md §4.4）。

插件经 ``ctx`` 取服务、提供服务、往注册表贡献、订阅事件、起后台任务、挂子插件。
凡是注册类操作都是「可撤销的副作用」：插件卸载时按登记的逆序自动撤回。
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Coroutine
from typing import TYPE_CHECKING, Any, Generic, TypeVar

from movieclaw_kernel.contracts import Contract, RegistryKey, ServiceKey, internal_for_third_party
from movieclaw_kernel.events import DURABLE_EVENTS, Delivery, Event, EventBus
from movieclaw_kernel.observe import DeliveryInfo, Origin, current_delivery, current_origin
from movieclaw_kernel.plugin import Plugin
from movieclaw_kernel.registry import Registry, RegistryChange

if TYPE_CHECKING:
    import asyncio

    from movieclaw_kernel.kernel import Fiber, Kernel

T = TypeVar("T")
C = TypeVar("C")


class Context(Generic[C]):
    def __init__(self, kernel: Kernel, fiber: Fiber) -> None:
        self._kernel = kernel
        self._fiber = fiber
        self.logger = logging.getLogger(f"movieclaw.plugin.{fiber.id}")

    # ------------------------------------------------------------------ 只读信息
    @property
    def entry_id(self) -> str:
        return self._fiber.id

    @property
    def title(self) -> str:
        """插件的展示名（``@plugin(title=...)``）。"""
        return self._fiber.plugin.title

    @property
    def settings(self) -> Any:
        return self._kernel.settings

    @property
    def permissions(self) -> tuple[str, ...]:
        """插件声明需要的宿主操作（由宿主解释，见 ``@plugin(permissions=...)``）。"""
        return self._fiber.plugin.permissions

    @property
    def third_party(self) -> bool:
        """非内置来源（本地受信插件、将来的第三方插件）。"""
        return self._fiber.third_party

    @property
    def config(self) -> C:
        return self._fiber.config

    @property
    def origin(self) -> Origin:
        return current_origin.get()

    @property
    def delivery(self) -> DeliveryInfo | None:
        """正在处理的可靠事件的投递信息；不在可靠事件监听器里时为 ``None``。"""
        return current_delivery.get()

    @property
    def events(self) -> EventBus:
        return self._kernel.bus

    def _guard(self, contract: Contract) -> None:
        reason = internal_for_third_party(contract, third_party=self._fiber.third_party)
        if reason is not None:
            raise PermissionError(f"插件 {self.entry_id}：{reason}")

    # ------------------------------------------------------------------ 服务
    def use(self, key: ServiceKey[T]) -> T:
        """取已注入的服务。没在 ``inject`` 里声明的服务不能用 ``use`` 取。"""
        if all(k.name != key.name for k in self._fiber.plugin.inject):
            raise KeyError(f"插件 {self.entry_id} 没有在 inject 中声明服务 {key.name}")
        value = self._kernel.service(key)
        if value is None:
            raise LookupError(f"服务 {key.name} 当前没有提供方")
        return value

    def get(self, key: ServiceKey[T]) -> T | None:
        """取可选服务，没有提供方时返回 ``None``。"""
        self._guard(key)
        return self._kernel.service(key)

    def provide(self, key: ServiceKey[T], value: T) -> None:
        self._kernel._provide(self._fiber, key, value)

    # ------------------------------------------------------------------ 注册表
    def registry(self, key: RegistryKey[T]) -> Registry[T]:
        self._guard(key)
        return self._kernel.registry(key)

    def contribute(
        self,
        key: RegistryKey[T],
        contribution_id: str,
        item: T,
        *,
        priority: int = 0,
        override: bool = False,
    ) -> None:
        fiber = self._fiber
        # 第三方贡献自动加插件 id 前缀，避免撞名；内置贡献保留原 id（库里存着这些 key）。
        # 例外是显式覆盖（override=True）：第三方明确要替换某个已有贡献（例如整段替换内置的
        # 订阅定时阶段），必须用原 id 才能压进同一个覆盖栈；卸载时内置实现自动恢复
        prefixed = fiber.third_party and not override
        cid = f"{fiber.id}:{contribution_id}" if prefixed else contribution_id
        remove = self.registry(key).add(
            cid,
            item,
            entry_id=fiber.id,
            priority=priority,
            tier=1 if fiber.third_party else 0,
            override=override,
        )
        self._kernel._add_disposer(fiber, f"contribute:{key.name}:{cid}", remove)

    def watch(self, key: RegistryKey[T], callback: Callable[[RegistryChange[T]], None]) -> None:
        """订阅注册表增删。回调是同步的；需要异步处理就自己排队（例如交给 ``ctx.task``）。"""
        unwatch = self.registry(key).watch(callback)
        self._kernel._add_disposer(self._fiber, f"watch:{key.name}", unwatch)

    # ------------------------------------------------------------------ 事件
    def on(
        self,
        event: Event[Any, Any],
        handler: Callable[..., Any],
        *,
        id: str | None = None,
        priority: int = 0,
    ) -> None:
        fiber = self._fiber
        self._guard(event)
        if event.delivery is Delivery.DURABLE:
            if not id:
                raise ValueError(f"可靠事件 {event.name} 的监听器必须有稳定 id")
            store = self.use(DURABLE_EVENTS)
            unsubscribe = store.subscribe(event, entry_id=fiber.id, listener_id=id, handler=handler)
            self._kernel._add_disposer(fiber, f"on:{event.name}:{id}", unsubscribe)
            return
        remove = self._kernel.bus.add(
            event,
            handler,
            entry_id=fiber.id,
            listener_id=id,
            priority=priority,
            stats=fiber.stats,
            spawn=lambda coro, name: self.task(coro, name=name),
        )
        self._kernel._add_disposer(fiber, f"on:{event.name}:{id or ''}", remove)

    # ------------------------------------------------------------------ 生命周期
    def effect(self, disposer: Callable[[], Any], *, label: str = "effect") -> None:
        """登记一个释放函数（同步或异步），插件卸载时按登记逆序执行。"""
        self._kernel._add_disposer(self._fiber, label, disposer)

    def task(self, coro: Coroutine[Any, Any, Any], *, name: str) -> asyncio.Task[Any]:
        """起后台协程；插件卸载时取消并等它结束。任务名自动为 ``plugin:<条目 id>:<name>``。"""
        return self._kernel._spawn(self._fiber, coro, name)

    def plugin(self, child: Plugin) -> Fiber:
        """挂载子插件（可选依赖的标准写法）：父插件启动成功后、子插件依赖就绪时激活。"""
        return self._kernel._mount_child(self._fiber, child)
