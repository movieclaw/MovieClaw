"""微信通道插件（随应用携带的插件包，docs/design/plugin-channels.md §7）。

只依赖 SDK：驱动在 ``driver``，iLink 协议客户端在 ``client``，扫码绑定状态机在 ``binding``，
收消息循环在 ``adapter``，入站图片解密在 ``media``。
"""

from __future__ import annotations

from movieclaw_sdk import Context, plugin
from movieclaw_sdk.channels import IM_CHANNELS


@plugin("weixin-channel", title="微信通道", disableable=True, reloadable=True)
async def weixin(ctx: Context) -> None:
    from .driver import WeixinDriver

    driver = WeixinDriver()
    ctx.effect(driver.close, label="close-weixin")
    ctx.contribute(IM_CHANNELS, "weixin", driver)
