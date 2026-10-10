"""媒体库文件的下载来源（docs/design/library-boundary.md §5；原 services/library/relations.py）。

种子关联属于下载领域：媒体库只管文件、条目、库、回收站。这里维护「哪个库文件来自哪个下载任务」
（``download_file_source``），并回答「一个条目背后是哪些订阅与下载器任务」。关联来自三处：

- 订阅下载记录（``subscription_download_attempt``）：订阅投递过的每个种子，
  含自有 / H&R 标记与覆盖的季集；
- 手动下载意图（``manual_download_intent``）：手动下载在入库前的锚；
- 文件来源记录（``download_file_source``，入库 / 扫描时由入库桥写入）。

同一个下载器任务按 ``(下载器, info_hash)`` 去重，来源按上面的顺序取第一个。查询只读。

**谁的数据谁清理**：来源记录不随库文件级联删除。文件行没了以后记录还在，下载模块据此处理删除；
处理不到的由 ``sweep_orphans`` 收尾。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field, replace
from datetime import timedelta

from sqlalchemy import delete, exists, func, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    DownloaderClient,
    DownloadFileSource,
    LibraryFile,
    ManualDownloadIntent,
    Subscription,
    SubscriptionDownloadAttempt,
    utcnow,
)
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_scheduler import register_task

logger = logging.getLogger("movieclaw_api.download_sources")

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
    """媒体库里记着来自这个种子的文件（本条目的）。"""
    other_file_ids: tuple[int, ...] = ()
    """同一个种子还供着的**别的**文件：其他条目、没识别的文件，跨库。合集 / 季包拆进了
    几个条目时，删这个种子会连带毁掉它们。"""


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
                DownloadFileSource.info_hash,
                DownloadFileSource.downloader_id,
                DownloadFileSource.site_id,
                DownloadFileSource.torrent_id,
                LibraryFile.season_number,
                LibraryFile.episode_number,
            )
            .join(DownloadFileSource, DownloadFileSource.library_file_id == LibraryFile.id)
            .where(
                LibraryFile.media_item_id == media_item_id,
                DownloadFileSource.info_hash.is_not(None),  # type: ignore[union-attr]
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

    # 同一个种子还供着哪些别的文件（任何条目、任何库，含没识别的行）
    hashes = {h for _, h in links}
    others: dict[str, list[int]] = {}
    if hashes:
        rows = (
            await session.execute(
                select(LibraryFile.id, DownloadFileSource.info_hash)
                .join(DownloadFileSource, DownloadFileSource.library_file_id == LibraryFile.id)
                .where(
                    DownloadFileSource.info_hash.in_(hashes),  # type: ignore[union-attr]
                    (LibraryFile.media_item_id != media_item_id)  # type: ignore[arg-type]
                    | LibraryFile.media_item_id.is_(None),  # type: ignore[union-attr]
                )
            )
        ).all()
        for row in rows:
            others.setdefault(row.info_hash.lower(), []).append(row.id)

    return ItemRelations(
        media_item_id=media_item_id,
        subscription_id=subscription.id if subscription is not None else None,
        subscription_status=subscription.status if subscription is not None else None,
        torrents=[
            replace(link, other_file_ids=tuple(sorted(others.get(link.info_hash, ()))))
            for link in links.values()
        ],
    )


# ---------------------------------------------------------------------- 按文件查种子


@dataclass(frozen=True)
class FileTorrent:
    """一组库文件背后的一个下载器任务（文件可以已经从媒体库删掉，来源记录还在）。"""

    info_hash: str
    downloader_id: int | None
    downloader_name: str | None
    title: str | None
    source: str
    """``subscription``（订阅投递）/ ``file``（只有文件来源记录）。"""
    subscription_id: int | None = None
    owned_by_movieclaw: bool | None = None
    hit_and_run: bool | None = None
    file_ids: tuple[int, ...] = ()
    """问到的文件里来自这个种子的。"""
    other_file_ids: tuple[int, ...] = ()
    """同一个种子还供着的、还在媒体库里的别的文件（任何条目、任何库）；非空时删种会连带毁掉它们。"""


async def stamps_for_files(
    session: AsyncSession, file_ids: list[int]
) -> dict[int, tuple[str, str | None]]:
    """这些库文件来自站点上的哪个种子：{文件 id: (站点, 种子编号)}，只含有站点的。"""
    if not file_ids:
        return {}
    rows = await session.execute(
        select(
            DownloadFileSource.library_file_id,
            DownloadFileSource.site_id,
            DownloadFileSource.torrent_id,
        ).where(
            DownloadFileSource.library_file_id.in_(file_ids),  # type: ignore[attr-defined]
            DownloadFileSource.site_id.is_not(None),  # type: ignore[union-attr]
        )
    )
    return {file_id: (site, torrent) for file_id, site, torrent in rows.all()}


async def torrents_for_files(session: AsyncSession, file_ids: list[int]) -> list[FileTorrent]:
    """这些库文件来自哪些下载器任务。只读；删除后（文件行已没了）照样能查。"""
    if not file_ids:
        return []
    sources = (
        await session.execute(
            select(DownloadFileSource).where(
                DownloadFileSource.library_file_id.in_(file_ids),  # type: ignore[attr-defined]
                DownloadFileSource.info_hash.is_not(None),  # type: ignore[union-attr]
            )
        )
    ).scalars()
    grouped: dict[tuple[int | None, str], list[int]] = {}
    for row in sources:
        assert row.info_hash is not None
        grouped.setdefault((row.downloader_id, row.info_hash), []).append(row.library_file_id)
    if not grouped:
        return []
    hashes = {h for _, h in grouped}
    names = dict((await session.execute(select(DownloaderClient.id, DownloaderClient.name))).all())
    attempts: dict[str, SubscriptionDownloadAttempt] = {}
    for attempt in (
        await session.execute(
            select(SubscriptionDownloadAttempt)
            .where(func.lower(SubscriptionDownloadAttempt.info_hash).in_(hashes))
            .order_by(SubscriptionDownloadAttempt.id)
        )
    ).scalars():
        attempts[attempt.info_hash.lower()] = attempt  # 同一种子多次投递取最近一次
    asked = set(file_ids)
    others: dict[str, list[int]] = {}
    for file_id, info_hash in (
        await session.execute(
            select(DownloadFileSource.library_file_id, DownloadFileSource.info_hash)
            .join(LibraryFile, LibraryFile.id == DownloadFileSource.library_file_id)
            .where(DownloadFileSource.info_hash.in_(hashes))  # type: ignore[union-attr]
        )
    ).all():
        if file_id not in asked:
            others.setdefault(info_hash, []).append(file_id)
    out: list[FileTorrent] = []
    for (downloader_id, info_hash), ids in grouped.items():
        attempt = attempts.get(info_hash)
        out.append(
            FileTorrent(
                info_hash=info_hash,
                downloader_id=downloader_id,
                downloader_name=names.get(downloader_id),
                title=(attempt.torrent_title or attempt.download_name) if attempt else None,
                source="subscription" if attempt else "file",
                subscription_id=attempt.subscription_id if attempt else None,
                owned_by_movieclaw=attempt.owned_by_movieclaw if attempt else None,
                hit_and_run=attempt.hit_and_run if attempt else None,
                file_ids=tuple(sorted(ids)),
                other_file_ids=tuple(sorted(others.get(info_hash, ()))),
            )
        )
    return out


# ---------------------------------------------------------------------- 写入与清扫

ORPHAN_GRACE = timedelta(days=7)
"""文件行没了以后，来源记录再留多久（等下载模块处理删除）。"""


async def record_source(
    session: AsyncSession,
    library_file_id: int | None,
    *,
    info_hash: str | None,
    downloader_id: int | None,
    site_id: str | None,
    torrent_id: str | None,
) -> None:
    """入库桥写完台账后调用：记下这个文件来自哪个下载任务（不提交，随调用方的事务）。

    知道什么更新什么：扫描重试不知道来源，不能把入库时记下的抹掉（台账旧列的站点 / 种子编号
    每次照写，扫描会把它们清空，这里不沿用）。什么都不知道且没有旧记录时不写。
    """
    if library_file_id is None:
        return
    row = (
        await session.execute(
            select(DownloadFileSource).where(DownloadFileSource.library_file_id == library_file_id)
        )
    ).scalar_one_or_none()
    known = any(v is not None for v in (info_hash, site_id, torrent_id))
    if row is None:
        if not known:
            return
        row = DownloadFileSource(library_file_id=library_file_id)
        session.add(row)
    if site_id is not None or torrent_id is not None:
        row.site_id = site_id
        row.torrent_id = torrent_id
    if info_hash is not None:
        row.info_hash = info_hash.lower()
        row.downloader_id = downloader_id
    row.orphaned_at = None
    row.updated_at = utcnow()


async def sweep_orphans(session: AsyncSession) -> int:
    """每日清扫：文件行已不在的来源记录先记下发现时间，满 ``ORPHAN_GRACE`` 删除。返回删除条数。"""
    now = utcnow()
    gone = ~exists().where(LibraryFile.id == DownloadFileSource.library_file_id)
    await session.execute(
        update(DownloadFileSource)
        .where(gone, DownloadFileSource.orphaned_at.is_(None))  # type: ignore[union-attr]
        .values(orphaned_at=now)
    )
    result = await session.execute(
        delete(DownloadFileSource).where(
            gone,
            DownloadFileSource.orphaned_at < now - ORPHAN_GRACE,  # type: ignore[operator]
        )
    )
    await session.commit()
    return result.rowcount or 0


@register_task(
    "download_sources_orphan_sweep",
    title="下载来源记录清扫",
    trigger_type=TriggerType.CRON,
    cron="50 4 * * *",
    description="库文件已删除、满 7 天仍没被处理的下载来源记录，清掉",
)
async def sweep_orphan_sources() -> None:
    async with get_database().session() as session:
        removed = await sweep_orphans(session)
    if removed:
        logger.info("已清掉 %d 条库文件已删除的下载来源记录", removed)
