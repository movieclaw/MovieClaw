"""issue #1224：跨季绝对集号从候选详情到订阅认领的真实流程。"""

from __future__ import annotations

from types import SimpleNamespace

import httpx
import pytest
import pytest_asyncio
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.library.layout import explicit_unit
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
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"

_ROUTES = {
    "/3/tv/1224": {
        "id": 1224,
        "name": "绝对号长番",
        "original_name": "Absolute Show",
        "first_air_date": "2024-01-01",
        "status": "Ended",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": number} for number in (1, 2, 3)],
    },
    "/3/tv/1224/season/1": {
        "name": "第 1 季",
        "air_date": "2024-01-01",
        "episodes": [
            {"episode_number": 1, "name": "E1", "air_date": "2024-01-01"},
            {"episode_number": 2, "name": "E2", "air_date": "2024-01-08"},
        ],
    },
    "/3/tv/1224/season/2": {
        "name": "第 2 季",
        "air_date": "2024-02-01",
        "episodes": [
            {"episode_number": 3, "name": "E3", "air_date": "2024-02-01"},
            {"episode_number": 4, "name": "E4", "air_date": "2024-02-08"},
        ],
    },
    "/3/tv/1224/season/3": {
        "name": "第 3 季",
        "air_date": "2024-03-01",
        "episodes": [
            {"episode_number": 5, "name": "E5", "air_date": "2024-03-01"},
            {"episode_number": 6, "name": "E6", "air_date": "2024-03-08"},
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
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'absolute.db'}")
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "true")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    init_setting_store()
    yield get_database()
    reset_setting_store()
    await dispose_db()
    get_settings.cache_clear()


async def _setup(
    session, *, selected_seasons: list[int] | None = None
) -> tuple[int, SiteTorrent]:
    service = SubscriptionService(session, MediaLibraryService(session, _fake_tmdb()))
    subscription = await service.create(
        MediaKind.TV, 1224, selected_seasons=selected_seasons or [1, 3]
    )
    torrent = SiteTorrent(
        site_id="adweb",
        torrent_id="episode-5",
        title="Absolute.Show.S01.2024.1080p.WEB-DL-ADWeb",
        subtitle="",
        attrs={"media_type": "tv", "seasons": [1], "resolution": "1080p"},
        enrich_version=1,
        source=TorrentSource.LIST,
        seeders=10,
        size_bytes=1_400_000_000,
        download_volume_factor=0.0,
        is_free=True,
        publish_time=utcnow(),
    )
    session.add(torrent)
    await session.commit()
    await session.refresh(torrent)
    assert subscription.id is not None
    return subscription.id, torrent


def _install_detail(monkeypatch, files: list[str]) -> None:
    class _Site:
        async def get_torrent_detail(self, target):
            return SimpleNamespace(file_list=files)

    class _Access:
        async def get(self, site_id):
            return _Site()

    from movieclaw_api.services import site_access

    monkeypatch.setattr(site_access, "get_site_access", lambda: _Access())


@pytest.mark.parametrize(
    "stem",
    [
        "One.Piece.S21E01-E02",
        "One.Piece.S21E01E02",
        "One.Piece.S21E01+E02",
        "One.Piece.S21E01&E02",
        "One.Piece.S21E01~E02",
        "One.Piece.S21E01-02",
    ],
)
def test_explicit_unit_does_not_reduce_multi_episode_names_to_the_first(stem: str) -> None:
    assert explicit_unit(stem) is None


def test_explicit_unit_keeps_resolution_suffix_as_a_single_episode() -> None:
    assert explicit_unit("One.Piece.S21E01-1080p") == (21, 1)


async def test_same_title_single_is_claimed_by_file_unit_not_as_season_pack(
    db, monkeypatch
) -> None:
    """ADWeb 标题无集号；详情文件 S01E5 只认领 TMDB S03E5，不碰 S01。"""
    _install_detail(monkeypatch, ["Absolute.Show.S01E05.mkv"])
    async with db.session() as session:
        subscription_id, torrent = await _setup(session)
        item = (
            await session.execute(select(MediaItem).where(MediaItem.tmdb_id == 1224))
        ).scalar_one()
        assert item.season_mapping and any(
            entry.get("absolute") for entry in item.season_mapping
        )

        summary = await evaluate_and_dispatch(session, [torrent], source="被动匹配")
        wanted = list(
            (
                await session.execute(
                    select(WantedItem).where(WantedItem.subscription_id == subscription_id)
                )
            ).scalars()
        )

    status = {(row.season_number, row.episode_number): row.status for row in wanted}
    assert summary.dispatched_units == 1
    assert status[(3, 5)] == WantedStatus.GRABBED
    assert status[(1, 1)] == WantedStatus.WANTED
    assert status[(1, 2)] == WantedStatus.WANTED


async def test_missing_file_list_rejects_instead_of_claiming_s01_pack(db, monkeypatch) -> None:
    """无法取得文件集号时不猜，S01 工单保持 wanted，并留下拒绝活动。"""
    _install_detail(monkeypatch, [])
    async with db.session() as session:
        subscription_id, torrent = await _setup(session)
        summary = await evaluate_and_dispatch(session, [torrent], source="被动匹配")
        wanted = list(
            (
                await session.execute(
                    select(WantedItem).where(WantedItem.subscription_id == subscription_id)
                )
            ).scalars()
        )
        activities = list(
            (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == subscription_id,
                        SubscriptionActivity.type == ActivityType.MATCH_REJECTED,
                    )
                )
            ).scalars()
        )

    assert summary.dispatched_units == 0 and summary.rejected == 1
    assert all(row.status == WantedStatus.WANTED for row in wanted)
    assert activities[-1].payload["reason_code"] == "episode_file_list_unavailable"


async def test_unparsed_videos_make_file_list_recheck_fail_closed(db, monkeypatch) -> None:
    """样片可排除，但其余视频认不出单元时不能只凭样片或部分清单认领。"""
    _install_detail(
        monkeypatch,
        [
            "Absolute.Show.S01E03.sample.mkv",
            "Absolute.Show/video-01.mkv",
            "Absolute.Show/video-02.mkv",
        ],
    )
    async with db.session() as session:
        subscription_id, torrent = await _setup(session, selected_seasons=[2])
        summary = await evaluate_and_dispatch(session, [torrent], source="被动匹配")
        wanted = list(
            (
                await session.execute(
                    select(WantedItem).where(WantedItem.subscription_id == subscription_id)
                )
            ).scalars()
        )

    assert summary.dispatched_units == 0 and summary.rejected == 1
    assert all(row.status == WantedStatus.WANTED for row in wanted)


async def test_duplicate_file_units_make_file_list_recheck_fail_closed(db, monkeypatch) -> None:
    """两个文件归一到同一 TMDB 单元不是单集证据，必须拒绝整份候选。"""
    _install_detail(
        monkeypatch,
        ["Absolute.Show.S01E05.mkv", "Absolute.Show.S03E01.mkv"],
    )
    async with db.session() as session:
        subscription_id, torrent = await _setup(session, selected_seasons=[3])
        summary = await evaluate_and_dispatch(session, [torrent], source="被动匹配")
        wanted = list(
            (
                await session.execute(
                    select(WantedItem).where(WantedItem.subscription_id == subscription_id)
                )
            ).scalars()
        )

    assert summary.dispatched_units == 0 and summary.rejected == 1
    assert all(row.status == WantedStatus.WANTED for row in wanted)


@pytest.mark.parametrize(
    "filename",
    [
        "Absolute.Show.S03E01-E02.mkv",
        "Absolute.Show.S03E01E02.mkv",
        "Absolute.Show.S03E01+E02.mkv",
    ],
)
async def test_multi_episode_file_is_never_claimed_as_only_its_first_episode(
    db, monkeypatch, filename: str
) -> None:
    _install_detail(monkeypatch, [filename])
    async with db.session() as session:
        subscription_id, torrent = await _setup(session, selected_seasons=[3])
        summary = await evaluate_and_dispatch(session, [torrent], source="被动匹配")
        wanted = list(
            (
                await session.execute(
                    select(WantedItem).where(WantedItem.subscription_id == subscription_id)
                )
            ).scalars()
        )

    assert summary.dispatched_units == 0 and summary.rejected == 1
    assert all(row.status == WantedStatus.WANTED for row in wanted)


async def test_sample_video_does_not_spoil_a_complete_file_list(db, monkeypatch) -> None:
    """明确 sample 继续沿用既有排除口径，不让附带样片误伤有效单集。"""
    _install_detail(
        monkeypatch,
        ["Absolute.Show.S01E05.mkv", "Absolute.Show.S01E03.sample.mkv"],
    )
    async with db.session() as session:
        subscription_id, torrent = await _setup(session, selected_seasons=[3])
        summary = await evaluate_and_dispatch(session, [torrent], source="被动匹配")
        wanted = await session.execute(
            select(WantedItem).where(WantedItem.subscription_id == subscription_id)
        )

    status = {
        (row.season_number, row.episode_number): row.status for row in wanted.scalars()
    }
    assert summary.dispatched_units == 1
    assert status[(3, 5)] == WantedStatus.GRABBED


async def test_season_relative_title_maps_without_detail_lookup(db, monkeypatch) -> None:
    """情形 A 与文件层共用归一入口：S03E01 唯一换算到 TMDB S03E05。"""

    class _UnexpectedAccess:
        async def get(self, _site_id):
            raise AssertionError("标题已带集号，不应读取详情文件清单")

    from movieclaw_api.services import site_access

    monkeypatch.setattr(site_access, "get_site_access", lambda: _UnexpectedAccess())
    async with db.session() as session:
        subscription_id, torrent = await _setup(session)
        torrent.title = "Absolute.Show.S03E01.2024.1080p.WEB-DL"
        torrent.attrs = {
            "media_type": "tv",
            "seasons": [3],
            "episodes": [1],
            "resolution": "1080p",
        }
        await session.commit()

        summary = await evaluate_and_dispatch(session, [torrent], source="被动匹配")
        wanted = list(
            (
                await session.execute(
                    select(WantedItem).where(WantedItem.subscription_id == subscription_id)
                )
            ).scalars()
        )

    status = {(row.season_number, row.episode_number): row.status for row in wanted}
    assert summary.dispatched_units == 1
    assert status[(3, 5)] == WantedStatus.GRABBED
    assert status[(1, 1)] == WantedStatus.WANTED


async def test_out_of_range_title_is_rejected_with_activity(db, monkeypatch) -> None:
    """季内号超过该季长度时不猜，并把原因写进订阅活动。"""
    _install_detail(monkeypatch, [])
    async with db.session() as session:
        subscription_id, torrent = await _setup(session)
        torrent.title = "Absolute.Show.S03E03.2024.1080p.WEB-DL"
        torrent.attrs = {
            "media_type": "tv",
            "seasons": [3],
            "episodes": [3],
            "resolution": "1080p",
        }
        await session.commit()

        summary = await evaluate_and_dispatch(session, [torrent], source="被动匹配")
        activity = (
            await session.execute(
                select(SubscriptionActivity).where(
                    SubscriptionActivity.subscription_id == subscription_id,
                    SubscriptionActivity.type == ActivityType.MATCH_REJECTED,
                )
            )
        ).scalar_one()

    assert summary.dispatched_units == 0 and summary.rejected == 1
    assert activity.payload["reason_code"] == "episode_out_of_range"
