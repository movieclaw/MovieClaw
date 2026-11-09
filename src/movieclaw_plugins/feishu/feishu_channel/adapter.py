"""FeishuAdapter —— 飞书推送适配器。

自定义机器人和自建应用都没有收消息能力,run() 只是一个等待停止的空转循环:
ChannelManager 要求每个账号有一个可守护的「收消息任务」,这里用它满足生命周期
契约。推送扇出经 dispatcher 发送泵到达 send_text / send_photo。

send_photo 发交互式卡片(应用模式会带上传后的海报)。卡片失败时改发纯文本,
纯文本再失败则把异常抛回发送泵,由它重试,避免成功之后再发一遍。
"""

from __future__ import annotations

import asyncio
import logging

from movieclaw_sdk.channels import ChannelContext, ReplyContext

from .client import FeishuApiError, FeishuClient

logger = logging.getLogger("movieclaw_plugins.feishu.adapter")

CHANNEL_ID = "feishu"


class FeishuAdapter:
    """飞书通道适配器(单账号,推送-only)。"""

    channel_id = CHANNEL_ID
    #: 纯文本分片上限:远小于消息体上限,推送文案足够用且留足余量
    max_text_len = 4000
    #: 宿主默认超过 1000 字就不调 send_photo。飞书卡片会截断简介,这里放宽后海报仍能进卡片。
    photo_caption_limit = 20_000

    def __init__(self, client: FeishuClient, account_id: str) -> None:
        self._client = client
        self._account_id = account_id

    async def run(self, ctx: ChannelContext) -> None:
        # 无收消息循环:挂起直到账号被停止/解绑(满足 manager 的守护契约)
        stop = ctx.stop or asyncio.Event()
        await stop.wait()

    async def send_text(self, reply: ReplyContext, text: str) -> None:
        # 目标在凭据里,与 reply 无关:一个账号对应一个群或一个用户
        await self._client.send_text(text)

    async def send_photo(self, reply: ReplyContext, photo: bytes, caption: str) -> None:
        try:
            await self._client.send_card(caption, photo)
        except FeishuApiError as exc:
            # 只记异常类型,不把响应体打进日志(里面不该出现密钥)
            logger.warning("飞书卡片发送失败,改发纯文本 type=%s", type(exc).__name__)
            await self._client.send_text(caption)
