"""第一批领域事件（docs/design/plugin-phase2a.md §4）。

全部是可靠事件（随记录事实的那次提交成立、至少一次投递）、实验级契约，供插件订阅::

    @plugin("acme.cascade", inject=(DURABLE_EVENTS,))
    async def apply(ctx):
        ctx.on(LIBRARY_ITEM_DELETED, on_deleted, id="cascade")

载荷是**发生时的快照**：删除类事件里的条目、文件、关联种子在事件投递时多半已经查不到了。
业务侧经 ``record_*`` 写入；没有插件订阅某个事件时，这里连快照都不拍（一次内存查找就返回）。
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Iterable
from typing import Any

from pydantic import BaseModel, ConfigDict
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services import durable_events
from movieclaw_kernel import Delivery, Event, Mode, Stability

Unit = tuple[int, int]


class _Frozen(BaseModel):
    model_config = ConfigDict(frozen=True)


class MediaRef(_Frozen):
    """媒体条目快照。"""

    id: int
    kind: str
    title: str
    original_title: str | None = None
    year: int | None = None
    tmdb_id: int | None = None
    imdb_id: str | None = None


class FileRef(_Frozen):
    """媒体库文件快照。"""

    id: int
    library_id: int
    season: int | None = None
    episode: int | None = None
    path: str
    original_path: str | None = None
    """在回收站里时，进回收站之前的路径。"""
    size_bytes: int | None = None
    info_hash: str | None = None
    downloader_id: int | None = None


class TorrentRef(_Frozen):
    """与条目相关的下载器任务。"""

    info_hash: str
    downloader_id: int | None = None
    title: str | None = None
    source: str
    """``subscription`` / ``manual`` / ``file``，见 services/download_sources.py。"""
    site_id: str | None = None
    torrent_id: str | None = None
    owned_by_movieclaw: bool | None = None
    hit_and_run: bool | None = None
    shared: bool = False
    """这个种子还供着本次没删的文件：季包删了一集，或合集 / 季包还拆在别的条目、别的库、
    没识别的文件里。删种会连带毁掉它们。"""


class Links(_Frozen):
    subscription_id: int | None = None
    subscription_status: str | None = None
    torrents: tuple[TorrentRef, ...] = ()


class LibraryDeleted(_Frozen):
    """从磁盘删除了条目在某个库里的全部文件（``whole_item``）或其中一部分。"""

    library_id: int
    media: MediaRef | None
    whole_item: bool
    files: tuple[FileRef, ...]
    links: Links


class LibraryFileRecycled(_Frozen):
    """文件进回收站 / 从回收站恢复 / 被彻底清除。"""

    file: FileRef
    media: MediaRef | None
    reason: str | None = None
    """``upgrade_replaced`` / ``upgrade_refuted`` / ``duplicate_cleanup`` /
    ``subscription_cancelled`` / ``expired``（到期清除）/ ``manual``。"""
    trigger_kind: str | None = None
    trigger_id: str | None = None


class DownloadCompleted(_Frozen):
    """订阅投递的种子在下载器里下载完成（入库之前）。"""

    subscription_id: int
    media: MediaRef | None
    units: tuple[Unit, ...]
    info_hash: str
    downloader_id: int | None
    site_id: str | None = None
    torrent_id: str | None = None
    title: str | None = None
    save_path: str | None = None
    download_name: str | None = None
    purpose: str = "download"
    """``download`` / ``upgrade``（洗版）。"""


class IngestImported(_Frozen):
    """一个下载条目整理入库完成。"""

    media: MediaRef
    library_id: int | None
    """入到哪个库；自定义目录（暂存）规则为 ``None``。"""
    files: tuple[FileRef, ...]
    """本次新入账的文件（暂存规则不入账，为空）。"""
    imported_names: tuple[str, ...]
    """条目内被整理的源文件名（相对路径）。"""
    info_hashes: tuple[str, ...]
    rule_id: int | None = None
    staging: bool = False
    intent_owner: str | None = None
    """手动下载意图的归属：``manual`` / ``plugin:<条目 id>``；不是手动下载为 ``None``。"""


class SubscriptionChanged(_Frozen):
    subscription_id: int
    media: MediaRef | None
    member_id: int | None = None
    """发起人成员；``None`` = 超管。"""
    status: str | None = None
    previous_status: str | None = None
    reason: str | None = None
    cleanup_job_id: str | None = None
    """删除时一并发起的清理任务。"""


class SubscriptionUnits(_Frozen):
    subscription_id: int
    media: MediaRef
    units: tuple[Unit, ...]
    info_hash: str | None = None
    site_id: str | None = None
    torrent_title: str | None = None
    upgrade: bool = False


def _event(name: str, payload: type, doc: str) -> Event[Any, Any]:
    return Event(
        name,
        Mode.EMIT,
        payload=payload,
        delivery=Delivery.DURABLE,
        stability=Stability.EXPERIMENTAL,
        doc=doc,
    )


LIBRARY_ITEM_DELETED = _event(
    "library.item.deleted", LibraryDeleted, "条目在某个库里的文件已从磁盘全部删除"
)
LIBRARY_FILE_DELETED = _event("library.file.deleted", LibraryDeleted, "条目的部分文件已从磁盘删除")
LIBRARY_FILE_TRASHED = _event("library.file.trashed", LibraryFileRecycled, "文件进了回收站")
LIBRARY_FILE_RESTORED = _event("library.file.restored", LibraryFileRecycled, "文件从回收站恢复")
LIBRARY_FILE_PURGED = _event("library.file.purged", LibraryFileRecycled, "回收站里的文件被彻底清除")
DOWNLOAD_COMPLETED = _event("download.completed", DownloadCompleted, "订阅投递的种子下载完成")
LIBRARY_INGEST_IMPORTED = _event("library.ingest.imported", IngestImported, "下载条目整理入库完成")
SUBSCRIPTION_CREATED = _event("subscription.created", SubscriptionChanged, "新建了订阅")
SUBSCRIPTION_DELETED = _event("subscription.deleted", SubscriptionChanged, "订阅被删除")
SUBSCRIPTION_STATUS_CHANGED = _event(
    "subscription.status-changed", SubscriptionChanged, "订阅状态变化（追踪中 / 已收齐 / 暂停）"
)
SUBSCRIPTION_DOWNLOAD_STARTED = _event(
    "subscription.download-started", SubscriptionUnits, "订阅的种子已真实提交下载器"
)
SUBSCRIPTION_FULFILLED = _event(
    "subscription.fulfilled", SubscriptionUnits, "订阅的季集已由媒体库对账确认入库"
)


# ---------------------------------------------------------------------- 快照


def media_ref(item: Any) -> MediaRef | None:
    if item is None or item.id is None:
        return None
    return MediaRef(
        id=item.id,
        kind=item.kind,
        title=item.title,
        original_title=item.original_title,
        year=item.year,
        tmdb_id=item.tmdb_id,
        imdb_id=item.imdb_id,
    )


def file_ref(row: Any) -> FileRef:
    return FileRef(
        id=row.id,
        library_id=row.library_id,
        season=row.season_number,
        episode=row.episode_number,
        path=row.file_path,
        original_path=row.trash_original_path,
        size_bytes=row.size_bytes,
        info_hash=row.info_hash,
        downloader_id=row.downloader_id,
    )


def _units(raw: Iterable[Any]) -> tuple[Unit, ...]:
    units: list[Unit] = []
    for unit in raw or ():
        if isinstance(unit, (list, tuple)) and len(unit) == 2:
            try:
                units.append((int(unit[0]), int(unit[1])))
            except (TypeError, ValueError):
                continue
    return tuple(units)


async def record_lazy(
    session: AsyncSession,
    event: Event[Any, Any],
    build: Callable[[], Awaitable[Any]],
) -> bool:
    """没有订阅者就连快照都不拍；有才构造载荷并写入（随调用方的下一次提交成立）。"""
    if not await durable_events.wanted(session, event):
        return False
    payload = await build()
    if payload is None:
        return False
    return await durable_events.record(session, event, payload)


async def _media(session: AsyncSession, media_item_id: int | None) -> MediaRef | None:
    if media_item_id is None:
        return None
    from movieclaw_db.models import MediaItem

    return media_ref(await session.get(MediaItem, media_item_id))


# ---------------------------------------------------------------------- 删除


async def deletion_recorder(
    session: AsyncSession, library_id: int, item: Any, rows: list[Any]
) -> Callable[[set[int]], Awaitable[None]] | None:
    """删条目 / 删文件前调用：先把关联拍好（删完就查不到了），返回「按实际删掉的行写事件」的回调。

    没有插件订阅删除事件时返回 ``None``，删除路径上没有任何额外查询。
    """
    if not (
        await durable_events.wanted(session, LIBRARY_ITEM_DELETED)
        or await durable_events.wanted(session, LIBRARY_FILE_DELETED)
    ):
        return None
    from movieclaw_api.services.download_sources import item_relations

    relations = await item_relations(session, item.id)
    snapshots = {row.id: file_ref(row) for row in rows}
    media = media_ref(item)

    async def record(deleted_ids: set[int]) -> None:
        deleted = [snapshots[i] for i in sorted(deleted_ids) if i in snapshots]
        if not deleted:
            return
        whole = len(deleted) == len(snapshots)
        deleted_units = {(f.season, f.episode) for f in deleted}
        torrents: list[TorrentRef] = []
        for link in relations.torrents:
            touches = (
                not link.units
                or any(u in deleted_units for u in link.units)
                or any(fid in deleted_ids for fid in link.file_ids)
            )
            if not whole and not touches:
                continue
            keeps_files = bool(link.other_file_ids) or any(
                fid not in deleted_ids for fid in link.file_ids
            )
            keeps_units = not whole and bool(link.units) and not set(link.units) <= deleted_units
            torrents.append(
                TorrentRef(
                    info_hash=link.info_hash,
                    downloader_id=link.downloader_id,
                    title=link.title,
                    source=link.source,
                    site_id=link.site_id,
                    torrent_id=link.torrent_id,
                    owned_by_movieclaw=link.owned_by_movieclaw,
                    hit_and_run=link.hit_and_run,
                    shared=keeps_files or keeps_units,
                )
            )
        payload = LibraryDeleted(
            library_id=library_id,
            media=media,
            whole_item=whole,
            files=tuple(deleted),
            links=Links(
                subscription_id=relations.subscription_id,
                subscription_status=relations.subscription_status,
                torrents=tuple(torrents),
            ),
        )
        await durable_events.record(
            session, LIBRARY_ITEM_DELETED if whole else LIBRARY_FILE_DELETED, payload
        )

    return record


# ---------------------------------------------------------------------- 回收站


async def record_recycled(
    session: AsyncSession,
    event: Event[Any, Any],
    row: Any,
    *,
    reason: str | None = None,
    trigger: dict | None = None,
) -> None:
    async def build() -> LibraryFileRecycled:
        context = row.trash_context or {}
        trig = trigger if trigger is not None else context.get("trigger") or {}
        return LibraryFileRecycled(
            file=file_ref(row),
            media=await _media(session, row.media_item_id),
            reason=reason if reason is not None else context.get("reason"),
            trigger_kind=(trig or {}).get("kind"),
            trigger_id=None if (trig or {}).get("id") is None else str(trig["id"]),
        )

    await record_lazy(session, event, build)


# ---------------------------------------------------------------------- 下载与入库


async def record_download_completed(session: AsyncSession, attempt: Any) -> None:
    async def build() -> DownloadCompleted:
        from movieclaw_db.models import Subscription

        subscription = await session.get(Subscription, attempt.subscription_id)
        return DownloadCompleted(
            subscription_id=attempt.subscription_id,
            media=await _media(session, subscription.media_item_id if subscription else None),
            units=_units(attempt.units),
            info_hash=attempt.info_hash.lower(),
            downloader_id=attempt.downloader_id,
            site_id=attempt.site_id,
            torrent_id=attempt.torrent_id,
            title=attempt.torrent_title or None,
            save_path=attempt.save_path,
            download_name=attempt.download_name,
            purpose=attempt.purpose,
        )

    await record_lazy(session, DOWNLOAD_COMPLETED, build)


async def record_ingest_imported(
    session: AsyncSession,
    *,
    item: Any,
    library_id: int | None,
    batch_id: str,
    imported_names: Iterable[str],
    info_hashes: Iterable[str],
    rule_id: int | None,
    staging: bool,
    intent_owner: str | None,
) -> None:
    async def build() -> IngestImported | None:
        from sqlmodel import select

        from movieclaw_db.models import LibraryFile

        media = media_ref(item)
        if media is None:
            return None
        rows = (
            (
                await session.execute(
                    select(LibraryFile)
                    .where(LibraryFile.added_batch_id == batch_id)
                    .order_by(LibraryFile.id)
                )
            )
            .scalars()
            .all()
        )
        return IngestImported(
            media=media,
            library_id=library_id,
            files=tuple(file_ref(row) for row in rows),
            imported_names=tuple(dict.fromkeys(imported_names)),
            info_hashes=tuple(sorted({h.lower() for h in info_hashes if h})),
            rule_id=rule_id,
            staging=staging,
            intent_owner=intent_owner,
        )

    await record_lazy(session, LIBRARY_INGEST_IMPORTED, build)


# ---------------------------------------------------------------------- 订阅


async def record_subscription(
    session: AsyncSession,
    event: Event[Any, Any],
    subscription: Any,
    *,
    previous_status: str | None = None,
    reason: str | None = None,
    cleanup_job_id: str | None = None,
) -> None:
    async def build() -> SubscriptionChanged | None:
        if subscription.id is None:
            return None
        return SubscriptionChanged(
            subscription_id=subscription.id,
            media=await _media(session, subscription.media_item_id),
            member_id=subscription.created_by_member_id,
            status=str(subscription.status) if subscription.status is not None else None,
            previous_status=previous_status,
            reason=reason,
            cleanup_job_id=cleanup_job_id,
        )

    await record_lazy(session, event, build)


async def record_subscription_units(
    session: AsyncSession,
    event: Event[Any, Any],
    *,
    subscription_id: int,
    item: Any,
    units: Iterable[Unit],
    info_hash: str | None = None,
    site_id: str | None = None,
    torrent_title: str | None = None,
    upgrade: bool = False,
) -> None:
    async def build() -> SubscriptionUnits | None:
        media = media_ref(item)
        if media is None:
            return None
        return SubscriptionUnits(
            subscription_id=subscription_id,
            media=media,
            units=tuple(units),
            info_hash=info_hash.lower() if info_hash else None,
            site_id=site_id,
            torrent_title=torrent_title,
            upgrade=upgrade,
        )

    await record_lazy(session, event, build)
