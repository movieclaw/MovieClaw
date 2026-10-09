"""通道与推送插件（plugin-kernel.md §7）。

IM 通道中枢与各通道（微信 / Telegram / Discord / 飞书）、Cloud、推送中枢、新片到达、
Jellyfin 局域网发现。
"""

from __future__ import annotations

from movieclaw_api.plugins.keys import (
    AGENT_RUNS,
    CHANNEL_HUB,
    CLOUD,
    DB,
    EGRESS,
    IM_CHANNELS,
    PUSH_HUB,
)
from movieclaw_kernel import Context, plugin


@plugin(
    "channels.hub",
    title="IM 通道中枢",
    inject=(DB, AGENT_RUNS),
    provides=(CHANNEL_HUB,),
    reloadable=True,
)
async def channel_hub(ctx: Context) -> None:
    from movieclaw_api.services.channel_hub import ChannelHub, set_hub

    # 通道列表 = 注册表现取：通道插件装上 / 关掉 / 卸载，中枢跟着启停账号
    # （docs/design/plugin-channels.md §6）。入站消息驱动 AI 助手，所以依赖 Agent 注册表
    # （关闭时先停通道：掐断在飞长轮询、停会话 worker，再停 Agent）
    registry = ctx.registry(IM_CHANNELS)
    hub = ChannelHub(
        lambda: dict(registry.items()),
        lambda: {c.id: c.entry_id for c in registry.contributions()},
    )
    set_hub(hub)
    ctx.watch(IM_CHANNELS, lambda _change: hub.schedule_sync())

    async def close() -> None:
        set_hub(None)
        await hub.stop()

    ctx.effect(close, label="close-channel-hub")
    await hub.start()
    ctx.provide(CHANNEL_HUB, hub)


@plugin("channel.weixin", title="微信通道", disableable=True, reloadable=True)
async def weixin(ctx: Context) -> None:
    from movieclaw_channel.weixin.driver import WeixinDriver

    driver = WeixinDriver()
    ctx.effect(driver.close, label="close-weixin")
    ctx.contribute(IM_CHANNELS, "weixin", driver)


@plugin("channel.telegram", title="Telegram 通道", disableable=True, reloadable=True)
async def telegram(ctx: Context) -> None:
    from movieclaw_channel.telegram.driver import TelegramDriver

    ctx.contribute(IM_CHANNELS, "telegram", TelegramDriver())


@plugin("channel.discord", title="Discord 通道", disableable=True, reloadable=True)
async def discord(ctx: Context) -> None:
    from movieclaw_channel.discord.driver import DiscordDriver

    ctx.contribute(IM_CHANNELS, "discord", DiscordDriver())


@plugin("channel.feishu", title="飞书通道", disableable=True, reloadable=True)
async def feishu(ctx: Context) -> None:
    from movieclaw_channel.feishu.driver import FeishuDriver

    ctx.contribute(IM_CHANNELS, "feishu", FeishuDriver())


@plugin(
    "cloud",
    title="MovieClaw Cloud",
    inject=(EGRESS,),
    provides=(CLOUD,),
    disableable=True,
    reloadable=True,
)
async def cloud(ctx: Context) -> None:
    from movieclaw_api.services.cloud import close_cloud_service, init_cloud_service

    # 已连接就起续签循环；未连接时对云端不发任何请求（docs/design/cloud-push.md §2、§3）
    service = await init_cloud_service()
    ctx.effect(close_cloud_service, label="close-cloud")
    ctx.provide(CLOUD, service)


@plugin("push.hub", title="推送事件中枢", inject=(DB,), provides=(PUSH_HUB,), reloadable=True)
async def push_hub(ctx: Context) -> None:
    from movieclaw_api.services.push import hub

    # 中枢懒启动（第一次 emit 时建队列和消费者），这里只负责关停：
    # 停消费者、取消剧卡的定时（docs/design/cloud-push.md §5.1）
    ctx.effect(hub.stop, label="stop-push-hub")
    ctx.provide(PUSH_HUB, hub)


@plugin("push.channels-refresh", title="推送通道能力快照", inject=(CLOUD,), reloadable=True)
async def push_channels_refresh(ctx: Context) -> None:
    from movieclaw_api.services.push.channels import start_refresh_loop, stop_refresh_loop

    # 推送通道的能力快照（/v1/info）每半小时检查一次是否过期
    start_refresh_loop()
    ctx.effect(stop_refresh_loop, label="stop-refresh-loop")


@plugin(
    "push.arrivals", title="媒体库有新片", inject=(PUSH_HUB, DB), disableable=True, reloadable=True
)
async def push_arrivals(ctx: Context) -> None:
    from movieclaw_api.services.push import arrivals

    # 每两分钟看一眼台账里新出现的行；先于推送中枢停下
    arrivals.start()
    ctx.effect(arrivals.stop, label="stop-arrivals")


@plugin("jellyfin.discovery", title="Jellyfin 局域网发现", disableable=True, reloadable=True)
async def jellyfin_discovery(ctx: Context) -> None:
    from movieclaw_jellyfin.udp import start_discovery, stop_discovery

    # UDP 7359；开关关闭 / 端口被占时内部自行降级
    await start_discovery(ctx.settings.jellyfin_public_port)
    ctx.effect(stop_discovery, label="stop-discovery")
