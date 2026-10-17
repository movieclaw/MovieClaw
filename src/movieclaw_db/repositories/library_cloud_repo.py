from __future__ import annotations

from datetime import datetime

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models.base import utcnow
from movieclaw_db.models.library_cloud_folder import LibraryCloudFolder
from movieclaw_db.models.library_file import LibraryFile
from movieclaw_db.models.library_file_replica import (
    REPLICA_LOST,
    REPLICA_ORIGIN_IMPORTED,
    REPLICA_VERIFIED,
    LibraryFileReplica,
)


class LibraryCloudRepository:
    """库的网盘文件夹与库文件的网盘副本（docs/design/cloud-storage.md §3.2、§3.5）。"""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # -- 文件夹 ------------------------------------------------------------

    async def folders(self, library_id: int) -> list[LibraryCloudFolder]:
        result = await self._session.execute(
            select(LibraryCloudFolder)
            .where(LibraryCloudFolder.library_id == library_id)
            .order_by(LibraryCloudFolder.sort_order, LibraryCloudFolder.id)
        )
        return list(result.scalars().all())

    async def all_folders(self) -> list[LibraryCloudFolder]:
        result = await self._session.execute(
            select(LibraryCloudFolder).order_by(LibraryCloudFolder.id)
        )
        return list(result.scalars().all())

    async def folders_of_account(self, account_id: int) -> list[LibraryCloudFolder]:
        result = await self._session.execute(
            select(LibraryCloudFolder).where(LibraryCloudFolder.account_id == account_id)
        )
        return list(result.scalars().all())

    async def get_folder(self, folder_id: int) -> LibraryCloudFolder | None:
        return await self._session.get(LibraryCloudFolder, folder_id)

    async def add_folder(self, folder: LibraryCloudFolder) -> LibraryCloudFolder:
        self._session.add(folder)
        await self._session.commit()
        return folder

    async def save_folder(self, folder: LibraryCloudFolder) -> None:
        folder.updated_at = utcnow()
        self._session.add(folder)
        await self._session.commit()

    async def remove_folder(self, folder: LibraryCloudFolder) -> list[int]:
        """把文件夹从库里拿掉：只删台账（文件夹、纳管来的文件与副本记录），不动网盘（§10）。

        返回被删的文件挂着的条目 id（调用方清理没有文件了的条目）。
        """
        rows = (
            await self._session.execute(
                select(LibraryFile.id, LibraryFile.media_item_id)
                .join(LibraryFileReplica, LibraryFileReplica.library_file_id == LibraryFile.id)
                .where(
                    LibraryFileReplica.folder_id == folder.id,
                    LibraryFile.local_bytes.is_(False),  # type: ignore[attr-defined]
                )
            )
        ).all()
        file_ids = [row[0] for row in rows]
        if file_ids:
            await self._session.execute(
                delete(LibraryFile).where(LibraryFile.id.in_(file_ids))  # type: ignore[union-attr]
            )
        await self._session.execute(
            delete(LibraryFileReplica).where(LibraryFileReplica.folder_id == folder.id)  # type: ignore[arg-type]
        )
        await self._session.delete(folder)
        await self._session.commit()
        return sorted({row[1] for row in rows if row[1] is not None})

    # -- 副本 --------------------------------------------------------------

    async def replica_of(self, file_id: int) -> LibraryFileReplica | None:
        result = await self._session.execute(
            select(LibraryFileReplica).where(LibraryFileReplica.library_file_id == file_id)
        )
        return result.scalar_one_or_none()

    async def replica_paths(self, library_id: int) -> dict[tuple[int, str], str]:
        """库里已有副本的文件：(账号, 网盘文件 id) → 台账路径（纳管时认出已经入账的文件）。"""
        rows = (
            await self._session.execute(
                select(
                    LibraryFileReplica.account_id,
                    LibraryFileReplica.remote_id,
                    LibraryFile.file_path,
                )
                .join(LibraryFile, LibraryFile.id == LibraryFileReplica.library_file_id)
                .where(LibraryFile.library_id == library_id)
            )
        ).all()
        return {(account_id, remote_id): path for account_id, remote_id, path in rows}

    async def folder_replicas(self, folder_id: int) -> list[tuple[LibraryFileReplica, LibraryFile]]:
        rows = (
            await self._session.execute(
                select(LibraryFileReplica, LibraryFile)
                .join(LibraryFile, LibraryFile.id == LibraryFileReplica.library_file_id)
                .where(LibraryFileReplica.folder_id == folder_id)
            )
        ).all()
        return [(replica, file) for replica, file in rows]

    async def account_replicas(
        self, account_id: int, remote_ids: list[str]
    ) -> list[tuple[LibraryFileReplica, LibraryFile]]:
        if not remote_ids:
            return []
        rows = (
            await self._session.execute(
                select(LibraryFileReplica, LibraryFile)
                .join(LibraryFile, LibraryFile.id == LibraryFileReplica.library_file_id)
                .where(
                    LibraryFileReplica.account_id == account_id,
                    LibraryFileReplica.remote_id.in_(remote_ids),  # type: ignore[attr-defined]
                )
            )
        ).all()
        return [(replica, file) for replica, file in rows]

    async def record_import(
        self,
        file: LibraryFile,
        *,
        folder_id: int,
        account_id: int,
        remote_id: str,
        remote_path: str,
        size_bytes: int,
        sha1: str | None,
        fresh: bool = False,
    ) -> LibraryFileReplica:
        """纳管入账：台账行改为「只在网盘上」，副本记为已核验（以列表给的大小与哈希为准）。

        ``fresh``：台账行是刚插入的，不可能已有副本（省一次查询）。
        """
        now = utcnow()
        replica = None if fresh else await self.replica_of(file.id)  # type: ignore[arg-type]
        if replica is None:
            replica = LibraryFileReplica(
                library_file_id=file.id,  # type: ignore[arg-type]
                account_id=account_id,
                remote_id=remote_id,
                origin=REPLICA_ORIGIN_IMPORTED,
                state=REPLICA_VERIFIED,
            )
        replica.folder_id = folder_id
        replica.account_id = account_id
        replica.remote_id = remote_id
        replica.remote_path = remote_path
        replica.size_bytes = size_bytes
        replica.sha1 = sha1
        replica.state = REPLICA_VERIFIED
        replica.verified_at = replica.verified_at or now
        replica.checked_at = now
        replica.updated_at = now
        self._session.add(replica)
        file.local_bytes = False
        self._session.add(file)
        await self._session.commit()
        return replica

    async def mark_checked(
        self,
        replica: LibraryFileReplica,
        *,
        remote_path: str | None,
        size_bytes: int | None,
        sha1: str | None,
        at: datetime,
    ) -> None:
        """复查看到了它：更新展示路径与列表给的大小、哈希；之前标了丢失的认回来。"""
        replica.remote_path = remote_path or replica.remote_path
        if size_bytes is not None:
            replica.size_bytes = size_bytes
        replica.sha1 = sha1 or replica.sha1
        replica.state = REPLICA_VERIFIED
        replica.checked_at = at
        replica.updated_at = at
        self._session.add(replica)

    async def mark_lost(self, replica: LibraryFileReplica, *, at: datetime) -> None:
        replica.state = REPLICA_LOST
        replica.checked_at = at
        replica.updated_at = at
        self._session.add(replica)

    async def drop_orphan_replicas(self) -> int:
        """台账行已经不在了的「纳管来的」副本记录（我们上传的留给删除流程处理）。"""
        result = await self._session.execute(
            delete(LibraryFileReplica).where(
                LibraryFileReplica.origin == REPLICA_ORIGIN_IMPORTED,  # type: ignore[arg-type]
                LibraryFileReplica.library_file_id.not_in(select(LibraryFile.id)),  # type: ignore[attr-defined]
            )
        )
        return result.rowcount or 0

    async def commit(self) -> None:
        await self._session.commit()
