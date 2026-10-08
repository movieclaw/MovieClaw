"""隔离验收用同名电影；调用正式匹配链路，站点与下载器不连外网。"""

from datetime import timedelta
from unittest.mock import AsyncMock, patch

from sqlmodel import select

from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_db.models import (
    MediaItem,
    SiteTorrent,
    Subscription,
    TorrentSource,
    WantedItem,
    utcnow,
)
from movieclaw_matcher.smart import SmartPolicy


async def seed_identity_case(session, *, verified=False):
    item = (
        (await session.execute(select(MediaItem).where(MediaItem.tmdb_id == 990039)))
        .scalars()
        .first()
    )
    if item is None:
        item = MediaItem(
            kind="movie",
            tmdb_id=990039,
            title="奥德赛",
            original_title="The Odyssey",
            year=2026,
            aliases=["奥德赛", "The Odyssey"],
            imdb_id="tt33764258",
            identity_twins=[
                {
                    "tmdb_id": 1698863,
                    "title": "奥德赛",
                    "year": 2026,
                    "imdb_id": "tt41605854",
                    "runtime_minutes": 86,
                }
            ],
        )
        session.add(item)
        await session.flush()
        sub = Subscription(
            media_item_id=item.id,
            kind="movie",
            selection_mode="smart",
            smart_policy=SmartPolicy(kind="movie", profile_revision=1, wait_seconds=0).model_dump(
                mode="json"
            ),
        )
        session.add(sub)
        await session.flush()
        session.add(
            WantedItem(
                subscription_id=sub.id,
                media_item_id=item.id,
                next_search_at=utcnow(),
                search_attempts=2,
            )
        )
        await session.commit()
    else:
        sub = (
            await session.execute(select(Subscription).where(Subscription.media_item_id == item.id))
        ).scalar_one()
    torrent_id = "verified" if verified else "ambiguous"
    row = (
        (
            await session.execute(
                select(SiteTorrent).where(
                    SiteTorrent.site_id == "identity-test", SiteTorrent.torrent_id == torrent_id
                )
            )
        )
        .scalars()
        .first()
    )
    if row is None:
        row = SiteTorrent(
            site_id="identity-test",
            torrent_id=torrent_id,
            title="The.Odyssey.2026.1080p.AMZN.WEB-DL.DDP.5.1.H.264-Kitsune",
            imdb_id="tt33764258" if verified else None,
            source=TorrentSource.SEARCH,
            publish_time=utcnow() - timedelta(days=80),
            seeders=88,
            attrs={
                "media_type": "movie",
                "year": 2026,
                "resolution": "1080p",
                "media_source": "WEB-DL",
                "release_group": "Kitsune",
            },
        )
        session.add(row)
        await session.commit()

    async def no_external_detail(candidate_session, candidate):
        return candidate

    with patch(
        "movieclaw_api.services.subscription.matching.fetch_external_ids",
        new=AsyncMock(side_effect=no_external_detail),
    ):
        result = await evaluate_and_dispatch(
            session, [row], source="隔离身份验收", subscription_ids={sub.id}
        )
    return {"id": sub.id, "dispatched": result.dispatched_units}
