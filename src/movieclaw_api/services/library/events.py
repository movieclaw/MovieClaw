"""媒体库域的事件产生（docs/design/domain-events.md §4、§8）：删除、回收站、整理入库。

只有媒体库自己的事实（library-boundary.md §3.6）：种子、订阅归别的领域，订阅方按文件 id、条目 id
经宿主操作去查。
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Iterable
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api import event_refs, events
from movieclaw_sdk.events import (
    LIBRARY_FILE_DELETED,
    LIBRARY_FILE_PURGED,
    LIBRARY_FILE_RESTORED,
    LIBRARY_FILE_TRASHED,
    LIBRARY_INGEST_COMPLETED,
    LIBRARY_ITEM_DELETED,
    FileRecycled,
    IngestCompleted,
    LibraryDeleted,
)


async def _media(session: AsyncSession, media_item_id: int | None):  # type: ignore[no-untyped-def]
    if media_item_id is None:
        return None
    from movieclaw_db.models import MediaItem

    return event_refs.media_ref(await session.get(MediaItem, media_item_id))


async def deletion_recorder(
    session: AsyncSession,
    library_id: int,
    item: Any,
    rows: list[Any],
    *,
    options: Iterable[str] = (),
) -> Callable[[set[int]], Awaitable[None]] | None:
    """删条目 / 删文件前调用：先拍快照（删完就查不到了），返回「按实际删掉的行发事件」的回调。

    没人订删除事件时返回 ``None``，删除路径上没有任何额外开销。
    """
    if not (
        await events.wanted(session, LIBRARY_ITEM_DELETED)
        or await events.wanted(session, LIBRARY_FILE_DELETED)
    ):
        return None
    snapshots = {row.id: event_refs.file_ref(row) for row in rows}
    media = event_refs.media_ref(item)
    chosen = tuple(options)

    async def record(deleted_ids: set[int]) -> None:
        deleted = [snapshots[i] for i in sorted(deleted_ids) if i in snapshots]
        if not deleted:
            return
        whole = len(deleted) == len(snapshots)
        await events.publish(
            session,
            LIBRARY_ITEM_DELETED if whole else LIBRARY_FILE_DELETED,
            lambda: LibraryDeleted(
                library_id=library_id,
                media=media,
                whole_item=whole,
                files=tuple(deleted),
                options=chosen,
            ),
        )

    return record


_RECYCLE_EVENTS = {
    "trashed": LIBRARY_FILE_TRASHED,
    "restored": LIBRARY_FILE_RESTORED,
    "purged": LIBRARY_FILE_PURGED,
}


async def publish_recycled(
    session: AsyncSession,
    kind: str,
    row: Any,
    *,
    reason: str | None = None,
    trigger: dict | None = None,
) -> None:
    """文件进回收站 / 恢复 / 彻底清除（随调用方的提交成立）。"""

    async def build() -> FileRecycled:
        context = row.trash_context or {}
        trig = trigger if trigger is not None else context.get("trigger") or {}
        return FileRecycled(
            file=event_refs.file_ref(row),
            media=await _media(session, row.media_item_id),
            reason=reason if reason is not None else context.get("reason"),
            trigger_kind=(trig or {}).get("kind"),
            trigger_id=None if (trig or {}).get("id") is None else str(trig["id"]),
        )

    await events.publish(session, _RECYCLE_EVENTS[kind], build)


async def publish_ingest_completed(
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
    """一个下载条目整理入库完成（随入库结论的那次提交成立）。"""
    names = tuple(dict.fromkeys(imported_names))
    hashes = tuple(sorted({h.lower() for h in info_hashes if h}))

    async def build() -> IngestCompleted | None:
        from sqlmodel import select

        from movieclaw_db.models import LibraryFile

        media = event_refs.media_ref(item)
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
        return IngestCompleted(
            media=media,
            library_id=library_id,
            files=tuple(event_refs.file_ref(row) for row in rows),
            imported_names=names,
            info_hashes=hashes,
            rule_id=rule_id,
            staging=staging,
            intent_owner=intent_owner,
        )

    await events.publish(session, LIBRARY_INGEST_COMPLETED, build)
