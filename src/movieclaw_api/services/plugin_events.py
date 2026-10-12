"""插件自己的事件与通知（docs/design/domain-events.md §7）。

三件事：

1. **声明**（安装 / 加载时）：插件包清单的 ``[[events]]``、``[[notifications]]``、
   ``[permissions] events``，本地插件在 ``plugins.yaml`` 里写同样的 ``events`` / ``notifications``。
   用户批准安装 = 批准这些声明；会通知到普通成员的须单独确认（``allow_member_notifications``）。
2. **登记**（插件运行时，``PLUGIN_EVENTS.register``）：插件把事件对象交给宿主——进系统事件目录
   （别的插件、Webhook 都能订）；清单里对应的通知规则登记进通知规则表，「账号 → 通知」里多出
   这个插件的一组开关。插件停用、卸载时一并撤下。
3. **发出**（``publisher.publish``）：经唯一入口 ``events.publish_now``，和系统事件走同一条总线。

宿主把关只做必须的：只能发自己 id 下、声明过的事件；载荷按事件的 Schema 校验；通知上标
「来自 插件名」；载荷带 ``MediaRef`` 的照常按收件人做可见性过滤。频率限制、文案长度等
先不做（§7.5）。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re
from dataclasses import dataclass, field
from typing import Any

from pydantic import BaseModel, ConfigDict, create_model

from movieclaw_api.services.push.plugin_rules import fill
from movieclaw_sdk.events import EventType, MediaRef

logger = logging.getLogger("movieclaw_api.plugin_events")

#: 收件人写法：admins / member:<字段> / media:<字段>
_AUDIENCE = re.compile(r"^(admins|member:[\w.]+|media:[\w.]+)$")
LEVELS = ("passive", "active")
OPENS = ("plugin", "media")


class DeclarationError(ValueError):
    """清单里的事件 / 通知声明不合规。"""


@dataclass(frozen=True)
class NotificationSpec:
    """清单里的一条通知规则：一个事件对应一条通知，模板只做字段替换（``{a.b}``）。"""

    event: str
    title: str
    body: str = ""
    audience: str = "admins"
    level: str = "active"
    default: bool = True
    open: str = "plugin"
    description: str = ""

    @property
    def reaches_members(self) -> bool:
        return self.audience != "admins"


@dataclass(frozen=True)
class Declared:
    """一个插件声明了什么（安装批准 / plugins.yaml 里写的）。"""

    entry_id: str
    title: str
    events: dict[str, str] = field(default_factory=dict)
    """事件名 → 标题。"""
    notifications: tuple[NotificationSpec, ...] = ()
    sensitive: tuple[str, ...] = ()
    """要订阅的敏感事件（``playback.*`` 或具体名字）。"""
    members_allowed: bool = False
    """用户批准了通知到普通成员。"""
    trusted: bool = False
    """本地受信插件（用户自己写的代码）：订阅敏感事件不另外要求声明。"""


def parse(
    entry_id: str,
    title: str,
    *,
    events: Any = None,
    notifications: Any = None,
    sensitive: Any = None,
) -> tuple[dict[str, str], tuple[NotificationSpec, ...], tuple[str, ...]]:
    """校验并解析声明；不合规抛 ``DeclarationError``（中文说明）。"""
    from movieclaw_sdk.events import CORE_DOMAINS, core_events

    declared: dict[str, str] = {}
    for raw in events or []:
        if not isinstance(raw, dict) or not isinstance(raw.get("name"), str):
            raise DeclarationError("events 的每一项须是 {name, title}")
        name = raw["name"]
        if not name.startswith(f"{entry_id}."):
            raise DeclarationError(f"事件 {name} 须以插件 id 开头（{entry_id}.）")
        if name.split(".", 1)[0] in CORE_DOMAINS:
            raise DeclarationError(f"事件 {name} 用了系统保留的域")
        if name in declared:
            raise DeclarationError(f"事件 {name} 重复声明")
        declared[name] = str(raw.get("title") or name)
    specs: list[NotificationSpec] = []
    for raw in notifications or []:
        if not isinstance(raw, dict):
            raise DeclarationError("notifications 的每一项须是表")
        allowed = set(NotificationSpec.__dataclass_fields__)
        unknown = set(raw) - allowed
        if unknown:
            raise DeclarationError(f"通知声明里有不认识的字段：{'、'.join(sorted(unknown))}")
        try:
            spec = NotificationSpec(**raw)
        except TypeError as exc:
            raise DeclarationError(f"通知声明不完整：{exc}") from exc
        if spec.event not in declared:
            raise DeclarationError(f"通知引用的事件 {spec.event} 没在 events 里声明")
        if any(s.event == spec.event for s in specs):
            raise DeclarationError(f"事件 {spec.event} 只能有一条通知")
        if not _AUDIENCE.match(spec.audience):
            raise DeclarationError(
                f"收件人 {spec.audience} 不合规：admins、member:<字段> 或 media:<字段>"
            )
        if spec.level not in LEVELS:
            raise DeclarationError(f"打扰级别 {spec.level} 不合规：{' / '.join(LEVELS)}")
        if spec.open not in OPENS:
            raise DeclarationError(f"点开去哪 {spec.open} 不合规：{' / '.join(OPENS)}")
        if not spec.title.strip():
            raise DeclarationError(f"事件 {spec.event} 的通知没有标题")
        specs.append(spec)
    patterns: list[str] = []
    sensitive_names = {e.name for e in core_events() if e.sensitive}
    for item in sensitive or []:
        if not isinstance(item, str):
            raise DeclarationError("permissions.events 须是事件名列表")
        if item.endswith(".*"):
            prefix = item[:-1]
            if not any(n.startswith(prefix) for n in sensitive_names):
                raise DeclarationError(f"{item} 下没有敏感事件")
        elif item not in sensitive_names:
            raise DeclarationError(f"{item} 不是需要单独授权的敏感事件")
        patterns.append(item)
    return declared, tuple(specs), tuple(patterns)


# ---------------------------------------------------------------------- 声明登记
_declared: dict[str, Declared] = {}


def declare(item: Declared) -> None:
    _declared[item.entry_id] = item


def forget(entry_id: str) -> None:
    _declared.pop(entry_id, None)


def declared(entry_id: str) -> Declared | None:
    return _declared.get(entry_id)


def sensitive_reason(entry_id: str, event: Any) -> str | None:
    """插件包订阅敏感事件（谁在什么时候看了什么）须在清单里声明、经用户批准。"""
    if not getattr(event, "sensitive", False):
        return None
    item = _declared.get(entry_id)
    if item is None or item.trusted:
        return None  # 内置、本地受信插件：不另外要求
    for pattern in item.sensitive:
        if pattern == event.name or (
            pattern.endswith(".*") and event.name.startswith(pattern[:-1])
        ):
            return None
    return (
        f"事件 {event.name} 涉及谁在什么时候看了什么，须在清单 [permissions] events 里声明、"
        "经用户批准后才能订阅"
    )


# ---------------------------------------------------------------------- 运行时目录
_catalog: dict[str, EventType] = {}


def catalog() -> dict[str, EventType]:
    """当前在运行的插件登记的事件。"""
    return dict(_catalog)


def all_events() -> dict[str, EventType]:
    """系统事件 + 插件事件（Webhook 勾选、通知引擎、插件订阅都按它）。"""
    from movieclaw_sdk.events import core_events

    found: dict[str, EventType] = {e.name: e for e in core_events()}
    found.update(_catalog)
    return found


def _changed() -> None:
    """目录变了：通知引擎补挂 / 撤下监听，Webhook 按新目录调整订阅。"""
    from movieclaw_api.services.push import engine

    engine.refresh()
    with contextlib.suppress(RuntimeError):
        from movieclaw_api.services.webhook import resync

        asyncio.get_running_loop().create_task(resync())


def _register(entry_id: str, events: tuple[EventType, ...]) -> None:
    item = _declared.get(entry_id)
    title = item.title if item else entry_id
    for event in events:
        if not isinstance(event, EventType):
            raise TypeError(f"{event!r} 不是插件事件（用 movieclaw_sdk.events.plugin_event 定义）")
        if not event.name.startswith(f"{entry_id}."):
            raise ValueError(f"插件 {entry_id} 只能发 {entry_id}. 开头的事件，{event.name} 不行")
        if item is not None and not item.trusted and event.name not in item.events:
            raise ValueError(f"事件 {event.name} 没在插件清单的 [[events]] 里声明")
        owner = _catalog.get(event.name)
        if owner is not None and owner is not event:
            raise ValueError(f"事件 {event.name} 已经登记过")
        event.owner = entry_id
        event.group = title
        _catalog[event.name] = event
    if item is not None:
        _register_rules(item, {e.name for e in events})
    _changed()


def _unregister(entry_id: str, names: set[str]) -> None:
    from movieclaw_api.services.push import rules

    for name in names:
        _catalog.pop(name, None)
        rules.unregister(name)
    _changed()


# ---------------------------------------------------------------------- 通知规则
def _register_rules(item: Declared, names: set[str]) -> None:
    from movieclaw_api.services.push import rules
    from movieclaw_api.services.push.plugin_rules import template_rule

    for spec in item.notifications:
        if spec.event not in names:
            continue
        if spec.reaches_members and not item.members_allowed:
            logger.warning(
                "插件 %s 的通知 %s 会通知到普通成员，但没有获得批准，已跳过",
                item.entry_id,
                spec.event,
            )
            continue
        rules.unregister(spec.event)
        rules.register(template_rule(item, spec))


# ---------------------------------------------------------------------- 服务
class _Publisher:
    def __init__(self, entry_id: str, names: set[str]) -> None:
        self._entry_id = entry_id
        self._names = names

    async def publish(self, event: EventType, payload: Any) -> None:
        if event.name not in self._names:
            raise ValueError(f"事件 {event.name} 没有登记，先 register")
        if not isinstance(payload, event.payload):
            raise TypeError(f"事件 {event.name} 的载荷须是 {event.payload.__name__}")
        from movieclaw_api import events

        await events.publish_now(event, lambda: payload)


class PluginEvents:
    """``PLUGIN_EVENTS`` 的宿主实现（进程内）；进程外插件经网关的 ``events`` 服务。"""

    async def register(self, ctx: Any, *events: EventType) -> _Publisher:
        entry_id = ctx.entry_id
        _register(entry_id, tuple(events))
        names = {e.name for e in events}
        ctx.effect(lambda: _unregister(entry_id, names), label="unregister-plugin-events")
        return _Publisher(entry_id, names)


# ---------------------------------------------------------------------- 进程外插件
class _RemotePayload(BaseModel):
    """进程外插件事件的载荷：字段由插件声明的 JSON Schema 决定（宿主侧按 Schema 校验）。"""

    model_config = ConfigDict(frozen=True, extra="allow")


def remote_event(definition: dict[str, Any]) -> EventType:
    """按进程外插件给的定义（name、title、doc、schema）造宿主侧的事件对象。"""
    from movieclaw_sdk.events import plugin_event

    name = str(definition["name"])
    model = create_model(
        "Payload_" + re.sub(r"\W", "_", name), __base__=_RemotePayload
    )
    title = str(definition.get("title") or name)
    event = plugin_event(name, model, title=title, doc=str(definition.get("doc") or ""))
    event.schema = definition.get("schema") or {"type": "object"}  # type: ignore[attr-defined]
    return event


def remote_payload(event: EventType, data: Any) -> Any:
    """校验进程外插件发来的载荷（JSON Schema），通过就造成事件对象的载荷。"""
    import jsonschema

    schema = getattr(event, "schema", None) or {"type": "object"}
    try:
        jsonschema.validate(data, schema)
    except jsonschema.ValidationError as exc:
        raise ValueError(f"事件 {event.name} 的载荷不合 Schema：{exc.message}") from exc
    return event.payload.model_validate(data)


__all__ = [
    "Declared",
    "DeclarationError",
    "MediaRef",
    "NotificationSpec",
    "PluginEvents",
    "all_events",
    "catalog",
    "declare",
    "fill",
    "forget",
    "parse",
    "sensitive_reason",
]
