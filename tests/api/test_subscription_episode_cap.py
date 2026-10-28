"""订阅窗口：一季上千集时先订阅一段（docs/design/subscription-episode-cap.md）。

夹具用一部《长篇漫剧》：TMDB 里一季 120 集、全部已播。
- 创建时带窗口：只展开窗口内集号的工单，窗口里的集下完订阅也不判「已收齐」；
- 完结季「前 N 集」（end 设值）；在播季「最新 N 集起」（end=None）——之后播出的
  新集照常进来，追新与窗口不再互斥；
- 往宽调 / 往窄调 / 清除：沿用 update 的 diff，已下载、已入库的内容一律保留；
- 元数据刷新不会把窗口外的集重新展开（end=None 的窗口除外——那是追新本意）；
- 接口：创建 / 调整接受 ``episode_caps``，列表与详情给出被截断的季。
"""

from __future__ import annotations

from datetime import timedelta

import httpx
import pytest
import pytest_asyncio
from fastapi.testclient import TestClient
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_api.services.subscription.core import expected_units
from movieclaw_api.services.subscription.episode_cap import EpisodeCap, caps_of, windows_of
from movieclaw_api.settings.store import init_setting_store, reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    MediaEpisode,
    Subscription,
    SubscriptionActivity,
    SubscriptionStatus,
    WantedItem,
    WantedStatus,
)
from movieclaw_db.models.base import utcnow
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"
_AIRED = (utcnow().date() - timedelta(days=30)).isoformat()
_TOTAL = 120  # 夹具里那一季的 TMDB 集数


def _routes(episodes: int = _TOTAL) -> dict[str, dict]:
    return {
        "/3/tv/1043": {
            "id": 1043,
            "name": "长篇漫剧",
            "original_name": "Long Comic Drama",
            "first_air_date": "2025-01-01",
            "status": "Ended",
            "external_ids": {},
            "alternative_titles": {"results": []},
            "translations": {"translations": []},
            "seasons": [{"season_number": 1}],
        },
        "/3/tv/1043/season/1": {
            "name": "第 1 季",
            "air_date": "2025-01-01",
            "episodes": [
                {"episode_number": n, "name": f"E{n}", "air_date": _AIRED}
                for n in range(1, episodes + 1)
            ],
        },
        "/3/tv/1045": {
            "id": 1045,
            "name": "在播长篇剧",
            "original_name": "Airing Long Drama",
            "first_air_date": "2025-01-01",
            "status": "Returning Series",
            "external_ids": {},
            "alternative_titles": {"results": []},
            "translations": {"translations": []},
            "seasons": [{"season_number": 1}],
        },
        "/3/tv/1045/season/1": {
            "name": "第 1 季",
            "air_date": "2025-01-01",
            "episodes": [
                {"episode_number": n, "name": f"E{n}", "air_date": _AIRED}
                for n in range(1, episodes + 1)
            ],
        },
        "/3/movie/77": {
            "id": 77,
            "title": "某电影",
            "original_title": "Some Movie",
            "release_date": "2020-05-01",
            "status": "Released",
            "external_ids": {},
            "alternative_titles": {"titles": []},
            "translations": {"translations": []},
        },
    }


def _fake_tmdb(routes: dict[str, dict]) -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        payload = routes.get(request.url.path)
        return httpx.Response(200 if payload else 404, json=payload or {})

    return TmdbClient(_KEY, transport=httpx.MockTransport(handler))


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'cap.db'}")
    # 只测 E 的展开与状态机：dry-run 投递，不连站点与下载器
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "true")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    init_setting_store()
    yield get_database()
    reset_setting_store()
    await dispose_db()
    get_settings.cache_clear()


def _service(session, routes: dict[str, dict] | None = None) -> SubscriptionService:
    library = MediaLibraryService(session, _fake_tmdb(routes or _routes()))
    return SubscriptionService(session, library)


async def _wanted(session, sub_id: int) -> dict[tuple[int, int], WantedItem]:
    rows = (
        (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub_id)))
        .scalars()
        .all()
    )
    return {(w.season_number, w.episode_number): w for w in rows}


def _in_scope(wanted: dict[tuple[int, int], WantedItem]) -> list[int]:
    return sorted(episode for (_season, episode), w in wanted.items() if w.in_scope)


async def _import_all(session, sub_id: int) -> None:
    for row in (await _wanted(session, sub_id)).values():
        if row.in_scope:
            row.status = WantedStatus.IMPORTED
            session.add(row)
    await session.commit()


async def _subscription(session, sub_id: int) -> Subscription:
    sub = await session.get(Subscription, sub_id)
    assert sub is not None
    await session.refresh(sub)
    return sub


async def _messages(session, sub_id: int) -> list[str]:
    return [
        a.message
        for a in (
            await session.execute(
                select(SubscriptionActivity).where(SubscriptionActivity.subscription_id == sub_id)
            )
        ).scalars()
    ]


# ---------------------------------------------------------------------------
# E 的展开：窗口是 E 定义的一部分
# ---------------------------------------------------------------------------


def _episodes(count: int, *, future_from: int | None = None) -> list[MediaEpisode]:
    today = utcnow().date()
    return [
        MediaEpisode(
            media_item_id=1,
            season_number=1,
            episode_number=n,
            air_date=today + timedelta(days=n) if future_from and n >= future_from else today,
        )
        for n in range(1, count + 1)
    ]


def test_window_cuts_expected_units() -> None:
    units = expected_units(MediaKind.TV, _episodes(30), [1], False, None, {1: EpisodeCap(1, 12)})
    assert [u.episode_number for u in units] == list(range(1, 13))
    # 没设窗口的季不受影响
    units = expected_units(MediaKind.TV, _episodes(30), [1], False, None, {2: EpisodeCap(1, 5)})
    assert len(units) == 30


def test_tail_window_bounds_follow_future_and_placeholders_too() -> None:
    """end 设值的窗口（完结季「前 N 集」）：追新的未播集与下限占位集一并受限。"""
    episodes = _episodes(14, future_from=11)  # E11～E14 还没播
    units = expected_units(MediaKind.TV, episodes, [], True, {1: 16}, {1: EpisodeCap(1, 12)})
    assert [u.episode_number for u in units] == [11, 12]  # 勾选的季为空，只剩追新贡献
    units = expected_units(MediaKind.TV, episodes, [1], True, {1: 16}, {1: EpisodeCap(1, 12)})
    assert [(u.episode_number, u.provisional) for u in units] == [(n, False) for n in range(1, 13)]
    # 清除窗口：追新、占位集全部回来
    units = expected_units(MediaKind.TV, episodes, [1], True, {1: 16}, None)
    assert [u.episode_number for u in units] == list(range(1, 17))


def test_head_window_keeps_follow_future_flowing() -> None:
    """end=None 的窗口（在播季「从第 X 集起」）：之后播出的集照常进来，追新不再被挡。"""
    episodes = _episodes(14, future_from=11)  # E11～E14 还没播
    # 勾选的季为空、只开着追新：从第 5 集起未播的集全部在 E
    units = expected_units(
        MediaKind.TV, episodes, [], True, None, {1: EpisodeCap(5, None)}
    )
    assert [u.episode_number for u in units] == [11, 12, 13, 14]
    # 勾了整季：第 5 集起的已播集 + 未播集 + 下限占位集（≥ start 的）都在 E
    units = expected_units(
        MediaKind.TV, episodes, [1], True, {1: 18}, {1: EpisodeCap(5, None)}
    )
    assert [u.episode_number for u in units] == list(range(5, 19))
    assert all(u.provisional for u in units if u.episode_number > 14)


def test_windows_cover_only_truncated_tracked_seasons() -> None:
    sub = Subscription(
        media_item_id=1,
        kind="tv",
        selected_seasons=[1],
        follow_future=False,
        # 第 2 季没勾，不算
        episode_caps={"1": {"start": 1, "end": 20}, "2": {"start": 1, "end": 5}},
    )
    windows = windows_of(sub, {1: 120, 2: 30})
    assert [(w.season_number, w.start, w.end, w.total) for w in windows] == [(1, 1, 20, 120)]
    # 盖住整季：没有截断
    assert windows_of(sub, {1: 20}) == []
    # 在播窗口：start>1、不设上界
    sub.episode_caps = {"1": {"start": 101, "end": None}}
    assert [(w.start, w.end, w.total) for w in windows_of(sub, {1: 120})] == [(101, None, 120)]
    # 集数下限撑起的占位集也算本季的集
    sub.episode_floors = {"1": 130}
    sub.episode_caps = {"1": {"start": 1, "end": 125}}
    assert [(w.end, w.total) for w in windows_of(sub, {1: 120})] == [(125, 130)]
    assert caps_of(sub) == {1: EpisodeCap(1, 125)}


def test_caps_of_reads_legacy_int_values() -> None:
    """窗口之前的落库形态是纯集号，读作「从第 1 集订到第 N 集」。"""
    sub = Subscription(media_item_id=1, kind="tv", episode_caps={"1": 20, "2": "x", "x": 5})
    assert caps_of(sub) == {1: EpisodeCap(1, 20)}


# ---------------------------------------------------------------------------
# 订阅：创建 / 状态 / 往宽调 / 往窄调 / 清除
# ---------------------------------------------------------------------------


async def test_create_with_window_only_materializes_the_window(db) -> None:
    async with db.session() as session:
        sub = await _service(session).create(
            MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 20)}
        )
        wanted = await _wanted(session, sub.id)
        messages = await _messages(session, sub.id)

    assert sorted(wanted) == [(1, n) for n in range(1, 21)]
    assert all(w.status == WantedStatus.WANTED and w.in_scope for w in wanted.values())
    assert sub.episode_caps == {"1": {"start": 1, "end": 20}}
    assert sub.status == SubscriptionStatus.ACTIVE
    assert any("第 1 季先订阅到第 20 集（本季共 120 集）" in m for m in messages)


async def test_create_with_head_window_and_follow_future(db) -> None:
    """在播季「最新 N 集起」：先订 101～120，开着追新，之后的集照常进来。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(
            MediaKind.TV,
            1043,
            selected_seasons=[1],
            follow_future=True,
            episode_caps={1: EpisodeCap(101, None)},
        )
        wanted = await _wanted(session, sub.id)
        messages = await _messages(session, sub.id)

    assert sorted(wanted) == [(1, n) for n in range(101, 121)]
    assert sub.episode_caps == {"1": {"start": 101, "end": None}}
    assert any("第 1 季先订阅最新 20 集（从第 101 集起" in m for m in messages)


async def test_window_done_keeps_subscription_open_until_cleared(db) -> None:
    """窗口里的集全部入库：订阅仍留在订阅中；清除窗口、下完整季后才收齐。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(
            MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 20)}
        )
        await _import_all(session, sub.id)
        await service.update(sub.id)  # 触发状态重算
        assert (await _subscription(session, sub.id)).status == SubscriptionStatus.ACTIVE

        await service.update(sub.id, episode_caps={})
        wanted = await _wanted(session, sub.id)
        assert len(wanted) == _TOTAL and all(w.in_scope for w in wanted.values())
        assert (await _subscription(session, sub.id)).status == SubscriptionStatus.ACTIVE

        await _import_all(session, sub.id)
        await service.update(sub.id)
        assert (await _subscription(session, sub.id)).status == SubscriptionStatus.COMPLETED


async def test_completed_subscription_reopens_when_a_window_is_added(db) -> None:
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 1043, selected_seasons=[1])
        await _import_all(session, sub.id)
        await service.update(sub.id)
        assert (await _subscription(session, sub.id)).status == SubscriptionStatus.COMPLETED

        await service.update(sub.id, episode_caps={1: EpisodeCap(1, 20)})
        assert (await _subscription(session, sub.id)).status == SubscriptionStatus.ACTIVE
        messages = await _messages(session, sub.id)
        assert any("本季还有没订到的集，可随时继续订阅" in m for m in messages)


async def test_widen_window_adds_next_batch_and_keeps_history(db) -> None:
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(
            MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 20)}
        )
        await _import_all(session, sub.id)

        await service.update(sub.id, episode_caps={1: EpisodeCap(1, 40)})
        wanted = await _wanted(session, sub.id)
        assert _in_scope(wanted) == list(range(1, 41))
        assert all(wanted[(1, n)].status == WantedStatus.IMPORTED for n in range(1, 21))
        now = utcnow()
        for n in range(21, 41):
            row = wanted[(1, n)]
            assert row.status == WantedStatus.WANTED
            assert row.next_search_at is not None and row.next_search_at <= now
        assert (await _subscription(session, sub.id)).episode_caps == {"1": {"start": 1, "end": 40}}
        assert any("第 1 季先订阅到第 40 集" in m for m in await _messages(session, sub.id))


async def test_backfill_window_pulls_earlier_episodes_in(db) -> None:
    """「往前再订」：start 往前挪，更早的集补工单并立即搜索；已入库的保留。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(
            MediaKind.TV,
            1043,
            selected_seasons=[1],
            follow_future=True,
            episode_caps={1: EpisodeCap(101, None)},
        )
        wanted = await _wanted(session, sub.id)
        assert sorted(wanted) == [(1, n) for n in range(101, 121)]
        # 前 20 集之外的更早的集从未见过：往前订 20 集补上工单
        await service.update(sub.id, episode_caps={1: EpisodeCap(81, None)})
        wanted = await _wanted(session, sub.id)
        assert _in_scope(wanted) == list(range(81, 121))
        now = utcnow()
        for n in range(81, 101):
            row = wanted[(1, n)]
            assert row.status == WantedStatus.WANTED
            assert row.next_search_at is not None and row.next_search_at <= now
        stored = (await _subscription(session, sub.id)).episode_caps
        assert stored == {"1": {"start": 81, "end": None}}
        messages = await _messages(session, sub.id)
        assert any("第 1 季先订阅最新 40 集（从第 81 集起" in m for m in messages)


async def test_narrow_window_only_flips_scope_and_keeps_downloaded_content(db) -> None:
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(
            MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 40)}
        )
        await _import_all(session, sub.id)

        await service.update(sub.id, episode_caps={1: EpisodeCap(1, 10)})
        wanted = await _wanted(session, sub.id)
        assert _in_scope(wanted) == list(range(1, 11))
        # 出域的只切 in_scope：已入库的历史原样保留
        assert all(wanted[(1, n)].status == WantedStatus.IMPORTED for n in range(11, 41))
        _sub, _item, in_scope_rows = await service.detail(sub.id)
        assert sorted(w.episode_number for w in in_scope_rows) == list(range(1, 11))

        # 再调回去：复用原工单重新纳入，不重复建行
        await service.update(sub.id, episode_caps={1: EpisodeCap(1, 40)})
        wanted = await _wanted(session, sub.id)
        assert len(wanted) == 40 and all(w.in_scope for w in wanted.values())


async def test_clear_window_restores_the_whole_season(db) -> None:
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(
            MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 20)}
        )
        await service.update(sub.id, episode_caps={})
        sub = await _subscription(session, sub.id)
        assert sub.episode_caps is None
        assert _in_scope(await _wanted(session, sub.id)) == list(range(1, _TOTAL + 1))
        assert any("不再限制订阅的集数" in m for m in await _messages(session, sub.id))


async def test_window_validation(db) -> None:
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 1043, selected_seasons=[1])
        with pytest.raises(BadRequestException):
            await service.update(sub.id, episode_caps={3: EpisodeCap(1, 10)})  # 没有第 3 季
        with pytest.raises(BadRequestException):
            await service.update(sub.id, episode_caps={1: EpisodeCap(0, 10)})
        with pytest.raises(BadRequestException):
            await service.update(sub.id, episode_caps={1: EpisodeCap(1, 99999)})
        with pytest.raises(BadRequestException):
            await service.update(sub.id, episode_caps={1: EpisodeCap(30, 10)})  # end < start
        # 两头都收的混合窗口不接受
        with pytest.raises(BadRequestException):
            await service.update(sub.id, episode_caps={1: EpisodeCap(30, 60)})
        # start 超过本季已有的集号：窗口一集都盖不住，多半是客户端的错
        with pytest.raises(BadRequestException):
            await service.update(sub.id, episode_caps={1: EpisodeCap(500, None)})
        # 盖住整季：没有截断，视为不设
        await service.update(sub.id, episode_caps={1: EpisodeCap(1, _TOTAL)})
        assert (await _subscription(session, sub.id)).episode_caps is None
        await service.update(sub.id, episode_caps={1: EpisodeCap(1, None)})
        assert (await _subscription(session, sub.id)).episode_caps is None
        await service.update(sub.id, episode_caps={1: EpisodeCap(1, _TOTAL + 50)})
        assert (await _subscription(session, sub.id)).episode_caps is None
        # 在播窗口：start>1、不设上界，正常落库
        await service.update(sub.id, episode_caps={1: EpisodeCap(101, None)})
        stored = (await _subscription(session, sub.id)).episode_caps
        assert stored == {"1": {"start": 101, "end": None}}
        # 电影没有「集」
        with pytest.raises(BadRequestException):
            await service.create(MediaKind.MOVIE, 77, episode_caps={1: EpisodeCap(1, 5)})


async def test_window_survives_metadata_refresh(db, monkeypatch) -> None:
    """TMDB 又多录了 5 集：end 设值的窗口不把窗口外的集重新展开；end=None 的照常纳入。"""
    from movieclaw_api.services.media_scrape import scrape_media_item

    routes = _routes()
    monkeypatch.setattr(
        "movieclaw_api.services.media_discover.get_tmdb_client", lambda: _fake_tmdb(routes)
    )
    async with db.session() as session:
        service = _service(session, routes)
        capped = await service.create(
            MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 20)}
        )
        item_id = capped.media_item_id
        assert _in_scope(await _wanted(session, capped.id)) == list(range(1, 21))

    routes.update(_routes(_TOTAL + 5))
    assert await scrape_media_item(item_id)

    async with db.session() as session:
        wanted = await _wanted(session, capped.id)
        assert sorted(wanted) == [(1, n) for n in range(1, 21)]
        episodes = (
            await session.execute(select(MediaEpisode).where(MediaEpisode.media_item_id == item_id))
        ).scalars()
        assert len(list(episodes)) == _TOTAL + 5  # 刷新确实跑过了
        sub = await _subscription(session, capped.id)
        assert sub.status == SubscriptionStatus.ACTIVE
        # 解除窗口后，才把整季（含新录的 5 集）展开
        await _service(session, routes).update(sub.id, episode_caps={})
        assert _in_scope(await _wanted(session, sub.id)) == list(range(1, _TOTAL + 6))


async def test_head_window_grows_with_metadata_refresh(db, monkeypatch) -> None:
    """end=None 的窗口：TMDB 多录的 5 集照常补工单——追新与窗口不互斥。"""
    from movieclaw_api.services.media_scrape import scrape_media_item

    routes = _routes()
    monkeypatch.setattr(
        "movieclaw_api.services.media_discover.get_tmdb_client", lambda: _fake_tmdb(routes)
    )
    async with db.session() as session:
        service = _service(session, routes)
        sub = await service.create(
            MediaKind.TV, 1043, selected_seasons=[1], follow_future=True,
            episode_caps={1: EpisodeCap(101, None)},
        )
        item_id = sub.media_item_id
        assert _in_scope(await _wanted(session, sub.id)) == list(range(101, 121))

    routes.update(_routes(_TOTAL + 5))
    assert await scrape_media_item(item_id)

    async with db.session() as session:
        assert _in_scope(await _wanted(session, sub.id)) == list(range(101, 126))


# ---------------------------------------------------------------------------
# 接口：创建 / 调整接受 episode_caps，列表与详情给出被截断的季
# ---------------------------------------------------------------------------


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'cap-api.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "true")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()

    from movieclaw_api.api.routes import subscriptions as routes
    from movieclaw_api.app import create_app

    monkeypatch.setattr(routes, "get_tmdb_client", lambda: _fake_tmdb(_routes()))
    with TestClient(create_app()) as test_client:
        response = test_client.post(
            "/api/v1/auth/bootstrap", json={"username": "admin", "password": "s3cret-pass"}
        )
        assert response.status_code == 200
        yield test_client

    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def test_window_through_the_api(client: TestClient) -> None:
    created = client.post(
        "/api/v1/subscriptions",
        json={
            "title_ref": "tmdb:tv:1043",
            "selected_seasons": [1],
            "episode_caps": {"1": {"start": 1, "end": 20}},
        },
    )
    assert created.status_code == 200, created.text
    detail = created.json()["data"]["subscription"]
    sub_id = detail["id"]
    assert detail["progress"]["total"] == 20
    assert detail["episode_windows"] == [
        {"season_number": 1, "start": 1, "end": 20, "total": _TOTAL, "airing": False}
    ]
    assert detail["episode_seasons"] == [
        {"season_number": 1, "tmdb_count": _TOTAL, "floor": None, "window": {"start": 1, "end": 20}}
    ]

    listed = client.get("/api/v1/subscriptions").json()["data"]
    assert [row["episode_windows"] for row in listed] == [
        [{"season_number": 1, "start": 1, "end": 20, "total": _TOTAL, "airing": False}]
    ]

    # 调大一批：新增的集补上工单，详情随之更新
    patched = client.patch(
        f"/api/v1/subscriptions/{sub_id}", json={"episode_caps": {"1": {"start": 1, "end": 40}}}
    )
    assert patched.status_code == 200, patched.text
    detail = patched.json()["data"]
    assert detail["progress"]["total"] == 40
    assert detail["episode_windows"] == [
        {"season_number": 1, "start": 1, "end": 40, "total": _TOTAL, "airing": False}
    ]

    # 没带 episode_caps 的调整不改窗口
    unchanged = client.patch(f"/api/v1/subscriptions/{sub_id}", json={"follow_future": False})
    assert unchanged.json()["data"]["episode_windows"][0]["end"] == 40

    # 换成在播窗口：只订最新的 20 集
    aired = client.patch(
        f"/api/v1/subscriptions/{sub_id}", json={"episode_caps": {"1": {"start": 101, "end": None}}}
    )
    assert aired.status_code == 200, aired.text
    detail = aired.json()["data"]
    assert detail["progress"]["total"] == 20
    assert detail["episode_windows"] == [
        {"season_number": 1, "start": 101, "end": None, "total": _TOTAL, "airing": False}
    ]
    assert detail["episode_seasons"][0]["window"] == {"start": 101, "end": None}

    # 两头都收的混合窗口被拒
    mixed = client.patch(
        f"/api/v1/subscriptions/{sub_id}", json={"episode_caps": {"1": {"start": 30, "end": 60}}}
    )
    assert mixed.status_code == 400

    # 清除：回到整季，列表与详情都不再有被截断的季
    cleared = client.patch(f"/api/v1/subscriptions/{sub_id}", json={"episode_caps": {}})
    detail = cleared.json()["data"]
    assert detail["progress"]["total"] == _TOTAL
    assert detail["episode_windows"] is None
    assert detail["episode_seasons"][0]["window"] is None
    assert client.get("/api/v1/subscriptions").json()["data"][0]["episode_windows"] is None


def test_open_ended_window_is_marked_airing_only_for_the_airing_season(
    client: TestClient,
) -> None:
    """不设上界的窗口：在播剧标 airing（「最新 N 集」），完结剧不标（「从第 N 集起」）。

    issue #950。
    """
    window = {"1": {"start": 101, "end": None}}
    for title_ref in ("tmdb:tv:1043", "tmdb:tv:1045"):
        created = client.post(
            "/api/v1/subscriptions",
            json={"title_ref": title_ref, "selected_seasons": [1], "episode_caps": window},
        )
        assert created.status_code == 200, created.text
    listed = {
        row["media"]["tmdb_id"]: row["episode_windows"]
        for row in client.get("/api/v1/subscriptions").json()["data"]
    }
    assert listed == {
        1043: [{"season_number": 1, "start": 101, "end": None, "total": _TOTAL, "airing": False}],
        1045: [{"season_number": 1, "start": 101, "end": None, "total": _TOTAL, "airing": True}],
    }
    for row in client.get("/api/v1/subscriptions").json()["data"]:
        detail = client.get(f"/api/v1/subscriptions/{row['id']}").json()["data"]
        assert detail["episode_windows"] == listed[row["media"]["tmdb_id"]]


def test_window_is_rejected_for_movies_through_the_api(client: TestClient) -> None:
    response = client.post(
        "/api/v1/subscriptions",
        json={"title_ref": "tmdb:movie:77", "episode_caps": {"1": {"start": 1, "end": 5}}},
    )
    assert response.status_code == 400, response.text


def test_list_priority_ignores_the_part_of_a_windowed_season_the_user_did_not_subscribe() -> None:
    """订阅墙排序：只订阅了一段、这段都在库、还在洗版——没订的集不算缺集。"""
    from types import SimpleNamespace

    from movieclaw_api.schemas.subscription import (
        EpisodeWindowView,
        SeasonOverview,
        SubscriptionView,
    )

    def view(windows):
        return SubscriptionView.model_construct(
            status="active",
            selected_seasons=[1],
            media=SimpleNamespace(kind="tv"),
            progress=SimpleNamespace(wanted=0, grabbed=0, downloaded=0, imported=20, upgrading=1),
            season_collection=[
                SeasonOverview(
                    season_number=1,
                    name="第 1 季",
                    air_date=None,
                    episode_count=1043,
                    aired_count=1043,
                    owned_count=20,
                )
            ],
            episode_windows=windows,
        )

    # 没有窗口：库里 20 集对 1043 个已播集是缺集，排在「获取资源」那一档
    assert view(None).list_priority == 0
    # 完结季窗口：订阅范围内齐了，只剩洗版，排在洗版那一档
    assert (
        view([EpisodeWindowView(season_number=1, start=1, end=20, total=1043)]).list_priority == 1
    )
    # 在播窗口：第 1,024 集起的 20 集都在库，同样不算缺集
    assert (
        view([EpisodeWindowView(season_number=1, start=1024, end=None, total=1043)]).list_priority
        == 1
    )
