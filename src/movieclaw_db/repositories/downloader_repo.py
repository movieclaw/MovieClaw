from __future__ import annotations

from datetime import datetime, timedelta
from uuid import uuid4

from sqlalchemy import and_, or_, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.crypto import get_secret_box
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.downloader_client import DownloaderClient
from movieclaw_db.models.site_credential import ConfigStatus

# 给 30 秒探测、10 秒清理以及请求交接和数据库提交留出时间。
_VERIFICATION_LEASE = timedelta(seconds=60)


def _new_verification(now: datetime) -> dict:
    return {
        "status": ConfigStatus.VERIFYING,
        "verification_token": uuid4().hex,
        "verification_expires_at": now + _VERIFICATION_LEASE,
        "updated_at": now,
    }


class DownloaderRepository:
    """下载器配置表的数据访问层。

    密码的加解密统一收口在本层：
    - 写入（create/update）时用 SecretBox 加密再落库；
    - ``decrypted_password`` 按需解密，仅在真正要连下载器时调用，
      避免密码明文在各层之间随 ORM 对象到处传递。
    """

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    # -- 查询 --------------------------------------------------------------

    async def get(self, downloader_id: int, *, refresh: bool = False) -> DownloaderClient | None:
        """按主键查询；不存在返回 None。"""
        return await self._session.get(DownloaderClient, downloader_id, populate_existing=refresh)

    async def get_by_name(self, name: str) -> DownloaderClient | None:
        """按名称查询（名称全局唯一）；不存在返回 None。"""
        result = await self._session.execute(
            select(DownloaderClient).where(DownloaderClient.name == name)
        )
        return result.scalar_one_or_none()

    async def list_all(self, *, refresh: bool = False) -> list[DownloaderClient]:
        """返回所有下载器（含已停用），按 id 排序保持添加顺序。"""
        result = await self._session.execute(
            select(DownloaderClient)
            .order_by(DownloaderClient.id)
            .execution_options(populate_existing=refresh)
        )
        return list(result.scalars().all())

    async def get_default(self) -> DownloaderClient | None:
        """返回默认下载器；一台都没配置时返回 None。"""
        result = await self._session.execute(
            select(DownloaderClient).where(DownloaderClient.is_default == True)  # noqa: E712
        )
        return result.scalar_one_or_none()

    @staticmethod
    def decrypted_password(row: DownloaderClient) -> str | None:
        """解密某条记录的密码密文，返回明文（未设密码返回 None）。"""
        if row.password is None:
            return None
        return get_secret_box().decrypt(row.password)

    # -- 写入 --------------------------------------------------------------

    async def create(
        self,
        *,
        name: str,
        client_type: str,
        url: str,
        username: str | None,
        password: str | None,
        save_path: str | None,
        path_mappings: list[dict[str, str]] | None = None,
        enabled: bool = True,
        verify: bool = False,
    ) -> DownloaderClient:
        """新增配置，按调用方要求同时登记一次验证。

        默认下载器不变量：当前没有默认（通常是第一台）时，新增的这台自动成为默认。
        """
        is_default = await self.get_default() is None
        now = utcnow()
        row = DownloaderClient(
            name=name,
            client_type=client_type,
            url=url,
            username=username,
            password=get_secret_box().encrypt(password) if password else None,
            save_path=save_path,
            path_mappings=path_mappings,
            enabled=enabled,
            is_default=is_default,
            created_at=now,
            **(_new_verification(now) if verify else {}),
        )
        self._session.add(row)
        await self._session.commit()
        await self._session.refresh(row)
        return row

    async def update_and_start_verification(
        self,
        downloader_id: int,
        *,
        name: str,
        client_type: str,
        url: str,
        username: str | None,
        password: str | None,
        save_path: str | None,
        path_mappings: list[dict[str, str]] | None = None,
        enabled: bool,
    ) -> DownloaderClient | None:
        """整体更新配置并占用验证，两步同事务，避免与其他进程的请求交错。"""
        return await self._claim_verification(
            downloader_id,
            name=name,
            client_type=client_type,
            url=url,
            username=username,
            password=get_secret_box().encrypt(password) if password else None,
            save_path=save_path,
            path_mappings=path_mappings,
            enabled=enabled,
            last_error=None,
            last_error_ref=None,
        )

    async def start_verification(self, downloader_id: int) -> DownloaderClient | None:
        return await self._claim_verification(downloader_id)

    async def _claim_verification(self, downloader_id: int, **values) -> DownloaderClient | None:
        result = await self._session.execute(
            update(DownloaderClient)
            .where(
                DownloaderClient.id == downloader_id,
                DownloaderClient.status != ConfigStatus.VERIFYING,
            )
            .values(**values, **_new_verification(utcnow()))
            .returning(DownloaderClient)
            .execution_options(populate_existing=True)
        )
        row = result.scalar_one_or_none()
        await self._session.commit()
        return row

    @staticmethod
    def owns_verification(row: DownloaderClient, token: str) -> bool:
        return (
            row.status == ConfigStatus.VERIFYING
            and row.verification_token == token
            and row.verification_expires_at is not None
            and row.verification_expires_at > utcnow()
        )

    @staticmethod
    def verification_expired(row: DownloaderClient) -> bool:
        if row.status != ConfigStatus.VERIFYING:
            return False
        deadline = row.verification_expires_at or (row.updated_at + _VERIFICATION_LEASE)
        return deadline <= utcnow()

    async def update_status(
        self,
        downloader_id: int,
        status: ConfigStatus,
        *,
        verification_token: str,
        last_error: str | None = None,
        last_error_ref: dict | None = None,
        version: str | None = None,
        path_health: list[dict[str, str]] | None = None,
    ) -> bool:
        """仅当前尚未过期的验证可写入终态并释放占位。"""
        now = utcnow()
        values = {
            "status": status,
            "verification_token": None,
            "verification_expires_at": None,
            "last_checked_at": now,
            "updated_at": now,
        }
        if status == ConfigStatus.ACTIVE:
            values.update(
                last_error=None, last_error_ref=None, version=version, path_health=path_health
            )
        elif last_error is not None:
            values.update(last_error=last_error, last_error_ref=last_error_ref)
        result = await self._session.execute(
            update(DownloaderClient)
            .where(
                DownloaderClient.id == downloader_id,
                DownloaderClient.status == ConfigStatus.VERIFYING,
                DownloaderClient.verification_token == verification_token,
                DownloaderClient.verification_expires_at > now,  # type: ignore[operator]
            )
            .values(**values)
        )
        await self._session.commit()
        return result.rowcount == 1

    async def fail_stale_verifying(
        self, *, last_error: str, last_error_ref: dict, downloader_id: int | None = None
    ) -> int:
        """回收已过期的验证。旧版无租约的记录从最后一次更新起使用同样的宽限期。"""
        now = utcnow()
        statement = update(DownloaderClient).where(
            DownloaderClient.status == ConfigStatus.VERIFYING,
            or_(
                DownloaderClient.verification_expires_at <= now,  # type: ignore[operator]
                and_(
                    DownloaderClient.verification_expires_at == None,  # noqa: E711
                    DownloaderClient.updated_at <= now - _VERIFICATION_LEASE,
                ),
            ),
        )
        if downloader_id is not None:
            statement = statement.where(DownloaderClient.id == downloader_id)
        result = await self._session.execute(
            statement.values(
                status=ConfigStatus.FAILED,
                verification_token=None,
                verification_expires_at=None,
                last_error=last_error,
                last_error_ref=last_error_ref,
                updated_at=now,
            )
        )
        await self._session.commit()
        return result.rowcount or 0

    async def set_enabled(self, downloader_id: int, enabled: bool) -> bool:
        """启用/停用某下载器。返回是否命中记录。"""
        row = await self.get(downloader_id)
        if row is None:
            return False
        row.enabled = enabled
        row.updated_at = utcnow()
        await self._session.commit()
        return True

    async def set_default(self, downloader_id: int) -> bool:
        """把某台设为默认下载器（同时清掉其他台的默认标记）。返回是否命中记录。"""
        row = await self.get(downloader_id)
        if row is None:
            return False
        now = utcnow()
        for other in await self.list_all():
            if other.is_default and other.id != downloader_id:
                other.is_default = False
                other.updated_at = now
        row.is_default = True
        row.updated_at = now
        await self._session.commit()
        return True

    async def delete(self, downloader_id: int) -> bool:
        """删除某下载器配置。返回是否命中记录。

        默认下载器不变量：删除的是默认时，自动把默认让给剩下最早添加的一台，
        保证"只要还有下载器就有默认"，一键下载永远有目标。
        """
        row = await self.get(downloader_id)
        if row is None:
            return False
        was_default = row.is_default
        await self._session.delete(row)
        await self._session.commit()
        if was_default:
            remaining = await self.list_all()
            if remaining:
                remaining[0].is_default = True
                remaining[0].updated_at = utcnow()
                await self._session.commit()
        return True
