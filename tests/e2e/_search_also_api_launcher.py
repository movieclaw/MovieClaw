"""详情页同搜英文名/原名的隔离浏览器验收：TMDB 与 PT 站点用假实现，搜索/历史/订阅业务保持真实。

两个假站点模拟 issue #680 的场景：馒头只认中文名，TTG 只认英文名（scene 命名）。
只搜中文名时 TTG 一条都搜不到；带上英文名后两站的结果都能出来。
"""

from dataclasses import dataclass

from tests.api.test_subscription_pipeline import _MOVIE_ROUTES, _fake_tmdb

import movieclaw_api.services.site_search as site_search
from movieclaw_api.api.routes import subscriptions
from movieclaw_api.app import create_app
from movieclaw_api.services import media_discover
from movieclaw_media.service import MediaDiscoverService
from movieclaw_tracker.models import SearchQuery, SearchResult, TorrentListItem

MOVIE_ID = 104  # 恶人传 / The Gangster, the Cop, the Devil / 악인전
routes = {
    "/3/genre/tv/list": {"genres": []},
    "/3/genre/movie/list": {"genres": []},
    f"/3/movie/{MOVIE_ID}": {
        **_MOVIE_ROUTES[f"/3/movie/{MOVIE_ID}"],
        "poster_path": "/lab.jpg",
        "overview": "隔离验收夹具。",
        "vote_average": 7.0,
        "genres": [],
    },
}
media_discover.get_tmdb_client = lambda: _fake_tmdb(routes)
subscriptions.get_tmdb_client = media_discover.get_tmdb_client
media_discover.get_media_service = lambda: MediaDiscoverService(
    _fake_tmdb(routes), image_base_url="https://image.tmdb.org/t/p"
)

ENGLISH = "The Gangster, the Cop, the Devil"
_RESULTS = {
    "mteam": {
        "恶人传": [TorrentListItem(torrent_id="m1", title="恶人传 2019 1080p BluRay", seeders=30)],
        # 英文名在馒头也能搜到同一个种子：合并时不能出现两条
        ENGLISH: [TorrentListItem(torrent_id="m1", title="恶人传 2019 1080p BluRay", seeders=30)],
    },
    "ttg": {
        ENGLISH: [
            TorrentListItem(
                torrent_id="t1",
                title="The.Gangster.the.Cop.the.Devil.2019.1080p.BluRay.x264-WiKi",
                seeders=12,
            )
        ],
    },
}
#: 每个假站点收到的搜索词（按顺序），供测试断言后端真的把同搜词下发到了每个站
search_log: dict[str, list[str]] = {site_id: [] for site_id in _RESULTS}


@dataclass
class _Cred:
    site_id: str
    protected: bool = False


class _FakeSite:
    def __init__(self, site_id: str):
        self._site_id = site_id

    async def search(self, query: SearchQuery) -> SearchResult:
        search_log[self._site_id].append(query.keyword)
        items = _RESULTS[self._site_id].get(query.keyword, [])
        return SearchResult(items=items, page=query.page, total_pages=1, has_more=False)


class _FakeAccess:
    async def get(self, site_id: str) -> _FakeSite:
        return _FakeSite(site_id)


async def _active_sites():
    return [_Cred(site_id) for site_id in _RESULTS]


site_search._active_sites = _active_sites
site_search.get_site_access = _FakeAccess

app = create_app()


@app.get("/__lab/search-log")
async def get_search_log():
    return search_log


@app.post("/__lab/library-item")
async def seed_library_item(library_id: int, root: str):
    """往已建好的电影库里挂上这部片（带英文名），返回条目 id。不走扫描——扫描要真实
    TMDB 识别，这里只验证详情页把英文名带进搜索。"""
    from pathlib import Path

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import FileSource, LibraryFile, MediaItem

    path = Path(root) / "恶人传 (2019)" / "恶人传.2019.1080p.mkv"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * 1024)
    async with get_database().session() as session:
        item = MediaItem(
            kind="movie",
            tmdb_id=9104,
            title="恶人传",
            original_title="악인전",
            english_title=ENGLISH,
            year=2019,
            aliases=[],
        )
        session.add(item)
        await session.flush()
        session.add(
            LibraryFile(
                library_id=library_id,
                media_item_id=item.id,
                file_path=str(path),
                size_bytes=1024,
                source=FileSource.SCANNED,
            )
        )
        await session.commit()
        return {"item_id": item.id}
