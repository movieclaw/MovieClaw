"""条目关联的订阅与种子（docs/design/plugin-phase2a.md §4、§5.3）。

「删了片子要不要顺手删种子、删订阅」需要知道条目背后是哪些下载器任务。关联来自三处：

- 订阅下载记录（``subscription_download_attempt``）：订阅投递过的每个种子，
  含自有 / H&R 标记与覆盖的季集；
- 手动下载意图（``manual_download_intent``）：手动下载在入库前的锚；
- 媒体库文件自己记的来源（``library_file.info_hash``，入库时写入）。

同一个下载器任务按 ``(下载器, info_hash)`` 去重，来源按上面的顺序取第一个。只读，不改任何状态。
"""

from __future__ import annotations

from dataclasses import dataclass, field

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models import (
    DownloaderClient,
    LibraryFile,
    ManualDownloadIntent,
    Subscription,
    SubscriptionDownloadAttempt,
)

Unit = tuple[int, int]


@dataclass(frozen=True)
class TorrentLink:
    info_hash: str
    downloader_id: int | None
    downloader_name: str | None
    title: str | None
    source: str
    """``subscription`` / ``manual`` / ``file``。"""
    site_id: str | None = None
    torrent_id: str | None = None
    owned_by_movieclaw: bool | None = None
    hit_and_run: bool | None = None
    status: str | None = None
    """订阅下载记录的状态（其他来源为 ``None``）。"""
    units: tuple[Unit, ...] = ()
    """覆盖的季集；空 = 未知或整部（电影）。"""
    file_ids: tuple[int, ...] = ()
    """媒体库里记着来自这个种子的文件。"""


@dataclass(frozen=True)
class ItemRelations:
    media_item_id: int
    subscription_id: int | None = None
    subscription_status: str | None = None
    torrents: list[TorrentLink] = field(default_factory=list)


def _units(raw: object) -> tuple[Unit, ...]:
    units: list[Unit] = []
    for unit in raw if isinstance(raw, list) else []:
        if isinstance(unit, (list, tuple)) and len(unit) == 2:
            try:
                units.append((int(unit[0]), int(unit[1])))
            except (TypeError, ValueError):
                continue
    return tuple(units)


async def item_relations(session: AsyncSession, media_item_id: int) -> ItemRelations:
    subscription = (
        await session.execute(
            select(Subscription).where(Subscription.media_item_id == media_item_id)
        )
    ).scalar_one_or_none()
    names = dict((await session.execute(select(DownloaderClient.id, DownloaderClient.name))).all())

    files = (
        await session.execute(
            select(
                LibraryFile.id,
                LibraryFile.info_hash,
                LibraryFile.downloader_id,
                LibraryFile.site_id,
                LibraryFile.torrent_id,
                LibraryFile.season_number,
                LibraryFile.episode_number,
            ).where(
                LibraryFile.media_item_id == media_item_id,
                LibraryFile.info_hash.is_not(None),  # type: ignore[union-attr]
            )
        )
    ).all()
    files_by_hash: dict[str, list[int]] = {}
    for row in files:
        files_by_hash.setdefault(row.info_hash.lower(), []).append(row.id)

    links: dict[tuple[int | None, str], TorrentLink] = {}

    def add(link: TorrentLink) -> None:
        key = (link.downloader_id, link.info_hash)
        if key not in links:
            links[key] = link

    if subscription is not None:
        attempts = (
            await session.execute(
                select(SubscriptionDownloadAttempt)
                .where(SubscriptionDownloadAttempt.subscription_id == subscription.id)
                .order_by(SubscriptionDownloadAttempt.id)
            )
        ).scalars()
        for attempt in attempts:
            info_hash = attempt.info_hash.lower()
            add(
                TorrentLink(
                    info_hash=info_hash,
                    downloader_id=attempt.downloader_id,
                    downloader_name=names.get(attempt.downloader_id),
                    title=attempt.torrent_title or attempt.download_name,
                    source="subscription",
                    site_id=attempt.site_id,
                    torrent_id=attempt.torrent_id,
                    owned_by_movieclaw=attempt.owned_by_movieclaw,
                    hit_and_run=attempt.hit_and_run,
                    status=attempt.status,
                    units=_units(attempt.units),
                    file_ids=tuple(files_by_hash.get(info_hash, ())),
                )
            )

    intents = (
        await session.execute(
            select(ManualDownloadIntent).where(ManualDownloadIntent.media_item_id == media_item_id)
        )
    ).scalars()
    for intent in intents:
        info_hash = intent.info_hash.lower()
        add(
            TorrentLink(
                info_hash=info_hash,
                downloader_id=intent.downloader_id,
                downloader_name=names.get(intent.downloader_id),
                title=intent.download_name,
                source="manual",
                site_id=intent.site_id,
                torrent_id=intent.torrent_id,
                owned_by_movieclaw=True,
                file_ids=tuple(files_by_hash.get(info_hash, ())),
            )
        )

    for row in files:
        info_hash = row.info_hash.lower()
        if any(h == info_hash for _, h in links):
            continue
        units = tuple(
            sorted(
                {
                    (f.season_number, f.episode_number)
                    for f in files
                    if f.info_hash.lower() == info_hash
                    and f.season_number is not None
                    and f.episode_number is not None
                }
            )
        )
        add(
            TorrentLink(
                info_hash=info_hash,
                downloader_id=row.downloader_id,
                downloader_name=names.get(row.downloader_id),
                title=None,
                source="file",
                site_id=row.site_id,
                torrent_id=row.torrent_id,
                units=units,
                file_ids=tuple(files_by_hash.get(info_hash, ())),
            )
        )

    return ItemRelations(
        media_item_id=media_item_id,
        subscription_id=subscription.id if subscription is not None else None,
        subscription_status=subscription.status if subscription is not None else None,
        torrents=list(links.values()),
    )
