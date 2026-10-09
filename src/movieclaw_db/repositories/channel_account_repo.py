from __future__ import annotations

import json
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.crypto import get_secret_box
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.channel_account import ChannelAccount, ChannelAccountStatus


class ChannelAccountRepository:
    """IM 通道账号表的数据访问层（docs/design/plugin-channels.md §6）。

    敏感字段加解密收口在本层（与站点凭据 / 下载器同款约定）：凭据 JSON 用 SecretBox 加密后落库，
    ``credentials`` 只在启动账号时调用，明文不随 ORM 对象传递。

    旧行兼容（插件化之前绑定的账号，惰性迁移）：``token`` 是裸凭据（微信 / Telegram / Discord）
    或凭据 JSON（飞书），微信的网关地址在 ``base_url``；游标与会话令牌在 ``cursor`` /
    ``context_token``。
    读取时按旧形态解释，下一次写入即转成新形态。
    """

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, channel_id: str, account_id: str) -> ChannelAccount | None:
        result = await self._session.execute(
            select(ChannelAccount).where(
                ChannelAccount.channel_id == channel_id,
                ChannelAccount.account_id == account_id,
            )
        )
        return result.scalar_one_or_none()

    async def list_all(self) -> list[ChannelAccount]:
        result = await self._session.execute(
            select(ChannelAccount).order_by(ChannelAccount.created_at)
        )
        return list(result.scalars().all())

    async def list_by_channel(self, channel_id: str) -> list[ChannelAccount]:
        result = await self._session.execute(
            select(ChannelAccount)
            .where(ChannelAccount.channel_id == channel_id)
            .order_by(ChannelAccount.created_at)
        )
        return list(result.scalars().all())

    async def upsert(
        self,
        *,
        channel_id: str,
        account_id: str,
        credentials: dict[str, str],
        display_name: str,
        bound_user_id: str | None,
        state: dict[str, Any] | None = None,
    ) -> ChannelAccount:
        """绑定成功后落库（重复绑定同一账号时覆盖凭据并复位状态）。

        私有状态一并复位：新凭据对应平台的新会话，旧游标 / 会话令牌已无意义。
        """
        token_enc = get_secret_box().encrypt(json.dumps(credentials, ensure_ascii=False))
        row = await self.get(channel_id, account_id)
        if row is None:
            row = ChannelAccount(channel_id=channel_id, account_id=account_id, token=token_enc)
        row.token = token_enc
        row.base_url = ""
        row.display_name = display_name
        row.bound_user_id = bound_user_id
        row.state = json.dumps(state or {}, ensure_ascii=False)
        row.cursor = None
        row.context_token = None
        row.status = ChannelAccountStatus.ACTIVE
        row.last_error = None
        row.updated_at = utcnow()
        self._session.add(row)
        await self._session.commit()
        await self._session.refresh(row)
        return row

    async def save_state(self, channel_id: str, account_id: str, patch: dict[str, Any]) -> None:
        """合并插件私有状态（游标每轮长轮询都可能写，高频小写入）。"""
        row = await self.get(channel_id, account_id)
        if row is None:
            return
        state = self.state(row)
        state.update(patch)
        row.state = json.dumps(state, ensure_ascii=False)
        row.updated_at = utcnow()
        self._session.add(row)
        await self._session.commit()

    async def set_agent_session(
        self, channel_id: str, account_id: str, session_id: str | None
    ) -> None:
        """绑定 / 清空该账号当前的 AI 会话（None = /reset，下条消息建新会话）。"""
        row = await self.get(channel_id, account_id)
        if row is None:
            return
        row.agent_session_id = session_id
        row.updated_at = utcnow()
        self._session.add(row)
        await self._session.commit()

    async def mark_stale(self, channel_id: str, account_id: str, reason: str) -> None:
        """凭据失效：标记 stale，设置页据此引导用户重新绑定。"""
        row = await self.get(channel_id, account_id)
        if row is None:
            return
        row.status = ChannelAccountStatus.STALE
        row.last_error = reason
        row.updated_at = utcnow()
        self._session.add(row)
        await self._session.commit()

    async def delete(self, channel_id: str, account_id: str) -> bool:
        row = await self.get(channel_id, account_id)
        if row is None:
            return False
        await self._session.delete(row)
        await self._session.commit()
        return True

    @staticmethod
    def credentials(row: ChannelAccount) -> dict[str, str]:
        """解密凭据。旧行：裸凭据 → ``{"token": …}``（微信再带上 ``base_url``）。"""
        plain = get_secret_box().decrypt(row.token)
        try:
            value = json.loads(plain)
        except ValueError:
            value = None
        if isinstance(value, dict):
            return {str(k): str(v) for k, v in value.items()}
        legacy = {"token": plain}
        if row.base_url:
            legacy["base_url"] = row.base_url
        return legacy

    @staticmethod
    def state(row: ChannelAccount) -> dict[str, Any]:
        """插件私有状态。旧行：``cursor`` / ``context_token`` 两列。"""
        if row.state:
            try:
                value = json.loads(row.state)
            except ValueError:
                value = None
            if isinstance(value, dict):
                return value
        legacy: dict[str, Any] = {}
        if row.cursor:
            legacy["cursor"] = row.cursor
        if row.context_token:
            legacy["context_token"] = row.context_token
        return legacy
