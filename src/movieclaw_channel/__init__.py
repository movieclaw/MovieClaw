"""movieclaw_channel —— IM 通道中枢的内部构件（docs/design/plugin-channels.md §6）。

各平台的收发与绑定是通道插件（``src/movieclaw_plugins/*``，只依赖 SDK）；这里是所有通道共用、
插件看不到的部分，由 ``services/channel_hub`` 组装：

- ``types``      消息 DTO（定义在 SDK，这里转出沿用）；
- ``adapter``    中枢内部的适配器协议（通道驱动经 ``_DriverAdapter`` 接进来）；
- ``pusher``     StepReplyPusher：把 AgentRunner 事件流按「步」收敛成离散 IM 消息；
- ``dispatcher`` 事件驱动的收发解耦：会话串行队列（入站）+ 出站发送泵；
- ``manager``    每账号一个后台任务的生命周期管理（启动 / 停止 / 崩溃重启）。
"""

from movieclaw_channel.adapter import ChannelAdapter, ChannelContext
from movieclaw_channel.dispatcher import ChannelDispatcher, split_message
from movieclaw_channel.manager import ChannelManager
from movieclaw_channel.pusher import StepReplyPusher
from movieclaw_channel.types import (
    ChannelAuthError,
    InboundImage,
    InboundMessage,
    OutboundEnvelope,
    ReplyContext,
)

__all__ = [
    "ChannelAdapter",
    "ChannelAuthError",
    "ChannelContext",
    "ChannelDispatcher",
    "ChannelManager",
    "InboundImage",
    "InboundMessage",
    "OutboundEnvelope",
    "ReplyContext",
    "StepReplyPusher",
    "split_message",
]
