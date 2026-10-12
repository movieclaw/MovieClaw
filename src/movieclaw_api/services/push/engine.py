"""通知引擎（docs/design/domain-events.md §6.1）：总线上的事件 → 通知规则 → ``notify``。

内置插件 ``push.hub`` 启动时 ``attach``：为每个有通知规则的事件挂一个实时监听器。

- 规则：解析收件人 → 按人过滤（看得到这部片、没静音这部片）→ 写文案 → ``notify``
  （偏好开关、App 与 IM 渠道都在 notify 里）；
- 聚合器：原样交给它（剧卡、待处理事项），它自己排队合并。

通知是实时投递：服务重启时在途的丢了就丢了，重启后补发过时的通知比不发更糟。
"""

from __future__ import annotations

import logging
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services.push import rules
from movieclaw_api.services.push.notify import AlertContent, notify
from movieclaw_sdk.events import MediaRef

logger = logging.getLogger("movieclaw_api.push.engine")


def known_events() -> dict[str, Any]:
    """能挂监听器的事件：系统事件 + 在运行的插件登记的事件（§7）。"""
    from movieclaw_api.services import plugin_events

    return plugin_events.all_events()


#: ``push.hub`` 的内核上下文与已挂的监听：事件名 → 取消函数
_ctx: Any = None
_attached: dict[str, Any] = {}


def attach(ctx: Any) -> None:
    """给每个有通知规则的事件挂一个实时监听器（``ctx`` 是 ``push.hub`` 的内核上下文）。"""
    global _ctx
    _ctx = ctx
    _attached.clear()
    ctx.effect(detach, label="detach-notify-engine")
    refresh()


def detach() -> None:
    global _ctx
    _ctx = None
    _attached.clear()


def refresh() -> None:
    """通知规则表或事件目录变了（插件装上 / 停用）：补挂新事件的监听、撤下没有规则了的。"""
    if _ctx is None:
        return
    catalog = known_events()
    wanted = {name for name in rules.event_names() if name in catalog}
    for name in sorted(set(_attached) - wanted):
        _attached.pop(name)()
    for name in sorted(wanted - set(_attached)):
        _attached[name] = _ctx.on(catalog[name], _listener(name), id=f"notify:{name}")


def _listener(name: str):  # type: ignore[no-untyped-def]
    def handle(payload: Any) -> None:
        dispatch(name, payload)

    return handle


def dispatch(name: str, payload: Any) -> None:
    """一个事件交给它的每条规则 / 聚合器；出错只记日志。"""
    for entry in rules.for_event(name):
        try:
            if isinstance(entry, rules.Aggregator):
                entry.handle(name, payload)
            else:
                _apply(entry, payload)
        except Exception:  # noqa: BLE001 -- 一条规则出错不影响别的
            logger.exception("通知规则 %s 处理事件 %s 失败（已忽略）", entry.pref_key, name)


def media_of(payload: Any) -> MediaRef | None:
    """载荷里的条目（第一个 ``MediaRef`` 字段）：有就按收件人做可见性与静音过滤。"""
    for value in vars(payload).values() if hasattr(payload, "__dict__") else ():
        if isinstance(value, MediaRef):
            return value
    return None


def _apply(rule: rules.Rule, payload: Any) -> None:
    if rule.when is not None and not rule.when(payload):
        return
    media = media_of(payload)

    async def recipients(session: AsyncSession) -> set[int]:
        return await rule.audience.resolve(session, payload)

    async def build(session: AsyncSession, member_id: int) -> AlertContent | None:
        if media is not None and not await _may_see(session, member_id, media.id):
            return None
        return await rule.render(session, member_id, payload)

    notify(
        rule.pref_key,
        recipients,
        build,
        collapse=rule.collapse(payload) if rule.collapse is not None else None,
        exclude_device_ids=(
            rule.exclude_devices(payload) if rule.exclude_devices is not None else frozenset()
        ),
    )


async def _may_see(session: AsyncSession, member_id: int, item_id: int) -> bool:
    """看得到这部片、没静音这部片。"""
    from movieclaw_api.services.push import preferences
    from movieclaw_api.services.push.audience import item_visible

    muted = await preferences.muted_items(session, {member_id})
    if item_id in muted.get(member_id, set()):
        return False
    return await item_visible(session, member_id, item_id)


def reset_state() -> None:
    """测试用：清掉内存里的推送状态（剧卡、攒着的告警、推送状态快照）。"""
    from movieclaw_api.services.push import alerts, hub, status

    hub.reset_state()
    status.reset_state()
    alerts.reset_state()
