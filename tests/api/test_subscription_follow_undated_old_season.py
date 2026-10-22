"""issue #974 现场：只勾最新季 + 自动续订，旧季里 TMDB 漏填日期的集不该被下载。

夹具还原《现在就出发》：S3 前段有日期、后段（E34～E47）没日期但早已播完，
S4 正在播。站点上同时有 S3 和 S4 的单集种子，走与首轮搜索相同的匹配投递
（dry-run，不连站点与下载器），只有 S4 应该被投递。
"""

from __future__ import annotations

from datetime import timedelta

import httpx
import pytest_asyncio
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.settings.store import init_setting_store, reset_setting_store
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    SiteTorrent,
    TorrentSource,
    WantedItem,
    WantedStatus,
)
from movieclaw_db.models.base import utcnow
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"
_TODAY = utcnow().date()

_ROUTES = {
    "/3/tv/231620": {
        "id": 231620,
        "name": "现在就出发",
        "original_name": "Natural High",
        "first_air_date": "2023-01-01",
        "status": "Returning Series",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 3}, {"season_number": 4}],
    },
    "/3/tv/231620/season/3": {
        "name": "第 3 季",
        "air_date": "2025-10-25",
        "episodes": [
            *(
                {
                    "episode_number": n,
                    "name": f"E{n}",
                    "air_date": ("2025-10-25" if n == 1 else "2025-12-28"),
                }
                for n in range(1, 21)
            ),
            *({"episode_number": n, "name": f"E{n}", "air_date": None} for n in range(34, 48)),
        ],
    },
    "/3/tv/231620/season/4": {
        "name": "第 4 季",
        "air_date": (_TODAY - timedelta(days=14)).isoformat(),
        "episodes": [
            {
                "episode_number": 1,
                "name": "E1",
                "air_date": (_TODAY - timedelta(days=14)).isoformat(),
            },
            {
                "episode_number": 2,
                "name": "E2",
                "air_date": (_TODAY - timedelta(days=7)).isoformat(),
            },
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
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'follow.db'}")
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "true")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    init_setting_store()
    yield get_database()
    reset_setting_store()
    await dispose_db()
    get_settings.cache_clear()


async def _torrent(session, season: int, episode: int) -> SiteTorrent:
    row = SiteTorrent(
        site_id="testsite",
        torrent_id=f"s{season}e{episode}",
        title=f"Natural High S{season:02d}E{episode:02d} 2160p TX WEB-DL AAC2.0 H.265-MWeb",
        subtitle="",
        attrs={
            "media_type": "tv",
            "resolution": "2160p",
            "seasons": [season],
            "episodes": [episode],
        },
        enrich_version=1,
        source=TorrentSource.SEARCH,
        seeders=100,
        download_volume_factor=0.0,
        is_free=True,
        publish_time=utcnow(),
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row


async def test_old_season_undated_episodes_are_not_grabbed(db) -> None:
    async with db.session() as session:
        service = SubscriptionService(session, MediaLibraryService(session, _fake_tmdb()))
        sub = await service.create(MediaKind.TV, 231620, selected_seasons=[4], follow_future=True)
        torrents = [await _torrent(session, 3, n) for n in (34, 35, 41, 47)]
        torrents.append(await _torrent(session, 4, 1))
        await evaluate_and_dispatch(session, torrents, source="主动搜索")

        rows = (
            (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub.id)))
            .scalars()
            .all()
        )
        wanted = {(w.season_number, w.episode_number): w for w in rows}

    # 投递出去的只有 S4 的种子，S3 的一个都没动
    grabbed = {key for key, w in wanted.items() if w.status == WantedStatus.GRABBED}
    assert grabbed == {(4, 1)}

    # 只有 S4 的集进订阅：已播的两集 + 末尾真正未定档的 E3（继续追）
    assert set(wanted) == {(4, 1), (4, 2), (4, 3)}
    assert wanted[(4, 1)].status == WantedStatus.GRABBED
    assert wanted[(4, 3)].status == WantedStatus.WANTED
