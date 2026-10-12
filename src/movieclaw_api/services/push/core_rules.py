"""内置的通知规则（docs/design/domain-events.md §6.1、§8）。

登记顺序就是「账号 → 通知」页上的顺序。剧卡（入库、开始下载、洗版、媒体库有新片）与待处理
事项是聚合器：事件交给 cards.py / alerts.py 合并；其余是一个事件一条通知的规则。
"""

from __future__ import annotations

from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services.push.notify import AlertContent, server_identity
from movieclaw_api.services.push.rules import Aggregator, Audience, Rule, register


def _cards(name: str, payload: Any) -> None:
    from movieclaw_api.services.push import cards

    cards.on_event(name, payload)


def _alert(_name: str, payload: Any) -> None:
    from movieclaw_api.services.push import alerts

    alerts.queue(payload.dedupe_key)


# ---------------------------------------------------------------------- 订阅、媒体库
async def _identity_skipped(_s: AsyncSession, _member: int, p: Any) -> AlertContent:
    return AlertContent(
        title=f"《{p.media.title}》仍在寻找资源",
        body="发现同名影片，部分资源暂时无法确认，已跳过。订阅会继续寻找，无需你处理。",
        open=f"/subscriptions/{p.subscription_id}",
        thread=f"subscription:{p.subscription_id}",
    )


# ---------------------------------------------------------------------- 账号安全
async def _new_device(_s: AsyncSession, _member: int, p: Any) -> AlertContent:
    # 安全提醒一定要说清是哪台服务器：不知道在哪，就没法判断是不是自己、去哪注销
    server = (await server_identity())["name"]
    where = f"，来源 {p.ip}" if p.ip else ""
    return AlertContent(
        title="新设备登录了你的账号",
        body=(
            f"你在「{server}」上的账号刚在新设备登录：「{p.device_name}」（{p.kind_label}）{where}。"
            "不是你本人的话，去「账号 → 设备」注销它。"
        ),
        open="/settings/devices",
        thread="account",
        source="account",
        # 账号安全：专注模式下也要提醒（App 有「时效性通知」能力）
        level="time-sensitive",
    )


# ---------------------------------------------------------------------- 管理员
async def _new_version(_s: AsyncSession, _member: int, p: Any) -> AlertContent:
    how = (
        "在「设置 → 更新与维护」里一键更新"
        if p.compatible
        else "这个版本要更新 Docker 镜像，步骤见「设置 → 更新与维护」"
    )
    return AlertContent(
        title=f"MovieClaw {p.version} 可以更新了",
        body=how,
        open="/settings/app",
        thread="update",
        source="server",
    )


#: 使用建议的文案（``system.tip.suggested`` 的 ``tip``）
TIPS: dict[str, dict[str, str]] = {
    "reel-clips": {
        "title": "开启片段预切，预告和刷片更流畅",
        "body": "家里已经有人在刷片或看电视大图预告了。在「设置 → 播放」打开片段预切，"
        "起播更快、不卡顿。",
        "open": "/settings/playback",
    },
}


async def _tip(_s: AsyncSession, _member: int, p: Any) -> AlertContent | None:
    text = TIPS.get(p.tip)
    if text is None:
        return None
    return AlertContent(
        title=text["title"], body=text["body"], open=text["open"], thread="tips", source="server"
    )


def register_all() -> None:
    register(
        Aggregator(
            key="subscription.fulfilled",
            title="入库完成",
            description="你订阅或手动下载的电影、剧集整理进媒体库时",
            group="我的订阅",
            default=True,
            events=("subscription.fulfilled", "download.imported"),
            handle=_cards,
        )
    )
    register(
        Aggregator(
            key="subscription.download_started",
            title="开始下载",
            description="你订阅的内容找到资源、交给下载器时",
            group="我的订阅",
            default=False,
            events=("subscription.download_started",),
            handle=_cards,
        )
    )
    register(
        Rule(
            event="subscription.identity_skipped",
            title="已跳过同名资源",
            description="订阅发现无法确认身份的同名资源时知会一次，无需处理",
            group="我的订阅",
            default=True,
            audience=Audience.subscribers("subscription_id"),
            render=_identity_skipped,
            collapse=lambda p: ("identity-skipped", str(p.subscription_id)),
        )
    )
    register(
        Aggregator(
            key="subscription.upgraded",
            title="洗版完成",
            description="你订阅的内容换成了更好的版本时",
            group="我的订阅",
            default=False,
            events=("subscription.upgraded",),
            handle=_cards,
        )
    )
    register(
        Aggregator(
            key="library.items.arrived",
            title="媒体库有新片",
            description="你关心的媒体库来了新片或新剧集，不管是谁下载的",
            group="媒体库",
            default=False,
            events=("library.items.arrived",),
            handle=_cards,
        )
    )
    register(
        Rule(
            event="account.device.signed_in",
            title="新设备登录",
            description="有新的 App、播放器、命令行或转码器登录了你的账号",
            group="账号安全",
            default=True,
            audience=Audience.member("member_id"),
            render=_new_device,
            when=lambda p: p.new_device,
            exclude_devices=lambda p: frozenset(
                i for i in (p.device_id, p.approver_device_id) if i is not None
            ),
        )
    )
    register(
        Aggregator(
            key="system.alert.raised",
            title="需要处理的问题",
            description="下载器、站点、导入出错这类需要管理员处理的问题",
            group="管理员",
            default=True,
            admin_only=True,
            events=("system.alert.raised",),
            handle=_alert,
        )
    )
    register(
        Rule(
            event="system.update.available",
            title="有新版本",
            description="MovieClaw 发布了新版本时，每个版本只提醒一次",
            group="管理员",
            default=True,
            admin_only=True,
            audience=Audience.admins(),
            render=_new_version,
            collapse=lambda p: ("update", "app"),
        )
    )
    register(
        Rule(
            event="system.tip.suggested",
            title="使用建议",
            description=(
                "发现有设置能改善体验时（比如家里有人在用刷片、电视大图预告，建议开启片段预切），"
                "每条只提醒一次"
            ),
            group="管理员",
            default=True,
            admin_only=True,
            audience=Audience.admins(),
            render=_tip,
            collapse=lambda p: ("tip", p.tip),
        )
    )
