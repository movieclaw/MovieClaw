"""手动下载的「入库完成」：推给点下载的人（docs/design/cloud-push.md §5）。

提交下载时 ``remember`` 记下是谁点的（``push_download_watch``）。入库有两条路，各自对上：

- **监听导入**：入库那一刻按 infohash 对上（``ingested``，ingest 收尾时调）。边下边入库时
  一个种子分几批进来，每批记下批次号，整个种子入库完才推，推的是这次下载的全部季集；
- **直接下进库目录、靠扫描入账**：按「保存目录/任务名」这个路径对上（``match_scanned``，
  「媒体库有新片」的后台每两分钟调一次），这次下载的文件 3 分钟没有新的了才推。

和订阅入库同一个开关、同一张剧卡（cards.py）：只下了一部的进这部剧的卡，这几集已经在卡上
说过的（订阅对账、「媒体库有新片」）不再推。没对上的记录 30 天后清理。推送失败绝不影响
下载和入库。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import PurePosixPath

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import delete, select

from movieclaw_db.engine import get_database
from movieclaw_db.models import Library, LibraryFile, MediaItem, PushDownloadWatch, utcnow

logger = logging.getLogger("movieclaw_api.push.downloads")

#: 没对上的记录留多久（任务被删了、下到了不进媒体库的目录）
WATCH_TTL = timedelta(days=30)
#: 扫描入账：这次下载的文件这么久没有新的了，才算入库完（比「媒体库有新片」的 5 分钟
#: 短：点下载的人先收到「入库完成」，同一集「媒体库有新片」就不再推给他）
SCAN_QUIET = timedelta(minutes=3)
#: 一条汇总里点名的片数
NAMED_IN_SUMMARY = 3


@dataclass(frozen=True)
class Finished:
    """一次手动下载入库完了：推给谁、是哪些台账行。"""

    member_id: int
    library_id: int
    download_name: str | None
    batch_ids: tuple[str, ...] = ()
    row_ids: tuple[int, ...] = ()
    #: 这次一个新文件都没搬（内容早就在库里）时，点开到的条目
    fallback_item_id: int | None = None


async def remember(
    *, member_id: int, info_hash: str, save_path: str | None, download_name: str | None
) -> None:
    """提交下载后记下是谁点的。同一个人重复提交同一个种子只记一次；出错只记日志。"""
    try:
        async with get_database().session() as session:
            await session.execute(
                delete(PushDownloadWatch).where(
                    PushDownloadWatch.created_at < utcnow() - WATCH_TTL  # type: ignore[arg-type]
                )
            )
            normalized = info_hash.lower()
            exists = (
                await session.execute(
                    select(PushDownloadWatch.id).where(  # type: ignore[call-overload]
                        PushDownloadWatch.member_id == member_id,
                        PushDownloadWatch.info_hash == normalized,
                    )
                )
            ).first()
            if exists is None:
                session.add(
                    PushDownloadWatch(
                        member_id=member_id,
                        info_hash=normalized,
                        save_path=save_path,
                        download_name=download_name,
                    )
                )
            await session.commit()
    except Exception:  # noqa: BLE001 -- 推送记录出错不能让下载提交失败
        logger.exception("记录手动下载的推送对象失败（已忽略）")


async def ingested(
    session: AsyncSession,
    *,
    hashes: list[str],
    complete: list[str],
    batch_id: str,
    imported: bool,
    library_id: int,
    item_id: int | None,
) -> list[Finished]:
    """监听导入把这些种子的文件入库了。ingest 在提交入库结论之前调，改动随它一起提交。

    ``hashes`` 是这次入库涉及的种子，``complete`` 是其中已经整个入库完的；``imported``
    为假表示这一批没有搬进新文件（内容早就在库里）。返回入库完的，调用方提交之后交给
    ``announce`` 推送。
    """
    if not hashes:
        return []
    watches = (
        (
            await session.execute(
                select(PushDownloadWatch).where(
                    PushDownloadWatch.info_hash.in_([h.lower() for h in hashes])  # type: ignore[attr-defined]
                )
            )
        )
        .scalars()
        .all()
    )
    done = {h.lower() for h in complete}
    finished: list[Finished] = []
    for watch in watches:
        if imported and batch_id not in watch.batch_ids:
            watch.batch_ids = [*watch.batch_ids, batch_id]
            session.add(watch)
        if watch.info_hash in done:
            finished.append(
                Finished(
                    member_id=watch.member_id,
                    library_id=library_id,
                    download_name=watch.download_name,
                    batch_ids=tuple(watch.batch_ids),
                    fallback_item_id=item_id,
                )
            )
            await session.delete(watch)
    return finished


async def match_scanned(session: AsyncSession, now: datetime) -> list[Finished]:
    """直接下进库目录的：按路径找这次下载入账的文件，入完了就推。返回推了的。"""
    await session.execute(
        delete(PushDownloadWatch).where(
            PushDownloadWatch.created_at < now - WATCH_TTL  # type: ignore[arg-type]
        )
    )
    watches = (
        (
            await session.execute(
                select(PushDownloadWatch).where(
                    PushDownloadWatch.save_path.is_not(None),  # type: ignore[union-attr]
                    PushDownloadWatch.download_name.is_not(None),  # type: ignore[union-attr]
                )
            )
        )
        .scalars()
        .all()
    )
    finished: list[Finished] = []
    for watch in watches:
        base = str(PurePosixPath(watch.save_path or "") / (watch.download_name or ""))
        rows = (
            await session.execute(
                select(LibraryFile.id, LibraryFile.library_id, LibraryFile.created_at).where(  # type: ignore[call-overload]
                    LibraryFile.created_at >= watch.created_at,
                    (LibraryFile.file_path == base)
                    | LibraryFile.file_path.startswith(base + "/", autoescape=True),  # type: ignore[attr-defined]
                )
            )
        ).all()
        rows = [r for r in rows if r.library_id is not None]
        if not rows or max(r.created_at for r in rows) > now - SCAN_QUIET:
            continue  # 还没入账，或者还在陆续入账
        library_id = rows[0].library_id
        finished.append(
            Finished(
                member_id=watch.member_id,
                library_id=library_id,
                download_name=watch.download_name,
                row_ids=tuple(r.id for r in rows if r.library_id == library_id),
            )
        )
        await session.delete(watch)
    await session.commit()
    return finished


def announce(items: list[Finished]) -> None:
    """推「入库完成」给点下载的人：投事件，进这部剧的卡（cards.py）。"""
    from movieclaw_api.services.push.hub import Downloaded, emit

    for done in items:
        emit(Downloaded(finished=done))


async def units_of(session: AsyncSession, done: Finished) -> dict[int, list[tuple[int, int]]]:
    """这次下载入库的条目 → 单元（按入库顺序）。一个新文件都没搬时是兜底条目的整部。"""
    rows = []
    if done.batch_ids or done.row_ids:
        condition = (
            LibraryFile.added_batch_id.in_(done.batch_ids)  # type: ignore[union-attr]
            if done.batch_ids
            else LibraryFile.id.in_(done.row_ids)  # type: ignore[union-attr]
        )
        rows = (
            await session.execute(
                select(  # type: ignore[call-overload]
                    LibraryFile.media_item_id,
                    LibraryFile.season_number,
                    LibraryFile.episode_number,
                )
                .where(LibraryFile.library_id == done.library_id, condition)
                .order_by(LibraryFile.id)
            )
        ).all()
    units: dict[int, list[tuple[int, int]]] = {}
    for item_id, season, episode in rows:
        if item_id is not None:
            found = units.setdefault(int(item_id), [])
            if (int(season), int(episode)) not in found:
                found.append((int(season), int(episode)))
    if not units and done.fallback_item_id is not None:
        units[done.fallback_item_id] = [(0, 0)]
    return units


def announce_summary(done: Finished, item_ids: list[int]) -> None:
    """一次下载里有好几部（合集、「其他」库的一堆视频）：合成「你下载的 N 部已入库」。"""
    from movieclaw_api.services.channel_push import tmdb_push_image_url
    from movieclaw_api.services.push.events import _lazy_image
    from movieclaw_api.services.push.notify import AlertContent, notify

    async def build(session: AsyncSession, member_id: int) -> AlertContent | None:
        items = [item for i in item_ids if (item := await session.get(MediaItem, i)) is not None]
        if not items:
            return None
        library = await session.get(Library, done.library_id)
        videos = library is not None and library.kind not in ("movie", "tv")
        names = "、".join(item.title for item in items[:NAMED_IN_SUMMARY])
        more = "等" if len(items) > NAMED_IN_SUMMARY else ""
        image = _lazy_image(tmdb_push_image_url(items[0].backdrop_path, items[0].poster_path))
        return AlertContent(
            title=f"你下载的 {len(items)} {'个视频' if videos else '部'}已入库",
            body=f"{names}{more}，点开就能看",
            image=await image(),
            open=f"/library/{done.library_id}",
            thread=f"download-{done.library_id}",
        )

    notify("imported", {done.member_id}, build)
