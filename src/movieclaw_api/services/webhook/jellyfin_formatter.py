"""Jellyfin 兼容格式（docs/design/webhook.md §3、domain-events.md §6.2）。

兼容等式：MovieClaw 提供与 jellyfin-plugin-webhook 同名的变量字典 + 渲染用户从下游文档粘贴的
同一段 Handlebars 模板。变量子集按插件文档实现（对齐插件 master @ 2026-08），缺失项渲染为空串。
只有播放与用户数据类事件有 Jellyfin 对应物（``catalog.JELLYFIN_TYPES``）。

关键映射：
- ``playback.stopped`` → ``PlaybackStop``，``PlayedToCompletion`` 取停止时是否刚好看完
  （Jellyfin 没有独立的 completed 事件，所以 ``playback.completed`` 不映射）；
- 标记已看 / 取消已看级联到多集时按集各发一条 ``UserDataSaved``（同插件）；
- ``ItemId`` / ``SeriesId`` 与 Jellyfin 兼容 API 对外的条目 ID **同源**
  （movieclaw_jellyfin.ids 结构化 GUID），下游可回调兼容 API 查详情拉海报；
- 单集标题这类载荷里没有的，在这里（投递时、业务链路之外）补查；
- ticks 换算只发生在这里：``position_ms × 10000``，与入站方向对称。
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from movieclaw_api.services.webhook.catalog import JELLYFIN_TYPES
from movieclaw_jellyfin.ids import episode_guid, item_guid, season_guid, user_guid_for
from movieclaw_kernel import DeliveryInfo

TICKS_PER_MS = 10_000

_ITEM_TYPES = {"movie": "Movie", "episode": "Episode", "season": "Season", "series": "Series"}


def _hhmmss(ms: int | None) -> str:
    if not ms or ms < 0:
        return "00:00:00"
    seconds = ms // 1000
    return f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"


def _target(media: dict, season: int | None, episode: int | None, level: str | None) -> dict:
    """事件落在哪一层：电影 / 整剧 / 一季 / 一集。"""
    if level is None:
        if media.get("kind") == "movie" or season is None:
            level = "movie" if media.get("kind") == "movie" else "series"
        else:
            level = "episode" if episode is not None else "season"
    return {"level": level, "season": season, "episode": episode}


def _item_guid(media_id: int, target: dict) -> str:
    if target["level"] == "season":
        return season_guid(media_id, target["season"] or 0)
    if target["level"] == "episode":
        return episode_guid(media_id, target["season"] or 0, target["episode"] or 0)
    return item_guid(media_id)


def variables(
    notification_type: str,
    data: dict,
    target: dict,
    *,
    occurred_at: datetime,
    server: dict,
    username: str,
    episode_title: str | None,
    completed: bool,
    favorite: bool,
) -> dict:
    """插件同名的变量字典。"""
    media = data.get("media") or {}
    client = data.get("client") or {}
    media_id = int(media.get("id") or 0)
    values: dict = {
        # Server（全体通知可用）
        "ServerId": server.get("id", ""),
        "ServerName": server.get("name", ""),
        "ServerVersion": server.get("version", ""),
        "ServerUrl": server.get("url", ""),
        "NotificationType": notification_type,
        # User
        "UserId": user_guid_for(int(data.get("member_id") or 0)),
        "NotificationUsername": username,
        "Username": username,
        # Device & Client
        "DeviceName": client.get("device_name") or "",
        "DeviceId": client.get("device_id") or "",
        "ClientName": client.get("name") or "",
        "Client": client.get("name") or "",
        # BaseItem
        "Timestamp": occurred_at.astimezone().isoformat(),
        "UtcTimestamp": occurred_at.astimezone(UTC).isoformat(),
        "ItemId": _item_guid(media_id, target),
        "ItemType": _ITEM_TYPES.get(target["level"], ""),
        "Name": (episode_title if target["level"] == "episode" else None)
        or media.get("title")
        or "",
        "Overview": "",
        "Year": media.get("year") or "",
        "Provider_tmdb": media.get("tmdb_id") or "",
        "Provider_imdb": media.get("imdb_id") or "",
        "RunTime": _hhmmss(data.get("duration_ms")),
        "RunTimeTicks": (data.get("duration_ms") or 0) * TICKS_PER_MS,
        # Playback / UserData
        "PlaybackPosition": _hhmmss(data.get("position_ms")),
        "PlaybackPositionTicks": (data.get("position_ms") or 0) * TICKS_PER_MS,
        "PlayedToCompletion": completed,
        "Played": bool(data.get("played")),
        "PlayCount": data.get("play_count") or 0,
        "Favorite": favorite,
        "IsPaused": False,
    }
    if target["level"] == "episode":
        season = target["season"] or 0
        episode = target["episode"] or 0
        values.update(
            {
                "SeriesName": media.get("title") or "",
                "SeriesId": item_guid(media_id),
                "SeasonNumber": season,
                "SeasonNumber00": f"{season:02d}",
                "SeasonNumber000": f"{season:03d}",
                "EpisodeNumber": episode,
                "EpisodeNumber00": f"{episode:02d}",
                "EpisodeNumber000": f"{episode:03d}",
            }
        )
    return values


def targets(name: str, data: dict) -> list[dict]:
    """这个事件要发几条、各落在哪一层。"""
    media = data.get("media") or {}
    if name.startswith("library.item."):
        return [_target(media, data.get("season"), data.get("episode"), data.get("level"))]
    if name.startswith("playback.marked_"):
        units = data.get("units") or []
        if not units:
            return [_target(media, None, None, None)]
        return [_target(media, u["season"], u["episode"], "episode") for u in units]
    unit = data.get("unit")
    if unit is None:
        return [_target(media, None, None, "movie")]
    return [_target(media, unit["season"], unit["episode"], "episode")]


async def _lookups(data: dict, wanted: list[dict], server: dict) -> tuple[str, dict]:
    """补查载荷里没有的：成员名、单集标题（投递时查，不占业务链路）。"""
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import MediaEpisode, Member

    member_id = int(data.get("member_id") or 0)
    media_id = int((data.get("media") or {}).get("id") or 0)
    pairs = {(t["season"], t["episode"]) for t in wanted if t["level"] == "episode"}
    username = server.get("username", "")
    titles: dict = {}
    async with get_database().session() as session:
        if member_id:
            member = await session.get(Member, member_id)
            if member is not None:
                username = member.username
        if pairs and media_id:
            rows = await session.execute(
                select(
                    MediaEpisode.season_number, MediaEpisode.episode_number, MediaEpisode.name
                ).where(MediaEpisode.media_item_id == media_id)
            )
            titles = {(s, e): n for s, e, n in rows.all() if (s, e) in pairs and n}
    return username, titles


async def render(
    info: DeliveryInfo, data: dict, server: dict, template: str
) -> list[tuple[bytes, dict[str, str]]]:
    """渲染用户模板为请求体；没有 Jellyfin 对应物的事件返回空列表。模板错误抛 ``ValueError``。"""
    from movieclaw_api.services.webhook.handlebars import TemplateError
    from movieclaw_api.services.webhook.handlebars import render as render_template

    test = info.name == "webhook.test"
    notification_type = "PlaybackStop" if test else JELLYFIN_TYPES.get(info.name)
    if notification_type is None:
        return []
    wanted = targets("playback.stopped" if test else info.name, data)
    username, titles = await _lookups(data, wanted, server)
    occurred = datetime.fromisoformat(info.occurred_at)
    headers = {
        "Content-Type": "application/json; charset=utf-8",
        "User-Agent": f"MovieClaw/{server.get('version', '')}",
    }
    out = []
    for target in wanted:
        values = variables(
            notification_type,
            data,
            target,
            occurred_at=occurred,
            server=server,
            username=username,
            episode_title=titles.get((target["season"], target["episode"])),
            completed=bool(data.get("completed")),
            favorite=info.name == "library.item.favorited",
        )
        try:
            body = render_template(template, values)
        except TemplateError as exc:
            raise ValueError(str(exc)) from exc
        out.append((body.encode("utf-8"), headers))
    return out


__all__: list[Any] = ["render", "targets", "variables"]
