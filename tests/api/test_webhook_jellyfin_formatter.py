"""Jellyfin 变量字典单测：ticks 换算、补零、GUID 同源、层级翻译、看完标记。"""

from __future__ import annotations

from datetime import UTC, datetime

from movieclaw_api.services.webhook.jellyfin_formatter import targets, variables
from movieclaw_jellyfin.ids import episode_guid, item_guid, season_guid, user_guid_for
from movieclaw_sdk.events import ClientRef, ItemFavorite, MediaRef, PlaybackStopped, UnitRef

SERVER = {
    "id": "srv01",
    "name": "MovieClaw",
    "version": "0.5.0",
    "url": "http://mc.lan:3000",
    "username": "admin",
}
OCCURRED = datetime(2026, 8, 4, 12, 30, tzinfo=UTC)
SHOW = MediaRef(id=7, kind="tv", title="绝命毒师", year=2008, tmdb_id=1396, imdb_id="tt0903747")


def _stopped(completed: bool) -> dict:
    return PlaybackStopped(
        member_id=0,
        media=SHOW,
        unit=UnitRef(season=2, episode=4),
        position_ms=3_120_000,
        duration_ms=3_300_000,
        played=True,
        play_count=1,
        client=ClientRef(name="Infuse", device_name="Apple TV", device_id="d1"),
        completed=completed,
    ).model_dump(mode="json")


def _values(name: str, data: dict, **kw) -> dict:  # type: ignore[no-untyped-def]
    [target] = targets(name, data)
    return variables(
        kw.pop("type", "PlaybackStop"),
        data,
        target,
        occurred_at=OCCURRED,
        server=SERVER,
        username="admin",
        episode_title=kw.pop("episode_title", "Down"),
        completed=bool(data.get("completed")),
        favorite=kw.pop("favorite", False),
    )


def test_episode_variables() -> None:
    values = _values("playback.stopped", _stopped(completed=True))
    assert values["NotificationType"] == "PlaybackStop"
    assert values["PlayedToCompletion"] is True
    assert values["ServerUrl"] == "http://mc.lan:3000"
    assert values["NotificationUsername"] == "admin"
    assert values["UserId"] == user_guid_for(0)
    # GUID 与 Jellyfin 兼容 API 同源
    assert values["ItemId"] == episode_guid(7, 2, 4)
    assert values["SeriesId"] == item_guid(7)
    assert values["ItemType"] == "Episode"
    assert values["Name"] == "Down"  # 单集标题优先
    assert values["SeriesName"] == "绝命毒师"
    assert values["SeasonNumber00"] == "02"
    assert values["EpisodeNumber000"] == "004"
    # ticks 换算只在此边界发生
    assert values["PlaybackPositionTicks"] == 3_120_000 * 10_000
    assert values["RunTime"] == "00:55:00"
    assert values["PlaybackPosition"] == "00:52:00"
    assert values["DeviceName"] == "Apple TV"
    assert values["Provider_tmdb"] == 1396


def test_stopped_without_finishing() -> None:
    values = _values("playback.stopped", _stopped(completed=False))
    assert values["PlayedToCompletion"] is False


def test_favorite_on_a_season() -> None:
    data = ItemFavorite(
        member_id=0, media=SHOW, level="season", season=2
    ).model_dump(mode="json")
    values = _values("library.item.favorited", data, type="UserDataSaved", favorite=True)
    assert values["NotificationType"] == "UserDataSaved"
    assert values["Favorite"] is True
    assert values["ItemType"] == "Season"
    assert values["ItemId"] == season_guid(7, 2)
    assert values["Name"] == "绝命毒师"  # 不是单集：不用单集标题
    assert "SeriesName" not in values  # 非 episode 不给剧集变量


def test_movie_playback_targets_the_item() -> None:
    movie = MediaRef(id=9, kind="movie", title="奥德赛")
    data = PlaybackStopped(member_id=0, media=movie, unit=None).model_dump(mode="json")
    [target] = targets("playback.stopped", data)
    assert target["level"] == "movie"
    values = _values("playback.stopped", data)
    assert values["ItemType"] == "Movie" and values["ItemId"] == item_guid(9)
    assert values["Name"] == "奥德赛"
