"""注册表：多个贡献方、可撤销、可覆盖（docs/design/plugin-kernel.md §4.2）。

- 同一 id 第二次贡献会失败，除非显式 ``override=True``；
- ``override`` 形成覆盖栈：新贡献生效、旧贡献被遮住；覆盖者撤下后旧贡献自动恢复；
- 遍历顺序按 ``(priority 降序, 层级, 注册顺序)``，结果可复现；
- 增删通知（``watch``）只做同步回调：需要异步处理的消费方自己排队。
"""

from __future__ import annotations

import itertools
import logging
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from typing import Any, Generic, TypeVar

from movieclaw_kernel.contracts import RegistryKey

T = TypeVar("T")

logger = logging.getLogger("movieclaw_kernel.registry")

_order = itertools.count()


class ContributionConflict(Exception):
    pass


@dataclass(frozen=True)
class Contribution(Generic[T]):
    id: str
    item: T
    entry_id: str
    priority: int
    tier: int
    """0 = 内置，1 = 第三方；同优先级时内置排前。"""
    order: int


@dataclass(frozen=True)
class RegistryChange(Generic[T]):
    kind: str
    """``added`` / ``removed``。覆盖时先发旧项 ``removed`` 再发新项 ``added``。"""
    id: str
    item: T
    entry_id: str


Watcher = Callable[[RegistryChange[Any]], None]


class Registry(Generic[T]):
    def __init__(self, key: RegistryKey[T]) -> None:
        self.key = key
        # id → 覆盖栈，栈顶生效
        self._stacks: dict[str, list[Contribution[T]]] = {}
        self._watchers: list[tuple[int, Watcher]] = []

    # ------------------------------------------------------------- 读
    def get(self, contribution_id: str) -> T | None:
        stack = self._stacks.get(contribution_id)
        return stack[-1].item if stack else None

    def __contains__(self, contribution_id: object) -> bool:
        return contribution_id in self._stacks

    def __len__(self) -> int:
        return len(self._stacks)

    def contributions(self) -> list[Contribution[T]]:
        active = [stack[-1] for stack in self._stacks.values()]
        active.sort(key=lambda c: (-c.priority, c.tier, c.order))
        return active

    def items(self) -> list[tuple[str, T]]:
        return [(c.id, c.item) for c in self.contributions()]

    def __iter__(self) -> Iterator[T]:
        return iter([c.item for c in self.contributions()])

    def describe(self) -> list[dict[str, Any]]:
        out = []
        for c in self.contributions():
            stack = self._stacks[c.id]
            out.append(
                {
                    "id": c.id,
                    "entry": c.entry_id,
                    "priority": c.priority,
                    "shadows": [s.entry_id for s in stack[:-1]],
                }
            )
        return out

    # ------------------------------------------------------------- 写（由 Context 调用）
    def add(
        self,
        contribution_id: str,
        item: T,
        *,
        entry_id: str,
        priority: int = 0,
        tier: int = 0,
        override: bool = False,
    ) -> Callable[[], None]:
        schema = self.key.schema
        if schema is not None and not isinstance(item, schema):
            raise TypeError(
                f"注册表 {self.key.name} 的贡献项须是 {schema.__name__}，收到 {type(item).__name__}"
            )
        contribution = Contribution(contribution_id, item, entry_id, priority, tier, next(_order))
        stack = self._stacks.get(contribution_id)
        if stack and not override:
            raise ContributionConflict(
                f"注册表 {self.key.name} 的 {contribution_id!r} 已由 {stack[-1].entry_id} 贡献"
            )
        if stack:
            self._notify(
                RegistryChange("removed", contribution_id, stack[-1].item, stack[-1].entry_id)
            )
            stack.append(contribution)
        else:
            self._stacks[contribution_id] = [contribution]
        self._notify(RegistryChange("added", contribution_id, item, entry_id))

        def remove() -> None:
            self._remove(contribution)

        return remove

    def _remove(self, contribution: Contribution[T]) -> None:
        stack = self._stacks.get(contribution.id)
        if not stack or contribution not in stack:
            return
        was_top = stack[-1] is contribution
        stack.remove(contribution)
        if was_top:
            self._notify(
                RegistryChange("removed", contribution.id, contribution.item, contribution.entry_id)
            )
            if stack:
                top = stack[-1]
                self._notify(RegistryChange("added", top.id, top.item, top.entry_id))
        if not stack:
            del self._stacks[contribution.id]

    def watch(self, callback: Watcher) -> Callable[[], None]:
        token = next(_order)
        self._watchers.append((token, callback))

        def unwatch() -> None:
            self._watchers[:] = [w for w in self._watchers if w[0] != token]

        return unwatch

    def _notify(self, change: RegistryChange[T]) -> None:
        for _, callback in list(self._watchers):
            try:
                callback(change)
            except Exception:  # noqa: BLE001 -- 一个观察者出错不能影响注册本身
                logger.exception("注册表 %s 的观察者处理变更失败", self.key.name)

    def owned_by(self, entry_id: str) -> list[str]:
        return [c.id for stack in self._stacks.values() for c in stack if c.entry_id == entry_id]
