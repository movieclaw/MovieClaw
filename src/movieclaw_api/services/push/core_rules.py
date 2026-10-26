"""内置的通知规则（docs/design/domain-events.md §6.1、§8）。

登记顺序就是「账号 → 通知」页上的顺序。剧卡（入库、开始下载、洗版、媒体库有新片、订阅收齐）与待处理
事项是聚合器：事件交给 cards.py / alerts.py 合并；其余是一个事件一条通知的规则。
"""

from __future__ import annotations

from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.i18n import t
from movieclaw_api.i18n.labels import device_kind, language_name
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.services.push.notify import AlertContent, server_identity
from movieclaw_api.services.push.rules import Aggregator, Audience, Rule, register


def _cards(name: str, payload: Any) -> None:
    from movieclaw_api.services.push import cards

    cards.on_event(name, payload)


def _alert(_name: str, payload: Any) -> None:
    from movieclaw_api.services.push import alerts

    alerts.queue(payload.dedupe_key)


def _alert_resolved(_name: str, payload: Any) -> None:
    from movieclaw_api.services.push import alerts

    alerts.resolved(payload.dedupe_key)


# ---------------------------------------------------------------------- 订阅、媒体库
async def _identity_skipped(_s: AsyncSession, _member: int, p: Any) -> AlertContent:
    return AlertContent(
        title=t("notify.identitySkipped.title", title=p.media.title),
        body=t("notify.identitySkipped.body"),
        open=f"/subscriptions/{p.subscription_id}",
        thread=f"subscription:{p.subscription_id}",
    )


async def _stuck(_s: AsyncSession, _member: int, p: Any) -> AlertContent:
    from movieclaw_api.services.push.labels import units_text

    which = units_text([(u.season, u.episode) for u in p.units])
    return AlertContent(
        title=t("notify.stuck.title", title=p.media.title, units=which),
        body=t("notify.stuck.body", hours=p.retry_hours),
        open=f"/subscriptions/{p.subscription_id}",
        thread=f"subscription:{p.subscription_id}",
    )


async def _awaiting_subtitles(_s: AsyncSession, _member: int, p: Any) -> AlertContent:
    from movieclaw_api.services.push.labels import units_text

    which = units_text([(u.season, u.episode) for u in p.units])
    return AlertContent(
        title=t("notify.subtitles.title", title=p.media.title, units=which),
        body=t(
            "notify.subtitles.body",
            hours=p.waited_hours,
            acceptable=(
                t("media.language.or").join(language_name(code) for code in p.acceptable_languages)
                if p.acceptable_languages
                else p.acceptable
            ),
            language=language_name(p.language_code) if p.language_code is not None else p.language,
            count=p.originals,
        ),
        open=f"/subscriptions/{p.subscription_id}",
        thread=f"subscription:{p.subscription_id}",
    )


async def _more_episodes(_s: AsyncSession, _member: int, p: Any) -> AlertContent:
    return AlertContent(
        title=t(
            "notify.moreEpisodes.title", title=p.media.title, season=p.season, count=p.hinted_count
        ),
        body=t("notify.moreEpisodes.body", count=p.known_count, source=p.source),
        open=f"/subscriptions/{p.subscription_id}",
        thread=f"subscription:{p.subscription_id}",
    )


# ---------------------------------------------------------------------- 账号安全
async def _new_device(_s: AsyncSession, _member: int, p: Any) -> AlertContent:
    # 安全提醒一定要说清是哪台服务器：不知道在哪，就没法判断是不是自己、去哪注销
    server = (await server_identity())["name"]
    return AlertContent(
        title=t("notify.device.title"),
        body=t(
            "notify.device.body",
            server=server,
            device=p.device_name,
            kind=p.kind_label if p.kind == "player" else device_kind(p.kind, p.kind_label),
            hasSource="yes" if p.ip else "no",
            ip=p.ip or "",
        ),
        open="/settings/devices",
        thread="account",
        source="account",
        # 账号安全：专注模式下也要提醒（App 有「时效性通知」能力）
        level="time-sensitive",
    )


# ---------------------------------------------------------------------- 管理员
async def _new_version(_s: AsyncSession, _member: int, p: Any) -> AlertContent:
    how = t("notify.update.inApp") if p.compatible else t("notify.update.docker")
    return AlertContent(
        title=t("notify.update.title", version=p.version),
        body=how,
        open="/settings/app",
        thread="update",
        source="server",
    )


#: 使用建议的文案（``system.tip.suggested`` 的 ``tip``）
TIPS: dict[str, dict[str, str]] = {
    "reel-clips": {
        "title": "notify.tips.prewarmTitle",
        "body": "notify.tips.prewarmBody",
        "open": "/settings/playback",
    },
}


async def _tip(_s: AsyncSession, _member: int, p: Any) -> AlertContent | None:
    text = TIPS.get(p.tip)
    if text is None:
        return None
    return AlertContent(
        title=t(text["title"]),
        body=t(text["body"]),
        open=text["open"],
        thread="tips",
        source="server",
    )


async def _agent_finished(_s: AsyncSession, _member: int, p: Any) -> AlertContent | None:
    # 只留最该看的：标题 = 哪个会话，正文 = 回答开头；出错时正文开头就说「没能完成」。
    # 不写「AI 助手已回复」——来源有 App 图标交代，多个会话同时跑时靠标题区分（2026-10-13 用户定）
    if p.status == "done":
        body = p.answer or t("notify.agent.replied")
    else:
        error_ref = getattr(p, "error_ref", None)
        body = t(
            "notify.agent.failed",
            reason=render_value(error_ref) if error_ref else p.error or t("notify.agent.unknown"),
        )
    return AlertContent(
        title=(
            render_value({**p.title_ref, "message": p.title or ""}).strip()[:80]
            if getattr(p, "title_ref", None)
            else p.title
        )
        or t("notify.agent.title"),
        body=body,
        open=f"/sessions/{p.session_id}",
        thread=f"agent:{p.session_id}",
        source="server",
    )


def register_all() -> None:
    register(
        Aggregator(
            key="subscription.fulfilled",
            title="notify.preferences.importedTitle",
            description="notify.preferences.importedDescription",
            group="notify.groups.subscriptions",
            default=True,
            events=("subscription.fulfilled", "download.imported"),
            handle=_cards,
        )
    )
    register(
        Aggregator(
            key="subscription.download_started",
            title="notify.preferences.startedTitle",
            description="notify.preferences.startedDescription",
            group="notify.groups.subscriptions",
            default=False,
            events=("subscription.download_started",),
            handle=_cards,
        )
    )
    register(
        Rule(
            event="subscription.identity_skipped",
            title="notify.preferences.identitySkippedTitle",
            description="notify.preferences.identitySkippedDescription",
            group="notify.groups.subscriptions",
            default=True,
            audience=Audience.subscribers("subscription_id"),
            render=_identity_skipped,
            collapse=lambda p: ("identity-skipped", str(p.subscription_id)),
        )
    )
    register(
        Rule(
            event="subscription.awaiting_subtitles",
            title="notify.preferences.subtitlesTitle",
            description="notify.preferences.subtitlesDescription",
            group="notify.groups.subscriptions",
            default=True,
            audience=Audience.subscribers("subscription_id"),
            render=_awaiting_subtitles,
            collapse=lambda p: (
                "awaiting-subtitles",
                f"{p.subscription_id}:" + ",".join(f"{u.season}x{u.episode}" for u in p.units),
            ),
        )
    )
    register(
        Aggregator(
            key="subscription.upgraded",
            title="notify.preferences.upgradedTitle",
            description="notify.preferences.upgradedDescription",
            group="notify.groups.subscriptions",
            default=False,
            events=("subscription.upgraded",),
            handle=_cards,
        )
    )
    register(
        Aggregator(
            key="subscription.completed",
            title="notify.preferences.completedTitle",
            description="notify.preferences.completedDescription",
            group="notify.groups.subscriptions",
            default=True,
            events=("subscription.status_changed",),
            handle=_cards,
        )
    )
    register(
        Rule(
            event="subscription.download_stuck",
            title="notify.preferences.stuckTitle",
            description="notify.preferences.stuckDescription",
            group="notify.groups.subscriptions",
            default=True,
            audience=Audience.subscribers("subscription_id"),
            render=_stuck,
            collapse=lambda p: ("stuck", str(p.subscription_id)),
        )
    )
    register(
        Rule(
            event="subscription.more_episodes",
            title="notify.preferences.moreEpisodesTitle",
            description="notify.preferences.moreEpisodesDescription",
            group="notify.groups.subscriptions",
            default=True,
            audience=Audience.subscribers("subscription_id"),
            render=_more_episodes,
            collapse=lambda p: ("more-episodes", f"{p.subscription_id}:{p.season}"),
        )
    )
    register(
        Aggregator(
            key="library.items.arrived",
            title="notify.preferences.libraryArrivedTitle",
            description="notify.preferences.libraryArrivedDescription",
            group="notify.groups.library",
            default=False,
            events=("library.items.arrived",),
            handle=_cards,
        )
    )
    register(
        Rule(
            event="account.device.signed_in",
            title="notify.preferences.deviceSignedInTitle",
            description="notify.preferences.deviceSignedInDescription",
            group="notify.groups.security",
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
            title="notify.preferences.alertRaisedTitle",
            description="notify.preferences.alertRaisedDescription",
            group="notify.groups.admin",
            default=True,
            admin_only=True,
            events=("system.alert.raised",),
            handle=_alert,
        )
    )
    register(
        Aggregator(
            key="system.alert.resolved",
            title="notify.preferences.alertResolvedTitle",
            description="notify.preferences.alertResolvedDescription",
            group="notify.groups.admin",
            default=True,
            admin_only=True,
            events=("system.alert.resolved",),
            handle=_alert_resolved,
        )
    )
    register(
        Rule(
            event="system.update.available",
            title="notify.preferences.updateTitle",
            description="notify.preferences.updateDescription",
            group="notify.groups.admin",
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
            title="notify.preferences.tipTitle",
            description=("notify.preferences.tipDescription"),
            group="notify.groups.admin",
            default=True,
            admin_only=True,
            audience=Audience.admins(),
            render=_tip,
            collapse=lambda p: ("tip", p.tip),
        )
    )
    register(
        Rule(
            event="agent.run.finished",
            title="notify.preferences.agentFinishedTitle",
            description=("notify.preferences.agentFinishedDescription"),
            group="notify.groups.agent",
            default=True,
            admin_only=True,
            audience=Audience.member("member_id"),
            render=_agent_finished,
            when=lambda p: p.source == "app",
            collapse=lambda p: ("agent-run", p.session_id),
            to_im=False,
        )
    )
