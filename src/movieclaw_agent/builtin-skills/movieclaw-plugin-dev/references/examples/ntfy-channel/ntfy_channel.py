"""ntfy 通道（第三方通道插件示例，docs/design/plugin-channels.md §8）。

ntfy（https://ntfy.sh，也可以自建）是一个按「主题」收发消息的推送服务，手机上有 App。这个插件用两个
主题和 MovieClaw 对话：

- 你在 ntfy App 里往「收消息的主题」发消息 → MovieClaw 的 AI 助手处理；
- 回复和订阅、入库等推送发到「发消息的主题」→ 你在 App 里订阅它就能收到。

整个插件只依赖 SDK（``movieclaw_sdk.channels``）与开放契约 ``im-channels``，白名单、会话、AI 助手、
长消息拆分、推送都由 MovieClaw 的通道中枢负责。既能当本地插件（复制 ``ntfy_channel.py`` 到数据目录的
``plugins/``），也能用 ``mclaw plugin pack`` 打成插件包安装（默认在独立进程里运行）。

ntfy 的主题没有发送者身份：知道「收消息的主题」名字的人都能给你的 MovieClaw 发指令。请用不好猜的
长主题名，或者用自建服务器并开启访问控制（填访问令牌）。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import re
from urllib.parse import urlsplit

import httpx

from movieclaw_sdk import net, plugin
from movieclaw_sdk.channels import (
    IM_CHANNELS,
    Account,
    Binding,
    BindResult,
    Capabilities,
    ChannelAuthError,
    ChannelDriver,
    FormField,
    InboundMessage,
    ReplyContext,
)

logger = logging.getLogger("ntfy-channel")

_TOPIC = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
#: 断线后重连的等待（秒）
RECONNECT_S = 5.0
#: ntfy 默认 4096 字节的消息上限，中文按 3 字节算留出余量
MAX_TEXT = 1300
#: 认这个固定身份为白名单：ntfy 主题没有发送者身份，能往「收消息的主题」发消息的就是你
USER = "ntfy"
#: 连外网的服务名 = 条目 id，按用户的代理设置走
SERVICE = "ntfy-channel"


def _server(raw: str) -> str:
    server = (raw or "https://ntfy.sh").strip().rstrip("/")
    parts = urlsplit(server)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        raise ValueError("服务器地址须是 http(s):// 开头的完整地址")
    return server


def _headers(credentials: dict[str, str]) -> dict[str, str]:
    token = credentials.get("token", "")
    return {"Authorization": f"Bearer {token}"} if token else {}


class NtfyDriver(ChannelDriver):
    title = "ntfy"
    description = "在 ntfy App 里对话 AI 助手、接收推送（示例插件）"
    capabilities = Capabilities(receive=True, max_text_len=MAX_TEXT)
    binding = Binding.form(
        (
            FormField("server", "服务器地址", placeholder="https://ntfy.sh", required=False),
            FormField(
                "inbox",
                "收消息的主题",
                help="在 ntfy App 里往这个主题发消息就是在和 MovieClaw 对话；请用不好猜的长名字",
            ),
            FormField("outbox", "发消息的主题", help="在 ntfy App 里订阅这个主题，接收回复与推送"),
            FormField(
                "token", "访问令牌", secret=True, required=False, help="服务器开了访问控制才需要"
            ),
        ),
        hint="提交后会往「发消息的主题」发一条欢迎消息；在 ntfy App 里订阅它，收到即说明可用。",
    )

    async def validate(self, fields: dict[str, str]) -> BindResult:
        server = _server(fields.get("server", ""))
        inbox, outbox = (fields.get("inbox") or "").strip(), (fields.get("outbox") or "").strip()
        for name, topic in (("收消息的主题", inbox), ("发消息的主题", outbox)):
            if not _TOPIC.match(topic):
                raise ValueError(f"{name}只能用字母、数字、- 和 _，最长 64 个字符")
        if inbox == outbox:
            raise ValueError("收、发两个主题不能相同，否则 MovieClaw 会读到自己发的消息")
        credentials = {
            "server": server,
            "inbox": inbox,
            "outbox": outbox,
            "token": (fields.get("token") or "").strip(),
        }
        await self._publish(credentials, "🎉 MovieClaw 已接入：往收消息的主题发消息就能和我对话。")
        return BindResult(
            account_id=f"{urlsplit(server).netloc}/{inbox}",
            display_name=f"ntfy · {outbox}",
            credentials=credentials,
            bound_user=USER,
        )

    async def run(self, account: Account) -> None:
        creds = account.credentials
        url = f"{creds['server']}/{creds['inbox']}/json"
        async with httpx.AsyncClient(
            transport=net.http_transport(SERVICE), timeout=httpx.Timeout(10.0, read=None)
        ) as client:
            while not account.stopping.is_set():
                listen = asyncio.ensure_future(self._listen(client, url, account))
                stop = asyncio.ensure_future(account.stopping.wait())
                done, _ = await asyncio.wait({listen, stop}, return_when=asyncio.FIRST_COMPLETED)
                if listen not in done:
                    listen.cancel()
                    await asyncio.gather(listen, return_exceptions=True)
                    return
                stop.cancel()
                try:
                    listen.result()
                except ChannelAuthError:
                    raise
                except Exception as exc:  # noqa: BLE001 -- 断线、服务器重启：等一会儿重连
                    logger.warning("ntfy 订阅断开，%.0f 秒后重连：%s", RECONNECT_S, exc)
                    with contextlib.suppress(TimeoutError):
                        await asyncio.wait_for(account.stopping.wait(), RECONNECT_S)

    async def _listen(self, client: httpx.AsyncClient, url: str, account: Account) -> None:
        params = {}
        if account.state.get("cursor"):
            params["since"] = str(account.state["cursor"])
        headers = _headers(account.credentials)
        async with client.stream("GET", url, params=params, headers=headers) as resp:
            if resp.status_code in (401, 403):
                raise ChannelAuthError("ntfy 拒绝了访问令牌，请重新绑定")
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.strip():
                    continue
                event = json.loads(line)
                if event.get("event") != "message":
                    continue
                text = str(event.get("message") or "")
                reply = ReplyContext(account.channel_id, account.id, USER)
                await account.inbound(
                    InboundMessage(
                        channel_id=account.channel_id,
                        account_id=account.id,
                        user_id=USER,
                        text=text,
                        reply=reply,
                        provider_message_id=str(event.get("id") or ""),
                        timestamp_ms=int(event.get("time") or 0) * 1000,
                    )
                )
                await account.save_state({"cursor": event.get("id")})

    async def send(self, account: Account, reply: ReplyContext, text: str) -> None:
        await self._publish(account.credentials, text)

    async def _publish(self, credentials: dict[str, str], text: str) -> None:
        url = f"{credentials['server']}/{credentials['outbox']}"
        headers = {**_headers(credentials), "Title": "MovieClaw", "Markdown": "yes"}
        async with httpx.AsyncClient(transport=net.http_transport(SERVICE), timeout=15.0) as client:
            resp = await client.post(url, content=text.encode(), headers=headers)
        if resp.status_code in (401, 403):
            raise ValueError("ntfy 拒绝了访问令牌")
        resp.raise_for_status()


@plugin("ntfy-channel", title="ntfy 通道（示例）")
async def apply(ctx) -> None:
    ctx.contribute(IM_CHANNELS, "ntfy", NtfyDriver())
