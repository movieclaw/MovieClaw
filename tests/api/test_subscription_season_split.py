"""issue #1155 端到端：TMDB 合并季条目，站点按 S01/S02 两季发布也要收得到。

夹具用 issue 现场的真实日期：《我独自升级》TMDB 一季 25 集，
E01–E12 周更于 2024-01-07…2024-03-31，E13–E25 隔了 280 天于
2025-01-05…2025-03-30 播出。站点不认这套合并编号，照常拆成
``S01 Complete``（12 集）/ ``S02 Complete``（13 集）发布。

覆盖验收标准（docs/design/subscription-season-split.md）：
1/2/3. 三类种子都覆盖到正确的集，S02 包落进第 1 季的 E13–E25；
4. 活动流水出现 ``SEASON_MAPPED``；
5. 没有映射时出现 ``season_unmapped`` 拒绝，而不是静默无资源；
6. 普通两季剧行为零变化、``season_mapping == []``、无新增活动；
7. 两套编号同时存在时去重只入库一份；
8. 季 0 不受影响。
"""

from __future__ import annotations

import httpx
import pytest_asyncio
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.settings.store import init_setting_store, reset_setting_store
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    ActivityType,
    MediaItem,
    SiteTorrent,
    SubscriptionActivity,
    TorrentSource,
    WantedItem,
    WantedStatus,
)
from movieclaw_db.models.base import utcnow
from movieclaw_matcher.seasons import (
    SeasonBlock,
    derive_season_mapping,
    mapping_to_json,
)
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"

# --- issue #1155 的真实日期 -------------------------------------------------

_SOLO_S1_AIR = [
    "2024-01-07", "2024-01-14", "2024-01-21", "2024-01-28",
    "2024-02-04", "2024-02-11", "2024-02-18", "2024-02-25",
    "2024-03-03", "2024-03-10", "2024-03-17", "2024-03-24", "2024-03-31",
][:12]
_SOLO_S2_AIR = [
    "2025-01-05", "2025-01-12", "2025-01-19", "2025-01-26",
    "2025-02-02", "2025-02-09", "2025-02-16", "2025-02-23",
    "2025-03-02", "2025-03-09", "2025-03-16", "2025-03-23", "2025-03-30",
]


def _solo_episodes() -> list[dict]:
    """TMDB 的 25 集：E01–E12 是 2024 那批，E13–E25 是 2025 那批。"""
    return [
        {"episode_number": index + 1, "name": f"E{index + 1}", "air_date": day}
        for index, day in enumerate(_SOLO_S1_AIR)
    ] + [
        {"episode_number": index + 13, "name": f"E{index + 13}", "air_date": day}
        for index, day in enumerate(_SOLO_S2_AIR)
    ]


_ROUTES = {
    "/3/tv/127532": {
        "id": 127532,
        "name": "我独自升级",
        "original_name": "Solo Leveling",
        "first_air_date": "2024-01-07",
        "status": "Ended",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 0}, {"season_number": 1}],
    },
    "/3/tv/127532/season/0": {
        "name": "特别篇",
        "air_date": "2024-01-01",
        "episodes": [{"episode_number": 1, "name": "SP", "air_date": "2024-01-01"}],
    },
    "/3/tv/127532/season/1": {
        "name": "第 1 季",
        "air_date": "2024-01-07",
        "episodes": _solo_episodes(),
    },
    # 普通两季剧回归夹具：每季 10 集、季内无断档
    "/3/tv/300": {
        "id": 300,
        "name": "普通剧集",
        "original_name": "Plain Show",
        "first_air_date": "2024-01-07",
        "status": "Ended",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 1}, {"season_number": 2}],
    },
    "/3/tv/300/season/1": {
        "name": "第 1 季",
        "air_date": "2024-01-07",
        "episodes": [
            {"episode_number": n, "name": f"E{n}", "air_date": d}
            for n, d in enumerate(
                [f"2024-{m:02d}-{d:02d}" for m in (1, 2, 3) for d in (7, 14, 21, 28)][:10], start=1
            )
        ],
    },
    "/3/tv/300/season/2": {
        "name": "第 2 季",
        "air_date": "2025-04-06",
        "episodes": [
            {"episode_number": n, "name": f"E{n}", "air_date": d}
            for n, d in enumerate(
                [f"2025-{m:02d}-{d:02d}" for m in (4, 5, 6) for d in (6, 13, 20, 27)][:10], start=1
            )
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
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'season-split.db'}")
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
        # 发布日必须晚于最晚一集的播出日，否则整季包的发布时间上限会把这些集剔掉
        publish_time=utcnow(),
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row


async def _wanted(session, sub_id: int) -> dict[tuple[int, int], WantedItem]:
    rows = (
        (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub_id)))
        .scalars()
        .all()
    )
    return {(w.season_number, w.episode_number): w for w in rows}


async def _activities(session, sub_id: int, kind: str | None = None) -> list[SubscriptionActivity]:
    statement = select(SubscriptionActivity).where(SubscriptionActivity.subscription_id == sub_id)
    if kind is not None:
        statement = statement.where(SubscriptionActivity.type == kind)
    return list((await session.execute(statement)).scalars().all())


async def _item(session, tmdb_id: int) -> MediaItem:
    return (
        (await session.execute(select(MediaItem).where(MediaItem.tmdb_id == tmdb_id)))
        .scalars()
        .one()
    )


# ---------------------------------------------------------------------------
# 纯函数：真实日期推出来的映射
# ---------------------------------------------------------------------------


def test_real_dates_derive_two_blocks() -> None:
    """issue 的原始日期：280 天断档 → 站点第 2 季 = TMDB 第 1 季 E13–E25。"""
    from datetime import date

    rows = [
        (1, episode["episode_number"], date.fromisoformat(episode["air_date"]))
        for episode in _solo_episodes()
    ]
    mapping = derive_season_mapping(rows, today=date(2026, 11, 3))
    assert mapping.blocks == (
        SeasonBlock(site_season=1, season=1, start=1, end=12),
        SeasonBlock(site_season=2, season=1, start=13, end=25),
    )
    assert mapping.by_site_season(2).offset == 12
    # 落库只留需要换算的那块：站点 S01 与 TMDB S01 恒等，不含信息
    assert mapping_to_json(mapping) == [{"number": 2, "season": 1, "start": 13, "end": 25}]


# ---------------------------------------------------------------------------
# 建档：映射随条目落库
# ---------------------------------------------------------------------------


async def test_item_carries_the_derived_mapping(db) -> None:
    async with db.session() as session:
        await _service(session).create(MediaKind.TV, 127532, selected_seasons=[1])
        item = await _item(session, 127532)
    # 恒等块（站点 S01 == TMDB S01、从第 1 集起）不进映射；只有真正需要换算的
    # 那一块在，普通剧因此恒为 []
    assert item.season_mapping == [{"number": 2, "season": 1, "start": 13, "end": 25}]


# ---------------------------------------------------------------------------
# 覆盖：三类种子
# ---------------------------------------------------------------------------


async def test_site_season_two_pack_covers_e13_to_e25(db) -> None:
    """验收 1：S02 完整包（13 集）覆盖 E13–E25，且**不**碰 E01–E12。"""
    async with db.session() as session:
        sub = await _service(session).create(MediaKind.TV, 127532, selected_seasons=[1])
        pack = await _torrent(
            session,
            "s02-complete",
            "Solo Leveling 2025 S02 Complete 1080p WEB-DL",
            {"seasons": [2], "complete": True, "episodes_total": 13},
        )
        await evaluate_and_dispatch(session, [pack], source="被动匹配")

        wanted = await _wanted(session, sub.id)
        covered = {
            key for key, row in wanted.items() if row.status != WantedStatus.WANTED
        }
        assert covered == {(1, ep) for ep in range(13, 26)}
        # E01–E12 必须原封不动——保留 pack_seasons={1} 会把它们误标成已覆盖
        assert all(wanted[(1, ep)].status == WantedStatus.WANTED for ep in range(1, 13))


async def test_site_season_two_single_episode_covers_one_unit(db) -> None:
    """单集 S02E01 落到 (1, 13)。"""
    async with db.session() as session:
        sub = await _service(session).create(MediaKind.TV, 127532, selected_seasons=[1])
        single = await _torrent(
            session,
            "s02e01",
            "Solo Leveling S02E01 1080p WEB-DL",
            {"seasons": [2], "episodes": [1]},
        )
        await evaluate_and_dispatch(session, [single], source="被动匹配")

        wanted = await _wanted(session, sub.id)
        assert wanted[(1, 13)].status != WantedStatus.WANTED
        assert sum(1 for r in wanted.values() if r.status != WantedStatus.WANTED) == 1


async def test_site_season_one_rolling_numbers_still_work(db) -> None:
    """顺延编号的 S01E13-25 本来就走原路（今天的"苟活"路径，不能回归）。"""
    async with db.session() as session:
        sub = await _service(session).create(MediaKind.TV, 127532, selected_seasons=[1])
        rolling = await _torrent(
            session,
            "rolling",
            "Solo Leveling S01E13-25 2024 1080p",
            {"seasons": [1], "episodes": list(range(13, 26))},
        )
        await evaluate_and_dispatch(session, [rolling], source="被动匹配")

        wanted = await _wanted(session, sub.id)
        covered = {key for key, row in wanted.items() if row.status != WantedStatus.WANTED}
        assert covered == {(1, ep) for ep in range(13, 26)}


async def test_both_numberings_together_dedupe_to_one_claim(db) -> None:
    """验收 7：两套编号同时存在时去重，同一集只被认领一次。

    选优在同一轮里只挑一个候选投递（整季包优先、同类按评分），另一份不会
    重复认领已投递的单元。
    """
    async with db.session() as session:
        sub = await _service(session).create(MediaKind.TV, 127532, selected_seasons=[1])
        rolling = await _torrent(
            session,
            "rolling",
            "Solo Leveling S01E13-25 2024 1080p",
            {"seasons": [1], "episodes": list(range(13, 26))},
        )
        pack = await _torrent(
            session,
            "s02-complete",
            "Solo Leveling 2025 S02 Complete 1080p WEB-DL",
            {"seasons": [2], "complete": True, "episodes_total": 13},
        )
        summary = await evaluate_and_dispatch(session, [rolling, pack], source="被动匹配")

        # 13 个单元只走一份资源：选优在同一轮里只挑一个候选，另一份不会重复认领
        assert summary.dispatched_units == 13
        assert summary.dispatched_torrents == ["testsite/s02-complete"]
        wanted = await _wanted(session, sub.id)
        claimed = {key for key, row in wanted.items() if row.status != WantedStatus.WANTED}
        assert claimed == {(1, ep) for ep in range(13, 26)}


# ---------------------------------------------------------------------------
# 可见性
# ---------------------------------------------------------------------------


async def test_season_mapped_activity_is_recorded_once(db) -> None:
    """验收 4：归一成功记一条 SEASON_MAPPED，写明对应的 TMDB 集区间。"""
    async with db.session() as session:
        sub = await _service(session).create(MediaKind.TV, 127532, selected_seasons=[1])
        pack = await _torrent(
            session,
            "s02-complete",
            "Solo Leveling 2025 S02 Complete 1080p WEB-DL",
            {"seasons": [2], "complete": True, "episodes_total": 13},
        )
        await evaluate_and_dispatch(session, [pack], source="被动匹配")
        await evaluate_and_dispatch(session, [pack], source="被动匹配")  # 第二轮

        mapped = await _activities(session, sub.id, ActivityType.SEASON_MAPPED)
    assert len(mapped) == 1, "同一种子重复评估不应刷屏"
    assert "第 1 季第 13–25 集" in mapped[0].message
    assert mapped[0].payload["site_seasons"] == [2]
    assert mapped[0].wanted_item_id is None


async def test_unmapped_site_season_is_explained_not_silent(db) -> None:
    """验收 5：没有映射时记一条 season_unmapped 拒绝，而不是静默无资源。"""
    async with db.session() as session:
        sub = await _service(session).create(MediaKind.TV, 127532, selected_seasons=[1])
        # 抹掉映射，模拟 TMDB 未补登记 + 断档不足 90 天识别不出来的情形
        item = await _item(session, 127532)
        item.season_mapping = []
        session.add(item)
        await session.commit()

        pack = await _torrent(
            session,
            "s02-complete",
            "Solo Leveling 2025 S02 Complete 1080p WEB-DL",
            {"seasons": [2], "complete": True},
        )
        await evaluate_and_dispatch(session, [pack], source="被动匹配")

        rejected = await _activities(session, sub.id, ActivityType.MATCH_REJECTED)
    assert len(rejected) == 1
    assert rejected[0].payload["reason_code"] == "season_unmapped"
    assert rejected[0].payload["site_seasons"] == [2]
    assert "S02" in rejected[0].message and "S01" in rejected[0].message


async def test_pack_with_no_wanted_episodes_stays_silent(db) -> None:
    """日常情况（包里没有我要的集）保持静默：不写任何新活动类型。"""
    async with db.session() as session:
        sub = await _service(session).create(MediaKind.TV, 127532, selected_seasons=[1])
        # 先把 E13–E25 全部标记已收，再喂同一个 S02 包：覆盖为空、季号也读得懂
        for row in (await _wanted(session, sub.id)).values():
            if row.episode_number >= 13:
                row.status = WantedStatus.IMPORTED
                session.add(row)
        await session.commit()

        pack = await _torrent(
            session,
            "s02-complete",
            "Solo Leveling 2025 S02 Complete 1080p WEB-DL",
            {"seasons": [2], "complete": True},
        )
        await evaluate_and_dispatch(session, [pack], source="被动匹配")

        rejected = await _activities(session, sub.id, ActivityType.MATCH_REJECTED)
        mapped = await _activities(session, sub.id, ActivityType.SEASON_MAPPED)
    assert rejected == [] and mapped == []


# ---------------------------------------------------------------------------
# 普通剧零影响
# ---------------------------------------------------------------------------


async def test_plain_two_season_show_is_unchanged(db) -> None:
    """验收 6：普通两季剧的映射为空、匹配照旧、无任何新增活动。"""
    async with db.session() as session:
        sub = await _service(session).create(MediaKind.TV, 300, selected_seasons=[1, 2])
        item = await _item(session, 300)
        assert item.season_mapping is not None and item.season_mapping == []

        pack = await _torrent(
            session,
            "plain-s02",
            "Plain Show S02 Complete 1080p WEB-DL",
            {"seasons": [2], "complete": True},
        )
        await evaluate_and_dispatch(session, [pack], source="被动匹配")

        wanted = await _wanted(session, sub.id)
        covered = {key for key, row in wanted.items() if row.status != WantedStatus.WANTED}
        assert covered == {(2, ep) for ep in range(1, 11)}
        assert await _activities(session, sub.id, ActivityType.SEASON_MAPPED) == []
        assert await _activities(session, sub.id, ActivityType.MATCH_REJECTED) == []


async def test_mapping_does_not_touch_season_zero(db) -> None:
    """验收 8：特别篇（季 0）不受映射影响，也不参与推导。"""
    async with db.session() as session:
        await _service(session).create(MediaKind.TV, 127532, selected_seasons=[0, 1])
        item = await _item(session, 127532)
    assert all(entry["season"] == 1 for entry in item.season_mapping)


# ---------------------------------------------------------------------------
# 分集区标注
# ---------------------------------------------------------------------------


async def test_episode_list_marks_the_site_season_boundary(db, tmp_path) -> None:
    """验收 3：分集区在第 12 集与第 13 集之间给出「站点按第 2 季发布」。"""
    from movieclaw_api.api.routes.libraries import list_item_episodes
    from movieclaw_db.models import LibraryFile
    from movieclaw_db.repositories.library_repo import LibraryRepository

    root = tmp_path / "media" / "tv"
    root.mkdir(parents=True)

    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=[str(root)]
        )
        await _service(session).create(MediaKind.TV, 127532, selected_seasons=[1])
        item = await _item(session, 127532)
        item_id = item.id
        # 直接落台账行（本用例只测标注，省掉磁盘与扫描）
        for episode in (12, 13):
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=item_id,
                    season_number=1,
                    episode_number=episode,
                    file_path=str(root / f"我独自升级.S01E{episode:02d}.1080p.mkv"),
                    size_bytes=1,
                    source="scanned",
                )
            )
        await session.commit()
        library_id = library.id

    async with db.session() as session:
        response = await list_item_episodes(library_id, item_id, 1, _admin(), session)
        episodes = {e.episode_number: e for e in response.data.episodes}

    assert episodes[12].site_season_note is None
    assert episodes[13].site_season_note is not None
    assert "第 2 季" in episodes[13].site_season_note
    # 一条说明管一整段：后面的集不再重复挂
    assert all(e.site_season_note is None for number, e in episodes.items() if number != 13)


def _admin():
    return Principal(kind="admin", name="tester")
