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
    permissions: tuple[str, ...] = ()
    """插件需要的宿主操作（operationId，支持 ``领域.*``）。内核只存储、进诊断，由宿主解释。"""

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
    permissions: tuple[str, ...] = (),
) -> Callable[[Apply], Plugin]:
    """把一个 ``async def apply(ctx)`` 声明为插件。

    关键插件不设启动超时：数据库迁移这类步骤耗时不可预估，半途取消比等待更危险。
    """

    def decorator(fn: Apply) -> Plugin:
        if not inspect.iscoroutinefunction(fn):
            raise TypeError(f"插件 {name} 的 apply 必须是 async 函数")
        for label, keys in (("inject", inject), ("provides", provides)):
            for key in keys:
                if not isinstance(key, ServiceKey):
                    raise TypeError(_not_a_service(name, label, key))
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
            permissions=tuple(permissions),
        )

    return decorator


def _not_a_service(name: str, label: str, key: object) -> str:
    """``inject`` / ``provides`` 只收服务键；写进事件、钩子、注册表时直接说清该怎么写。

    不在这里拦住的话，内核会一直等一个没人提供的「服务」，插件卡在待启动、说不出原因。
    """
    kind = getattr(key, "kind", None)
    key_name = getattr(key, "name", repr(key))
    hint = {
        "registry": f"{key_name} 是注册表：在 apply 里 ctx.contribute(...) 即可",
        "event": f"{key_name} 是事件 / 钩子：在 apply 里 ctx.on(...) 即可",
    }.get(kind or "", "")
    return f"插件 {name} 的 {label} 只能写服务键，{key_name} 不是服务" + (
        f"（{hint}，不要写进 {label}；用到的契约写进清单 [requires]）" if hint else ""
    )


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
