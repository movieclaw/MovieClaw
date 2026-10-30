"""剧集详情页播出日历（issue #547）：分集接口附带的 air_schedule。

覆盖：在播且已订阅（缺集 / 下载中 / 预计入库 / 预测不稳 / 海外首播地）、
本季已播完不给日历、未订阅与缺日期时的口径，以及在播剧无订阅的刷新分档。
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import httpx
import pytest_asyncio

from movieclaw_api.api.routes.libraries import list_item_episodes
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.media_scrape import next_refresh_delay
from movieclaw_api.services.subscription.matching import publish_calendar_date
from movieclaw_api.settings.store import init_setting_store, reset_setting_store
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    LibraryFile,
    MediaEpisode,
    MediaItem,
    MediaMetadata,
    RuleSet,
    Subscription,
    WantedItem,
    WantedStatus,
    utcnow,
)
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_media.tmdb import TmdbClient

_ADMIN = Principal(kind="admin", name="tester")


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'air.db'}")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path / "data"))
    get_settings.cache_clear()
    reset_setting_store()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    init_setting_store(get_database())
    yield get_database()
    reset_setting_store()
    await dispose_db()
    get_settings.cache_clear()


async def _seed_show(
    db,
    tmp_path,
    air_offsets: dict[int, int | None],
    owned: set[int],
    *,
    origin: list[str] | None = None,
) -> tuple[int, int]:
    """一部单季剧：``air_offsets`` 为 集号 → 相对今天的天数（None=没日期）。"""
    today = publish_calendar_date(utcnow())
    root = tmp_path / "tv"
    root.mkdir(exist_ok=True)
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=[str(root)]
        )
        item = MediaItem(
            kind="tv",
            tmdb_id=777,
            title="长街夜行",
            original_title="Night Street",
            status="Returning Series",
        )
        session.add(item)
        await session.flush()
        session.add(MediaMetadata(media_item_id=item.id, origin_countries=origin or ["CN"]))
        for number, offset in air_offsets.items():
            session.add(
                MediaEpisode(
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=number,
                    air_date=None if offset is None else today + timedelta(days=offset),
                )
            )
        for number in owned:
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=number,
                    file_path=str(root / f"S01E{number:02d}.mkv"),
                    size_bytes=1,
                    source="scanned",
                )
            )
        await session.commit()
        return library.id, item.id


async def _subscribe(db, item_id: int, wanted: list[WantedItem]) -> int:
    async with db.session() as session:
        rule_set = RuleSet(name="默认", spec={})
        session.add(rule_set)
        await session.flush()
        sub = Subscription(media_item_id=item_id, kind="tv", rule_set_id=rule_set.id)
        session.add(sub)
        await session.flush()
        for row in wanted:
            row.subscription_id = sub.id
            row.media_item_id = item_id
            row.season_number = 1
            session.add(row)
        await session.commit()
        return sub.id


async def _episodes(db, library_id: int, item_id: int):
    async with db.session() as session:
        return (await list_item_episodes(library_id, item_id, 1, _ADMIN, session)).data


def _iso(value: datetime) -> str:
    return value.replace(tzinfo=UTC).isoformat()


async def test_airing_subscribed_season_reports_gaps_and_arrivals(db, tmp_path) -> None:
    """在播 + 已订阅：已播没入库的进缺集；在途的报下载中/整理中；今天及以后的
    报预计入库时刻（站点预测 + 投递→入库耗时），预测不稳的不报时刻。"""
    today = publish_calendar_date(utcnow())
    library_id, item_id = await _seed_show(
        db,
        tmp_path,
        {1: -8, 2: -8, 3: -7, 4: -1, 5: -1, 6: 0, 7: 1, 8: 7},
        owned={1, 2},
        origin=["US"],
    )
    predicted = utcnow() + timedelta(hours=2)
    sub_id = await _subscribe(
        db,
        item_id,
        [
            WantedItem(episode_number=3, status=WantedStatus.WANTED, air_date=today - timedelta(7)),
            WantedItem(episode_number=4, status=WantedStatus.GRABBED, info_hash="h4"),
            WantedItem(episode_number=5, status=WantedStatus.DOWNLOADED, info_hash="h5"),
            WantedItem(
                episode_number=6,
                status=WantedStatus.WANTED,
                air_date=today,
                release_forecast={"predicted_at": _iso(predicted), "confidence": "stable"},
            ),
            WantedItem(
                episode_number=7,
                status=WantedStatus.WANTED,
                air_date=today + timedelta(1),
                release_forecast={"predicted_at": _iso(predicted), "confidence": "volatile"},
            ),
            WantedItem(episode_number=8, status=WantedStatus.WANTED, air_date=today + timedelta(7)),
        ],
    )

    schedule = (await _episodes(db, library_id, item_id)).air_schedule
    assert schedule is not None
    assert schedule.today == today
    assert schedule.subscription_id == sub_id
    assert schedule.missing_episodes == [3]
    assert schedule.region == "US"  # 海外首播：日期是当地日期
    assert schedule.last_air_date == today + timedelta(days=7)
    recent = {(today + timedelta(days=d)).weekday() for d in (-8, -7, -1, 0, 1, 7)}
    assert schedule.weekdays == sorted(recent)

    by_number = {a.episode_number: a for a in schedule.arrivals}
    assert by_number[4].stage == "downloading" and by_number[4].expected_at is None
    assert by_number[5].stage == "organizing"
    assert by_number[6].stage == "waiting"
    # 没有入库历史时按默认 60 分钟的投递→入库耗时
    expected = by_number[6].expected_at
    assert expected is not None
    assert abs(expected.replace(tzinfo=None) - (predicted + timedelta(minutes=60))) < timedelta(
        seconds=1
    )
    assert by_number[7].stage == "waiting" and by_number[7].expected_at is None  # 预测不稳
    assert by_number[8].expected_at is None  # 还没有预测
    assert set(by_number) == {4, 5, 6, 7, 8}


async def test_season_fully_aired_has_no_schedule(db, tmp_path) -> None:
    """本季最后一集已经播过（已完结或季间空档）：不给日历，客户端整块不显示。"""
    library_id, item_id = await _seed_show(db, tmp_path, {1: -14, 2: -7, 3: -1}, owned={1})
    view = await _episodes(db, library_id, item_id)
    assert view.air_schedule is None
    assert [e.owned for e in view.episodes] == [True, False, False]


async def test_unsubscribed_season_without_full_dates(db, tmp_path) -> None:
    """未订阅：没有缺集与入库预告（用户没打算追）；有集没日期时不说哪天完结；
    国内首播不标地区。"""
    library_id, item_id = await _seed_show(
        db, tmp_path, {1: -2, 2: 0, 3: 1, 4: None}, owned={1}, origin=["CN"]
    )
    schedule = (await _episodes(db, library_id, item_id)).air_schedule
    assert schedule is not None
    assert schedule.subscription_id is None
    assert schedule.missing_episodes == [] and schedule.arrivals == []
    assert schedule.last_air_date is None
    assert schedule.region is None


def test_airing_show_without_subscription_refreshes_daily() -> None:
    """详情页日历要跟得上改档：在播剧没订阅也每天刷；季间空档没完结的 3 天一刷，
    完结/取消的仍 30 天。"""
    item = MediaItem(kind="tv", tmdb_id=1, title="x", status="Returning Series")
    assert next_refresh_delay(item, None, airing=True) == timedelta(hours=24)
    assert next_refresh_delay(item, None) == timedelta(days=3)
    for status in ("Ended", "Canceled"):
        item.status = status
        assert next_refresh_delay(item, None) == timedelta(days=30)
    movie = MediaItem(kind="movie", tmdb_id=2, title="y", status="Released")
    assert next_refresh_delay(movie, None) == timedelta(days=30)


def _fake_tmdb(routes: dict) -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        payload = routes.get(request.url.path)
        return httpx.Response(200 if payload else 404, json=payload or {})

    return TmdbClient("k", transport=httpx.MockTransport(handler))


async def test_new_season_reaches_calendar_before_premiere(db, tmp_path, monkeypatch) -> None:
    """没订阅的剧在季间空档刷新：3 天后再刷，期间 TMDB 公布的新季赶在首播前进库，
    详情页分集区有了第 2 季、日历出得来；之后转入在播档每天刷。"""
    from movieclaw_api.services import media_discover, media_refresh

    today = publish_calendar_date(utcnow())
    day = lambda offset: (today + timedelta(days=offset)).isoformat()  # noqa: E731
    library_id, item_id = await _seed_show(db, tmp_path, {1: -67, 2: -60}, owned={1, 2})
    show = {
        "id": 777,
        "name": "长街夜行",
        "original_name": "Night Street",
        "first_air_date": day(-67),
        "status": "Returning Series",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 1}],
    }
    season1 = {
        "name": "第 1 季",
        "air_date": day(-67),
        "episodes": [
            {"episode_number": 1, "name": "E1", "air_date": day(-67)},
            {"episode_number": 2, "name": "E2", "air_date": day(-60)},
        ],
    }
    routes = {"/3/tv/777": show, "/3/tv/777/season/1": season1}
    monkeypatch.setattr(media_discover, "get_tmdb_client", lambda: _fake_tmdb(routes))

    async def refresh() -> timedelta:
        await media_refresh.refresh_media_metadata()
        async with db.session() as session:
            item = await session.get(MediaItem, item_id)
            assert item is not None and item.next_refresh_at is not None
            return item.next_refresh_at - utcnow()

    # 季间空档：本地最新一集两个月前，原来会排到 30 天后
    assert timedelta(days=2, hours=23) < await refresh() <= timedelta(days=3)

    # 三天内 TMDB 公布第 2 季 10 天后开播；到期再刷
    routes["/3/tv/777"] = {**show, "seasons": [{"season_number": 1}, {"season_number": 2}]}
    routes["/3/tv/777/season/2"] = {
        "name": "第 2 季",
        "air_date": day(10),
        "episodes": [
            {"episode_number": 1, "name": "E1", "air_date": day(10)},
            {"episode_number": 2, "name": "E2", "air_date": day(17)},
        ],
    }
    async with db.session() as session:
        item = await session.get(MediaItem, item_id)
        assert item is not None
        item.next_refresh_at = utcnow()
        session.add(item)
        await session.commit()
    assert timedelta(hours=23) < await refresh() <= timedelta(hours=24)

    async with db.session() as session:
        view = (await list_item_episodes(library_id, item_id, 2, _ADMIN, session)).data
    assert [e.episode_number for e in view.episodes] == [1, 2]
    assert not any(e.owned for e in view.episodes)
    assert view.air_schedule is not None
    assert view.air_schedule.last_air_date == today + timedelta(days=17)
