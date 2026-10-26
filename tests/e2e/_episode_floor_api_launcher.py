"""集数下限（issue #640）浏览器验收专用后端：外部元数据隔离，业务服务保持真实。

还原 issue 现场：《死刑将至》TMDB 只录了 6 集（已完结），豆瓣标注 27 集。
TMDB 与豆瓣都换成本地假响应，走的仍是真实的豆瓣解析、豆瓣→TMDB 收敛、
订阅创建与匹配管线。``/__lab/*`` 只模拟两件外部事件：站点上出现新种子、
文件整理入库。
"""

from datetime import date, timedelta

import httpx
from tests.api.test_subscription_pipeline import _fake_tmdb

from movieclaw_api.api.routes import subscriptions
from movieclaw_api.app import create_app
from movieclaw_api.services import media_discover
from movieclaw_media.douban import DoubanClient, DoubanDiscoverService
from movieclaw_media.service import MediaDiscoverService

AIRED = (date.today() - timedelta(days=30)).isoformat()
DOUBAN_ID = "36000640"

SHOW = {
    "id": 640,
    "name": "死刑将至",
    "original_name": "Death Row Is Coming",
    "first_air_date": "2025-01-01",
    "status": "Ended",
    "poster_path": "/lab.jpg",
    "external_ids": {},
    "alternative_titles": {"results": []},
    "translations": {"translations": []},
    "seasons": [{"season_number": 1, "episode_count": 6, "air_date": "2025-01-01"}],
}
routes = {
    "/3/tv/640": SHOW,
    "/3/tv/640/season/1": {
        "name": "第 1 季",
        "air_date": "2025-01-01",
        "episodes": [
            {"episode_number": n, "name": f"第{n}集", "air_date": AIRED} for n in range(1, 7)
        ],
    },
    "/3/search/tv": {"results": [{**SHOW, "media_type": "tv"}]},
    "/3/search/multi": {"results": [{**SHOW, "media_type": "tv"}]},
    "/3/genre/tv/list": {"genres": []},
    "/3/genre/movie/list": {"genres": []},
}
media_discover.get_tmdb_client = lambda: _fake_tmdb(routes)
subscriptions.get_tmdb_client = media_discover.get_tmdb_client
media_discover.get_media_service = lambda: MediaDiscoverService(
    _fake_tmdb(routes), image_base_url="https://image.tmdb.org/t/p"
)

_DOUBAN_DETAIL = {
    "id": DOUBAN_ID,
    "title": "死刑将至",
    "original_title": "Death Row Is Coming",
    "type": "tv",
    "is_tv": True,
    "year": "2025",
    "cover_url": "https://img.example.invalid/cover.jpg",
    "episodes_count": 27,
    "aka": ["Death Row Is Coming"],
    "pubdate": ["2025-01-01(中国大陆)"],
    "rating": {"value": 8.1},
    "genres": ["剧情", "悬疑"],
    "intro": "隔离验收用的假豆瓣条目。",
}


def _douban(request: httpx.Request) -> httpx.Response:
    if request.url.path == f"/movie/{DOUBAN_ID}":
        return httpx.Response(200, json=_DOUBAN_DETAIL)
    if request.url.path == f"/movie/{DOUBAN_ID}/celebrities":
        return httpx.Response(200, json={"directors": [], "actors": []})
    return httpx.Response(404, json={})


_douban_service = DoubanDiscoverService(
    DoubanClient(base_url="http://douban.invalid", transport=httpx.MockTransport(_douban))
)
media_discover.get_douban_media_service = lambda: _douban_service

app = create_app()


@app.post("/__lab/torrent")
async def lab_torrent(payload: dict):
    """站点上出现一个新种子：落库后走真实的被动匹配。"""
    from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import SiteTorrent, TorrentSource
    from movieclaw_db.models.base import utcnow

    async with get_database().session() as session:
        row = SiteTorrent(
            site_id="labsite",
            torrent_id=payload["torrent_id"],
            title=payload["title"],
            subtitle="",
            attrs={"media_type": "tv", "resolution": "1080p", **payload["attrs"]},
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
        summary = await evaluate_and_dispatch(session, [row], source="被动匹配")
    return {"dispatched_units": summary.dispatched_units}


@app.post("/__lab/import-all/{subscription_id}")
async def lab_import_all(subscription_id: int):
    """整理入库：把订阅范围内的单元全部标为已入库，并重算订阅状态。"""
    from sqlmodel import select

    from movieclaw_api.services.subscription import recompute_subscription_status
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import MediaItem, Subscription, WantedItem, WantedStatus
    from movieclaw_db.models.base import utcnow

    async with get_database().session() as session:
        rows = (
            await session.execute(
                select(WantedItem).where(
                    WantedItem.subscription_id == subscription_id,
                    WantedItem.in_scope.is_(True),
                )
            )
        ).scalars()
        for row in rows:
            row.status = WantedStatus.IMPORTED
            row.imported_at = utcnow()
            session.add(row)
        await session.commit()
        subscription = await session.get(Subscription, subscription_id)
        item = await session.get(MediaItem, subscription.media_item_id)
        await recompute_subscription_status(session, subscription, item)
        await session.commit()
        return {"status": subscription.status}
