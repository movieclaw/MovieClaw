"""集数下限（issue #640）：TMDB 少录集数时订阅继续追。

夹具还原 issue 现场：《死刑将至》TMDB 只录了 6 集（已完结），实际 27 集。
- 下限：订阅里确认「第 1 季 27 集」后，E07～E27 作为占位单元立即排队搜索；
- 证据：站点出现 E09 / 「全 27 集」时记下证据，挡住「已收齐」并提示；
- 覆盖：单集种子与声明总集数的包能满足占位集，没声明总集数的整季包不能。
"""

from __future__ import annotations

from datetime import timedelta

import httpx
import pytest
import pytest_asyncio
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_api.services.subscription.core import ExpectedUnit, expected_units
from movieclaw_api.services.subscription.episode_floor import (
    pending_hints,
    record_episode_overflow,
    season_episode_max,
)
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.settings.store import init_setting_store, reset_setting_store
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    MediaEpisode,
    SiteTorrent,
    Subscription,
    SubscriptionActivity,
    SubscriptionStatus,
    TorrentSource,
    WantedItem,
    WantedStatus,
)
from movieclaw_db.models.base import utcnow
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"
_AIRED = (utcnow().date() - timedelta(days=30)).isoformat()

_ROUTES = {
    "/3/tv/640": {
        "id": 640,
        "name": "死刑将至",
        "original_name": "Death Row Is Coming",
        "first_air_date": "2025-01-01",
        "status": "Ended",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 1}],
    },
    "/3/tv/640/season/1": {
        "name": "第 1 季",
        "air_date": "2025-01-01",
        "episodes": [
            {"episode_number": n, "name": f"E{n}", "air_date": _AIRED} for n in range(1, 7)
        ],
    },
}


def _fake_tmdb() -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        payload = _ROUTES.get(request.url.path)
        return httpx.Response(200 if payload else 404, json=payload or {})

    return TmdbClient(_KEY, transport=httpx.MockTransport(handler))


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'floor.db'}")
    # 只测匹配与状态机：dry-run 投递，不连站点与下载器
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "true")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    init_setting_store()
    yield get_database()
    reset_setting_store()
    await dispose_db()
    get_settings.cache_clear()


def _service(session) -> SubscriptionService:
    return SubscriptionService(session, MediaLibraryService(session, _fake_tmdb()))


async def _wanted(session, sub_id: int) -> dict[tuple[int, int], WantedItem]:
    rows = (
        (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub_id)))
        .scalars()
        .all()
    )
    return {(w.season_number, w.episode_number): w for w in rows}


async def _torrent(session, torrent_id: str, title: str, attrs: dict) -> SiteTorrent:
    row = SiteTorrent(
        site_id="testsite",
        torrent_id=torrent_id,
        title=title,
        subtitle="",
        attrs={"media_type": "tv", "resolution": "1080p", **attrs},
        enrich_version=1,
        source=TorrentSource.LIST,
        seeders=10,
        download_volume_factor=0.0,
        is_free=True,
        publish_time=utcnow(),
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row


async def _import_all(session, sub_id: int) -> None:
    for row in (await _wanted(session, sub_id)).values():
        row.status = WantedStatus.IMPORTED
        session.add(row)
    await session.commit()


async def _subscription(session, sub_id: int) -> Subscription:
    sub = await session.get(Subscription, sub_id)
    assert sub is not None
    await session.refresh(sub)
    return sub


# ---------------------------------------------------------------------------
# E 的展开
# ---------------------------------------------------------------------------


def _episodes(season: int, count: int) -> list[MediaEpisode]:
    return [
        MediaEpisode(media_item_id=1, season_number=season, episode_number=n)
        for n in range(1, count + 1)
    ]


def test_floor_expands_placeholders_after_tmdb_episodes() -> None:
    units = expected_units(MediaKind.TV, _episodes(1, 6), [1], False, {1: 9})
    assert [(u.episode_number, u.provisional) for u in units] == [
        (1, False),
        (2, False),
        (3, False),
        (4, False),
        (5, False),
        (6, False),
        (7, True),
        (8, True),
        (9, True),
    ]
    assert all(u.air_date is None for u in units if u.provisional)


def test_floor_ignored_for_untracked_season_and_not_above_tmdb() -> None:
    episodes = _episodes(1, 6) + _episodes(2, 3)
    # 第 2 季没勾、也没开追新：下限不生效；第 1 季下限不超过 TMDB：没有占位
    units = expected_units(MediaKind.TV, episodes, [1], False, {1: 6, 2: 10})
    assert not any(u.provisional for u in units)
    # 开了追新，未勾的季的占位集和"未定档集"同类，一并纳入
    units = expected_units(MediaKind.TV, episodes, [1], True, {2: 5})
    assert [(u.season_number, u.episode_number) for u in units if u.provisional] == [
        (2, 4),
        (2, 5),
    ]


def test_placeholder_is_searched_immediately() -> None:
    from movieclaw_api.services.subscription import schedule_for

    next_search, _ = schedule_for("tv", ExpectedUnit(1, 7, None, provisional=True))
    assert next_search is not None and next_search <= utcnow()
    # 真正 TMDB 未定档的集仍不可调度
    assert schedule_for("tv", ExpectedUnit(1, 7, None))[0] is None


# ---------------------------------------------------------------------------
# 订阅：创建 / 调整 / 状态
# ---------------------------------------------------------------------------


async def test_create_with_floor_tracks_all_27_episodes(db) -> None:
    async with db.session() as session:
        sub = await _service(session).create(
            MediaKind.TV, 640, selected_seasons=[1], episode_floors={1: 27}
        )
        wanted = await _wanted(session, sub.id)

    assert sorted(wanted) == [(1, n) for n in range(1, 28)]
    now = utcnow()
    for n in range(7, 28):
        row = wanted[(1, n)]
        assert row.status == WantedStatus.WANTED
        assert row.next_search_at is not None and row.next_search_at <= now
    assert sub.episode_floors == {"1": 27}
    assert sub.status == SubscriptionStatus.ACTIVE


async def test_update_floor_raise_lower_and_clear(db) -> None:
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 640, selected_seasons=[1])
        assert len(await _wanted(session, sub.id)) == 6

        await service.update(sub.id, episode_floors={1: 10})
        wanted = await _wanted(session, sub.id)
        assert sorted(k for k, w in wanted.items() if w.in_scope) == [(1, n) for n in range(1, 11)]

        # 调低：超出新下限的占位集出域，TMDB 已录的集不受影响
        await service.update(sub.id, episode_floors={1: 8})
        wanted = await _wanted(session, sub.id)
        assert sorted(k for k, w in wanted.items() if w.in_scope) == [(1, n) for n in range(1, 9)]
        assert not wanted[(1, 9)].in_scope and not wanted[(1, 10)].in_scope

        # 再调高：复用原工单重新纳入，不重复建行
        await service.update(sub.id, episode_floors={1: 10})
        wanted = await _wanted(session, sub.id)
        assert len(wanted) == 10 and all(w.in_scope for w in wanted.values())

        # 清除：回到以 TMDB 为准
        await service.update(sub.id, episode_floors={})
        wanted = await _wanted(session, sub.id)
        assert sorted(k for k, w in wanted.items() if w.in_scope) == [(1, n) for n in range(1, 7)]
        sub = await _subscription(session, sub.id)
        assert sub.episode_floors is None

        messages = [
            a.message
            for a in (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == sub.id
                    )
                )
            ).scalars()
        ]
        assert any("第 1 季按 10 集" in m for m in messages)
        assert any("改回以 TMDB 为准" in m for m in messages)


async def test_floor_validation(db) -> None:
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 640, selected_seasons=[1])
        with pytest.raises(BadRequestException):
            await service.update(sub.id, episode_floors={3: 20})  # 没有第 3 季
        with pytest.raises(BadRequestException):
            await service.update(sub.id, episode_floors={1: 99999})
        # 不超过 TMDB 已录集数：视为不设
        await service.update(sub.id, episode_floors={1: 5})
        assert (await _subscription(session, sub.id)).episode_floors is None


async def test_floor_completes_after_placeholders_imported(db) -> None:
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 640, selected_seasons=[1], episode_floors={1: 8})
        await _import_all(session, sub.id)
        await service.update(sub.id)  # 触发状态重算
        assert (await _subscription(session, sub.id)).status == SubscriptionStatus.COMPLETED


# ---------------------------------------------------------------------------
# 站点证据 → 提示 → 忽略
# ---------------------------------------------------------------------------


async def test_site_evidence_reopens_completed_subscription(db) -> None:
    """issue 现场：6 集下完订阅已收齐，站点出了第 9 集——要提示，并退回追踪。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 640, selected_seasons=[1])
        await _import_all(session, sub.id)
        await service.update(sub.id)
        assert (await _subscription(session, sub.id)).status == SubscriptionStatus.COMPLETED

        e09 = await _torrent(
            session,
            "e09",
            "Death Row Is Coming S01E09 1080p WEB-DL",
            {"seasons": [1], "episodes": [9]},
        )
        await evaluate_and_dispatch(session, [e09], source="被动匹配")

        sub = await _subscription(session, sub.id)
        assert sub.status == SubscriptionStatus.ACTIVE
        hints = pending_hints(sub, await season_episode_max(session, sub.media_item_id))
        assert [(h.season_number, h.known_count, h.suggested, h.site_episode) for h in hints] == [
            (1, 6, 9, 9)
        ]
        assert hints[0].site_title == "Death Row Is Coming S01E09 1080p WEB-DL"
        activity = (
            await session.execute(
                select(SubscriptionActivity).where(
                    SubscriptionActivity.subscription_id == sub.id,
                    SubscriptionActivity.type == "episode_hint",
                )
            )
        ).scalar_one()
        assert "第 9 集" in activity.message and "只录了 6 集" in activity.message

        # 同样的证据再来一次：不重复记活动
        await evaluate_and_dispatch(session, [e09], source="被动匹配")
        count = len(
            (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == sub.id,
                        SubscriptionActivity.type == "episode_hint",
                    )
                )
            ).all()
        )
        assert count == 1

        # 忽略：回到收齐；更大的新证据才再提示
        await service.dismiss_episode_hint(sub.id, 1)
        assert (await _subscription(session, sub.id)).status == SubscriptionStatus.COMPLETED
        pack = await _torrent(
            session,
            "pack27",
            "死刑将至 全27集 1080p WEB-DL",
            {"seasons": [1], "complete": True, "episodes_total": 27},
        )
        await record_episode_overflow(session, [pack])
        sub = await _subscription(session, sub.id)
        assert sub.status == SubscriptionStatus.ACTIVE
        hints = pending_hints(sub, await season_episode_max(session, sub.media_item_id))
        assert [h.suggested for h in hints] == [27]

        # 采纳提示 = 设下限：提示消失，占位集进入追踪
        await service.update(sub.id, episode_floors={1: 27})
        sub = await _subscription(session, sub.id)
        assert pending_hints(sub, await season_episode_max(session, sub.media_item_id)) == []
        wanted = await _wanted(session, sub.id)
        assert wanted[(1, 27)].status == WantedStatus.WANTED


async def test_dismiss_without_hint_is_rejected(db) -> None:
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 640, selected_seasons=[1])
        with pytest.raises(BadRequestException):
            await service.dismiss_episode_hint(sub.id, 1)


# ---------------------------------------------------------------------------
# 占位集的满足：单集 / 声明总集数的包 / 未声明的整季包
# ---------------------------------------------------------------------------


async def test_single_episode_torrent_satisfies_placeholder(db) -> None:
    async with db.session() as session:
        sub = await _service(session).create(
            MediaKind.TV, 640, selected_seasons=[1], episode_floors={1: 27}
        )
        e07 = await _torrent(
            session,
            "e07",
            "Death Row Is Coming S01E07 1080p WEB-DL",
            {"seasons": [1], "episodes": [7]},
        )
        await evaluate_and_dispatch(session, [e07], source="被动匹配")
        wanted = await _wanted(session, sub.id)
        assert wanted[(1, 7)].status == WantedStatus.GRABBED
        assert wanted[(1, 8)].status == WantedStatus.WANTED


async def test_declared_total_pack_covers_placeholders(db) -> None:
    async with db.session() as session:
        sub = await _service(session).create(
            MediaKind.TV, 640, selected_seasons=[1], episode_floors={1: 27}
        )
        pack = await _torrent(
            session,
            "pack27",
            "Death Row Is Coming S01 全27集 1080p WEB-DL",
            {"seasons": [1], "complete": True, "episodes_total": 27},
        )
        await evaluate_and_dispatch(session, [pack], source="被动匹配")
        wanted = await _wanted(session, sub.id)
        assert all(w.status == WantedStatus.GRABBED for w in wanted.values())


async def test_undeclared_season_pack_leaves_placeholders(db) -> None:
    """没写总集数的整季包：说不清有没有第 7 集以后，只满足 TMDB 已录的集。"""
    async with db.session() as session:
        sub = await _service(session).create(
            MediaKind.TV, 640, selected_seasons=[1], episode_floors={1: 27}
        )
        pack = await _torrent(
            session, "s01", "Death Row Is Coming S01 1080p WEB-DL", {"seasons": [1]}
        )
        await evaluate_and_dispatch(session, [pack], source="被动匹配")
        wanted = await _wanted(session, sub.id)
        assert all(wanted[(1, n)].status == WantedStatus.GRABBED for n in range(1, 7))
        assert all(wanted[(1, n)].status == WantedStatus.WANTED for n in range(7, 28))
