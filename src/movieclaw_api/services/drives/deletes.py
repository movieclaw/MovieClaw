"""删网盘上的副本（docs/design/cloud-storage.md §10）。

语义与本地库一致：库里删片会删网盘上的文件（网盘有回收站就进回收站）。**只按台账里的文件 id
删**，绝不按路径、按目录删；只在两种情况下调用：用户在删除对话框里确认的删除、回收站清理。
纳管、同步、复查、对账永远不删网盘文件。

先删网盘再删台账：网盘没删掉就整件事不做（调用方据此保留台账行），不留「账没了、网盘上的
文件成了孤儿」。
"""

from __future__ import annotations

import logging
from collections.abc import Iterable

from sqlmodel import select

from movieclaw_api.services.drives import gateway
from movieclaw_db.engine import get_database
from movieclaw_db.models.library_file_replica import (
    REPLICA_DELETING,
    REPLICA_FAILED,
    REPLICA_LOST,
    REPLICA_UPLOADING,
    LibraryFileReplica,
)
from movieclaw_sdk import drives as dv

logger = logging.getLogger(__name__)

#: 一次调用最多删几个（插件契约）
BATCH = 100
#: 自动清理（回收站到期）一次最多删多少网盘文件；超过就等管理员确认（SmartStrm #37 的教训）
GUARD_FILES = 50
GUARD_BYTES = 200 * 1024**3


async def replicas_of(file_ids: Iterable[int]) -> list[LibraryFileReplica]:
    ids = list(file_ids)
    if not ids:
        return []
    async with get_database().session() as session:
        return list(
            (
                await session.execute(
                    select(LibraryFileReplica).where(
                        LibraryFileReplica.library_file_id.in_(ids)  # type: ignore[attr-defined]
                    )
                )
            )
            .scalars()
            .all()
        )


def needs_remote_call(replica: LibraryFileReplica) -> bool:
    """网盘上可能还有这个文件（要真的去删）。"""
    if not replica.remote_id:
        return False  # 还没传成：网盘上没有
    return replica.state not in (REPLICA_LOST, REPLICA_UPLOADING, REPLICA_FAILED)


def over_guard(replicas: list[LibraryFileReplica]) -> bool:
    """一次涉及的网盘文件是不是多到要等管理员确认（只用于自动清理）。"""
    live = [r for r in replicas if needs_remote_call(r)]
    return len(live) > GUARD_FILES or sum(r.size_bytes or 0 for r in live) > GUARD_BYTES


async def delete_cloud_copies(file_ids: Iterable[int]) -> str | None:
    """删掉这些库文件在网盘上的副本，并删副本记录。全部成功返回 None，否则返回原因（给用户看）。

    出错时网盘上可能已经删了一部分：删掉的那些副本记录照常清掉，没删的保持原样，调用方保留全部台账行，
    重试会把剩下的删完（已经不在的文件插件按删成功处理）。
    """
    from movieclaw_api.services.drives import sources

    replicas = await replicas_of(file_ids)
    if not replicas:
        return None
    by_account: dict[int, list[LibraryFileReplica]] = {}
    for replica in replicas:
        by_account.setdefault(replica.account_id, []).append(replica)
    done: list[LibraryFileReplica] = []
    error: str | None = None
    for account_id, group in by_account.items():
        live = [r for r in group if needs_remote_call(r)]
        done.extend(r for r in group if not needs_remote_call(r))
        for start in range(0, len(live), BATCH):
            chunk = live[start : start + BATCH]
            await _mark(chunk, REPLICA_DELETING)
            try:
                await gateway.call(
                    account_id,
                    "delete",
                    priority=gateway.Priority.USER,
                    remote_ids=[r.remote_id for r in chunk],
                )
            except dv.DriveError as exc:
                await _restore(chunk)
                error = f"网盘上的文件没删掉：{exc.message}"
                break
            except Exception as exc:  # noqa: BLE001 -- 插件不在等：这次不删
                await _restore(chunk)
                error = f"网盘上的文件没删掉：{exc}"
                break
            done.extend(chunk)
            for replica in chunk:
                sources.forget_links(account_id, replica.remote_id)
        if error is not None:
            break
    if done:
        async with get_database().session() as session:
            for replica in done:
                row = await session.get(LibraryFileReplica, replica.id)
                if row is not None:
                    await session.delete(row)
            await session.commit()
        for replica in done:
            await sources.refresh_file(replica.library_file_id)
        logger.info("已删除 %d 个网盘副本", len(done))
    return error


async def _mark(replicas: list[LibraryFileReplica], state: str) -> None:
    async with get_database().session() as session:
        for replica in replicas:
            row = await session.get(LibraryFileReplica, replica.id)
            if row is not None:
                row.state = state
                session.add(row)
        await session.commit()


async def _restore(replicas: list[LibraryFileReplica]) -> None:
    """删失败：副本回到删之前的状态。"""
    async with get_database().session() as session:
        for replica in replicas:
            row = await session.get(LibraryFileReplica, replica.id)
            if row is not None:
                row.state = replica.state
                session.add(row)
        await session.commit()
