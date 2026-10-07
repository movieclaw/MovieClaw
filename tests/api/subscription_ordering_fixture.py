"""隔离列表验收：缺资源、首轮下载、旧集洗版与新集缺口并存、纯洗版。"""

from datetime import date, datetime, timedelta

from movieclaw_db.models import (
    Library,
    LibraryFile,
    MediaEpisode,
    MediaItem,
    MediaSeason,
    Subscription,
    WantedItem,
)
from movieclaw_matcher import QualitySnapshot
from movieclaw_matcher.smart import SmartPolicy


async def seed_subscription_ordering(session):
    result = {}
    for kind, noun in (("movie", "电影"), ("tv", "剧集")):
        library = Library(name=f"排序{noun}库", kind=kind)
        session.add(library)
        await session.flush()
        ids = {}
        for index, state in enumerate(("search", "mixed", "pipeline", "upgrade", "paused", "done")):
            title = f"排序{noun}{state}"
            media = MediaItem(
                kind=kind,
                tmdb_id=980000 + (100 if kind == "tv" else 0) + index,
                title=title,
                original_title=title,
                status="Released" if kind == "movie" else "Ended",
            )
            session.add(media)
            await session.flush()
            stamp = datetime(2026, 1, 1) + timedelta(days=index)
            sub = Subscription(
                media_item_id=media.id,
                kind=kind,
                selected_seasons=[1] if kind == "tv" else [],
                follow_future=False,
                selection_mode="smart",
                library_id=library.id,
                smart_policy=SmartPolicy(kind=kind, profile_revision=1).model_dump(mode="json"),
                status="paused"
                if state == "paused"
                else "completed"
                if state in ("upgrade", "done")
                else "active",
                created_at=stamp,
                updated_at=stamp,
                last_activity_at=stamp,
            )
            session.add(sub)
            await session.flush()
            ids[state] = sub.id
            season = 1 if kind == "tv" else 0
            episodes = [1, 2] if kind == "tv" else [0]
            if kind == "tv":
                session.add(
                    MediaSeason(
                        media_item_id=media.id, season_number=1, name="第 1 季", episode_count=2
                    )
                )
            for episode in episodes:
                if kind == "tv":
                    session.add(
                        MediaEpisode(
                            media_item_id=media.id,
                            season_number=1,
                            episode_number=episode,
                            air_date=date(2024, 1, 1),
                        )
                    )
                owned = state in ("upgrade", "done", "paused") or (
                    kind == "tv" and state == "mixed" and episode == 1
                )
                quality = (
                    QualitySnapshot(
                        resolution="2160p" if state == "done" else "1080p",
                        media_source="WEB-DL",
                        resolution_verified=True,
                        source_evidence="consistent_declaration",
                    ).model_dump(mode="json")
                    if owned
                    else None
                )
                session.add(
                    WantedItem(
                        subscription_id=sub.id,
                        media_item_id=media.id,
                        season_number=season,
                        episode_number=episode,
                        status="imported"
                        if owned
                        else "grabbed"
                        if state == "pipeline"
                        else "wanted",
                        quality=quality,
                    )
                )
                if owned:
                    session.add(
                        LibraryFile(
                            library_id=library.id,
                            media_item_id=media.id,
                            season_number=season,
                            episode_number=episode,
                            file_path=f"/isolated-order/{kind}/{state}/{episode}.mkv",
                            source="scanned",
                        )
                    )
        result[kind] = ids
    await session.commit()
    return result
