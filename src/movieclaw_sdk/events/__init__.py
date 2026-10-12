"""系统事件目录（docs/design/domain-events.md §3）。

业务里每件「发生了的事」在这里定义一次：名字、载荷、说明。通知、Webhook、插件都从同一条总线取，
看到的是同一个名字、同一份载荷::

    from movieclaw_sdk import plugin
    from movieclaw_sdk.events import SUBSCRIPTION_FULFILLED

    @plugin("my-plugin", title="…")
    async def apply(ctx):
        ctx.on(SUBSCRIPTION_FULFILLED, on_fulfilled, id="fulfilled")                 # 实时
        ctx.on(SUBSCRIPTION_FULFILLED, on_fulfilled, id="fulfilled", durable=True)   # 可靠

命名 ``<域>.<对象>.<动作>``，全小写，段内用下划线，动作用过去时。本包只依赖内核与 pydantic：
进程外插件导入它很轻。
"""

from __future__ import annotations

from movieclaw_sdk.events._base import (
    CORE_DOMAINS,
    ClientRef,
    EventType,
    FileRef,
    MediaRef,
    UnitRef,
    core_events,
    define,
)
from movieclaw_sdk.events.account import ACCOUNT_DEVICE_SIGNED_IN, DeviceSignedIn
from movieclaw_sdk.events.subscription import (
    SUBSCRIPTION_IDENTITY_SKIPPED,
    SubscriptionIdentitySkipped,
)
from movieclaw_sdk.events.system import (
    SYSTEM_ALERT_RAISED,
    SYSTEM_ALERT_RESOLVED,
    SYSTEM_TIP_SUGGESTED,
    SYSTEM_UPDATE_AVAILABLE,
    AlertRaised,
    AlertResolved,
    TipSuggested,
    UpdateAvailable,
)

__all__ = [
    "ACCOUNT_DEVICE_SIGNED_IN",
    "SUBSCRIPTION_IDENTITY_SKIPPED",
    "SYSTEM_ALERT_RAISED",
    "SYSTEM_ALERT_RESOLVED",
    "SYSTEM_TIP_SUGGESTED",
    "SYSTEM_UPDATE_AVAILABLE",
    "AlertRaised",
    "AlertResolved",
    "DeviceSignedIn",
    "SubscriptionIdentitySkipped",
    "TipSuggested",
    "UpdateAvailable",
    "CORE_DOMAINS",
    "ClientRef",
    "EventType",
    "FileRef",
    "MediaRef",
    "UnitRef",
    "core_events",
    "define",
]
