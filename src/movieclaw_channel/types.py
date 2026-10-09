"""通道层的平台无关 DTO：定义在 SDK（``movieclaw_sdk.channels``），这里转出给主程序沿用。

设计要点：``ReplyContext.token`` 是**通道私有的不透明字典**——微信往里放 context_token，
别的通道放别的；通用层（dispatcher / pusher / 中枢）永远不解读它，只原样带回给同一个驱动。
"""

from __future__ import annotations

from movieclaw_sdk.channels import (
    ChannelAuthError,
    InboundImage,
    InboundMessage,
    OutboundEnvelope,
    ReplyContext,
)

__all__ = [
    "ChannelAuthError",
    "InboundImage",
    "InboundMessage",
    "OutboundEnvelope",
    "ReplyContext",
]
