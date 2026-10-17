from __future__ import annotations

import json
from datetime import datetime

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.crypto import get_secret_box
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.drive_account import DRIVE_STATUS_OK, DriveAccount


class DriveAccountRepository:
    """网盘账号表的数据访问层（docs/design/cloud-storage.md §3.1）。

    凭据加解密收口在本层（与站点凭据、IM 通道账号同款约定）：凭据 JSON 用 SecretBox 加密后落库，
    ``credentials`` 只在调用插件时取，明文不随 ORM 对象传递。
    """

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, account_id: int) -> DriveAccount | None:
        return await self._session.get(DriveAccount, account_id)

    async def find(self, backend: str, remote_user_id: str) -> DriveAccount | None:
        result = await self._session.execute(
            select(DriveAccount).where(
                DriveAccount.backend == backend,
                DriveAccount.remote_user_id == remote_user_id,
            )
        )
        return result.scalar_one_or_none()

    async def list_all(self) -> list[DriveAccount]:
        result = await self._session.execute(select(DriveAccount).order_by(DriveAccount.id))
        return list(result.scalars().all())

    @staticmethod
    def credentials(row: DriveAccount) -> dict[str, str]:
        data = json.loads(get_secret_box().decrypt(row.credentials))
        return {str(k): str(v) for k, v in data.items()}

    @staticmethod
    def _encrypt(credentials: dict[str, str]) -> str:
        return get_secret_box().encrypt(json.dumps(credentials, ensure_ascii=False))

    async def upsert_login(
        self,
        *,
        backend: str,
        remote_user_id: str,
        display_name: str,
        credentials: dict[str, str],
        login_method: str,
        login_detail: str | None,
    ) -> tuple[DriveAccount, bool]:
        """登录成功：同一网盘用户已有账号就换凭据并复位状态（不改用户起的名字），否则新建。

        返回（行, 是否新建）。
        """
        row = await self.find(backend, remote_user_id)
        created = row is None
        if row is None:
            row = DriveAccount(
                backend=backend,
                remote_user_id=remote_user_id,
                name=display_name or remote_user_id,
                credentials="",
            )
        row.credentials = self._encrypt(credentials)
        row.login_method = login_method
        row.login_detail = login_detail
        row.status = DRIVE_STATUS_OK
        row.status_message = None
        row.status_until = None
        row.updated_at = utcnow()
        self._session.add(row)
        await self._session.commit()
        await self._session.refresh(row)
        return row, created

    async def save_credentials(self, account_id: int, credentials: dict[str, str]) -> None:
        row = await self.get(account_id)
        if row is None:
            return
        row.credentials = self._encrypt(credentials)
        row.updated_at = utcnow()
        self._session.add(row)
        await self._session.commit()

    async def set_status(
        self,
        account_id: int,
        status: str,
        message: str | None = None,
        until: datetime | None = None,
    ) -> DriveAccount | None:
        row = await self.get(account_id)
        if row is None:
            return None
        row.status = status
        row.status_message = message
        row.status_until = until
        row.updated_at = utcnow()
        self._session.add(row)
        await self._session.commit()
        return row

    async def delete(self, account_id: int) -> bool:
        row = await self.get(account_id)
        if row is None:
            return False
        await self._session.delete(row)
        await self._session.commit()
        return True

    async def update(self, row: DriveAccount) -> DriveAccount:
        row.updated_at = utcnow()
        self._session.add(row)
        await self._session.commit()
        await self._session.refresh(row)
        return row
