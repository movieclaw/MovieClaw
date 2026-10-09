"""微信通道驱动（iLink 网关）。

- 绑定是插件驱动的交互式流程：二维码 → 扫码 → 可能要输入手机上显示的配对数字 → 确认；
  状态机在 ``binding.WeixinBindingRegistry``，这里把它的快照翻译成 ``FlowState``；
- 收消息循环与会话令牌（context_token）在 ``adapter.WeixinAdapter``：令牌存进账号的私有状态，
  主动推送没有对应的入站消息时复用它定位会话；
- 「正在输入」：getconfig 换 typing_ticket（按用户缓存 12 小时），处理期间每 5 秒保活，结束发取消。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from typing import Any

from movieclaw_sdk.channels import (
    Account,
    Binding,
    BindResult,
    Capabilities,
    FlowState,
    ReplyContext,
)

from .adapter import WeixinAdapter
from .binding import BindingChallenge, BindingResult, WeixinBindingRegistry
from .client import DEFAULT_BASE_URL, WeixinClient
from .kit import AdapterDriver

logger = logging.getLogger("movieclaw_plugins.weixin.driver")

#: 「正在输入」保活间隔（秒），对齐 openclaw 的 5s 续期
TYPING_KEEPALIVE_S = 5.0
#: typing_ticket 缓存时长（秒）：票据由服务端按用户发放，12 小时后重取
TYPING_TICKET_TTL_S = 12 * 60 * 60

_STATUS = {
    "pending": "pending",
    "scanned": "scanned",
    "need_verify_code": "need_input",
    "confirmed": "confirmed",
    "already_bound": "already_bound",
    "expired": "expired",
    "failed": "failed",
}


class WeixinDriver(AdapterDriver):
    title = "微信"
    description = "手机扫码绑定，无需自建机器人"
    capabilities = Capabilities(receive=True, typing=True, max_text_len=WeixinAdapter.max_text_len)
    binding = Binding.flow(
        hint="打开手机微信扫描下方二维码。扫码人即唯一可对话的用户，同时也是推送目标。"
    )

    def __init__(self) -> None:
        super().__init__()
        self._existing_tokens: list[str] = []
        self._registry = WeixinBindingRegistry(
            on_confirmed=self._on_confirmed, get_local_tokens=self._local_tokens
        )
        #: (账号, 用户) → (typing_ticket, 过期时刻)；失败不缓存，下条消息重试
        self._tickets: dict[tuple[str, str], tuple[str, float]] = {}
        #: (账号, 用户) → 保活任务
        self._typing: dict[tuple[str, str], tuple[asyncio.Task[None], str]] = {}

    async def close(self) -> None:
        """插件停止时调用：停掉进行中的绑定与保活。"""
        await self._registry.close()
        for task, _ticket in self._typing.values():
            task.cancel()
        self._typing.clear()

    # ------------------------------------------------------------------ 绑定
    async def _local_tokens(self) -> list[str]:
        return list(self._existing_tokens)

    async def _on_confirmed(self, result: BindingResult) -> None:
        # 落库与启动由中枢负责（它读到 confirmed 快照里的结果后做），这里无事可做
        return None

    async def begin_flow(self, accounts: list[Account]) -> FlowState:
        # 服务端据此判断「这个微信是否已绑定过本实例」
        self._existing_tokens = [a.credentials.get("token", "") for a in accounts]
        challenge = await self._registry.begin()
        return self._snapshot(challenge)

    async def flow_state(self, flow_id: str) -> FlowState:
        challenge = self._registry.get(flow_id)
        if challenge is None:
            return FlowState(flow_id=flow_id, status="expired", message="绑定已过期，请重新发起")
        return self._snapshot(challenge)

    async def flow_input(self, flow_id: str, value: str) -> FlowState:
        self._registry.submit_verify_code(flow_id, value)
        return await self.flow_state(flow_id)

    def _snapshot(self, challenge: BindingChallenge) -> FlowState:
        status = _STATUS.get(challenge.status, "pending")
        result = None
        if status == "confirmed" and challenge.result is not None:
            r = challenge.result
            result = BindResult(
                account_id=r.bot_id,
                display_name="微信",
                credentials={"token": r.bot_token, "base_url": r.base_url or DEFAULT_BASE_URL},
                bound_user=r.user_id or None,
            )
        return FlowState(
            flow_id=challenge.challenge_id,
            status=status,  # type: ignore[arg-type]
            message=challenge.message,
            qr=challenge.qrcode_url or None,
            input_label="输入手机微信上显示的配对数字" if status == "need_input" else None,
            result=result,
        )

    # ------------------------------------------------------------------ 收发
    def open(self, account: Account) -> tuple[Any, Any]:
        client = WeixinClient(
            account.credentials.get("base_url") or DEFAULT_BASE_URL, account.credentials["token"]
        )

        async def remember(context_token: str) -> None:
            await account.save_state({"context_token": context_token})

        adapter = WeixinAdapter(
            client,
            account.id,
            # 主动推送要靠会话令牌定位会话：只记绑定人的，重启后从私有状态读回
            bound_user_id=account.bound_user or "",
            initial_context_token=str(account.state.get("context_token") or ""),
            on_context_token=remember,
        )
        return client, adapter

    async def typing(self, account: Account, reply: ReplyContext, on: bool) -> None:
        key = (account.id, reply.user_id)
        client = self.live(account)[0]
        if not on:
            running = self._typing.pop(key, None)
            if running is None:
                return
            task, ticket = running
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
            try:
                await client.send_typing(reply.user_id, ticket, typing=False)
            except Exception as exc:  # noqa: BLE001
                logger.debug("sendtyping 取消失败（忽略）：%s", exc)
            return
        ticket = await self._ticket(client, account, reply)
        if not ticket or key in self._typing:
            return

        async def send() -> None:
            try:
                await client.send_typing(reply.user_id, ticket, typing=True)
            except Exception as exc:  # noqa: BLE001
                logger.debug("sendtyping 失败（忽略）：%s", exc)

        async def keepalive() -> None:
            while True:
                await asyncio.sleep(TYPING_KEEPALIVE_S)
                await send()

        # 第一下当场发：回复很快时保活任务还没轮到就被取消，用户会一直看不到「正在输入」
        await send()

        task = asyncio.create_task(keepalive(), name=f"weixin-typing-{reply.user_id}")
        self._typing[key] = (task, ticket)

    async def _ticket(self, client: WeixinClient, account: Account, reply: ReplyContext) -> str:
        key = (account.id, reply.user_id)
        cached = self._tickets.get(key)
        now = time.monotonic()
        if cached is not None and now < cached[1]:
            return cached[0]
        try:
            ticket = await client.get_config(reply.user_id, reply.token.get("context_token"))
        except Exception as exc:  # noqa: BLE001 -- 正在输入是锦上添花，失败只降级
            logger.warning("getconfig 失败，本轮没有「正在输入」状态：%s", exc)
            return ""
        if ticket:
            self._tickets[key] = (ticket, now + TYPING_TICKET_TTL_S)
        return ticket
