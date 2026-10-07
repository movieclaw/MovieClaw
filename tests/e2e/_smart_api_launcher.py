"""只用于隔离浏览器验收，替换外部影视元数据，业务服务保持真实。"""

from tests.api.test_subscription_pipeline import _TV_ROUTES, _fake_tmdb

from movieclaw_api.api.routes import subscriptions
from movieclaw_api.app import create_app
from movieclaw_api.services import media_discover
from movieclaw_media.service import MediaDiscoverService

routes = {
    **_TV_ROUTES,
    "/3/genre/tv/list": {"genres": []},
    "/3/genre/movie/list": {"genres": []},
    "/3/movie/100": {
        "id": 100,
        "title": "测试电影",
        "original_title": "Test Movie",
        "release_date": "2024-01-01",
        "status": "Released",
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
        "poster_path": "/lab.jpg",
    },
}
routes["/3/search/multi"] = {"results": [{**routes["/3/movie/100"], "media_type": "movie"}]}
routes["/3/tv/200"] = {**routes["/3/tv/200"], "poster_path": "/lab.jpg"}
for movie_id, title in ((101, "精简订阅验证"), (102, "规则订阅验证"), (103, "自定义等待验证")):
    routes[f"/3/movie/{movie_id}"] = {**routes["/3/movie/100"], "id": movie_id, "title": title}
routes["/3/tv/201"] = {**routes["/3/tv/200"], "id": 201, "name": "自定义追剧验证"}
for season in (1, 2):
    routes[f"/3/tv/201/season/{season}"] = routes[f"/3/tv/200/season/{season}"]
media_discover.get_tmdb_client = lambda: _fake_tmdb(routes)
subscriptions.get_tmdb_client = media_discover.get_tmdb_client
media_discover.get_media_service = lambda: MediaDiscoverService(
    _fake_tmdb(routes), image_base_url="https://image.tmdb.org/t/p"
)
app = create_app()


@app.post("/__lab/subscription-downloader/{enabled}")
async def subscription_downloader(enabled: bool):
    """只供表单预检读取；调度关闭且投递 dry-run，不连接真实下载器。"""
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models.downloader_client import ClientType, DownloaderClient
    from movieclaw_db.models.site_credential import ConfigStatus

    async with get_database().session() as session:
        row = (await session.execute(select(DownloaderClient))).scalars().first()
        if row is None:
            row = DownloaderClient(
                name="隔离预检",
                client_type=ClientType.QBITTORRENT,
                url="http://127.0.0.1:1",
                status=ConfigStatus.ACTIVE,
                is_default=True,
            )
        row.enabled = enabled
        session.add(row)
        await session.commit()
    return {"ok": True}


@app.post("/__lab/discover")
async def discover():
    from tests.api.test_smart_subscription import resource

    from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
    from movieclaw_db.engine import get_database

    async with get_database().session() as session:
        return await evaluate_and_dispatch(
            session, [await resource(session)], source="隔离浏览器验收"
        )


@app.post("/__lab/import-progress/{stage}")
async def import_progress(stage: str):
    from sqlmodel import select

    from movieclaw_api.services.subscription.smart_selection import confirm_import
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import Subscription, WantedItem
    from movieclaw_matcher import QualitySnapshot

    async with get_database().session() as session:
        sub = (
            await session.execute(select(Subscription).where(Subscription.kind == "tv"))
        ).scalar_one()
        rows = (
            (
                await session.execute(
                    select(WantedItem)
                    .where(WantedItem.subscription_id == sub.id)
                    .order_by(WantedItem.episode_number)
                )
            )
            .scalars()
            .all()
        )
        snapshot = QualitySnapshot(
            resolution="2160p",
            media_source="WEB-DL",
            resolution_verified=True,
            source_evidence="consistent_declaration",
        )
        for index, row in enumerate(rows):
            if stage == "all" or index == 0:
                row.status = "imported"
                row.quality = snapshot.model_dump(mode="json")
                await confirm_import(session, sub, row, snapshot)
            else:
                row.status = "grabbed"
            session.add(row)
        await session.commit()
    return {"ok": True}


@app.post("/__lab/old-release")
async def old_release():
    from tests.api.smart_waiting_fixture import seed_old_release

    from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
    from movieclaw_db.engine import get_database

    async with get_database().session() as session:
        sub, candidates = await seed_old_release(session)
        result = await evaluate_and_dispatch(session, candidates, source="NAS快照正式链路")
        return {
            "id": sub.id,
            "selected": result.dispatched_units,
            "torrents": len(result.dispatched_torrents),
        }


@app.post("/__lab/unified-status/{subscription_id}")
async def unified_status(subscription_id: int):
    from datetime import timedelta

    from sqlmodel import select

    from movieclaw_api.services.subscription.smart_selection import confirm_import
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import Subscription, WantedItem, utcnow
    from movieclaw_matcher import QualitySnapshot

    async with get_database().session() as session:
        sub = await session.get(Subscription, subscription_id)
        sub.status = "active"
        first = (
            await session.execute(
                select(WantedItem).where(
                    WantedItem.subscription_id == sub.id, WantedItem.episode_number == 1
                )
            )
        ).scalar_one()
        quality = QualitySnapshot(
            resolution="1080p",
            media_source="WEB-DL",
            resolution_verified=True,
            source_evidence="consistent_declaration",
        )
        first.status, first.quality, first.imported_at = (
            "imported",
            quality.model_dump(mode="json"),
            utcnow(),
        )
        await confirm_import(session, sub, first, quality)
        for number in (3, 4, 5):
            session.add(
                WantedItem(
                    subscription_id=sub.id,
                    media_item_id=sub.media_item_id,
                    season_number=2,
                    episode_number=number,
                    air_date=(utcnow() + timedelta(days=1 if number == 5 else -1)).date(),
                    next_search_at=utcnow() + timedelta(days=1),
                )
            )
        await session.commit()
    return {"ok": True}


@app.post("/__lab/identity/{verified}")
async def identity_case(verified: bool):
    from tests.api.smart_identity_fixture import seed_identity_case
    from movieclaw_db.engine import get_database

    async with get_database().session() as session:
        return await seed_identity_case(session, verified=verified)


@app.post("/__lab/subscription-order")
async def subscription_order():
    from tests.api.subscription_ordering_fixture import seed_subscription_ordering

    from movieclaw_db.engine import get_database

    async with get_database().session() as session:
        return await seed_subscription_ordering(session)
