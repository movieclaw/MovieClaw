"""智能订阅记忆的隔离验收后端：Web、iOS、Android 模拟器共用。

只替换外部影视元数据（tests/api/smart_memory_fixture.py）；订阅、记忆、匹配与等待
都是真实服务，投递走 dry-run。``/__lab/*`` 只在本启动器里存在，用来模拟站点上
出现资源、时间过去。
"""

import os
from datetime import timedelta

from tests.api.smart_memory_fixture import MOVIES, ROUTES, SHOWS
from tests.api.test_subscription_pipeline import _fake_tmdb

from movieclaw_api.api.routes import subscriptions
from movieclaw_api.app import create_app
from movieclaw_api.services import media_discover
from movieclaw_media.service import MediaDiscoverService

media_discover.get_tmdb_client = lambda: _fake_tmdb(ROUTES)
subscriptions.get_tmdb_client = media_discover.get_tmdb_client
media_discover.get_media_service = lambda: MediaDiscoverService(
    _fake_tmdb(ROUTES), image_base_url="https://image.tmdb.org/t/p"
)
app = create_app()

if os.environ.get("MC_LAB_LEGACY_SERVER") == "1":
    # 装成 0.42.0 之前的服务器：预检不带智能摘要，验新客户端的降级

    async def _no_smart_plan(*_args, **_kwargs):
        return None

    subscriptions._smart_plan_view = _no_smart_plan


@app.post("/__lab/release/{kind}/{tmdb_id}")
async def release(
    kind: str, tmdb_id: int, name: str = "RAW", subs: str = "", hours_ago: int = 0
):
    """站点上出现一个资源（默认 4K WEB-DL、不带字幕声明），并立即走一遍真实匹配。"""
    from sqlmodel import select

    from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import SiteTorrent, Subscription, WantedItem
    from movieclaw_db.models.base import utcnow
    from movieclaw_db.models.site_torrent import TorrentSource

    data = (MOVIES if kind == "movie" else SHOWS)[tmdb_id]
    original = data.get("original_title") or data.get("original_name")
    attrs = {
        "media_type": kind,
        "title": original,
        "year": int((data.get("release_date") or data.get("first_air_date"))[:4]),
        "resolution": "2160p",
        "media_source": "WEB-DL",
        "release_group": name,
        "subtitle_languages": [s for s in subs.split(",") if s],
    }
    episode = ""
    if kind == "tv":
        attrs.update(seasons=[1], episodes=[1])
        episode = " S01E01"
    async with get_database().session() as session:
        row = SiteTorrent(
            site_id="lab",
            torrent_id=f"{kind}-{tmdb_id}-{name}",
            title=f"{original}{episode} {attrs['year']} 2160p WEB-DL-{name}",
            subtitle="",
            attrs=attrs,
            enrich_version=1,
            source=TorrentSource.LIST,
            seeders=20,
            download_volume_factor=0.0,
            is_free=True,
            publish_time=utcnow() - timedelta(hours=hours_ago),
        )
        session.add(row)
        await session.commit()
        await session.refresh(row)
        result = await evaluate_and_dispatch(session, [row], source="隔离验收")
        sub = (
            await session.execute(
                select(Subscription)
                .join(WantedItem, WantedItem.subscription_id == Subscription.id)
                .where(WantedItem.media_item_id == Subscription.media_item_id)
            )
        ).scalars().first()
        return {
            "dispatched": result.dispatched_units,
            "torrents": result.dispatched_torrents,
            "subscription": sub.id if sub else None,
        }


@app.post("/__lab/evaluate/{subscription_id}")
async def evaluate(subscription_id: int):
    """到期扫描：让「这次先下原版」之类的人工请求立即被处理。"""
    from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
    from movieclaw_db.engine import get_database

    async with get_database().session() as session:
        result = await evaluate_and_dispatch(
            session, [], source="隔离验收", subscription_ids={subscription_id}
        )
        return {"dispatched": result.dispatched_units, "torrents": result.dispatched_torrents}
