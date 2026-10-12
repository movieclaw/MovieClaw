"""插件自己的事件（docs/design/domain-events.md §7）。

插件声明自己的事件，和系统事件进同一个目录：别的插件能订、Webhook 能勾；清单里再声明通知规则，
用户批准安装后，发出的事件就按规则推到手机和 IM（收件人由宿主解析、按每个人的偏好过滤）::

    from pydantic import BaseModel, ConfigDict

    from movieclaw_sdk import plugin
    from movieclaw_sdk.events import PLUGIN_EVENTS, plugin_event

    class QuotaExceeded(BaseModel):
        model_config = ConfigDict(frozen=True)
        site: str
        remaining_gb: float

    QUOTA_EXCEEDED = plugin_event("acme.quota.exceeded", QuotaExceeded, title="站点配额超限")

    @plugin("acme", title="配额提醒", inject=(PLUGIN_EVENTS,))
    async def apply(ctx):
        events = await ctx.use(PLUGIN_EVENTS).register(ctx, QUOTA_EXCEEDED)
        ...
        await events.publish(QUOTA_EXCEEDED, QuotaExceeded(site="mteam", remaining_gb=2.5))

事件名必须以插件 id 开头（``acme.``），插件包的清单 ``[[events]]`` 里要列出来。
"""

from __future__ import annotations

from typing import Any, Protocol

from movieclaw_kernel import ServiceKey, Stability
from movieclaw_sdk.events._base import CORE_DOMAINS, EventType


def plugin_event(name: str, payload: type, *, title: str, doc: str = "") -> EventType:
    """定义一个插件事件。载荷须是冻结的 pydantic 模型（要落库、跨进程）。"""
    domain = name.split(".", 1)[0]
    if domain in CORE_DOMAINS or "." not in name:
        raise ValueError(f"插件事件 {name} 须以插件 id 开头，且不能用系统保留的域")
    return EventType(name, payload, title=title, group="插件", doc=doc, owner="plugin")


class Publisher(Protocol):
    async def publish(self, event: EventType, payload: Any) -> None:
        """发出一个事件：不在业务事务里，发出即成立；没人订就什么都不做。"""
        ...


class PluginEventsApi(Protocol):
    async def register(self, ctx: Any, *events: EventType) -> Publisher:
        """登记这个插件要发的事件（插件停用时自动撤下），返回发事件用的门面。"""
        ...


PLUGIN_EVENTS: ServiceKey[Any] = ServiceKey(
    "plugin-events",
    stability=Stability.EXPERIMENTAL,
    doc="插件自己的事件：登记后发出，别的插件、Webhook 能订；清单声明了通知的经用户批准推成通知",
)
