"""通道与推送插件（plugin-kernel.md §7）。

IM 通道中枢（各通道是随带的插件包，见 src/movieclaw_plugins）、Cloud、推送中枢、新片到达、
Jellyfin 局域网发现。
"""

from __future__ import annotations

from typing import Any

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
    """连接已配置的聊天通道（如 Telegram、飞书、微信），把收到的消息交给 AI 助手处理并回复。"""
    from movieclaw_api.services.channel_hub import ChannelHub, set_hub

    # 通道列表 = 注册表现取：通道插件装上 / 关掉 / 卸载，中枢跟着启停账号
    # （docs/design/plugin-channels.md §6）。入站消息驱动 AI 助手，所以依赖 Agent 注册表
    # （关闭时先停通道：掐断在飞长轮询、停会话 worker，再停 Agent）
    registry = ctx.registry(IM_CHANNELS)

    def channels() -> list[tuple[str, str, Any]]:
        """(通道 id, 提供它的条目, 驱动)。插件包替换随带插件包时沿用随带版本的通道 id：
        第三方贡献的 id 带插件前缀，这里摘掉，已绑定的账号照常对得上（plugin-channels.md §7）。"""
        from movieclaw_api.plugins.bundled import replaceable_ids

        replaceable = replaceable_ids()
        out = []
        for c in registry.contributions():
            cid = c.id
            if c.entry_id in replaceable and cid.startswith(f"{c.entry_id}:"):
                cid = cid[len(c.entry_id) + 1 :]
            out.append((cid, c.entry_id, c.item))
        return out

    hub = ChannelHub(
        lambda: {cid: item for cid, _entry, item in channels()},
        lambda: {cid: entry for cid, entry, _item in channels()},
    )
    set_hub(hub)
    ctx.watch(IM_CHANNELS, lambda _change: hub.schedule_sync())

    async def close() -> None:
        set_hub(None)
        await hub.stop()

    ctx.effect(close, label="close-channel-hub")
    await hub.start()
    ctx.provide(CHANNEL_HUB, hub)


@plugin(
    "cloud",
    title="MovieClaw Cloud",
    inject=(EGRESS,),
    provides=(CLOUD,),
    disableable=True,
    reloadable=True,
)
async def cloud(ctx: Context) -> None:
    """连接 MovieClaw Cloud（用于手机推送等）；未连接时不会向云端发送任何请求。"""
    from movieclaw_api.services.cloud import close_cloud_service, init_cloud_service

    # 已连接就起续签循环；未连接时对云端不发任何请求（docs/design/cloud-push.md §2、§3）
    service = await init_cloud_service()
    ctx.effect(close_cloud_service, label="close-cloud")
    ctx.provide(CLOUD, service)


@plugin("push.hub", title="推送事件中枢", inject=(DB,), provides=(PUSH_HUB,), reloadable=True)
async def push_hub(ctx: Context) -> None:
    """推送消息的统一出口：汇集各类通知事件（如新片入库），整理后推送到手机。"""
    from movieclaw_api.services.push import hub

    # 中枢懒启动（第一次 emit 时建队列和消费者），这里只负责关停：
    # 停消费者、取消剧卡的定时（docs/design/cloud-push.md §5.1）
    ctx.effect(hub.stop, label="stop-push-hub")
    ctx.provide(PUSH_HUB, hub)


@plugin("push.channels-refresh", title="推送通道能力快照", inject=(CLOUD,), reloadable=True)
async def push_channels_refresh(ctx: Context) -> None:
    """每半小时检查推送通道的信息是否过期并刷新，让手机推送选对通道。"""
    from movieclaw_api.services.push.channels import start_refresh_loop, stop_refresh_loop

    # 推送通道的能力快照（/v1/info）每半小时检查一次是否过期
    start_refresh_loop()
    ctx.effect(stop_refresh_loop, label="stop-refresh-loop")


@plugin(
    "push.arrivals", title="媒体库有新片", inject=(PUSH_HUB, DB), disableable=True, reloadable=True
)
async def push_arrivals(ctx: Context) -> None:
    """媒体库有新片入库时推送到手机：后台每两分钟检查一次新入库的内容。"""
    from movieclaw_api.services.push import arrivals

    # 每两分钟看一眼台账里新出现的行；先于推送中枢停下
    arrivals.start()
    ctx.effect(arrivals.stop, label="stop-arrivals")


@plugin("jellyfin.discovery", title="Jellyfin 局域网发现", disableable=True, reloadable=True)
async def jellyfin_discovery(ctx: Context) -> None:
    """在局域网内应答 Jellyfin 客户端的自动发现，客户端不必手填地址就能找到本服务器。"""
    from movieclaw_jellyfin.udp import start_discovery, stop_discovery

    # UDP 7359；开关关闭 / 端口被占时内部自行降级
    await start_discovery(ctx.settings.jellyfin_public_port)
    ctx.effect(stop_discovery, label="stop-discovery")
