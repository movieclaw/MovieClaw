"""脱敏 NAS 34 回归数据，仅在隔离测试数据库内建档。"""

import json
from datetime import date, datetime
from pathlib import Path

from movieclaw_db.models import MediaItem, SiteTorrent, Subscription, TorrentSource, WantedItem
from movieclaw_matcher.smart import SmartPolicy


async def seed_old_release(session):
    records = json.loads(
        (Path(__file__).parents[1] / "fixtures/smart_waiting/nas_decisions.json").read_text()
    )
    records = [r for r in records if r["subscription_id"] == 34]
    item = MediaItem(
        kind="tv",
        tmdb_id=253797,
        title="幸福伽菜子的快乐杀手生活",
        original_title="幸せカナコの殺し屋生活",
        year=2025,
        aliases=[
            "幸福伽菜子的快乐杀手生活",
            "Happy Kanako's Killer Life",
            "Happy Kanakos Killer Life",
        ],
    )
    session.add(item)
    await session.flush()
    sub = Subscription(
        media_item_id=item.id,
        kind="tv",
        selected_seasons=[2],
        selection_mode="smart",
        smart_policy=SmartPolicy(kind="tv", profile_revision=1, wait_seconds=21600).model_dump(
            mode="json"
        ),
    )
    session.add(sub)
    await session.flush()
    rows = {}
    for record in records:
        episode = record["episode_number"]
        session.add(
            WantedItem(
                subscription_id=sub.id,
                media_item_id=item.id,
                season_number=2,
                episode_number=episode,
                air_date=date(2026, 9, 17),
            )
        )
        for c in record["inputs"]["candidates"]:
            key = (c["site_id"], c["torrent_id"])
            rows[key] = SiteTorrent(
                site_id=c["site_id"],
                torrent_id=c["torrent_id"],
                title=c["title"],
                attrs=c["attrs"],
                seeders=c["seeders"],
                publish_time=datetime.fromisoformat(c["publish_time"]),
                source=TorrentSource.SEARCH,
            )
    session.add_all(list(rows.values()))
    await session.commit()
    return sub, list(rows.values())
