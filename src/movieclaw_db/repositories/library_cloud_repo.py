from __future__ import annotations

from datetime import datetime

from sqlalchemy import and_, delete, or_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models.base import utcnow
from movieclaw_db.models.library_cloud_folder import LibraryCloudFolder
from movieclaw_db.models.library_file import LibraryFile
from movieclaw_db.models.library_file_fingerprint import LibraryFileFingerprint
from movieclaw_db.models.library_file_replica import (
    REPLICA_FAILED,
    REPLICA_LOST,
    REPLICA_ORIGIN_IMPORTED,
    REPLICA_ORIGIN_UPLOADED,
    REPLICA_UPLOADING,
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

    async def replica_paths(self) -> dict[tuple[int, str], tuple[str, bool, int]]:
        """已有副本的文件（全部库）：(账号, 网盘文件 id) → (台账路径, 本地有没有字节, 所在库)。

        纳管时据此认出已经入账的文件（含我们自己传上去、本地还在的，以及转移到别的库的）。
        """
        rows = (
            await self._session.execute(
                select(
                    LibraryFileReplica.account_id,
                    LibraryFileReplica.remote_id,
                    LibraryFile.file_path,
                    LibraryFile.local_bytes,
                    LibraryFile.library_id,
                ).join(LibraryFile, LibraryFile.id == LibraryFileReplica.library_file_id)
            )
        ).all()
        return {
            (account_id, remote_id): (path, bool(local), owner)
            for account_id, remote_id, path, local, owner in rows
        }

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

    # -- 上传 --------------------------------------------------------------

    async def primary_folders(self) -> list[LibraryCloudFolder]:
        """主根在网盘的库的那个文件夹（新内容上传到这里）。"""
        result = await self._session.execute(
            select(LibraryCloudFolder).where(LibraryCloudFolder.is_primary.is_(True))  # type: ignore[attr-defined]
        )
        return list(result.scalars().all())

    async def primary_folder(self, library_id: int) -> LibraryCloudFolder | None:
        result = await self._session.execute(
            select(LibraryCloudFolder).where(
                LibraryCloudFolder.library_id == library_id,
                LibraryCloudFolder.is_primary.is_(True),  # type: ignore[attr-defined]
            )
        )
        return result.scalars().first()

    async def upload_candidates(
        self, library_id: int, *, retry_failed_before: datetime, limit: int | None = None
    ) -> list[LibraryFile]:
        """该上传的本地文件，新入库的在前。

        在位、本地有字节、不是原盘 / 镜像 / strm，且还没有网盘副本（或副本还在传、或上次失败已过了
        重试间隔）。
        """
        statement = (
            select(LibraryFile)
            .join(
                LibraryFileReplica,
                LibraryFileReplica.library_file_id == LibraryFile.id,
                isouter=True,
            )
            .where(
                LibraryFile.library_id == library_id,
                LibraryFile.in_place(),
                LibraryFile.local_bytes.is_(True),  # type: ignore[attr-defined]
                LibraryFile.ignored_at.is_(None),  # type: ignore[union-attr]
                ~LibraryFile.strm_path(),
                or_(
                    LibraryFile.container.is_(None),  # type: ignore[union-attr]
                    LibraryFile.container.not_in(("bluray", "dvd", "iso")),  # type: ignore[union-attr]
                ),
                or_(
                    LibraryFileReplica.id.is_(None),  # type: ignore[union-attr]
                    LibraryFileReplica.state == REPLICA_UPLOADING,
                    # 传上去的副本在网盘上没了，本地还在：重新传（§9）
                    LibraryFileReplica.state == REPLICA_LOST,
                    and_(
                        LibraryFileReplica.state == REPLICA_FAILED,
                        LibraryFileReplica.updated_at < retry_failed_before,
                    ),
                ),
            )
            .order_by(LibraryFile.created_at.desc(), LibraryFile.id.desc())  # type: ignore[union-attr]
        )
        if limit is not None:
            statement = statement.limit(limit)
        return list((await self._session.execute(statement)).scalars().all())

    async def start_upload(
        self, file: LibraryFile, *, account_id: int, folder_id: int
    ) -> LibraryFileReplica:
        """记下「正在上传」（文件区据此显示上传中）。"""
        now = utcnow()
        replica = await self.replica_of(file.id)  # type: ignore[arg-type]
        if replica is None:
            replica = LibraryFileReplica(
                library_file_id=file.id,  # type: ignore[arg-type]
                account_id=account_id,
                remote_id="",
                origin=REPLICA_ORIGIN_UPLOADED,
                state=REPLICA_UPLOADING,
            )
        replica.account_id = account_id
        replica.folder_id = folder_id
        replica.origin = REPLICA_ORIGIN_UPLOADED
        replica.state = REPLICA_UPLOADING
        replica.error = None
        replica.updated_at = now
        self._session.add(replica)
        await self._session.commit()
        return replica

    async def finish_upload(
        self,
        file_id: int,
        *,
        remote_id: str,
        remote_path: str,
        size_bytes: int,
        sha1: str | None,
    ) -> None:
        """上传并核验过了：副本已核验。"""
        now = utcnow()
        replica = await self.replica_of(file_id)
        if replica is None:
            return
        replica.remote_id = remote_id
        replica.remote_path = remote_path
        replica.size_bytes = size_bytes
        replica.sha1 = sha1
        replica.state = REPLICA_VERIFIED
        replica.error = None
        replica.verified_at = now
        replica.checked_at = now
        replica.updated_at = now
        self._session.add(replica)
        await self._session.commit()

    async def fail_upload(self, file_id: int, error: str) -> None:
        replica = await self.replica_of(file_id)
        if replica is None or replica.state == REPLICA_VERIFIED:
            return
        replica.state = REPLICA_FAILED
        replica.error = error
        replica.updated_at = utcnow()
        self._session.add(replica)
        await self._session.commit()

    # -- 指纹 --------------------------------------------------------------

    async def fingerprint_of(self, file_id: int) -> LibraryFileFingerprint | None:
        result = await self._session.execute(
            select(LibraryFileFingerprint).where(LibraryFileFingerprint.library_file_id == file_id)
        )
        return result.scalar_one_or_none()

    async def save_fingerprint(
        self,
        file_id: int,
        *,
        size_bytes: int,
        file_mtime_ns: int | None,
        sha1: str,
        md5: str,
        head_sha1: str,
    ) -> None:
        row = await self.fingerprint_of(file_id) or LibraryFileFingerprint(
            library_file_id=file_id, size_bytes=size_bytes, sha1=sha1
        )
        row.size_bytes = size_bytes
        row.file_mtime_ns = file_mtime_ns
        row.sha1 = sha1
        row.md5 = md5
        row.head_sha1 = head_sha1
        row.computed_at = utcnow()
        row.updated_at = utcnow()
        self._session.add(row)
        await self._session.commit()

    async def commit(self) -> None:
        await self._session.commit()
