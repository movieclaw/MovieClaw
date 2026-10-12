"""订阅域的事件产生（docs/design/domain-events.md §4、§8）。

订阅的每件事在这里拼一次载荷、``publish`` 一次；通知、Webhook、插件都从总线上取。
电影的内部单元 (0, 0) 不外泄：载荷里电影的季集列表为空。
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api import event_refs, events
from movieclaw_sdk.events import (
    DOWNLOAD_COMPLETED,
    SUBSCRIPTION_DOWNLOAD_STARTED,
    SUBSCRIPTION_DOWNLOAD_STUCK,
    SUBSCRIPTION_FULFILLED,
    SUBSCRIPTION_MORE_EPISODES,
    SUBSCRIPTION_UPGRADED,
    DownloadCompleted,
    EventType,
    SubscriptionChanged,
    SubscriptionDownloadStarted,
    SubscriptionDownloadStuck,
    SubscriptionFulfilled,
    SubscriptionMoreEpisodes,
    SubscriptionUpgraded,
    TorrentRef,
)


async def publish_changed(
    session: AsyncSession,
    event: EventType,
    subscription: Any,
    *,
    previous_status: Any = None,
    reason: str | None = None,
    cleanup_job_id: str | None = None,
) -> None:
    """订阅建立 / 删除 / 状态变化（随接下来那次保存一起提交）。"""
    from movieclaw_db.models import MediaItem

    async def build() -> SubscriptionChanged | None:
        if subscription.id is None:
            return None
        item = await session.get(MediaItem, subscription.media_item_id)
        return SubscriptionChanged(
            subscription_id=subscription.id,
            media=event_refs.media_ref(item),
            member_id=subscription.created_by_member_id or 0,
            status=_text(subscription.status),
            previous_status=_text(previous_status),
            reason=reason,
            cleanup_job_id=cleanup_job_id,
        )

    await events.publish(session, event, build)


def _text(value: Any) -> str | None:
    if value is None:
        return None
    return str(getattr(value, "value", value))


async def publish_download_started(
    session: AsyncSession,
    *,
    subscription_id: int,
    item: Any,
    units: Iterable[tuple[int, int]],
    site_id: str | None,
    torrent_id: str | None,
    torrent_title: str,
    info_hash: str | None,
    resolution: str | None,
    spec: str,
    upgrade: bool,
    actor_member_id: int | None,
) -> None:
    """种子已真实提交下载器（模拟投递不调）。"""
    media = event_refs.media_ref(item)
    if media is None:
        return
    await events.publish(
        session,
        SUBSCRIPTION_DOWNLOAD_STARTED,
        lambda: SubscriptionDownloadStarted(
            subscription_id=subscription_id,
            media=media,
            units=event_refs.units(units),
            torrent=TorrentRef(
                site_id=site_id,
                torrent_id=torrent_id,
                title=torrent_title,
                info_hash=info_hash.lower() if info_hash else None,
                resolution=resolution or None,
                spec=spec,
            ),
            upgrade=upgrade,
            actor_member_id=actor_member_id,
        ),
    )


async def publish_fulfilled(
    session: AsyncSession,
    *,
    subscription_id: int,
    item: Any,
    units: Iterable[tuple[int, int]],
    requested_units: Iterable[tuple[int, int]],
) -> None:
    """订阅的季集经媒体库对账确认入库。"""
    media = event_refs.media_ref(item)
    if media is None:
        return
    await events.publish(
        session,
        SUBSCRIPTION_FULFILLED,
        lambda: SubscriptionFulfilled(
            subscription_id=subscription_id,
            media=media,
            units=event_refs.units(units),
            requested_units=event_refs.units(requested_units),
        ),
    )


async def publish_upgraded(
    session: AsyncSession,
    *,
    subscription_id: int,
    item: Any,
    unit: tuple[int, int],
    old_label: str,
    new_label: str,
) -> None:
    """订阅的一集（或电影）换成了更好的版本。"""
    media = event_refs.media_ref(item)
    if media is None:
        return
    await events.publish(
        session,
        SUBSCRIPTION_UPGRADED,
        lambda: SubscriptionUpgraded(
            subscription_id=subscription_id,
            media=media,
            unit=event_refs.unit(*unit),
            old_label=old_label,
            new_label=new_label,
        ),
    )


async def publish_download_completed(session: AsyncSession, attempt: Any) -> None:
    """订阅投递的种子在下载器里下载完成（入库之前）。"""
    from movieclaw_db.models import MediaItem, Subscription

    async def build() -> DownloadCompleted:
        subscription = await session.get(Subscription, attempt.subscription_id)
        item = (
            await session.get(MediaItem, subscription.media_item_id) if subscription else None
        )
        return DownloadCompleted(
            subscription_id=attempt.subscription_id,
            media=event_refs.media_ref(item),
            units=event_refs.units(attempt.units or ()),
            info_hash=attempt.info_hash.lower(),
            downloader_id=attempt.downloader_id,
            site_id=attempt.site_id,
            torrent_id=attempt.torrent_id,
            title=attempt.torrent_title or None,
            save_path=attempt.save_path,
            download_name=attempt.download_name,
            purpose=attempt.purpose,
        )

    await events.publish(session, DOWNLOAD_COMPLETED, build)


async def publish_download_stuck(session: AsyncSession, attempt: Any, *, retry_hours: int) -> None:
    """订阅的下载卡住、第一次自动换源落空（每个下载任务只发一次）。"""
    from movieclaw_db.models import MediaItem, Subscription

    async def build() -> SubscriptionDownloadStuck | None:
        subscription = await session.get(Subscription, attempt.subscription_id)
        item = await session.get(MediaItem, subscription.media_item_id) if subscription else None
        media = event_refs.media_ref(item)
        if media is None:
            return None
        return SubscriptionDownloadStuck(
            subscription_id=attempt.subscription_id,
            media=media,
            units=event_refs.units(attempt.units or ()),
            torrent_title=attempt.torrent_title or None,
            retry_hours=retry_hours,
        )

    await events.publish(session, SUBSCRIPTION_DOWNLOAD_STUCK, build)


async def publish_more_episodes(
    session: AsyncSession,
    subscription: Any,
    item: Any,
    *,
    season: int,
    known_count: int,
    hinted_count: int,
    source: str,
    hint_title: str | None = None,
) -> None:
    """这一季可能不止 TMDB 录的集数，等用户确认（站点或豆瓣给出了新线索才发）。"""
    media = event_refs.media_ref(item)
    if media is None or subscription.id is None:
        return
    await events.publish(
        session,
        SUBSCRIPTION_MORE_EPISODES,
        lambda: SubscriptionMoreEpisodes(
            subscription_id=subscription.id,
            media=media,
            season=season,
            known_count=known_count,
            hinted_count=hinted_count,
            source=source,
            hint_title=hint_title,
        ),
    )
