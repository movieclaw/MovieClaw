"""站点搜索后台运行（#920）的隔离浏览器验收：PT 站点用假实现，搜索/历史/快照业务保持真实。

三个假站点：fast 立即返回；slow 卡在实验台的闸门上，放行才返回（模拟慢站，测试据此
在「搜到一半」时离开/刷新）；flaky 第一次搜索报登录过期、之后正常（验证单站重试真的
重新打站）。每站收到的搜索词记进 search_log——打站次数就是它的长度。
"""

import asyncio
import os
from dataclasses import dataclass
from datetime import UTC, datetime

import movieclaw_api.services.site_search as site_search
from movieclaw_api.app import create_app
from movieclaw_tracker.exceptions import TrackerParseError
from movieclaw_tracker.models import SearchQuery, SearchResult, TorrentListItem

SITES = ("fast", "slow", "flaky")
search_log: dict[str, list[str]] = {site_id: [] for site_id in SITES}
_gate: asyncio.Event | None = None


def _slow_gate() -> asyncio.Event:
    global _gate
    if _gate is None:
        _gate = asyncio.Event()
        _gate.set()
    return _gate


@dataclass
class _Cred:
    site_id: str
    protected: bool = False


class _FakeSite:
    def __init__(self, site_id: str):
        self._site_id = site_id

    async def search(self, query: SearchQuery) -> SearchResult:
        search_log[self._site_id].append(query.keyword)
        if self._site_id == "slow":
            await _slow_gate().wait()
        if self._site_id == "flaky" and len(search_log["flaky"]) == 1:
            raise TrackerParseError(details={"login_redirect": True})
        title = f"{query.keyword}.2021.1080p.BluRay.x264-{self._site_id.upper()}"
        items = [TorrentListItem(torrent_id=f"{self._site_id}-1", title=title, seeders=10)]
        if os.environ.get("E2E_SEARCH_I18N"):
            group = self._site_id.upper()
            items = [
                TorrentListItem(
                    torrent_id=f"{self._site_id}-series",
                    title=f"Example.Series.S02.COMPLETE.2021.2160p.WEB-DL.x265.DDP5.1-{group}",
                    subtitle="全12集 简繁英字幕 国粤双语",
                    category="tv",
                    seeders=30,
                    leechers=2,
                    snatched=7,
                    free=True,
                    size_bytes=12 * 1024**3,
                    upload_time=datetime(2026, 10, 20, tzinfo=UTC),
                    detail_url="https://fixture.invalid/series",
                ),
                TorrentListItem(
                    torrent_id=f"{self._site_id}-episode",
                    title=f"Example.Series.S02E03.2021.1080p.WEB-DL.H264-{group}",
                    category="tv",
                    seeders=20,
                    size_bytes=1024**3,
                    upload_volume_factor=2,
                    detail_url="https://fixture.invalid/episode",
                ),
                TorrentListItem(
                    torrent_id=f"{self._site_id}-movie",
                    title=f"Original.Movie.2020.720p.BluRay.x264-{group}",
                    category="movie",
                    seeders=10,
                    size_bytes=2 * 1024**3,
                    detail_url="https://fixture.invalid/movie",
                ),
            ]
        return SearchResult(items=items, page=query.page, total_pages=1, has_more=False)


class _FakeAccess:
    async def get(self, site_id: str) -> _FakeSite:
        return _FakeSite(site_id)


async def _active_sites():
    return [_Cred(site_id) for site_id in SITES]


site_search._active_sites = _active_sites
site_search.get_site_access = _FakeAccess

app = create_app()


@app.get("/__lab/search-log")
async def get_search_log():
    return search_log


@app.post("/__lab/slow/hold")
async def hold_slow():
    """之后的 slow 搜索都卡住，直到 release。"""
    global _gate
    _gate = asyncio.Event()
    return {"ok": True}


@app.post("/__lab/slow/release")
async def release_slow():
    _slow_gate().set()
    return {"ok": True}


if os.environ.get("E2E_SEARCH_I18N"):
    from tests.api.test_subscription_pipeline import _fake_tmdb

    from movieclaw_api.api.routes import discover, subscriptions
    from movieclaw_api.services import title_discovery
    from movieclaw_media import MediaSearchItem, MediaSource

    class _TitleProvider:
        def __init__(self, source):
            self.source = source

        async def search(self, query):
            if query == "no-matches":
                return []
            return [
                MediaSearchItem(
                    id="123",
                    source=self.source,
                    title="原始影片名",
                    year=2021,
                    type="movie",
                    rating=8,
                    poster_url="",
                )
            ]

    app.dependency_overrides[discover.get_title_discovery_service] = lambda: (
        title_discovery.TitleDiscoveryService(
            lambda: _TitleProvider(MediaSource.TMDB), lambda: _TitleProvider(MediaSource.DOUBAN)
        )
    )

    subscriptions.get_tmdb_client = lambda: _fake_tmdb({})

    @app.post("/__lab/library")
    async def seed_library():
        from tests.api.test_library_search import _seed_advanced

        from movieclaw_db.engine import get_database

        await _seed_advanced(get_database())
        return {"ok": True}

    @app.post("/__lab/reset")
    async def reset_calls():
        for calls in search_log.values():
            calls.clear()
        return {"ok": True}
