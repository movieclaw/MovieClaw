"""投递救援巡检的内容核验测试：种子完成但承诺集数不在文件清单 → 缺失部分退回。

覆盖三层：
- ``_observed_units`` 纯函数（场景命名解析：连写/区间/认不出）；
- ``covered_units`` 的特别篇口径（全集包不承诺 season 0 的具体集）；
- ``_rescue_group`` 完成分支的端到端语义（缺失退回/存在不动/证据不足不动/
  电影不判/宽限期内不判）。下载器查询一律打桩，落点用真实临时目录。
"""

from __future__ import annotations

from datetime import date, timedelta

import httpx
import pytest
import pytest_asyncio
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import download_progress
from movieclaw_api.services.download_progress import _observed_units, _rescue_group
from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_api.services.subscription.matching import covered_units
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    ActivityType,
    DownloadAttemptStatus,
    SubscriptionActivity,
    SubscriptionDownloadAttempt,
    WantedItem,
    WantedStatus,
)
from movieclaw_db.models.base import utcnow
from movieclaw_downloader import TorrentStatus
from movieclaw_downloader.models import TorrentFile
from movieclaw_matcher.models import IdentityMatch
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"
_HASH = "59e5ba444a1fdc482c0e090764436cfc89f9691d"

_TODAY = utcnow().date()
_AIRED = (_TODAY - timedelta(days=30)).isoformat()

# 夹具剧集：S0 特别篇两集 + S1 正剧两集，全部已播
_ROUTES = {
    "/3/tv/300": {
        "id": 300,
        "name": "测试剧集",
        "original_name": "Test Show",
        "first_air_date": "2024-01-01",
        "status": "Returning Series",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 0}, {"season_number": 1}],
    },
    "/3/tv/300/season/0": {
        "name": "特别篇",
        "air_date": _AIRED,
        "episodes": [
            {"episode_number": 1, "name": "SP1", "air_date": _AIRED},
            {"episode_number": 2, "name": "SP2", "air_date": _AIRED},
        ],
    },
    "/3/tv/300/season/1": {
        "name": "第 1 季",
        "air_date": _AIRED,
        "episodes": [
            {"episode_number": 1, "name": "E1", "air_date": _AIRED},
            {"episode_number": 2, "name": "E2", "air_date": _AIRED},
        ],
    },
    "/3/movie/100": {
        "id": 100,
        "title": "测试电影",
        "original_title": "Test Movie",
        "release_date": _AIRED,
        "status": "Released",
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
    },
}


def _fake_tmdb() -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        payload = _ROUTES.get(request.url.path)
        return httpx.Response(200 if payload else 404, json=payload or {})

    return TmdbClient(_KEY, transport=httpx.MockTransport(handler))


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'rescue.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


class _FakeDownloaderRow:
    name = "测试下载器"
    path_mappings = None


async def _grabbed_subscription(session, kind: MediaKind, tmdb_id: int, **kw) -> int:
    """建订阅并把全部工单置为在途（GRABBED + info_hash + 已过宽限期）。"""
    service = SubscriptionService(session, MediaLibraryService(session, _fake_tmdb()))
    subscription = await service.create(kind, tmdb_id, **kw)
    assert subscription.id is not None
    rows = (
        (
            await session.execute(
                select(WantedItem).where(WantedItem.subscription_id == subscription.id)
            )
        )
        .scalars()
        .all()
    )
    assert rows
    aged = utcnow() - timedelta(minutes=25)
    for row in rows:
        row.status = WantedStatus.GRABBED
        row.info_hash = _HASH
        row.grabbed_at = aged
        session.add(row)
    await session.commit()
    return subscription.id


def _completed_status(
    tmp_path, file_paths: list[str], name: str = "Test.Show.Pack"
) -> TorrentStatus:
    """已完成种子：落点指向真实临时目录（内容根实际建出，落点核验通过）。"""
    root = file_paths[0].split("/")[0] if file_paths else name
    (tmp_path / root).mkdir(parents=True, exist_ok=True)
    return TorrentStatus(
        info_hash=_HASH,
        name=name,
        progress=1.0,
        completed=True,
        save_path=str(tmp_path),
        files=[TorrentFile(path=p, size_bytes=1) for p in file_paths],
        state="completed",
    )


def _stub_query(monkeypatch, status: TorrentStatus) -> None:
    async def fake_query(info_hash, downloaders, *, include_files=True):
        return _FakeDownloaderRow(), status

    monkeypatch.setattr(download_progress, "_query_torrent", fake_query)


async def _wanted_map(session, sub_id: int) -> dict[tuple[int, int], WantedItem]:
    rows = (
        (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub_id)))
        .scalars()
        .all()
    )
    return {(w.season_number, w.episode_number): w for w in rows}


async def _dispatch_failed(session, sub_id: int) -> list[SubscriptionActivity]:
    rows = (
        (
            await session.execute(
                select(SubscriptionActivity).where(
                    SubscriptionActivity.subscription_id == sub_id,
                    SubscriptionActivity.type == ActivityType.DISPATCH_FAILED,
                )
            )
        )
        .scalars()
        .all()
    )
    return list(rows)


# ---------------------------------------------------------------------------
# _observed_units：场景命名解析
# ---------------------------------------------------------------------------


def _files(*paths: str) -> list[TorrentFile]:
    return [TorrentFile(path=p, size_bytes=1) for p in paths]


def test_observed_units_scene_naming() -> None:
    """常规 SxxEyy（大小写皆可）逐文件解析。"""
    observed = _observed_units(
        _files(
            "Show/Show.S01E01.1080p.WEB-DL.mkv",
            "Show/show.s01e02.1080p.web-dl.mkv",
            "Show/Show.S02E01.mkv",
        )
    )
    assert observed == {(1, 1), (1, 2), (2, 1)}


def test_observed_units_multi_episode_and_range() -> None:
    """连写按列举，恰好两个递增集号按区间展开。"""
    assert _observed_units(_files("Show.S01E05E06.mkv")) == {(1, 5), (1, 6)}
    assert _observed_units(_files("Show.S01E05-E08.mkv")) == {(1, 5), (1, 6), (1, 7), (1, 8)}


def test_observed_units_ignores_unselected_files() -> None:
    """下载器里没勾选的文件永远不会落盘，不能算「清单里有」。"""
    files = [
        TorrentFile(path="Pack/Show.S01E001.mkv", size_bytes=1, selected=False),
        TorrentFile(path="Pack/Show.S01E204.mkv", size_bytes=1, selected=True),
    ]
    assert _observed_units(files) == {(1, 204)}


def test_observed_units_unrecognized_is_empty() -> None:
    """认不出集数（原盘结构/裸名）返回空集——调用方据此保守不动。"""
    assert _observed_units(_files("BDMV/STREAM/00001.m2ts", "Movie.2020.1080p.mkv")) == set()


# ---------------------------------------------------------------------------
# covered_units：全集包不承诺特别篇
# ---------------------------------------------------------------------------


def _wanted(season: int, episode: int) -> WantedItem:
    return WantedItem(
        subscription_id=1,
        media_item_id=1,
        season_number=season,
        episode_number=episode,
        air_date=date(2020, 1, 1),
    )


def test_complete_series_skips_specials() -> None:
    """全集包展开覆盖正剧与电影正片，但不覆盖特别篇的具体集。"""
    open_units = {
        (0, 1): _wanted(0, 1),  # 特别篇：不该被承诺
        (1, 1): _wanted(1, 1),  # 正剧：照常覆盖
    }
    covered = covered_units(IdentityMatch(is_complete_series=True), open_units, published=_TODAY)
    assert [(w.season_number, w.episode_number) for w in covered] == [(1, 1)]


def test_complete_series_still_covers_movie_unit() -> None:
    """电影单元 (0, 0) 不是特别篇，全集包语义保持原状。"""
    open_units = {(0, 0): _wanted(0, 0)}
    covered = covered_units(IdentityMatch(is_complete_series=True), open_units, published=_TODAY)
    assert len(covered) == 1


def test_explicit_special_episode_still_covered() -> None:
    """标题显式声明的特别篇集号（episodes 通道）不受全集包口径影响。"""
    open_units = {(0, 1): _wanted(0, 1)}
    covered = covered_units(
        IdentityMatch(episodes=frozenset({(0, 1)})), open_units, published=_TODAY
    )
    assert len(covered) == 1


def _dated(season: int, episode: int, air: date) -> WantedItem:
    return WantedItem(
        subscription_id=1,
        media_item_id=1,
        season_number=season,
        episode_number=episode,
        air_date=air,
    )


def test_explicit_episode_tolerates_early_release() -> None:
    """issue #1044：标题明确写了 S01E15 的单集，比记录播出日早一两天发布照样覆盖；
    早三天以上更像集号错配/远期集，仍剔除。"""
    published = date(2026, 10, 26)
    for days, expected in [(0, True), (1, True), (2, True), (3, False)]:
        open_units = {(1, 15): _dated(1, 15, published + timedelta(days=days))}
        covered = covered_units(
            IdentityMatch(episodes=frozenset({(1, 15)})), open_units, published=published
        )
        assert bool(covered) is expected, days


def test_season_pack_gets_no_early_release_tolerance() -> None:
    """整季包展开不享受提前容错：不拿它批量承诺明天才播的集。"""
    published = date(2026, 10, 26)
    open_units = {
        (1, 14): _dated(1, 14, published),
        (1, 15): _dated(1, 15, published + timedelta(days=1)),
    }
    covered = covered_units(
        IdentityMatch(pack_seasons=frozenset({1})), open_units, published=published
    )
    assert [(w.season_number, w.episode_number) for w in covered] == [(1, 14)]


# ---------------------------------------------------------------------------
# _rescue_group 完成分支：内容核验端到端
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_missing_episodes_requeued(db, tmp_path, monkeypatch) -> None:
    """真实教训回归：全集包声明覆盖特别篇但内容里没有——缺失集退回 wanted
    （info_hash 清空、冷却后重找），清单里存在的集保持在途等对账。"""
    async with db.session() as session:
        sub_id = await _grabbed_subscription(session, MediaKind.TV, 300, selected_seasons=[0, 1])
    _stub_query(
        monkeypatch,
        _completed_status(tmp_path, ["Show/Show.S01E01.mkv", "Show/Show.S01E02.mkv"]),
    )
    await _rescue_group(sub_id, _HASH, [(object(), object())])

    async with db.session() as session:
        wanted = await _wanted_map(session, sub_id)
        assert wanted[(0, 1)].status == WantedStatus.WANTED
        assert wanted[(0, 2)].status == WantedStatus.WANTED
        assert wanted[(0, 1)].info_hash is None
        assert wanted[(0, 1)].next_search_at is not None
        assert wanted[(1, 1)].status == WantedStatus.GRABBED
        assert wanted[(1, 2)].status == WantedStatus.GRABBED
        activities = await _dispatch_failed(session, sub_id)
        assert len(activities) == 1
        assert activities[0].payload["reason"] == "content_missing"
        assert "S00E01" in activities[0].message


@pytest.mark.asyncio
async def test_unselected_files_in_pack_are_requeued(db, tmp_path, monkeypatch) -> None:
    """NAS 实例回归：全集包列出了所有集，但下载器里只勾了一部分——没勾的集
    不会下载，必须退回重找，而不是以 grabbed 永远「等待入库」。"""
    async with db.session() as session:
        sub_id = await _grabbed_subscription(session, MediaKind.TV, 300, selected_seasons=[0, 1])
    status = _completed_status(
        tmp_path,
        [
            "Show/Show.S00E01.mkv",
            "Show/Show.S00E02.mkv",
            "Show/Show.S01E01.mkv",
            "Show/Show.S01E02.mkv",
        ],
    )
    # 只勾了第一季两集（特别篇两集列在清单里但未选中）
    status.files = [
        f.model_copy(update={"selected": "S01" in f.path}) for f in status.files
    ]
    _stub_query(monkeypatch, status)
    await _rescue_group(sub_id, _HASH, [(object(), object())])

    async with db.session() as session:
        wanted = await _wanted_map(session, sub_id)
        assert wanted[(0, 1)].status == WantedStatus.WANTED
        assert wanted[(0, 2)].status == WantedStatus.WANTED
        assert wanted[(1, 1)].status == WantedStatus.GRABBED
        assert wanted[(1, 2)].status == WantedStatus.GRABBED


@pytest.mark.asyncio
async def test_all_episodes_present_untouched(db, tmp_path, monkeypatch) -> None:
    """承诺的集数都在清单里：不退回，继续等库存对账正常关单。"""
    async with db.session() as session:
        sub_id = await _grabbed_subscription(session, MediaKind.TV, 300, selected_seasons=[0, 1])
    _stub_query(
        monkeypatch,
        _completed_status(
            tmp_path,
            [
                "Show/Show.S00E01.mkv",
                "Show/Show.S00E02.mkv",
                "Show/Show.S01E01.mkv",
                "Show/Show.S01E02.mkv",
            ],
        ),
    )
    await _rescue_group(sub_id, _HASH, [(object(), object())])

    async with db.session() as session:
        wanted = await _wanted_map(session, sub_id)
        assert all(w.status == WantedStatus.GRABBED for w in wanted.values())
        assert await _dispatch_failed(session, sub_id) == []


@pytest.mark.asyncio
async def test_unrecognized_filenames_untouched(db, tmp_path, monkeypatch) -> None:
    """清单一个集数都认不出（原盘目录）：证据不足，保守不动。"""
    async with db.session() as session:
        sub_id = await _grabbed_subscription(session, MediaKind.TV, 300, selected_seasons=[0, 1])
    _stub_query(
        monkeypatch,
        _completed_status(tmp_path, ["Show/BDMV/STREAM/00001.m2ts"], name="Show"),
    )
    await _rescue_group(sub_id, _HASH, [(object(), object())])

    async with db.session() as session:
        wanted = await _wanted_map(session, sub_id)
        assert all(w.status == WantedStatus.GRABBED for w in wanted.values())


@pytest.mark.asyncio
async def test_movie_units_never_judged(db, tmp_path, monkeypatch) -> None:
    """电影单元没有集号语义：即便清单里认得出别的集数也不判。"""
    async with db.session() as session:
        sub_id = await _grabbed_subscription(session, MediaKind.MOVIE, 100)
    _stub_query(
        monkeypatch,
        _completed_status(tmp_path, ["Bonus/Some.Show.S01E01.mkv"]),
    )
    await _rescue_group(sub_id, _HASH, [(object(), object())])

    async with db.session() as session:
        wanted = await _wanted_map(session, sub_id)
        assert all(w.status == WantedStatus.GRABBED for w in wanted.values())


@pytest.mark.asyncio
async def test_grace_period_defers_judgement(db, tmp_path, monkeypatch) -> None:
    """宽限期内（刚完成）不判：种子可能还在归位，下一轮再看。"""
    async with db.session() as session:
        sub_id = await _grabbed_subscription(session, MediaKind.TV, 300, selected_seasons=[0, 1])
        rows = (
            (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub_id)))
            .scalars()
            .all()
        )
        for row in rows:
            row.grabbed_at = utcnow()
            session.add(row)
        await session.commit()
    _stub_query(
        monkeypatch,
        _completed_status(tmp_path, ["Show/Show.S01E01.mkv"]),
    )
    await _rescue_group(sub_id, _HASH, [(object(), object())])

    async with db.session() as session:
        wanted = await _wanted_map(session, sub_id)
        assert all(w.status == WantedStatus.GRABBED for w in wanted.values())


@pytest.mark.asyncio
async def test_missing_episodes_recorded_on_attempt(db, tmp_path, monkeypatch) -> None:
    """真实教训回归：只退回工单不够——下一轮搜索会再次选中同一个种子（它还在
    下载器里且已完成），秒完成 → 再核验 → 再退回，无限循环。缺失结论必须写进
    台账的负面记忆，来源含历次投递过这份内容的站点条目。"""
    async with db.session() as session:
        sub_id = await _grabbed_subscription(session, MediaKind.TV, 300, selected_seasons=[0, 1])
        session.add(
            SubscriptionDownloadAttempt(
                subscription_id=sub_id,
                info_hash=_HASH,
                site_id="ssd",
                torrent_id="302480",
                units=[[0, 1], [0, 2], [1, 1], [1, 2]],
                last_progress_at=utcnow(),
                status=DownloadAttemptStatus.COMPLETED,
            )
        )
        # 同一份内容也曾从别的站点投递过：跨站镜像同样要进排除清单
        session.add(
            SubscriptionActivity(
                subscription_id=sub_id,
                type=ActivityType.GRABBED,
                message="已投递",
                payload={"info_hash": _HASH, "site_id": "chdbits", "torrent_id": "126352"},
            )
        )
        await session.commit()
    _stub_query(
        monkeypatch,
        _completed_status(tmp_path, ["Show/Show.S01E01.mkv", "Show/Show.S01E02.mkv"]),
    )
    await _rescue_group(sub_id, _HASH, [(object(), object())])

    async with db.session() as session:
        attempt = (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.subscription_id == sub_id
                )
            )
        ).scalar_one()
        assert attempt.content_missing["units"] == [[0, 1], [0, 2]]
        assert attempt.content_missing["sources"] == [
            ["chdbits", "126352"],
            ["ssd", "302480"],
        ]


@pytest.mark.asyncio
async def test_empty_file_list_untouched(db, tmp_path, monkeypatch) -> None:
    """旧适配器不上报文件清单：无证据，保守不动。"""
    async with db.session() as session:
        sub_id = await _grabbed_subscription(session, MediaKind.TV, 300, selected_seasons=[0, 1])
    _stub_query(monkeypatch, _completed_status(tmp_path, [], name="Show"))
    await _rescue_group(sub_id, _HASH, [(object(), object())])

    async with db.session() as session:
        wanted = await _wanted_map(session, sub_id)
        assert all(w.status == WantedStatus.GRABBED for w in wanted.values())
