"""插件声明与清单条目（docs/design/plugin-kernel.md §4.1、§4.3）。

- 插件：一段代码及其元数据（依赖、提供、契约要求）；
- 条目：插件的一次挂载，带自己的 id 和配置。诊断、补丁、日志、指标都以条目 id 为准。
"""

from __future__ import annotations

import inspect
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

from movieclaw_kernel.contracts import ServiceKey

if TYPE_CHECKING:
    from movieclaw_kernel.context import Context

Apply = Callable[["Context"], Awaitable[None]]


@dataclass(frozen=True, eq=False)
class Plugin:
    name: str
    title: str
    apply: Apply
    inject: tuple[ServiceKey, ...] = ()
    provides: tuple[ServiceKey, ...] = ()
    requires: Mapping[str, str] = field(default_factory=dict)
    critical: bool = False
    disableable: bool = False
    apply_timeout: float | None = 30.0
    reloadable: bool = False
    config: type | None = None

    def __repr__(self) -> str:
        return f"Plugin({self.name!r})"


def plugin(
    name: str,
    *,
    title: str,
    inject: tuple[ServiceKey, ...] = (),
    provides: tuple[ServiceKey, ...] = (),
    requires: Mapping[str, str] | None = None,
    critical: bool = False,
    disableable: bool = False,
    apply_timeout: float | None = 30.0,
    reloadable: bool = False,
    config: type | None = None,
) -> Callable[[Apply], Plugin]:
    """把一个 ``async def apply(ctx)`` 声明为插件。

    关键插件不设启动超时：数据库迁移这类步骤耗时不可预估，半途取消比等待更危险。
    """

    def decorator(fn: Apply) -> Plugin:
        if not inspect.iscoroutinefunction(fn):
            raise TypeError(f"插件 {name} 的 apply 必须是 async 函数")
        return Plugin(
            name=name,
            title=title,
            apply=fn,
            inject=tuple(inject),
            provides=tuple(provides),
            requires=dict(requires or {}),
            critical=critical,
            disableable=disableable,
            apply_timeout=None if critical else apply_timeout,
            reloadable=reloadable,
            config=config,
        )

    return decorator


@dataclass(frozen=True)
class Entry:
    """清单里的一行：挂载哪个插件、用什么 id 和配置。"""

    id: str
    plugin: Plugin
    config: Mapping[str, Any] | None = None
    source: str = "builtin"
    """``builtin`` = 本仓库内置；其他值视为第三方（契约检查与贡献 id 前缀规则不同）。"""


@dataclass(frozen=True)
class Patch:
    """补丁层的一行。第一阶段只认 ``disabled``（§10.3）。"""

    id: str
    disabled: bool = False
    source: str = "patch"
    """禁用来源，进诊断的 ``disabled_by``，如 ``patch`` / ``env:SCHEDULER_ENABLED``。"""
