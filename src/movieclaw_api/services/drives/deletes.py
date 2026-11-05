"""删网盘上的副本（docs/design/cloud-storage.md §10）。

语义与本地库一致：库里删片会删网盘上的文件（网盘有回收站就进回收站）。**只按台账里的文件 id
删**，绝不按路径、按目录删；只在两种情况下调用：用户在删除对话框里确认的删除、回收站清理。
纳管、同步、复查、对账永远不删网盘文件。

先删网盘再删台账：网盘没删掉就整件事不做（调用方据此保留台账行），不留「账没了、网盘上的
文件成了孤儿」。

只读后端（``writable=False``）绝不调写方法：要删的文件在它上面就拒绝
（docs/design/media-server-plugins.md §4）。一次删除里混着可写网盘时先整批看过，
发现只读或确认不了写能力的账号就直接拒绝，可写那边也不会先删。
"""

from __future__ import annotations

import logging
from collections.abc import Iterable

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.i18n import t
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.services.drives import gateway
from movieclaw_api.services.drives.messages import error_reference
from movieclaw_api.services.drives.registry import backends
from movieclaw_db.engine import get_database
from movieclaw_db.models.library_file_replica import (
    REPLICA_DELETING,
    REPLICA_FAILED,
    REPLICA_LOST,
    REPLICA_UPLOADING,
    LibraryFileReplica,
)
from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository
from movieclaw_db.repositories.library_cloud_repo import LibraryCloudRepository
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


async def _write_access(session: AsyncSession, account_id: int) -> tuple[str, str]:
    """这个账号能不能写：（``writable`` / ``read_only`` / ``unavailable``，给人看的名字）。

    插件不在注册表里是 ``unavailable``：确认不了能力，不能当成能写。
    """
    account = await DriveAccountRepository(session).get(account_id)
    if account is None:
        return "unavailable", ""
    backend = backends().get(account.backend)
    if backend is None:
        return "unavailable", account.backend
    if backend.capabilities.writable:
        return "writable", backend.title
    return "read_only", backend.title


def _write_refusal(kind: str, label: str) -> str:
    if kind == "read_only":
        return t("errors.drives.readOnly", name=label)
    return t("errors.driveLogin.backendUnavailable", type=label or "?")


async def on_read_only_backend(session: AsyncSession, file_id: int) -> bool:
    """这个库文件的副本不能写：只读，或插件不在、确认不了能不能写。

    自动清理不能动它。插件停用期间也不当成能写。
    """
    account_id = (
        await session.execute(
            select(LibraryFileReplica.account_id).where(
                LibraryFileReplica.library_file_id == file_id
            )
        )
    ).scalar_one_or_none()
    if account_id is None:
        return False
    kind, _label = await _write_access(session, account_id)
    return kind != "writable"


async def _unwritable_reason(
    by_account: dict[int, list[LibraryFileReplica]],
) -> str | None:
    """这些副本里有只读或确认不了写能力、并且网盘上可能还有文件的账号：返回拒绝原因。"""
    async with get_database().session() as session:
        for account_id, group in by_account.items():
            if not any(needs_remote_call(replica) for replica in group):
                continue
            kind, label = await _write_access(session, account_id)
            if kind != "writable":
                return _write_refusal(kind, label)
    return None


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
    重试会把剩下的删完（已经不在的文件插件按删成功处理）。只读或插件不在是例外：任何远端删除和
    状态修改之前就整批拒绝，一行都不改。
    """
    from movieclaw_api.services.drives import sources

    ids = set(file_ids)
    replicas = await replicas_of(ids)
    if not replicas:
        return None
    by_account: dict[int, list[LibraryFileReplica]] = {}
    for replica in replicas:
        by_account.setdefault(replica.account_id, []).append(replica)
    blocked = await _unwritable_reason(by_account)
    if blocked is not None:
        return blocked
    done: list[LibraryFileReplica] = []
    error: str | None = None
    for account_id, group in by_account.items():
        live = [r for r in group if needs_remote_call(r)]
        done.extend(r for r in group if r not in live)
        remote_ids = list(dict.fromkeys(r.remote_id for r in live))
        for start in range(0, len(remote_ids), BATCH):
            batch_ids = remote_ids[start : start + BATCH]
            candidates = [r for r in live if r.remote_id in batch_ids]
            async with get_database().session() as session:
                chunk = await LibraryCloudRepository(session).prepare_delete(
                    candidates, file_ids=ids
                )
            ready_ids = {r.id for r in chunk}
            done.extend(r for r in candidates if r.id not in ready_ids)
            if not chunk:
                continue
            batch_ids = list(dict.fromkeys(r.remote_id for r in chunk))
            try:
                await gateway.call(
                    account_id,
                    "delete",
                    priority=gateway.Priority.USER,
                    remote_ids=batch_ids,
                )
            except dv.DriveError as exc:
                await _restore(chunk)
                error = t("errors.drives.deleteFailed", reason=render_value(error_reference(exc)))
                break
            except Exception as exc:  # noqa: BLE001 -- 插件不在等：这次不删
                await _restore(chunk)
                error = t("errors.drives.deleteFailed", reason=str(exc))
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
                if row is not None and (row.library_file_id, row.account_id, row.remote_id) == (
                    replica.library_file_id,
                    replica.account_id,
                    replica.remote_id,
                ):
                    await session.delete(row)
            await session.commit()
        for replica in done:
            await sources.refresh_file(replica.library_file_id)
        logger.info("已删除 %d 个网盘副本", len(done))
    return error


async def _restore(replicas: list[LibraryFileReplica]) -> None:
    """删失败：副本回到删之前的状态。"""
    async with get_database().session() as session:
        for replica in replicas:
            row = await session.get(LibraryFileReplica, replica.id)
            if (
                row is not None
                and row.state == REPLICA_DELETING
                and (row.library_file_id, row.account_id, row.remote_id)
                == (replica.library_file_id, replica.account_id, replica.remote_id)
            ):
                row.state = replica.state
                session.add(row)
        await session.commit()
