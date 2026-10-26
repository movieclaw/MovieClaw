"""订阅手动干预（P5 落地）：立即搜索 search_now 与手动选种 grab_manual。

全程 dry-run 投递（同 test_subscription_pipeline）：只测语义与状态机，
不连站点与下载器。夹具剧集同 test_subscription_service。
"""

from __future__ import annotations

from datetime import datetime, timedelta

import httpx
import pytest
import pytest_asyncio
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.rule_sets import RuleSetService
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_api.services.subscription.manual_grab import grab_manual
from movieclaw_api.services.subscription.matching import FUTURE_GRACE, publish_calendar_date
from movieclaw_api.services.subscription.wanted_search import _postpone_open_wanted
from movieclaw_api.settings.store import init_setting_store, reset_setting_store
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import SubscriptionActivity, WantedItem, WantedStatus
from movieclaw_db.models.base import utcnow
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"

_TODAY = utcnow().date()
_AIRED = (_TODAY - timedelta(days=10)).isoformat()
_YESTERDAY = (_TODAY - timedelta(days=1)).isoformat()
_FUTURE = (_TODAY + timedelta(days=10)).isoformat()

_ROUTES = {
    "/3/movie/300": {
        "id": 300,
        "title": "未上映电影",
        "original_title": "Upcoming Movie",
        "release_date": (_TODAY + timedelta(days=30)).isoformat(),
        "status": "Post Production",
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
    },
    "/3/movie/301": {
        "id": 301,
        "title": "未定档电影",
        "original_title": "Undated Movie",
        "release_date": "",
        "status": "In Production",
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
    },
    "/3/tv/200": {
        "id": 200,
        "name": "测试剧集",
        "original_name": "Test Show",
        "first_air_date": "2024-01-01",
        "status": "Returning Series",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 1}, {"season_number": 2}],
    },
    "/3/tv/200/season/1": {
        "name": "第 1 季",
        "air_date": "2024-01-01",
        "episodes": [
            {"episode_number": 1, "name": "E1", "air_date": _AIRED},
            {"episode_number": 2, "name": "E2", "air_date": _AIRED},
        ],
    },
    "/3/tv/200/season/2": {
        "name": "第 2 季",
        "air_date": _YESTERDAY,
        "episodes": [
            {"episode_number": 1, "name": "E1", "air_date": _YESTERDAY},
            {"episode_number": 2, "name": "E2", "air_date": _FUTURE},
            {"episode_number": 3, "name": "E3", "air_date": None},
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
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'manual.db'}")
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


async def _wanted_map(session, sub_id: int) -> dict[tuple[int, int], WantedItem]:
    rows = (
        (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub_id)))
        .scalars()
        .all()
    )
    return {(w.season_number, w.episode_number): w for w in rows}


# ---------------------------------------------------------------------------
# 立即搜索
# ---------------------------------------------------------------------------


async def test_search_now_resets_cooldown_and_logs(db) -> None:
    """冷却中的缺口清零到当下；未定档/待播出的不碰；落一条可读活动。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 200, selected_seasons=[1, 2])

        # 人为把已播缺口推进冷却（模拟搜索无果后的退避）
        far = utcnow() + timedelta(hours=6)
        wanted = await _wanted_map(session, sub.id)
        for key in [(1, 1), (1, 2), (2, 1)]:
            wanted[key].next_search_at = far
            session.add(wanted[key])
        await session.commit()

        reset = await service.search_now(sub.id)
        assert reset == 3  # 已播的三集；E2 待播出、E3 未定档不在其列

        now = utcnow()
        wanted = await _wanted_map(session, sub.id)
        for key in [(1, 1), (1, 2), (2, 1)]:
            assert wanted[key].next_search_at is not None
            assert wanted[key].next_search_at <= now
        assert wanted[(2, 2)].next_search_at is not None  # 待播出：档期保留
        assert wanted[(2, 2)].next_search_at > now
        assert wanted[(2, 3)].next_search_at is None  # 未定档：保持不可调度

        acts = (
            (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == sub.id
                    )
                )
            )
            .scalars()
            .all()
        )
        assert any("立即搜索" in a.message for a in acts)


async def test_search_now_forces_movie_regardless_of_release(db) -> None:
    """电影不受"未上映/未定档不搜"限制：用户强制触发就是"我现在就要搜一次"。"""
    async with db.session() as session:
        service = _service(session)

        # 未上映（调度排在上映+宽限）：强制后清零到当下
        upcoming = await service.create(MediaKind.MOVIE, 300)
        w = list((await _wanted_map(session, upcoming.id)).values())[0]
        assert w.next_search_at is not None and w.next_search_at > utcnow()
        assert await service.search_now(upcoming.id) == 1
        w = list((await _wanted_map(session, upcoming.id)).values())[0]
        assert w.next_search_at is not None and w.next_search_at <= utcnow()

        # 未定档（不可调度 NULL）：同样可以强制
        undated = await service.create(MediaKind.MOVIE, 301)
        w = list((await _wanted_map(session, undated.id)).values())[0]
        assert w.next_search_at is None
        assert await service.search_now(undated.id) == 1
        w = list((await _wanted_map(session, undated.id)).values())[0]
        assert w.next_search_at is not None and w.next_search_at <= utcnow()


async def test_search_now_rejects_paused_and_empty(db) -> None:
    """暂停中拒绝；没有可搜缺口（全在途/待播）也给可读错误。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 200, selected_seasons=[1])

        await service.set_paused(sub.id, True)
        with pytest.raises(BadRequestException, match="已暂停"):
            await service.search_now(sub.id)
        await service.set_paused(sub.id, False)

        # 把全部缺口置为在途 → 无可搜项
        wanted = await _wanted_map(session, sub.id)
        for w in wanted.values():
            w.status = WantedStatus.GRABBED
            session.add(w)
        await session.commit()
        with pytest.raises(BadRequestException, match="没有可立即搜索的缺口"):
            await service.search_now(sub.id)


async def test_search_now_includes_episode_airing_within_early_tolerance(db) -> None:
    """issue #1044：记录播出日就在一两天内的待播集，平台常已提前首发——
    立即搜索要真搜它；远期待播集与未定档集照旧不碰。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 200, selected_seasons=[2])
        wanted = await _wanted_map(session, sub.id)
        # E2 记录明天播出、档期排在"播出 + 宽限"；E1 已播的先推进冷却
        tomorrow = publish_calendar_date(utcnow()) + timedelta(days=1)
        wanted[(2, 2)].air_date = tomorrow
        wanted[(2, 2)].next_search_at = utcnow() + timedelta(days=3)
        session.add(wanted[(2, 2)])
        await session.commit()

        assert await service.search_now(sub.id) == 2  # E1 已播 + E2 明天播
        wanted = await _wanted_map(session, sub.id)
        assert wanted[(2, 2)].next_search_at <= utcnow()
        assert wanted[(2, 3)].next_search_at is None  # 未定档：保持不可调度

        # 远期集（10 天后）仍跳过
        wanted[(2, 2)].air_date = publish_calendar_date(utcnow()) + timedelta(days=10)
        wanted[(2, 2)].next_search_at = utcnow() + timedelta(days=12)
        session.add(wanted[(2, 2)])
        await session.commit()
        assert await service.search_now(sub.id) == 1


async def test_early_search_miss_restores_air_schedule(db) -> None:
    """立即搜索没找到提前首发的资源时，档期回到"播出 + 宽限"，
    不按退避曲线（15 分钟起）在播出前反复空搜。已播集照常退避。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 200, selected_seasons=[2])
        sub_id = sub.id
        wanted = await _wanted_map(session, sub_id)
        tomorrow = publish_calendar_date(utcnow()) + timedelta(days=1)
        wanted[(2, 2)].air_date = tomorrow
        media_id = wanted[(2, 2)].media_item_id
        session.add(wanted[(2, 2)])
        await session.commit()
        await service.search_now(sub_id)
        await session.commit()

        postponed = await _postpone_open_wanted(session, media_id, delay=None, count_attempt=True)
        await session.commit()
        assert postponed == 2

        session.expire_all()
        wanted = await _wanted_map(session, sub_id)
        planned = datetime.combine(tomorrow, datetime.min.time()) + FUTURE_GRACE
        assert wanted[(2, 2)].next_search_at == planned
        aired = wanted[(2, 1)].next_search_at
        assert aired is not None and aired < utcnow() + timedelta(hours=1)  # 已播：退避


# ---------------------------------------------------------------------------
# 手动选种
# ---------------------------------------------------------------------------


async def test_grab_manual_bypasses_rules_and_dispatches(db) -> None:
    """手动选种跳过规则组（零做种、低分辨率照样投），身份/覆盖照常判定。"""
    async with db.session() as session:
        service = _service(session)
        # 严苛规则组：正常管线必拒（2160p + 做种 ≥5）；手动通道应无视它
        strict = await RuleSetService(session).create(
            "严苛", {"resolutions": ["2160p"], "min_seeders": 5}
        )
        sub = await service.create(MediaKind.TV, 200, selected_seasons=[1], rule_set_id=strict.id)

        covered = await grab_manual(
            session,
            sub.id,
            site_id="testsite",
            torrent_id="m1",
            title="Test Show S01E01 720p WEB-DL x264-GRP",
            subtitle="测试剧集 第一季第1集",
            category="tv",
            # attrs 回传搜索结果的解析（测试环境无 NER 模型，enrich 兜底路径
            # 抽不出片名/季集——生产由前端带回，这里等价模拟）
            attrs={
                "media_type": "tv",
                "title": "Test Show",
                "seasons": [1],
                "episodes": [1],
                "resolution": "720p",
            },
            download_url="magnet:?xt=urn:btih:aa",
            seeders=0,
        )
        assert [(w.season_number, w.episode_number) for w in covered] == [(1, 1)]

        wanted = await _wanted_map(session, sub.id)
        assert wanted[(1, 1)].status == WantedStatus.GRABBED
        assert wanted[(1, 2)].status == WantedStatus.WANTED  # 未覆盖的单元不动

        acts = (
            (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == sub.id
                    )
                )
            )
            .scalars()
            .all()
        )
        grabbed = [a for a in acts if a.type == "grabbed"]
        assert grabbed and grabbed[0].payload.get("source") == "手动选种"


async def test_grab_manual_rejects_identity_mismatch(db) -> None:
    """身份对不上（别的剧）→ 可读中文错误，工单不动。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 200, selected_seasons=[1])
        with pytest.raises(BadRequestException, match="无法确认"):
            await grab_manual(
                session,
                sub.id,
                site_id="testsite",
                torrent_id="m2",
                title="Another Series S01E01 1080p WEB-DL",
                category="tv",
                attrs={
                    "media_type": "tv",
                    "title": "Another Series",
                    "seasons": [1],
                    "episodes": [1],
                },
            )
        wanted = await _wanted_map(session, sub.id)
        assert all(w.status == WantedStatus.WANTED for w in wanted.values())


async def test_grab_manual_malformed_attrs_falls_back_to_enrich(db) -> None:
    """前端回传的 attrs 结构不合法 → 不抛 pydantic ValidationError（500），
    而是退回服务端 enrich 重新推导；标题本身可识别（别名 + SxxEyy），
    兜底路径照样完成投递。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 200, selected_seasons=[1])
        covered = await grab_manual(
            session,
            sub.id,
            site_id="testsite",
            torrent_id="m4",
            title="Test Show S01E01 1080p WEB-DL x264-GRP",
            category="tv",
            # seasons/episodes 传成非法类型：TorrentAttrs 校验必失败
            attrs={"media_type": "tv", "seasons": "第一季", "episodes": {"bad": 1}},
        )
        assert [(w.season_number, w.episode_number) for w in covered] == [(1, 1)]
        wanted = await _wanted_map(session, sub.id)
        assert wanted[(1, 1)].status == WantedStatus.GRABBED


async def test_grab_manual_rejects_uncovered_unit(db) -> None:
    """身份命中但集号不在缺口里（该集已 GRABBED）→ 报"没有可满足的追踪项"。"""
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(MediaKind.TV, 200, selected_seasons=[1])
        wanted = await _wanted_map(session, sub.id)
        wanted[(1, 1)].status = WantedStatus.GRABBED
        session.add(wanted[(1, 1)])
        await session.commit()

        with pytest.raises(BadRequestException, match="没有可满足的追踪项"):
            await grab_manual(
                session,
                sub.id,
                site_id="testsite",
                torrent_id="m3",
                title="Test Show S01E01 1080p WEB-DL x264-GRP",
                category="tv",
                attrs={
                    "media_type": "tv",
                    "title": "Test Show",
                    "seasons": [1],
                    "episodes": [1],
                },
            )
