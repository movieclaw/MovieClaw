"""上传核验过的库文件腾空本地（docs/design/cloud-storage.md §6）。

主根在网盘、没开「本地也保留一份」的库，文件传到网盘并核验后删掉本地那份，之后播放、转码都读网盘。
这是整条链上唯一不可逆的一步，所以闸门全部满足才动手：

1. 副本已核验；
2. 本地的派生活做完了（登记在 ``GATES``：规格、开着的章节、开着的片头片尾识别）。副本核验满 24 小时
   还没做完就照常腾空，没做完的以后按需远程补；
3. 现在没人在读这个本地文件（转码会话、离线导出、两分钟内的直出取流）；
4. 再核一遍：本地大小与修改时间和算指纹时一样，网盘上的文件还在、大小一样。

动作**先记台账再删文件**：先提交 ``local_bytes = false``，再删库内文件（旁车不删），删失败改回来。
顺序反过来，实时监控收到删除事件触发的扫描会把还标着本地在的行判成缺失。删掉后从它所在的目录往上
清掉变空的目录（非空即停、到库根即停），旁车还在的目录原样留着。腾空后发事件
``library.file.local-released``，下载模块据此清掉做完使命的下载任务（硬链接入库时空间要等那份
也删了才回来）。
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from collections.abc import Awaitable, Callable
from datetime import timedelta
from pathlib import Path

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.engine import get_database
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.library import Library
from movieclaw_db.models.library_file import FileState, LibraryFile
from movieclaw_db.models.library_file_replica import REPLICA_VERIFIED, LibraryFileReplica
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_db.repositories.library_cloud_repo import LibraryCloudRepository
from movieclaw_playback.streaming import is_strm
from movieclaw_scheduler.registry import register_task
from movieclaw_sdk import drives as dv

logger = logging.getLogger(__name__)

#: 副本核验满这么久，派生活没做完也照常腾空
GATE_TIMEOUT = timedelta(hours=24)
#: 直出取流过去这么久没有新请求，才算没人在读
READ_QUIET_S = 120.0
#: 每轮巡检最多腾几个（每个要一次 stat）
SWEEP_BATCH = 50

#: 一道派生活闸门：还在等这个文件就返回原因（给日志看），做完或不适用返回 None
Gate = Callable[[AsyncSession, Library, LibraryFile], Awaitable[str | None]]


async def _specs_probed(session: AsyncSession, library: Library, file: LibraryFile) -> str | None:
    if file.probe_version is None or file.audio_streams is None:
        return "规格还没探出来"
    return None


async def _chapters_done(session: AsyncSession, library: Library, file: LibraryFile) -> str | None:
    if library.extract_chapter_images and file.chapter_images is None:
        return "章节图还没生成"
    return None


async def _segments_done(session: AsyncSession, library: Library, file: LibraryFile) -> str | None:
    from movieclaw_db.models.media_segment import MediaSegmentState

    if library.kind != "tv" or not library.detect_media_segments:
        return None
    state = await session.get(MediaSegmentState, file.id)
    if state is None or state.fingerprint_status == "pending":
        return "片头片尾指纹还没算"
    return None


#: 派生活登记表（§6.1 第 2 条）：需要读本地字节、腾空后远程补很贵的活在这里登记
GATES: list[Gate] = [_specs_probed, _chapters_done, _segments_done]

_reads: dict[int, float] = {}


def note_read(file_id: int) -> None:
    """直出取流读了这个文件的本地字节（取流入口调用）。

    没有网盘后端时不记（cloud-storage.md §11.8）。
    """
    from movieclaw_api.services.drives.registry import active

    if active():
        _reads[file_id] = time.monotonic()


def _recently_read(file_id: int) -> bool:
    last = _reads.get(file_id)
    return last is not None and time.monotonic() - last < READ_QUIET_S


def _in_use(file_id: int) -> bool:
    from movieclaw_api.services.playback.session import get_session_manager

    return _recently_read(file_id) or file_id in get_session_manager().files_in_use()


def _stat(path: Path) -> os.stat_result | None:
    try:
        return path.stat()
    except OSError:
        return None


async def try_release(file_id: int) -> str | None:
    """腾空一个文件的本地副本。腾空了返回 None，没动返回原因。"""
    from movieclaw_api.services.drives import gateway, sources
    from movieclaw_api.services.library.organize import _prune_emptied_dirs

    async with get_database().session() as session:
        file = await session.get(LibraryFile, file_id)
        if file is None or file.state != FileState.IN_PLACE or not file.local_bytes:
            return "不是在位的本地文件"
        if is_strm(file.file_path):
            return "strm 占位文件不腾空"
        library = await session.get(Library, file.library_id)
        repo = LibraryCloudRepository(session)
        folder = await repo.primary_folder(file.library_id)
        if library is None or folder is None:
            return "库的主根不在网盘"
        if library.keep_local:
            return "这个库开着「本地也保留一份」"
        replica = await repo.replica_of(file_id)
        if replica is None or replica.state != REPLICA_VERIFIED:
            return "网盘副本还没核验"
        fingerprint = await repo.fingerprint_of(file_id)
        if fingerprint is None:
            return "没有本地指纹"
        timed_out = (
            replica.verified_at is not None and utcnow() - replica.verified_at > GATE_TIMEOUT
        )
        if not timed_out:
            for gate in GATES:
                reason = await gate(session, library, file)
                if reason is not None:
                    return reason
        path = Path(file.file_path)
        roots = [r.rstrip("/") for r in library.root_paths]
        account_id, remote_id = replica.account_id, replica.remote_id
        remote_size = replica.size_bytes
    if _in_use(file_id):
        return "有人正在读这个文件"
    stat = await asyncio.to_thread(_stat, path)
    if stat is None:
        return "本地文件不见了"
    if (stat.st_size, stat.st_mtime_ns) != (fingerprint.size_bytes, fingerprint.file_mtime_ns):
        return "本地文件在指纹之后变过"
    try:
        remote = await gateway.call(
            account_id, "stat", priority=gateway.Priority.BACKGROUND, remote_id=remote_id
        )
    except dv.DriveError as exc:
        return f"网盘那份核对不了：{exc.message}"
    if remote.size != stat.st_size or (remote_size is not None and remote.size != remote_size):
        return "网盘那份大小对不上"
    hardlinked = stat.st_nlink > 1
    # 先记台账，再删文件
    async with get_database().session() as session:
        file = await session.get(LibraryFile, file_id)
        if file is None or not file.local_bytes:
            return "台账已经变了"
        file.local_bytes = False
        file.local_released_at = utcnow()
        file.updated_at = utcnow()
        session.add(file)
        await session.commit()
        library_id = file.library_id
    try:
        await asyncio.to_thread(path.unlink)
    except OSError as exc:
        async with get_database().session() as session:
            file = await session.get(LibraryFile, file_id)
            if file is not None:
                file.local_bytes = True
                file.local_released_at = None
                session.add(file)
                await session.commit()
        logger.warning("腾空本地失败（已改回本地在）：%s（%s）", path, exc)
        return f"删不掉本地文件：{exc}"
    # 只清变空的目录：还有旁车或别的文件就非空，rmdir 不动它
    await asyncio.to_thread(_prune_emptied_dirs, {path.parent}, roots)
    await sources.refresh_file(file_id)
    await _publish(library_id, file_id, stat.st_size, hardlinked)
    logger.info("已腾空本地（网盘上有核验过的副本）：%s", path.name)
    return None


async def _publish(library_id: int, file_id: int, size: int, hardlinked: bool) -> None:
    from movieclaw_api import events
    from movieclaw_sdk.events import LIBRARY_FILE_LOCAL_RELEASED, LocalReleased

    await events.publish_now(
        LIBRARY_FILE_LOCAL_RELEASED,
        lambda: LocalReleased(
            library_id=library_id, file_id=file_id, bytes=size, hardlinked=hardlinked
        ),
    )


async def candidates(limit: int = SWEEP_BATCH) -> list[int]:
    """可能该腾空的文件：主根在网盘、没开保留本地的库里，本地还在、副本已核验的。"""
    async with get_database().session() as session:
        folders = await LibraryCloudRepository(session).primary_folders()
        library_ids = [f.library_id for f in folders]
        if not library_ids:
            return []
        rows = (
            await session.execute(
                select(LibraryFile.id)
                .join(LibraryFileReplica, LibraryFileReplica.library_file_id == LibraryFile.id)
                .join(Library, Library.id == LibraryFile.library_id)
                .where(
                    LibraryFile.library_id.in_(library_ids),  # type: ignore[attr-defined]
                    LibraryFile.local_bytes.is_(True),  # type: ignore[attr-defined]
                    LibraryFile.state == FileState.IN_PLACE,
                    ~LibraryFile.strm_path(),
                    LibraryFileReplica.state == REPLICA_VERIFIED,
                    Library.keep_local.is_(False),  # type: ignore[attr-defined]
                )
                .order_by(LibraryFileReplica.verified_at)
                .limit(limit)
            )
        ).all()
    return [row[0] for row in rows]


@register_task(
    "drive_release_sweep",
    title="网盘库腾空本地",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=600,
    description=(
        "主根在网盘的库：已上传并核验、本地派生活做完、没人在读的文件，删掉本地那份（旁车文件保留）。"
        "开了「本地也保留一份」的库不腾空。"
    ),
)
async def release_sweep() -> int:
    released = 0
    for file_id in await candidates():
        try:
            if await try_release(file_id) is None:
                released += 1
        except Exception:  # noqa: BLE001 -- 一个文件出错不影响其余
            logger.exception("腾空本地出错：文件 #%s", file_id)
    if released:
        logger.info("网盘库腾空本地：%d 个文件", released)
    return released
