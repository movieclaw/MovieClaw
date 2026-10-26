"""订阅窗口浏览器验收专用后端：外部元数据隔离，业务服务保持真实。

三部剧：《长篇漫剧》TMDB 一季 120 集（全部已播、已完结）——完结超长季，
「先订阅前 20 集」；《在播长篇剧》一季 120 集已播、剧还在播——在播超长季，
默认「先订阅最新 20 集」且追新照常；《短篇剧》一季 12 集——远低于阈值，
订阅弹层里不该多出任何选项。TMDB 换成本地假响应，走的仍是真实的订阅创建、
E 展开与状态派生。``/__lab/import-all`` 只模拟一件外部事件：文件整理入库。
"""

from datetime import date, timedelta

from tests.api.test_subscription_pipeline import _fake_tmdb

from movieclaw_api.api.routes import subscriptions
from movieclaw_api.app import create_app
from movieclaw_api.services import media_discover
from movieclaw_media.service import MediaDiscoverService

AIRED = (date.today() - timedelta(days=30)).isoformat()


def _show(tmdb_id: int, name: str, original: str, episodes: int, status: str = "Ended") -> dict:
    return {
        "id": tmdb_id,
        "name": name,
        "original_name": original,
        "first_air_date": "2025-01-01",
        "status": status,
        "poster_path": "/lab.jpg",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 1, "episode_count": episodes, "air_date": "2025-01-01"}],
    }


LONG = _show(1043, "长篇漫剧", "Long Comic Drama", 120)
SHORT = _show(1044, "短篇剧", "Short Drama", 12)
AIRING = _show(1045, "在播长篇剧", "Airing Long Drama", 120, status="Returning Series")


def _brief(show: dict) -> dict:
    return {**show, "media_type": "tv"}


def _season(episodes: int) -> dict:
    return {
        "name": "第 1 季",
        "air_date": "2025-01-01",
        "episodes": [
            {"episode_number": n, "name": f"第{n}集", "air_date": AIRED}
            for n in range(1, episodes + 1)
        ],
    }


routes = {
    "/3/tv/1043": LONG,
    "/3/tv/1043/season/1": _season(120),
    "/3/tv/1044": SHORT,
    "/3/tv/1044/season/1": _season(12),
    "/3/tv/1045": AIRING,
    "/3/tv/1045/season/1": _season(120),
    "/3/search/tv": {"results": [_brief(LONG), _brief(SHORT), _brief(AIRING)]},
    "/3/search/multi": {"results": [_brief(LONG), _brief(SHORT), _brief(AIRING)]},
    "/3/genre/tv/list": {"genres": []},
    "/3/genre/movie/list": {"genres": []},
}
media_discover.get_tmdb_client = lambda: _fake_tmdb(routes)
subscriptions.get_tmdb_client = media_discover.get_tmdb_client
media_discover.get_media_service = lambda: MediaDiscoverService(
    _fake_tmdb(routes), image_base_url="https://image.tmdb.org/t/p"
)

app = create_app()


@app.post("/__lab/import-all/{subscription_id}")
async def lab_import_all(subscription_id: int):
    """整理入库：把订阅范围内的单元全部标为已入库（媒体库里同时有了对应文件），并重算订阅状态。"""
    from sqlmodel import select

    from movieclaw_api.services.subscription import recompute_subscription_status
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import (
        Library,
        LibraryFile,
        MediaItem,
        Subscription,
        WantedItem,
        WantedStatus,
    )
    from movieclaw_db.models.base import utcnow

    async with get_database().session() as session:
        subscription = await session.get(Subscription, subscription_id)
        library = (
            (await session.execute(select(Library).where(Library.kind == "tv"))).scalars().first()
        )
        if library is None:
            library = Library(name="实验剧集库", kind="tv")
            session.add(library)
            await session.flush()
        rows = (
            await session.execute(
                select(WantedItem).where(
                    WantedItem.subscription_id == subscription_id,
                    WantedItem.in_scope.is_(True),
                )
            )
        ).scalars()
        for row in rows:
            if row.status != WantedStatus.IMPORTED:
                session.add(
                    LibraryFile(
                        library_id=library.id,
                        media_item_id=subscription.media_item_id,
                        season_number=row.season_number,
                        episode_number=row.episode_number,
                        file_path=f"/lab/{subscription_id}/S{row.season_number:02d}"
                        f"E{row.episode_number:04d}.mkv",
                        source="scanned",
                    )
                )
            row.status = WantedStatus.IMPORTED
            row.imported_at = utcnow()
            session.add(row)
        await session.commit()
        item = await session.get(MediaItem, subscription.media_item_id)
        await recompute_subscription_status(session, subscription, item)
        await session.commit()
        return {"status": subscription.status}
