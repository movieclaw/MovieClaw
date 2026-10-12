"""观看、收藏、浏览的事件产生（docs/design/domain-events.md §4、§8）。

网页与 Jellyfin 协议两条入口都经 ``watch.py`` / ``marks.py`` 汇到这里，拼一次载荷、``publish``
一次。内部单元 ``(条目, 季, 集)`` 的哨兵值不外泄：电影没有单元，收藏的 ``-1`` 换成层级。

载荷只在有人订阅时才拼（Webhook 没勾、插件没订就什么都不查）。
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api import event_refs, events
from movieclaw_db.models import MediaItem
from movieclaw_playback.events import ClientInfo
from movieclaw_playback.state import Unit
from movieclaw_sdk.events import (
    LIBRARY_ITEM_FAVORITED,
    LIBRARY_ITEM_UNFAVORITED,
    LIBRARY_ITEM_VIEWED,
    PLAYBACK_MARKED_PLAYED,
    PLAYBACK_MARKED_UNPLAYED,
    ClientRef,
    EventType,
    ItemFavorite,
    ItemViewed,
    PlaybackMarked,
    PlaybackStopped,
)


def client_ref(client: ClientInfo | None) -> ClientRef | None:
    if client is None:
        return None
    return ClientRef(
        name=client.name or None,
        device_name=client.device_name or None,
        device_id=client.device_id or None,
        version=client.version or None,
    )


async def publish_playback(
    session: AsyncSession,
    event: EventType,
    unit: Unit,
    state: Any,
    *,
    member_id: int,
    client: ClientInfo | None,
    duration_ms: int | None = None,
    file_id: int | None = None,
    completed: bool = False,
) -> None:
    """开始 / 停止 / 看完 / 进度：``state`` 是这次上报落库后的观看状态行。"""

    async def build() -> Any:
        media = event_refs.media_ref(await session.get(MediaItem, unit[0]))
        if media is None:
            return None
        # 停止的载荷多一个 completed；其余事件用同一个结构（PlaybackStopped 是它的子类）
        payload_type = event.payload
        fields: dict[str, Any] = {
            "member_id": member_id,
            "media": media,
            "unit": event_refs.unit(unit[1], unit[2]),
            "file_id": file_id,
            "position_ms": state.position_ms,
            "duration_ms": duration_ms,
            "played": bool(state.played),
            "play_count": state.play_count or 0,
            "client": client_ref(client),
        }
        if payload_type is PlaybackStopped:
            fields["completed"] = completed
        return payload_type(**fields)

    await events.publish(session, event, build)


async def publish_marked(
    session: AsyncSession,
    units: Iterable[Unit],
    *,
    played: bool,
    member_id: int,
    client: ClientInfo | None,
) -> None:
    """标记已看 / 取消已看：级联到的每一集在一个事件里。"""
    units = list(units)
    if not units:
        return

    async def build() -> PlaybackMarked | None:
        media = event_refs.media_ref(await session.get(MediaItem, units[0][0]))
        if media is None:
            return None
        return PlaybackMarked(
            member_id=member_id,
            media=media,
            units=event_refs.units((u[1], u[2]) for u in units),
            client=client_ref(client),
        )

    await events.publish(
        session, PLAYBACK_MARKED_PLAYED if played else PLAYBACK_MARKED_UNPLAYED, build
    )


async def publish_favorite(
    session: AsyncSession,
    unit: Unit,
    *,
    favorite: bool,
    member_id: int,
    client: ClientInfo | None,
) -> None:
    """收藏 / 取消收藏；收藏落在哨兵单元上：(-1,-1) 整剧、(季,-1) 整季。"""

    async def build() -> ItemFavorite | None:
        item = await session.get(MediaItem, unit[0])
        media = event_refs.media_ref(item)
        if media is None:
            return None
        _, season, episode = unit
        if (season, episode) == (-1, -1):
            level, season_out, episode_out = "series", None, None
        elif episode == -1:
            level, season_out, episode_out = "season", season, None
        elif media.kind == "movie":
            level, season_out, episode_out = "movie", None, None
        else:
            level, season_out, episode_out = "episode", season, episode
        return ItemFavorite(
            member_id=member_id,
            media=media,
            level=level,
            season=season_out,
            episode=episode_out,
            client=client_ref(client),
        )

    await events.publish(
        session, LIBRARY_ITEM_FAVORITED if favorite else LIBRARY_ITEM_UNFAVORITED, build
    )


async def publish_viewed(
    session: AsyncSession,
    media_item_id: int,
    *,
    member_id: int,
    season: int | None = None,
    episode: int | None = None,
    client: ClientInfo | None = None,
) -> None:
    """打开了条目详情（高频，只有实时订阅）。"""
    if not events.listening(LIBRARY_ITEM_VIEWED):
        return
    await events.publish_now(
        LIBRARY_ITEM_VIEWED,
        lambda: _viewed(session, media_item_id, member_id, season, episode, client),
    )


async def _viewed(
    session: AsyncSession,
    media_item_id: int,
    member_id: int,
    season: int | None,
    episode: int | None,
    client: ClientInfo | None,
) -> ItemViewed | None:
    media = event_refs.media_ref(await session.get(MediaItem, media_item_id))
    if media is None:
        return None
    return ItemViewed(
        member_id=member_id,
        media=media,
        season=season,
        episode=episode,
        client=client_ref(client),
    )
