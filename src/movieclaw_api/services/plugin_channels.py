"""进程外通道插件的宿主侧桩（docs/design/plugin-channels.md §5.3）。

插件进程里留着真正的驱动；宿主往 ``im-channels`` 登记一个 ``RemoteChannelDriver``，通道中枢照常
调用它，每个方法经 stdio 协议转到插件进程。收消息循环 ``run`` 是一次不限时的调用：账号要停时宿主
发「取消」，插件先置 ``account.stopping``、宽限期后再强制取消。账号句柄的回调（收到消息、
保存私有状态）以 RPC 回到宿主，交给中枢构造的那个句柄。
"""

from __future__ import annotations

import asyncio
import base64
import logging
from typing import Any

from movieclaw_sdk import channels as ch
from movieclaw_sdk.channels import Account, ChannelAuthError, ChannelDriver, ReplyContext

logger = logging.getLogger("movieclaw_api.plugin_channels")


class RemoteChannelDriver(ChannelDriver):
    def __init__(self, session: Any, cid: str, spec: dict[str, Any]) -> None:
        self._session = session
        self._cid = cid
        self.title = spec.get("title") or cid
        self.description = spec.get("description") or ""
        self.capabilities, self.binding = ch.spec_parts(spec)
        #: 账号 id → 中枢给的句柄（插件回调时交给它）
        self.accounts: dict[str, Account] = {}
        #: 账号 id → 主动推送的目标（推送目标是同步方法，启动账号时问插件一次记下）
        self._targets: dict[str, ReplyContext | None] = {}

    async def _call(
        self,
        method: str,
        *,
        timeout: float | None = 30.0,
        cancel: asyncio.Event | None = None,
        **payload: Any,
    ) -> Any:
        from movieclaw_api.services.plugin_runtime import RemoteCallError

        try:
            return await self._session.call(
                self._cid,
                {"method": method, **payload},
                timeout=timeout,
                kind="channel",
                cancel=cancel,
            )
        except RemoteCallError as exc:
            if exc.kind == "auth":
                raise ChannelAuthError(exc.detail) from exc
            if exc.kind == "value":
                raise ValueError(exc.detail) from exc
            raise

    # ---- 绑定
    async def validate(self, fields: dict[str, str]) -> ch.BindResult:
        return ch.bind_result_from(await self._call("validate", fields=fields))

    async def begin_flow(self, accounts: list[Account]) -> ch.FlowState:
        data = await self._call("begin_flow", accounts=[ch.account_dict(a) for a in accounts])
        return ch.flow_from(data)

    async def flow_state(self, flow_id: str) -> ch.FlowState:
        return ch.flow_from(await self._call("flow_state", flow_id=flow_id))

    async def flow_input(self, flow_id: str, value: str) -> ch.FlowState:
        return ch.flow_from(await self._call("flow_input", flow_id=flow_id, value=value))

    async def cancel_flow(self, flow_id: str) -> None:
        await self._call("cancel_flow", flow_id=flow_id)

    # ---- 运行
    async def run(self, account: Account) -> None:
        self.accounts[account.id] = account
        try:
            target = await self._call("push_target", account=ch.account_dict(account))
            self._targets[account.id] = ch.reply_from(target) if target else None
            await self._call(
                "run", timeout=None, cancel=account.stopping, account=ch.account_dict(account)
            )
        finally:
            if self.accounts.get(account.id) is account:
                del self.accounts[account.id]
                self._targets.pop(account.id, None)

    async def send(self, account: Account, reply: ReplyContext, text: str) -> None:
        await self._call(
            "send", account=ch.account_dict(account), reply=ch.reply_dict(reply), text=text
        )

    async def send_photo(
        self, account: Account, reply: ReplyContext, photo: bytes, caption: str
    ) -> None:
        await self._call(
            "send_photo",
            account=ch.account_dict(account),
            reply=ch.reply_dict(reply),
            photo=base64.b64encode(photo).decode(),
            caption=caption,
        )

    async def typing(self, account: Account, reply: ReplyContext, on: bool) -> None:
        await self._call(
            "typing", account=ch.account_dict(account), reply=ch.reply_dict(reply), on=on
        )

    def push_target(self, account: Account) -> ReplyContext | None:
        if account.id in self._targets:
            return self._targets[account.id]
        return super().push_target(account)

    # ---- 插件回调
    async def callback(self, method: str, params: dict[str, Any]) -> None:
        account = self.accounts.get(params["account"])
        if account is None:
            raise LookupError(f"账号 {params['account']} 没有在运行")
        if method == "channel.inbound":
            await account.inbound(ch.message_from(params["message"]))
        elif method == "channel.save_state":
            await account.save_state(dict(params["patch"]))
        else:
            raise ValueError(f"未知的通道回调 {method}")
