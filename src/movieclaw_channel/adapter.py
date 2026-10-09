"""中枢内部的通道适配器协议：dispatcher / manager 只认识它（docs/design/plugin-channels.md §6）。

通道插件实现的是 SDK 的 ``ChannelDriver``，由 ``services/channel_hub._DriverAdapter`` 接成本协议；
收消息循环的上下文 ``ChannelContext`` 定义在 SDK，这里沿用。
"""

from __future__ import annotations

from typing import Protocol

from movieclaw_channel.types import ReplyContext
from movieclaw_sdk.channels import ChannelContext


class ChannelAdapter(Protocol):
    """通道适配器:平台只需知道「怎么收字节、怎么发文本」。

    可选能力 ``send_photo(reply, photo, caption)``:平台支持图文消息时
    额外实现(Telegram/Discord 已实现),发送泵用 getattr 探测;未实现的
    通道(微信 iLink 未开放图片上传)自动退回纯文本,推送不丢内容。
    不进 Protocol 正文,避免逼所有平台实现空方法。
    """

    channel_id: str
    #: 单条文本消息的长度上限(超长由发送泵分片)
    max_text_len: int

    async def run(self, ctx: ChannelContext) -> None:
        """收消息主循环:阻塞运行直到 ``ctx.stop`` 置位。

        凭据失效时抛 ``ChannelAuthError``(manager 停账号、标记 stale);
        其余异常向上抛,由 manager 做退避重启。
        """
        ...

    async def send_text(self, reply: ReplyContext, text: str) -> None:
        """发送一条文本消息(调用方已完成分片,text 不超过 max_text_len)。"""
        ...
