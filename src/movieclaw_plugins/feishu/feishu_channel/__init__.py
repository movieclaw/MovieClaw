"""飞书通道插件（随应用携带的插件包，docs/design/plugin-channels.md §7）。

只依赖 SDK：驱动在 ``driver``，协议客户端在 ``client``，收消息循环在 ``adapter``。
"""

from __future__ import annotations

from movieclaw_sdk import Context, plugin
from movieclaw_sdk.channels import IM_CHANNELS


@plugin("channel.feishu", title="飞书通道", disableable=True, reloadable=True)
async def feishu(ctx: Context) -> None:
    from .driver import FeishuDriver

    ctx.contribute(IM_CHANNELS, "feishu", FeishuDriver())
