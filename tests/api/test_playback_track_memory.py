"""剧集的音轨 / 字幕记忆按整部剧生效（``services/playback/track_memory``）。

新的一集没有记忆时，沿用同一部剧最近一集的选择——但每集文件的轨序、外挂字幕文件名
都可能不同，只能**按语言换算**。这里测三件事：换算规则（轨序错位、外挂文件名不同、
换不出来就不给）、本集自己的记忆优先、电影不受影响。
"""

from __future__ import annotations

from datetime import datetime

import pytest_asyncio

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.playback.track_memory import (
    series_track_memory,
    translate_audio,
    translate_subtitle,
)
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaItem,
    MediaMetadata,
    PlaybackState,
)
from movieclaw_db.repositories.library_repo import LibraryRepository


def _audio(language: str, codec: str = "aac", channels: int = 2, default: bool = False) -> dict:
    return {"codec": codec, "channels": channels, "language": language, "default": default}


def _sub(language: str | None, codec: str = "subrip", **extra) -> dict:
    return {"codec": codec, "language": language, "title": None, "forced": False, **extra}


def _external(filename: str, language: str | None, **extra) -> dict:
    fmt = filename.rsplit(".", 1)[-1]
    return {
        "filename": filename,
        "format": fmt,
        "language": language,
        "title": None,
        "forced": False,
        **extra,
    }


def _file(**fields) -> LibraryFile:
    return LibraryFile(library_id=1, file_path="/tv/x.mkv", size_bytes=1,
                       source=FileSource.SCANNED, **fields)


# ---------------------------------------------------------------------------
# 换算规则
# ---------------------------------------------------------------------------


def test_audio_follows_language_when_track_order_shifts():
    """第 1 集国语在第 2 条；第 2 集多了一条评论音轨，国语挪到第 3 条。"""
    ep1 = _file(audio_streams=[_audio("eng", default=True), _audio("chi")])
    ep2 = _file(audio_streams=[_audio("eng", default=True), _audio("eng"), _audio("chi")])
    assert translate_audio("embedded:1", ep1, ep2) == "embedded:2"
    # zho / chi 是同一种语言（ISO 639-2 的 T / B 两种写法）
    ep3 = _file(audio_streams=[_audio("eng", default=True), _audio("zho")])
    assert translate_audio("embedded:1", ep1, ep3) == "embedded:1"


def test_audio_prefers_same_codec_and_channels():
    """同语言有两条（杜比 5.1 与 AAC 立体声）：沿用上一集同编码、同声道的那条。"""
    ep1 = _file(audio_streams=[_audio("eng", default=True), _audio("chi", "eac3", 6)])
    ep2 = _file(
        audio_streams=[_audio("eng", default=True), _audio("chi"), _audio("chi", "eac3", 6)]
    )
    assert translate_audio("embedded:1", ep1, ep2) == "embedded:2"


def test_audio_without_language_evidence_is_not_translated():
    """上一集的轨没标语言、或本集没有这种语言：换算不出来就交回默认选择。"""
    ep1 = _file(audio_streams=[_audio("eng", default=True), _audio("und"), _audio("chi")])
    ep2 = _file(audio_streams=[_audio("eng", default=True), _audio("jpn")])
    assert translate_audio("embedded:1", ep1, ep2) is None
    assert translate_audio("embedded:2", ep1, ep2) is None
    # 越界的旧引用（文件换过版本）同样不给
    assert translate_audio("embedded:9", ep1, ep2) is None


def test_external_subtitle_follows_language_across_filenames():
    """外挂字幕每集文件名都不同：按语言找本集的同类外挂字幕。"""
    ep1 = _file(
        external_subtitles=[
            _external("Show.S01E01.en.srt", "eng"),
            _external("Show.S01E01.chs.srt", "chi"),
        ]
    )
    ep2 = _file(
        external_subtitles=[
            _external("Show.S01E02.chs.srt", "chi"),
            _external("Show.S01E02.en.srt", "eng"),
        ]
    )
    got = translate_subtitle("external:Show.S01E01.chs.srt", ep1, ep2)
    assert got == "external:Show.S01E02.chs.srt"


def test_subtitle_prefers_same_kind_and_falls_back_across_kinds():
    """内封中文 → 本集也有内封中文就用内封；本集只有外挂中文也照样沿用（同语言胜过回到默认）。"""
    ep1 = _file(subtitle_streams=[_sub("eng"), _sub("chi")])
    ep2 = _file(
        subtitle_streams=[_sub("chi", "hdmv_pgs_subtitle"), _sub("eng"), _sub("chi")],
        external_subtitles=[_external("Show.S01E02.chs.srt", "chi")],
    )
    # 文字轨对文字轨：跳过同语言的图形字幕
    assert translate_subtitle("embedded:1", ep1, ep2) == "embedded:2"
    ep3 = _file(subtitle_streams=[_sub("eng")],
                external_subtitles=[_external("Show.S01E03.chs.srt", "chi")])
    assert translate_subtitle("embedded:1", ep1, ep3) == "external:Show.S01E03.chs.srt"


def test_subtitle_off_stays_off_and_unknown_is_dropped():
    # 上一集有默认字幕、用户关掉了：本集照旧关闭
    ep1 = _file(subtitle_streams=[_sub("chi", default=True), _sub(None)])
    ep2 = _file(subtitle_streams=[_sub("chi", default=True)])
    assert translate_subtitle("off", ep1, ep2) == "off"
    # 没标语言的轨无从换算
    assert translate_subtitle("embedded:1", ep1, ep2) is None
    assert translate_subtitle("external:gone.srt", ep1, ep2) is None


def test_default_choices_are_not_carried_over():
    """记着的是那一集的默认挑选（进度上报每次都记正在放的轨）：不是用户选的，新的一集照自己的默认走。"""
    ep1 = _file(
        audio_streams=[_audio("eng", default=True), _audio("chi")],
        subtitle_streams=[_sub("eng")],
        external_subtitles=[_external("Show.S01E01.chs.srt", "chi")],
    )
    ep2 = _file(
        audio_streams=[_audio("chi", default=True), _audio("eng")],
        subtitle_streams=[_sub("eng")],
        external_subtitles=[_external("Show.S01E02.chs.srt", "chi")],
    )
    assert translate_audio("embedded:0", ep1, ep2) is None
    # 装了外挂字幕就默认选外挂：记着它不代表用户选过
    assert translate_subtitle("external:Show.S01E01.chs.srt", ep1, ep2) is None
    # 那一集本来就没有默认字幕：「关闭」只是默认状态——第 1 集没字幕，不能把第 2 集的默认字幕也关掉
    bare = _file(subtitle_streams=[_sub("eng")])
    assert translate_subtitle("off", bare, ep2) is None


# ---------------------------------------------------------------------------
# 取记忆：本集优先、电影不受影响
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'memory.db'}")
    monkeypatch.setenv("TMDB_LANGUAGE", "zh-CN")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


def _episode(library_id: int, item_id: int, episode: int, audio: list[dict]) -> LibraryFile:
    return LibraryFile(
        library_id=library_id,
        media_item_id=item_id,
        season_number=1,
        episode_number=episode,
        file_path=f"/tv/{item_id}/S01E{episode:02d}.mkv",
        size_bytes=1,
        source=FileSource.SCANNED,
        state=FileState.IN_PLACE,
        audio_streams=audio,
        subtitle_streams=[_sub("eng"), _sub("chi")],
    )


def _state(item_id: int, episode: int, played_at: datetime, **tracks) -> PlaybackState:
    return PlaybackState(
        member_id=1,
        media_item_id=item_id,
        season_number=1,
        episode_number=episode,
        last_played_at=played_at,
        **tracks,
    )


async def test_latest_episode_choice_carries_to_a_new_episode(db):
    """第 1、2 集都换过轨，第 3 集没看过：按最近看的第 2 集换算；本集自己有记忆时以本集为准。

    库语言是中文（TMDB_LANGUAGE 默认 zh-CN）：中文字幕本来就是默认挑选，用户换成英文字幕才算选择。
    """
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=["/tv"]
        )
        show = MediaItem(kind="tv", tmdb_id=301, title="追剧", original_title="S")
        session.add(show)
        await session.flush()
        assert library.id and show.id
        plain = [_audio("eng", default=True), _audio("chi"), _audio("jpn")]
        session.add_all(
            [
                _episode(library.id, show.id, 1, plain),
                _episode(library.id, show.id, 2, plain),
                # 第 3 集多一条评论音轨，语言轨都往后挪了一位
                _episode(library.id, show.id, 3, [_audio("eng", default=True), *plain]),
            ]
        )
        await session.commit()

        states = {
            (show.id, 1, 1): _state(show.id, 1, datetime(2026, 9, 1), audio_track="embedded:2"),
            (show.id, 1, 2): _state(
                show.id,
                2,
                datetime(2026, 9, 2),
                audio_track="embedded:1",
                subtitle_track="embedded:0",
            ),
        }
        assert await series_track_memory(session, states, (show.id, 1, 3)) == (
            "embedded:2",
            "embedded:0",
        )

        # 本集已经记着自己的音轨：只补缺的字幕
        states[(show.id, 1, 3)] = _state(show.id, 3, datetime(2026, 9, 3),
                                         audio_track="embedded:0")
        assert await series_track_memory(session, states, (show.id, 1, 3)) == (
            None,
            "embedded:0",
        )


async def test_what_counts_as_the_default_follows_the_track_policy(db):
    """英文剧、国语配音标了默认：默认挑选是英语原声。用户在上一集换成国语（恰好是容器默认轨），
    是用户的选择、要沿用；选了英语原声就是默认挑选，不沿用。"""
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=["/tv"]
        )
        show = MediaItem(kind="tv", tmdb_id=302, title="英剧", original_title="Show")
        session.add(show)
        await session.flush()
        assert library.id and show.id
        session.add(MediaMetadata(media_item_id=show.id, original_language="en"))
        dubbed = [_audio("chi", default=True), _audio("eng")]
        session.add_all([_episode(library.id, show.id, n, dubbed) for n in (1, 2)])
        await session.commit()

        mandarin = {(show.id, 1, 1): _state(show.id, 1, datetime(2026, 9, 1),
                                            audio_track="embedded:0")}
        assert await series_track_memory(session, mandarin, (show.id, 1, 2)) == (
            "embedded:0",
            None,
        )
        original = {(show.id, 1, 1): _state(show.id, 1, datetime(2026, 9, 1),
                                            audio_track="embedded:1")}
        assert await series_track_memory(session, original, (show.id, 1, 2)) == (None, None)


async def test_movies_are_never_inherited(db):
    """电影一部一行、天然按片记：自己的记忆由开会话直接套用，这里不找「别的集」。"""
    async with db.session() as session:
        movie = PlaybackState(member_id=1, media_item_id=5, audio_track="embedded:1")
        assert await series_track_memory(session, {(5, 0, 0): movie}, (5, 0, 0)) == (None, None)
