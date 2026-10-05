"""刷片接口（``/reels``）：抽样、翻页、可见性、放法声明、黑场挪位、事件落库。

容器索引与抓帧都替换成假的（解析本身由 tests/playback/test_container_index.py 覆盖，
挑点规则由 test_reels_picker.py 覆盖），这里只锁接口层的行为。
"""

from __future__ import annotations

import asyncio
import itertools
import json
from datetime import date
from functools import partial
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.media_probe import VideoColor
from movieclaw_api.services.reels import feed as reels_feed
from movieclaw_api.services.reels import segments
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaItem,
    MediaItemPerson,
    MediaMetadata,
    Person,
    PlaybackState,
    ReelEvent,
)
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_playback.container_index import ContainerIndex, KeyframePoint, TrackInfo

_ADMIN = {"username": "admin", "password": "Sup3rSecret!"}


def _fake_index(path: str | Path) -> ContainerIndex | None:
    """一小时的片子，2 秒一个关键帧，1800～1900 秒码率翻倍；文件名带 broken 的读不出。"""
    if "broken" in str(path):
        return None
    points, offset = [], 4096
    for i in range(1800):
        t = i * 2.0
        points.append(KeyframePoint(t, offset))
        offset += 2_000_000 * (2 if 1800 <= t < 1900 else 1)
    return ContainerIndex(
        container="matroska",
        file_size=offset + 100_000,
        duration_s=3600.0,
        keyframes=tuple(points),
        tracks=(
            TrackInfo(1, "video", "V_MPEGH/ISO/HEVC", 0),
            TrackInfo(3, "subtitle", "S_HDMV/PGS", 0, "chi"),
        ),
        subtitle_events={3: ()},
        head_end=4096,
        index_range=(offset, offset + 100_000),
    )


_luma_plan: list[int] = []


def _fake_grab(video: Path, dest: Path, seconds: float, color: VideoColor) -> bool:
    """按 _luma_plan 依次出图（没有计划时出亮图）。"""
    dest.parent.mkdir(parents=True, exist_ok=True)
    level = _luma_plan.pop(0) if _luma_plan else 128
    Image.new("RGB", (32, 18), (level, level, level)).save(dest, "JPEG")
    return True


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'reels.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    monkeypatch.setenv("MOVIECLAW_REELS_CACHE_DIR", str(tmp_path / "reels-cache"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    monkeypatch.setattr(segments, "read_container_index", _fake_index)
    monkeypatch.setattr(segments, "grab_frame", _fake_grab)
    monkeypatch.setattr(segments, "video_color_for", lambda *_a, **_k: VideoColor())
    # 抓帧闸是全局共用的模块级信号量，等待过就绑在当时的事件循环上；每个用例一个新的
    monkeypatch.setattr(segments, "FRAME_GRAB_GATE", asyncio.Semaphore(2))
    # 全池补算在后台按条目 id 顺序算，会与断言翻页顺序的用例抢着改缓存；它单独测
    monkeypatch.setattr(reels_feed, "_fill_pool_in_background", lambda **_k: None)
    _luma_plan.clear()

    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        c.post("/api/v1/auth/bootstrap", json=_ADMIN)
        yield c

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


_counter = itertools.count(1)


async def _seed(
    tmp_path: Path,
    *,
    movies: int = 2,
    episodes: int = 3,
    extras: bool = True,
    clips: int = 0,
) -> dict:
    n = next(_counter)
    root = tmp_path / f"media{n}"
    root.mkdir(exist_ok=True)

    def _file(item_id, library_id, season, episode, name, container="mkv") -> LibraryFile:
        path = root / name
        path.write_bytes(b"FAKE" * 64)
        return LibraryFile(
            library_id=library_id,
            media_item_id=item_id,
            season_number=season,
            episode_number=episode,
            file_path=str(path),
            size_bytes=path.stat().st_size,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            duration_seconds=3600,
            container=container,
            resolution="1080p",
            subtitle_streams=[{"codec": "hdmv_pgs_subtitle", "language": "chi", "title": "简体"}],
            audio_streams=[
                {"codec": "truehd", "language": "eng", "default": True},
                {"codec": "ac3", "language": "eng"},
            ],
        )

    async with get_database().session() as session:
        repo = LibraryRepository(session)
        movie_lib = await repo.create(name=f"电影库{n}", kind="movie", root_paths=[str(root)])
        tv_lib = await repo.create(name=f"剧集库{n}", kind="tv", root_paths=[str(root)])
        other_lib = await repo.create(
            name=f"其他{n}", kind="video", source="local", root_paths=[str(root)]
        )
        ids = {"movies": [], "movie_library": movie_lib.id, "tv_library": tv_lib.id}
        for i in range(movies):
            item = MediaItem(
                kind="movie", tmdb_id=10_000 * n + i, title=f"电影{i}", original_title=f"M{i}"
            )
            session.add(item)
            await session.flush()
            session.add(_file(item.id, movie_lib.id, 0, 0, f"movie{i}.mkv"))
            ids["movies"].append(item.id)
        if episodes:
            show = MediaItem(kind="tv", tmdb_id=90_000 + n, title="剧", original_title="S")
            session.add(show)
            await session.flush()
            for e in range(1, episodes + 1):
                session.add(_file(show.id, tv_lib.id, 1, e, f"S01E{e:02d}.mkv"))
            ids["show"] = show.id
        if extras:
            disc = MediaItem(kind="movie", tmdb_id=80_000 + n, title="原盘", original_title="D")
            broken = MediaItem(kind="movie", tmdb_id=70_000 + n, title="坏片", original_title="B")
            clip = MediaItem(kind="video", tmdb_id=60_000 + n, title="个人视频", original_title="V")
            session.add_all([disc, broken, clip])
            await session.flush()
            session.add(_file(disc.id, movie_lib.id, 0, 0, "BDMV", container="bluray"))
            session.add(_file(broken.id, movie_lib.id, 0, 0, "broken.mkv"))
            session.add(_file(clip.id, other_lib.id, 0, 0, "clip.mkv"))
            ids.update(disc=disc.id, broken=broken.id, clip=clip.id)
        # 「其他」库里的家庭录像：一个文件一个条目（与 extras 里那条「个人视频」分开，
        # 后者用来锁「默认不推其他」，这里的要能被刷到）
        ids["clips"] = []
        for i in range(clips):
            home = MediaItem(
                kind="video", tmdb_id=50_000 * n + i, title=f"录像{i}", original_title=f"H{i}"
            )
            session.add(home)
            await session.flush()
            session.add(_file(home.id, other_lib.id, 0, 0, f"home{i}.mkv"))
            ids["clips"].append(home.id)
        await session.commit()
        return ids


def seed(client: TestClient, tmp_path: Path, **kwargs) -> dict:
    return client.portal.call(partial(_seed, tmp_path, **kwargs))  # type: ignore[attr-defined]


def feed(client: TestClient, **params) -> dict:
    resp = client.get("/api/v1/reels", params=params)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["success"] is True
    return body["data"]


def test_feed_draws_one_item_per_title_from_movie_and_tv_libraries(client, tmp_path):
    ids = seed(client, tmp_path)
    data = feed(client, limit=10)
    got = {item["title"]["media_item_id"] for item in data["items"]}
    # 原盘（一期不支持）、读不出索引的片、非电影 / 剧集库的条目都不出现；剧只出一条
    assert got == {*ids["movies"], ids["show"]}
    assert data["has_more"] is False
    assert isinstance(data["seed"], int)

    item = next(i for i in data["items"] if i["title"]["media_item_id"] == ids["movies"][0])
    assert item["title"]["kind"] == "movie"
    assert item["id"] == f"rl_{item['segment']['file_id']}_{item['segment']['start_ms']}"
    # 1800～1900 秒码率翻倍：挑中这一段
    assert item["segment"]["method"] == "bitrate"
    assert 1785_000 <= item["segment"]["start_ms"] <= 1860_000
    assert 30_000 <= item["segment"]["end_ms"] - item["segment"]["start_ms"] <= 60_000
    play = item["play"]
    assert play["mode"] == "seek"
    assert play["stream_url"].startswith(
        f"/api/v1/playback/files/{item['segment']['file_id']}/stream?token="
    )
    assert [r["purpose"] for r in play["prefetch"]] == ["head", "index", "start"]
    # 默认音轨是 TrueHD：换同语言的 AC3；中文字幕打开
    assert play["audio_ordinal"] == 1
    assert play["subtitle"]["ordinal"] == 0
    assert "/reels/" in item["cover_url"]

    show = next(i for i in data["items"] if i["title"]["media_item_id"] == ids["show"])
    assert show["title"]["kind"] == "tv"
    assert show["title"]["episode"]["season"] == 1


def test_stream_url_in_feed_serves_the_file(client, tmp_path):
    seed(client, tmp_path, episodes=0, extras=False, movies=1)
    item = feed(client)["items"][0]
    resp = client.get(item["play"]["stream_url"], headers={"Range": "bytes=0-3"})
    assert resp.status_code == 206
    assert resp.content == b"FAKE"


def test_same_seed_is_stable_and_pages_do_not_repeat(client, tmp_path):
    ids = seed(client, tmp_path, movies=23, episodes=12, extras=False)
    first = feed(client, limit=10)
    again = feed(client, limit=10, seed=first["seed"])
    assert [i["id"] for i in again["items"]] == [i["id"] for i in first["items"]]

    seen: list[int] = [i["title"]["media_item_id"] for i in first["items"]]
    offset, has_more = first["next_offset"], first["has_more"]
    while has_more:
        page = feed(client, limit=10, seed=first["seed"], offset=offset)
        seen += [i["title"]["media_item_id"] for i in page["items"]]
        offset, has_more = page["next_offset"], page["has_more"]
    assert len(seen) == len(set(seen)) == 24  # 23 部电影 + 1 部剧（12 集只占一个名额）
    assert set(seen) == {*ids["movies"], ids["show"]}


def test_fill_pool_computes_one_file_per_title(client, tmp_path):
    ids = seed(client, tmp_path, movies=2, episodes=3, extras=False)
    client.portal.call(reels_feed._fill_pool)  # type: ignore[attr-defined]

    async def files():
        async with get_database().session() as session:
            rows = (await session.execute(select(LibraryFile))).scalars().all()
            return {(f.media_item_id, f.episode_number): f.id for f in rows}

    by_unit = client.portal.call(files)  # type: ignore[attr-defined]
    cached = {int(p.stem) for p in (tmp_path / "reels-cache").glob("*.json")}
    # 电影各一个；剧只算第二集（刷片固定放的那一集），别的集不白算
    expected = {by_unit[(m, 0)] for m in ids["movies"]} | {by_unit[(ids["show"], 2)]}
    assert cached == expected


def test_text_subtitle_comes_with_a_clip_window(client, tmp_path, monkeypatch):
    ids = seed(client, tmp_path, movies=1, episodes=0, extras=False)
    # 《我的大叔》式片源：整条 ASS 同时标了默认和强制，另有一条 SRT
    streams = [
        {
            "codec": "ass",
            "language": "chi",
            "title": "简体中文-ASS",
            "default": True,
            "forced": True,
        },
        {"codec": "subrip", "language": "chi", "title": "简体中文-SRT"},
    ]

    async def set_streams():
        async with get_database().session() as session:
            row = (await session.execute(select(LibraryFile))).scalars().one()
            row.subtitle_streams = streams
            await session.commit()

    client.portal.call(set_streams)  # type: ignore[attr-defined]
    item = feed(client)["items"][0]
    assert item["title"]["media_item_id"] == ids["movies"][0]
    subtitle = item["play"]["subtitle"]
    # 默认 + 强制的整条 ASS 不再被当成「只翻标牌的强制字幕」扣分
    assert subtitle["ordinal"] == 0 and subtitle["format"] == "ass"
    start, end = item["segment"]["start_ms"], item["segment"]["end_ms"]
    url = subtitle["url"]
    assert url.startswith(f"/api/v1/playback/files/{item['segment']['file_id']}/subtitles?")
    assert "track=embedded:0" in url and "token=" in url
    assert f"start_ms={max(0, start - 10_000)}" in url and f"end_ms={end + 5_000}" in url

    # 这个地址真能取到字幕：走窗口抽取（这里替换成现成的产物），也能按 vtt 给叠加层
    from movieclaw_api.api.routes import playback as playback_routes
    from movieclaw_playback.subtitles import SubtitleRef

    product = tmp_path / "window.srt"
    product.write_text("1\n00:30:01,000 --> 00:30:02,000\n窗口里这句\n", encoding="utf-8")
    calls = []

    async def fake_window(file, index, start_ms, end_ms):
        calls.append((index, start_ms, end_ms))
        return SubtitleRef(path=product, format="srt")

    monkeypatch.setattr(playback_routes, "extract_embedded_subtitle_window_async", fake_window)
    monkeypatch.setattr(playback_routes, "window_format", lambda file, index: "srt")
    resp = client.get(url)
    assert resp.status_code == 200, resp.text
    assert "窗口里这句" in resp.text
    assert calls == [(0, max(0, start - 10_000), end + 5_000)]
    vtt = client.get(url + "&format=vtt")
    assert vtt.status_code == 200 and vtt.text.startswith("WEBVTT")


def test_graphic_subtitle_has_no_clip_window(client, tmp_path):
    seed(client, tmp_path, movies=1, episodes=0, extras=False)  # 种子里的字幕是 PGS
    subtitle = feed(client)["items"][0]["play"]["subtitle"]
    assert subtitle["codec"] == "hdmv_pgs_subtitle"
    assert subtitle["url"] is None and subtitle["format"] is None


def test_client_without_seek_mode_gets_nothing(client, tmp_path):
    seed(client, tmp_path)
    assert feed(client, modes="clip")["items"] == []


def test_dark_first_frame_moves_start_to_a_later_keyframe(client, tmp_path):
    seed(client, tmp_path, movies=1, episodes=0, extras=False)
    _luma_plan.extend([2, 3, 140])  # 前两次抓到黑场，第三次亮
    item = feed(client)["items"][0]
    start_ms = item["segment"]["start_ms"]
    record = json.loads(next((tmp_path / "reels-cache").glob("*.json")).read_text())
    assert record["segment"]["start_ms"] == start_ms
    covers = list((tmp_path / "metadata" / "images").rglob("*.jpg"))
    # 黑场那两张不留：只剩最终起点的封面
    assert [c.name for c in covers] == [f"{start_ms:010d}.jpg"]
    # 至少挪了两次、每次至少 2 秒
    assert start_ms >= 1785_000 + 4_000


def test_unsupported_file_is_remembered(client, tmp_path):
    ids = seed(client, tmp_path, movies=0, episodes=0)
    assert feed(client)["items"] == []
    records = [json.loads(p.read_text()) for p in (tmp_path / "reels-cache").glob("*.json")]
    assert any("unsupported" in r for r in records)
    assert ids["broken"]


def test_member_only_sees_visible_libraries(client, tmp_path):
    ids = seed(client, tmp_path)
    created = client.post(
        "/api/v1/members",
        json={"username": "family", "password": "family-pass-1", "nickname": "家人"},
    )
    assert created.status_code == 200, created.text
    updated = client.put(
        f"/api/v1/members/{created.json()['data']['id']}",
        json={"all_libraries": False, "library_ids": [ids["tv_library"]]},
    )
    assert updated.status_code == 200, updated.text
    client.post("/api/v1/auth/logout")
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "family", "password": "family-pass-1"}
        ).status_code
        == 200
    )
    got = {i["title"]["media_item_id"] for i in feed(client)["items"]}
    assert got == {ids["show"]}


def test_events_are_recorded_without_touching_watch_history(client, tmp_path):
    seed(client, tmp_path, movies=1, episodes=0, extras=False)
    item = feed(client)["items"][0]
    base = {
        "reel_id": item["id"],
        "media_item_id": item["title"]["media_item_id"],
        "file_id": item["segment"]["file_id"],
    }
    resp = client.post(
        "/api/v1/reels/events",
        json={
            "events": [
                {**base, "kind": "impression"},
                {**base, "kind": "first_frame", "wait_ms": 420},
                {
                    **base,
                    "kind": "fullscreen",
                    "watched_ms": 5_000,
                    "position_ms": item["segment"]["start_ms"] + 5_000,
                },
                {
                    **base,
                    "kind": "detail",
                    "watched_ms": 8_000,
                    "position_ms": item["segment"]["start_ms"] + 8_000,
                },
                {
                    **base,
                    "kind": "leave",
                    "watched_ms": 12_000,
                    "position_ms": item["segment"]["start_ms"] + 12_000,
                },
            ]
        },
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"] == {"accepted": 5}

    bad = client.post("/api/v1/reels/events", json={"events": [{**base, "kind": "hack"}]})
    assert bad.status_code == 422

    async def rows():
        async with get_database().session() as session:
            events = (await session.execute(select(ReelEvent))).scalars().all()
            states = (await session.execute(select(PlaybackState))).scalars().all()
            return [(e.kind, e.member_id, e.wait_ms, e.watched_ms) for e in events], len(states)

    events, states = client.portal.call(rows)  # type: ignore[attr-defined]
    assert events == [
        ("impression", 0, None, None),
        ("first_frame", 0, 420, None),
        ("fullscreen", 0, None, 5_000),
        ("detail", 0, None, 8_000),
        ("leave", 0, None, 12_000),
    ]
    assert states == 0


async def _set_metadata(genres: dict[int, list[str]]) -> None:
    async with get_database().session() as session:
        for item_id, names in genres.items():
            session.add(
                MediaMetadata(
                    media_item_id=item_id,
                    genres=names,
                    overview=f"条目 {item_id} 的简介",
                    runtime_minutes=101,
                )
            )
        await session.commit()


async def _set_profiles(profiles: dict[int, dict]) -> None:
    async with get_database().session() as session:
        for item_id, fields in profiles.items():
            session.add(MediaMetadata(media_item_id=item_id, **fields))
        await session.commit()


def _profile(genre_ids, country, year, rating, runtime) -> dict:
    return {
        "genre_ids": genre_ids,
        "origin_countries": [country],
        "release_date": date(year, 5, 1),
        "vote_average": rating,
        "runtime_minutes": runtime,
    }


def _facet(facets: dict, dim: str) -> dict[str, int]:
    return {v["value"]: v["count"] for v in facets[dim]}


def test_filters_match_library_semantics_and_facets_skip_own_dimension(client, tmp_path):
    ids = seed(client, tmp_path, movies=3, episodes=2, extras=False)
    a, b, c = ids["movies"]
    show = ids["show"]
    client.portal.call(  # type: ignore[attr-defined]
        partial(
            _set_profiles,
            {
                a: _profile([18, 10749], "CN", 2010, 8.5, 101),
                b: _profile([28], "US", 1995, 6.5, 130),
                c: _profile([18], "JP", 2021, 7.2, 85),
                show: _profile([18], "KR", 2016, 9.1, 50),
            },
        )
    )

    def facets(**params) -> dict:
        resp = client.get("/api/v1/reels/facets", params=params)
        assert resp.status_code == 200, resp.text
        return resp.json()["data"]

    def got(**params) -> set[int]:
        return {i["title"]["media_item_id"] for i in feed(client, **params)["items"]}

    whole = facets()
    assert whole["total"] == 4
    assert _facet(whole, "kinds") == {"movie": 3, "tv": 1}
    assert whole["genres"][0] == {"value": "18", "label": "剧情", "count": 3}
    assert _facet(whole, "genres") == {"18": 3, "28": 1, "10749": 1}
    assert _facet(whole, "countries") == {"CN": 1, "US": 1, "JP": 1, "KR": 1}
    assert _facet(whole, "decades") == {
        "2020s": 1,
        "2010s": 2,
        "2000s": 0,
        "1990s": 1,
        "earlier": 0,
    }
    assert _facet(whole, "ratings") == {"9": 1, "8": 2, "7": 3, "6": 4}
    assert _facet(whole, "runtimes") == {"lte60": 1, "60to90": 1, "90to120": 1, "gt120": 1}
    assert _facet(whole, "watch") == {"unwatched": 4}

    # 勾了「剧情」：类型这一维照旧（排除自身条件），其他维度跟着收窄
    drama = facets(g="18")
    assert drama["total"] == 3
    assert _facet(drama, "genres") == {"18": 3, "28": 1, "10749": 1}
    assert _facet(drama, "kinds") == {"movie": 2, "tv": 1}
    assert got(g="18") == {a, c, show}
    assert got(g="18,28", kind="movie") == {a, b, c}  # 维内 OR
    assert got(g="18", kind="movie", rating_gte=8) == {a}  # 维间 AND
    assert got(kind="tv") == {show}
    assert got(d="2010s,1990s", rt="gt120") == {b}

    marked = client.post("/api/v1/playback/marks", json={"media_item_id": a, "played": True})
    assert marked.status_code == 200, marked.text
    assert got(w="unwatched") == {b, c, show}
    assert _facet(facets(), "watch") == {"unwatched": 3}
    assert feed(client, g="99")["items"] == []  # 没有纪录片


# --- 「其他」库：独立的池，不混进默认 ---------------------------------------------------


def _facets(client: TestClient, **params) -> dict:
    resp = client.get("/api/v1/reels/facets", params=params)
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def test_other_libraries_are_a_separate_pool_not_mixed_into_default(client, tmp_path):
    ids = seed(client, tmp_path, movies=2, episodes=2, extras=False, clips=3)

    default = {i["title"]["media_item_id"] for i in feed(client, limit=10)["items"]}
    assert default == {*ids["movies"], ids["show"]}  # 默认只有电影 + 剧集，一部录像都没有

    other = feed(client, kind="video", limit=10)
    assert {i["title"]["media_item_id"] for i in other["items"]} == set(ids["clips"])
    item = other["items"][0]
    assert item["title"]["kind"] == "video"
    assert item["title"]["episode"] is None
    assert item["title"]["directors"] == []  # 没有 TMDB 档案：没有导演、没有类型
    assert item["title"]["genres"] == []
    assert item["play"]["mode"] == "seek"
    assert item["segment"]["end_ms"] > item["segment"]["start_ms"]

    # 选「电影」时也不带上录像
    got = {i["title"]["media_item_id"] for i in feed(client, kind="movie")["items"]}
    assert got == set(ids["movies"])


def test_other_pool_ignores_tmdb_filters_but_keeps_watch_state(client, tmp_path):
    ids = seed(client, tmp_path, movies=1, episodes=0, extras=False, clips=3)
    first, second, third = ids["clips"]

    def got(**params) -> set[int]:
        return {i["title"]["media_item_id"] for i in feed(client, kind="video", **params)["items"]}

    # 类型 / 评分这些来自 TMDB 档案，录像没有——带着它们也不该刷成空的
    assert got(g="18", rating_gte=8, d="2010s") == {first, second, third}

    marked = client.post("/api/v1/playback/marks", json={"media_item_id": first, "played": True})
    assert marked.status_code == 200, marked.text
    assert got(w="unwatched") == {second, third}  # 观看状态照常生效
    assert got(w="unwatched", g="18") == {second, third}


def test_facets_offer_other_as_a_switch_with_its_own_counts(client, tmp_path):
    ids = seed(client, tmp_path, movies=2, episodes=2, extras=False, clips=3)
    client.portal.call(  # type: ignore[attr-defined]
        partial(_set_profiles, {m: _profile([18], "CN", 2010, 8.0, 100) for m in ids["movies"]})
    )

    whole = _facets(client)
    assert whole["filterable"] is True
    assert whole["total"] == 3  # 默认池不含录像
    assert _facet(whole, "kinds") == {"movie": 2, "tv": 1, "video": 3}

    # 勾了「动作」：电影 / 剧集都被筛空，「其他」照旧算它自己的数——点它会清掉别的条件，
    # 数成 0 置灰就点不进去了
    action = _facets(client, g="28")
    assert _facet(action, "kinds") == {"movie": 0, "tv": 0, "video": 3}

    other = _facets(client, kind="video")
    assert other["filterable"] is False  # App 据此收起类型 / 年代 / 地区 / 评分 / 片长
    assert other["total"] == 3
    assert other["genres"] == other["countries"] == other["decades"] == []
    assert other["ratings"] == other["runtimes"] == []
    assert _facet(other, "watch") == {"unwatched": 3}  # 只剩观看状态


def test_no_other_libraries_means_no_other_choice(client, tmp_path):
    seed(client, tmp_path, movies=2, episodes=1, extras=False)  # 有「其他」库但里面没有文件
    assert _facet(_facets(client), "kinds") == {"movie": 2, "tv": 1}


def test_only_other_libraries_falls_back_so_all_is_not_empty(client, tmp_path):
    # 电影库、剧集库建了但一个文件都没有——「全部」也该是这些录像，不是空的
    ids = seed(client, tmp_path, movies=0, episodes=0, extras=False, clips=2)
    got = {i["title"]["media_item_id"] for i in feed(client, limit=10)["items"]}
    assert got == set(ids["clips"])

    whole = _facets(client)
    assert whole["total"] == 2
    assert whole["filterable"] is False
    assert whole["kinds"] == []  # 没有可切换的类型，App 不画这一行
    assert _facet(whole, "watch") == {"unwatched": 2}

    marked = client.post(
        "/api/v1/playback/marks", json={"media_item_id": ids["clips"][0], "played": True}
    )
    assert marked.status_code == 200, marked.text
    unwatched = {i["title"]["media_item_id"] for i in feed(client, w="unwatched")["items"]}
    assert unwatched == {ids["clips"][1]}


def test_fallback_needs_no_film_files_at_all_not_just_an_empty_filter_result(client, tmp_path):
    # 有电影：筛选刷空了就是空，不能偷偷改推录像
    seed(client, tmp_path, movies=1, episodes=0, extras=False, clips=2)
    assert feed(client, g="99")["items"] == []
    assert _facets(client, g="99")["total"] == 0


def test_fill_pool_for_other_libraries_is_separate(client, tmp_path):
    ids = seed(client, tmp_path, movies=1, episodes=0, extras=False, clips=2)
    client.portal.call(partial(reels_feed._fill_pool, video=True))  # type: ignore[attr-defined]

    async def files():
        async with get_database().session() as session:
            rows = (await session.execute(select(LibraryFile))).scalars().all()
            return {f.media_item_id: f.id for f in rows}

    by_item = client.portal.call(files)  # type: ignore[attr-defined]
    cached = {int(p.stem) for p in (tmp_path / "reels-cache").glob("*.json")}
    # 只补「其他」库的录像，电影不在这一轮里
    assert cached == {by_item[c] for c in ids["clips"]}


def test_feed_carries_marks_overview_and_runtime(client, tmp_path):
    ids = seed(client, tmp_path, movies=1, episodes=1, extras=False)
    movie = ids["movies"][0]
    client.portal.call(partial(_set_metadata, {movie: ["剧情"]}))  # type: ignore[attr-defined]
    marks = client.post("/api/v1/playback/marks", json={"media_item_id": movie, "favorite": True})
    assert marks.status_code == 200, marks.text
    marks = client.post(
        "/api/v1/playback/marks",
        json={
            "media_item_id": ids["show"],
            "season_number": 1,
            "episode_number": 1,
            "played": True,
        },
    )
    assert marks.status_code == 200, marks.text

    items = {i["title"]["media_item_id"]: i["title"] for i in feed(client)["items"]}
    assert items[movie]["favorite"] is True
    assert items[movie]["played"] is False
    assert items[movie]["overview"] == f"条目 {movie} 的简介"
    assert items[movie]["runtime_minutes"] == 101
    assert items[movie]["library_id"] == ids["movie_library"]
    show = items[ids["show"]]
    assert show["favorite"] is False
    assert show["played"] is True  # 这一集看过了
    assert show["runtime_minutes"] == 60  # 没有分集档案：按文件时长


async def _set_positions(rows: list[tuple[int, int, int, int, bool]]) -> None:
    async with get_database().session() as session:
        for item_id, season, episode, position_ms, played in rows:
            session.add(
                PlaybackState(
                    media_item_id=item_id,
                    season_number=season,
                    episode_number=episode,
                    position_ms=position_ms,
                    played=played,
                )
            )
        await session.commit()


def test_feed_carries_progress_for_half_watched_only(client, tmp_path):
    ids = seed(client, tmp_path, movies=2, episodes=1, extras=False)
    halfway, untouched = ids["movies"]
    client.portal.call(  # type: ignore[attr-defined]
        partial(
            _set_positions,
            [
                (halfway, 0, 0, 1_440_000, False),  # 文件 3600 秒，看到 24 分钟 = 40%
                (ids["show"], 1, 1, 1_800_000, True),  # 看完了：不画进度，按已看
            ],
        )
    )

    items = {i["title"]["media_item_id"]: i["title"] for i in feed(client)["items"]}
    assert items[halfway]["progress_percent"] == 40
    assert items[halfway]["played"] is False
    assert items[untouched]["progress_percent"] is None
    assert items[ids["show"]]["progress_percent"] is None
    assert items[ids["show"]]["played"] is True


async def _set_directors(movie_id: int, fallback_id: int) -> None:
    async with get_database().session() as session:
        person = Person(tmdb_person_id=4321, name="姜文", profile_path="/jiangwen.jpg")
        session.add(person)
        await session.flush()
        session.add(
            MediaItemPerson(
                media_item_id=movie_id, person_id=person.id, department="director", credit_order=0
            )
        )
        session.add(MediaMetadata(media_item_id=movie_id, directors=["不该用到的名字"]))
        session.add(MediaMetadata(media_item_id=fallback_id, directors=["甲", "乙", "丙"]))
        await session.commit()


def test_feed_carries_directors_and_film_duration(client, tmp_path):
    ids = seed(client, tmp_path, movies=2, episodes=0, extras=False)
    structured, fallback = ids["movies"]
    client.portal.call(partial(_set_directors, structured, fallback))  # type: ignore[attr-defined]
    items = {i["title"]["media_item_id"]: i for i in feed(client)["items"]}
    # 关系表里有的用关系表（带头像与人物 id）
    [director] = items[structured]["title"]["directors"]
    assert director["name"] == "姜文"
    assert director["tmdb_person_id"] == 4321
    assert director["avatar_url"].endswith("/original/jiangwen.jpg")
    # 没有关系行的旧条目退回档案里的姓名，最多两位
    assert [d["name"] for d in items[fallback]["title"]["directors"]] == ["甲", "乙"]
    assert items[fallback]["title"]["directors"][0]["tmdb_person_id"] is None
    # 原片总长（台账探测时长）
    assert items[structured]["segment"]["duration_ms"] == 3600 * 1000


# --- 大图预告（GET /reels/preview/{id}） ---------------------------------------------


def preview(client: TestClient, item_id: int, expect: int = 200, **params) -> dict | None:
    resp = client.get(f"/api/v1/reels/preview/{item_id}", params=params)
    assert resp.status_code == expect, resp.text
    return resp.json()["data"] if expect == 200 else None


def test_preview_highlight_is_the_reel_segment_without_subtitles(client, tmp_path):
    ids = seed(client, tmp_path, movies=1, episodes=0, extras=False)
    item = preview(client, ids["movies"][0])
    assert item is not None
    assert item["segment"]["method"] == "bitrate"
    assert 1785_000 <= item["segment"]["start_ms"] <= 1860_000
    assert item["play"]["stream_url"].startswith("/api/v1/playback/files/")
    assert [r["purpose"] for r in item["play"]["prefetch"]] == ["head", "index", "start"]
    # 大图左下角压着片名与简介：预告不开字幕
    assert item["play"]["subtitle"] is None
    # 与刷片同一份挑点（读缓存）
    same = next(i for i in feed(client)["items"] if i["title"]["media_item_id"] == ids["movies"][0])
    assert same["segment"] == item["segment"]


def test_preview_resume_plays_the_30_seconds_before_the_resume_point(client, tmp_path):
    ids = seed(client, tmp_path, movies=1, episodes=0, extras=False)
    movie = ids["movies"][0]
    client.portal.call(partial(_set_positions, [(movie, 0, 0, 1_441_000, False)]))  # type: ignore[attr-defined]
    item = preview(client, movie, source="resume")
    assert item is not None
    seg = item["segment"]
    assert seg["method"] == "resume"
    # 1441 - 30 = 1411 秒，往前落到 1410 秒的关键帧（假索引 2 秒一个）；放到停下的地方
    assert seg["start_ms"] == 1_410_000
    assert seg["end_ms"] == 1_441_000
    assert [r["purpose"] for r in item["play"]["prefetch"]] == ["head", "index", "start"]
    assert item["play"]["subtitle"] is None
    assert item["id"] == f"rl_{seg['file_id']}_1410000"


def test_preview_resume_near_the_start_begins_at_zero(client, tmp_path):
    ids = seed(client, tmp_path, movies=1, episodes=0, extras=False)
    movie = ids["movies"][0]
    client.portal.call(partial(_set_positions, [(movie, 0, 0, 20_000, False)]))  # type: ignore[attr-defined]
    seg = preview(client, movie, source="resume")["segment"]  # type: ignore[index]
    assert (seg["method"], seg["start_ms"], seg["end_ms"]) == ("resume", 0, 20_000)


@pytest.mark.parametrize(
    "state",
    [
        None,  # 没看过
        (5_000, False),  # 只看了几秒：回忆刚淡入就放完
        (1_441_000, True),  # 看完了
    ],
)
def test_preview_resume_without_a_usable_resume_point_falls_back_to_highlight(
    client, tmp_path, state
):
    ids = seed(client, tmp_path, movies=1, episodes=0, extras=False)
    movie = ids["movies"][0]
    if state:
        client.portal.call(partial(_set_positions, [(movie, 0, 0, *state)]))  # type: ignore[attr-defined]
    item = preview(client, movie, source="resume")
    assert item is not None
    assert item["segment"]["method"] == "bitrate"


def test_preview_for_a_series_resumes_that_episode_or_falls_back_to_episode_two(client, tmp_path):
    ids = seed(client, tmp_path, movies=0, episodes=3, extras=False)
    show = ids["show"]
    client.portal.call(partial(_set_positions, [(show, 1, 3, 600_000, False)]))  # type: ignore[attr-defined]

    recap = preview(client, show, source="resume", season=1, episode=3)
    assert recap["segment"]["method"] == "resume"  # type: ignore[index]
    assert recap["title"]["episode"]["episode"] == 3  # type: ignore[index]
    assert (recap["segment"]["start_ms"], recap["segment"]["end_ms"]) == (570_000, 600_000)  # type: ignore[index]

    # 下一集还没开始看：退回刷片的挑法，固定第二集
    upcoming = preview(client, show, source="resume", season=1, episode=1)
    assert upcoming["segment"]["method"] != "resume"  # type: ignore[index]
    assert upcoming["title"]["episode"]["episode"] == 2  # type: ignore[index]
    assert preview(client, show)["title"]["episode"]["episode"] == 2  # type: ignore[index]


def test_preview_is_null_when_nothing_can_be_played(client, tmp_path):
    ids = seed(client, tmp_path, movies=0, episodes=0)
    # 原盘（一期不支持的容器）与读不出索引的片：保持剧照
    assert preview(client, ids["disc"]) is None
    assert preview(client, ids["broken"]) is None
    client.portal.call(partial(_set_positions, [(ids["broken"], 0, 0, 600_000, False)]))  # type: ignore[attr-defined]
    assert preview(client, ids["broken"], source="resume") is None


def test_preview_respects_member_visibility(client, tmp_path):
    ids = seed(client, tmp_path, movies=1)
    created = client.post(
        "/api/v1/members",
        json={"username": "family", "password": "family-pass-1", "nickname": "家人"},
    )
    client.put(
        f"/api/v1/members/{created.json()['data']['id']}",
        json={"all_libraries": False, "library_ids": [ids["tv_library"]]},
    )
    client.post("/api/v1/auth/logout")
    client.post("/api/v1/auth/login", json={"username": "family", "password": "family-pass-1"})
    preview(client, ids["movies"][0], expect=404)
    assert preview(client, ids["show"]) is not None
