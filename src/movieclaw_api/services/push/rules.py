"""通知规则（docs/design/domain-events.md §6.1）：事件 → 发给谁、写什么。

事件是事实，通知是发给人的消息。每种通知登记一条，「账号 → 通知」的偏好开关按这张表渲染，
通知引擎（engine.py）按它从总线上的事件导出通知：

- **规则**（``Rule``）：一个事件对应一条通知——收件人、文案、打扰级别都在这里；
- **聚合器**（``Aggregator``）：要跨事件合并状态的（剧卡、待处理事项攒一会儿再推），
  事件交给它自己的代码处理，这里只登记偏好开关。

偏好开关的键默认就是事件名。收件人看得到的条目才推、静音了的条目不推，由引擎统一把关，
规则不用、也不能关掉这一步。
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.push.notify import AlertContent


def field_value(payload: Any, path: str) -> Any:
    """按 ``a.b`` 取载荷里的字段；取不到为 ``None``。"""
    value: Any = payload
    for part in path.split("."):
        value = value.get(part) if isinstance(value, dict) else getattr(value, part, None)
        if value is None:
            return None
    return value


def as_media(value: Any) -> Any:
    """一个字段值当作「片」：``MediaRef``，或进程外插件传来的 ``{id, kind, title}`` 字典。"""
    from movieclaw_sdk.events import MediaRef

    if isinstance(value, MediaRef):
        return value
    if isinstance(value, dict):
        try:
            return MediaRef.model_validate(
                {k: v for k, v in value.items() if k in MediaRef.model_fields}
            )
        except ValueError:
            return None
    return None


@dataclass(frozen=True)
class Audience:
    """收件人（宿主解析，规则只声明关系）。

    - ``admins``：管理员；
    - ``member``：载荷里 ``field`` 指定的成员；
    - ``subscribers``：载荷里 ``field`` 指定的订阅的发起人 + 关注者；
    - ``media``：订阅或关注了载荷里 ``field``（``MediaRef`` 或同形字典）这部片的人。
    """

    kind: str
    field: str | None = None

    @classmethod
    def admins(cls) -> Audience:
        return cls("admins")

    @classmethod
    def member(cls, field: str) -> Audience:
        return cls("member", field)

    @classmethod
    def subscribers(cls, field: str) -> Audience:
        return cls("subscribers", field)

    @classmethod
    def media(cls, field: str) -> Audience:
        return cls("media", field)

    async def resolve(self, session: AsyncSession, payload: Any) -> set[int]:
        if self.kind == "admins":
            return {0}
        value = field_value(payload, self.field or "")
        if self.kind == "member":
            return await _active_members(session, {value}) if isinstance(value, int) else set()
        if self.kind == "subscribers":
            if not isinstance(value, int):
                return set()
            from movieclaw_api.services.push.audience import subscribers

            return await subscribers(value)(session)
        if self.kind == "media":
            media = as_media(value)
            return await _media_followers(session, media.id) if media is not None else set()
        return set()


async def _active_members(session: AsyncSession, member_ids: set[int]) -> set[int]:
    """存在且启用的成员（0 = 超管，总在）。"""
    from movieclaw_db.models import Member

    found = {m for m in member_ids if m == 0}
    others = {m for m in member_ids if m != 0}
    if others:
        rows = await session.execute(
            select(Member.id).where(  # type: ignore[call-overload]
                Member.id.in_(others),  # type: ignore[union-attr]
                Member.status == "active",
            )
        )
        found.update(int(i) for i in rows.scalars())
    return found


async def _media_followers(session: AsyncSession, item_id: int) -> set[int]:
    """订阅或关注了这部片的人（与内置订阅通知同一口径）。"""
    from movieclaw_api.services.push.audience import subscribers
    from movieclaw_db.models import Subscription

    rows = await session.execute(
        select(Subscription.id).where(Subscription.media_item_id == item_id)  # type: ignore[call-overload]
    )
    members: set[int] = set()
    for subscription_id in rows.scalars():
        members |= await subscribers(int(subscription_id))(session)
    return members


#: 给一个收件人写文案：(会话, 收件人, 载荷) → 内容；返回 None 表示这个人不发
Render = Callable[[AsyncSession, int, Any], Awaitable[AlertContent | None]]


@dataclass(frozen=True)
class Rule:
    """一个事件对应一条通知。"""

    event: str
    title: str
    """偏好开关上的名字。"""
    description: str
    group: str
    default: bool
    audience: Audience
    render: Render
    key: str = ""
    """偏好开关的键；空 = 事件名。"""
    admin_only: bool = False
    """只有管理员会收到（成员看不到这个开关）。"""
    when: Callable[[Any], bool] | None = None
    """载荷满足条件才发（比如只有新设备才算「新设备登录」）。"""
    collapse: Callable[[Any], tuple[str, str] | None] | None = None
    """同一个键的新通知替换旧的。"""
    exclude_devices: Callable[[Any], frozenset[int]] | None = None
    """不发给这些设备（刚登录的那台）。"""
    to_im: bool = True
    """也发到收件人绑定的 IM（微信、Telegram…）。

    人就在 App 里盯着的事（AI 回复完成）不必再进 IM。"""
    owner: str = "core"

    @property
    def pref_key(self) -> str:
        return self.key or self.event

    @property
    def events(self) -> tuple[str, ...]:
        return (self.event,)


@dataclass(frozen=True)
class Aggregator:
    """要跨事件合并状态的通知：事件交给 ``handle``（同步、只投递，不阻塞）。"""

    key: str
    title: str
    description: str
    group: str
    default: bool
    handle: Callable[[str, Any], None]
    """(事件名, 载荷)。"""
    events: tuple[str, ...] = field(default=())
    admin_only: bool = False
    owner: str = "core"

    @property
    def pref_key(self) -> str:
        return self.key


Entry = Rule | Aggregator

#: 偏好键 → 规则 / 聚合器（登记顺序 = 偏好页上的顺序）
_entries: dict[str, Entry] = {}


def register(entry: Entry) -> None:
    if entry.pref_key in _entries:
        raise ValueError(f"通知 {entry.pref_key} 重复登记")
    _entries[entry.pref_key] = entry


def unregister(key: str) -> None:
    _entries.pop(key, None)


def entries() -> list[Entry]:
    _ensure_core()
    return list(_entries.values())


def get(key: str) -> Entry | None:
    _ensure_core()
    return _entries.get(key)


def for_event(name: str) -> list[Entry]:
    _ensure_core()
    return [e for e in _entries.values() if name in e.events]


def event_names() -> set[str]:
    _ensure_core()
    return {name for e in _entries.values() for name in e.events}


_core_loaded = False


def _ensure_core() -> None:
    global _core_loaded
    if _core_loaded:
        return
    _core_loaded = True
    from movieclaw_api.services.push import core_rules

    core_rules.register_all()
