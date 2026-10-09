"""驱动骨架：「客户端 + 适配器」接成 ``ChannelDriver``。

每个账号在 ``run`` 期间登记一份（客户端, 适配器），``send`` 取用它；``run`` 退出时注销并关闭客户端。
适配器的收消息循环吃一个 ``ChannelContext``：入站回调、游标的读写与停止信号都来自账号句柄。
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

from movieclaw_sdk.channels import Account, ChannelDriver, InboundMessage, ReplyContext


@dataclass(slots=True)
class ChannelContext:
    """交给适配器收消息循环的运行时上下文。"""

    account_id: str
    #: 入站回调：适配器归一化一条消息后调用
    on_inbound: Callable[[InboundMessage], Awaitable[None]]
    #: 游标持久化回调（微信的 get_updates_buf；重启后从上次位置续传）
    save_cursor: Callable[[str], Awaitable[None]]
    #: 上次持久化的游标，空串表示从头开始
    initial_cursor: str = ""
    #: 停止信号：置位后适配器应尽快中断在飞的长轮询并退出循环
    stop: asyncio.Event | None = None


class AdapterDriver(ChannelDriver):
    def __init__(self) -> None:
        self._live: dict[tuple[str, str], tuple[Any, Any]] = {}

    def open(self, account: Account) -> tuple[Any, Any]:
        """为一个账号建（客户端, 适配器）。客户端须有 ``aclose``。"""
        raise NotImplementedError

    async def run(self, account: Account) -> None:
        client, adapter = self.open(account)
        key = (account.channel_id, account.id)
        entry = (client, adapter)
        self._live[key] = entry

        async def save_cursor(cursor: str) -> None:
            await account.save_state({"cursor": cursor})

        try:
            await adapter.run(
                ChannelContext(
                    account_id=account.id,
                    on_inbound=account.inbound,
                    save_cursor=save_cursor,
                    initial_cursor=str(account.state.get("cursor") or ""),
                    stop=account.stopping,
                )
            )
        finally:
            # 同一账号重新启动时新句柄可能已登记：只注销自己那份
            if self._live.get(key) is entry:
                del self._live[key]
            await client.aclose()

    def live(self, account: Account) -> tuple[Any, Any]:
        entry = self._live.get((account.channel_id, account.id))
        if entry is None:
            raise RuntimeError(f"账号 {account.id} 没有在运行")
        return entry

    async def send(self, account: Account, reply: ReplyContext, text: str) -> None:
        await self.live(account)[1].send_text(reply, text)
