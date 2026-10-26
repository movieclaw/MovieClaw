"""Jellyfin 客户端的默认轨走同一个默认轨策略（``movieclaw_playback.track_policy``）。

PlaybackInfo 的 DefaultAudioStreamIndex / DefaultSubtitleStreamIndex 按原声、库语言给；
客户端每次进度都带着当前轨，报的就是这两条时不算用户的选择。
"""

from __future__ import annotations

import asyncio

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select

from jellyfin.helpers import jf_login
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.models import LibraryFile, MediaMetadata, PlaybackState
from movieclaw_jellyfin.ids import item_guid

# 没有外挂字幕：video=0、音轨 1/2、内封字幕 3/4（jellyfin-subtitle.md §4.1）
DUB_AUDIO, ORIGINAL_AUDIO = 1, 2
ENGLISH_SUBTITLE, CHINESE_SUBTITLE = 3, 4


@pytest.fixture
def policy_env(seeded: dict, monkeypatch) -> dict:
    """把《盗梦空间》改成：国语配音标了默认、英语原声第二；英文字幕标了默认、中文第二；
    原始语言英语。媒体库语言是默认的 zh-CN。"""
    from movieclaw_api.core.config import get_settings

    monkeypatch.setenv("TMDB_LANGUAGE", "zh-CN")
    get_settings.cache_clear()

    async def _update() -> None:
        init_db(get_settings().database_url, echo=False)
        async with get_database().session() as session:
            row = (
                await session.execute(
                    select(LibraryFile).where(
                        LibraryFile.file_path.like("%Inception.2010.2160p.mkv")
                    )
                )
            ).scalar_one()
            row.audio_streams = [
                {"codec": "aac", "channels": 2, "language": "chi", "default": True},
                {"codec": "aac", "channels": 6, "language": "eng", "default": False},
            ]
            row.subtitle_streams = [
                {"codec": "subrip", "language": "eng", "default": True, "forced": False},
                {"codec": "subrip", "language": "chi", "default": False, "forced": False},
            ]
            meta = (
                await session.execute(
                    select(MediaMetadata).where(MediaMetadata.media_item_id == seeded["movie"])
                )
            ).scalar_one()
            meta.original_language = "en"
            await session.commit()
        await dispose_db()

    asyncio.run(_update())
    return seeded


@pytest.fixture
def pclient(policy_env: dict, client: TestClient) -> TestClient:
    """播种在应用启动前完成（fixture 依赖顺序保证）。"""
    return client


def _source(client: TestClient, token: str, guid: str) -> dict:
    resp = client.post(f"/Items/{guid}/PlaybackInfo", headers={"X-Emby-Token": token}, json={})
    assert resp.status_code == 200, resp.text
    return next(s for s in resp.json()["MediaSources"] if s.get("Container") == "mkv")


def test_playback_info_defaults_follow_the_track_policy(pclient, policy_env) -> None:
    token = jf_login(pclient)
    source = _source(pclient, token, item_guid(policy_env["movie"]))
    assert source["DefaultAudioStreamIndex"] == ORIGINAL_AUDIO
    assert source["DefaultSubtitleStreamIndex"] == CHINESE_SUBTITLE


def test_reported_policy_tracks_are_not_remembered_but_the_dub_is(pclient, policy_env) -> None:
    token = jf_login(pclient)
    guid = item_guid(policy_env["movie"])
    source = _source(pclient, token, guid)

    def progress(**tracks) -> None:
        resp = pclient.post(
            "/Sessions/Playing/Progress",
            headers={"X-Emby-Token": token},
            json={
                "ItemId": guid,
                "MediaSourceId": source["Id"],
                "PositionTicks": 60 * 10_000_000,
                **tracks,
            },
        )
        assert resp.status_code == 204

    async def _tracks() -> list[tuple[str | None, str | None]]:
        async with get_database().session() as session:
            query = select(PlaybackState).where(
                PlaybackState.media_item_id == policy_env["movie"]
            )
            rows = (await session.execute(query)).scalars()
            return [(row.audio_track, row.subtitle_track) for row in rows]

    progress(AudioStreamIndex=ORIGINAL_AUDIO, SubtitleStreamIndex=CHINESE_SUBTITLE)
    assert pclient.portal.call(_tracks) == [(None, None)]  # type: ignore[attr-defined]
    # 换成国语配音（容器默认轨）是用户的选择；中文库里放国语照样开中文字幕，字幕仍是默认挑选
    progress(AudioStreamIndex=DUB_AUDIO, SubtitleStreamIndex=CHINESE_SUBTITLE)
    assert pclient.portal.call(_tracks) == [("embedded:0", None)]  # type: ignore[attr-defined]
