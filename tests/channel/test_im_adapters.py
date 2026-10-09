"""Telegram / Discord 适配器的消息归一化与配对码生命周期测试。"""

from __future__ import annotations

import asyncio

import pytest

from movieclaw_channel.discord.adapter import DiscordAdapter
from movieclaw_channel.discord.client import DiscordClient
from movieclaw_channel.telegram.adapter import TelegramAdapter
from movieclaw_channel.telegram.client import TelegramClient


def _tg_adapter() -> TelegramAdapter:
    return TelegramAdapter(TelegramClient("dummy-token"), "bot1")


def _dc_adapter() -> DiscordAdapter:
    return DiscordAdapter(DiscordClient("dummy-token"), "bot1")


class TestTelegramNormalize:
    def test_private_text_message(self) -> None:
        msg = _tg_adapter()._normalize(
            {
                "update_id": 100,
                "message": {
                    "message_id": 7,
                    "date": 1700000000,
                    "text": "帮我找沙丘2",
                    "chat": {"id": 123, "type": "private"},
                    "from": {"id": 123, "is_bot": False},
                },
            }
        )
        assert msg is not None
        assert msg.user_id == "123"
        assert msg.text == "帮我找沙丘2"
        assert msg.reply.token["chat_id"] == 123
        assert msg.provider_message_id == "123:7"

    def test_group_message_ignored(self) -> None:
        msg = _tg_adapter()._normalize(
            {
                "message": {
                    "text": "hi",
                    "chat": {"id": -100, "type": "supergroup"},
                    "from": {"id": 123, "is_bot": False},
                }
            }
        )
        assert msg is None

    def test_bot_message_ignored(self) -> None:
        msg = _tg_adapter()._normalize(
            {
                "message": {
                    "text": "hi",
                    "chat": {"id": 123, "type": "private"},
                    "from": {"id": 9, "is_bot": True},
                }
            }
        )
        assert msg is None


class TestDiscordNormalize:
    def test_dm_message(self) -> None:
        msg = _dc_adapter()._normalize(
            {
                "id": "555",
                "channel_id": "888",
                "content": "订阅怪奇物语",
                "author": {"id": "42", "bot": False},
            }
        )
        assert msg is not None
        assert msg.user_id == "42"
        assert msg.text == "订阅怪奇物语"
        assert msg.reply.token["dm_channel_id"] == "888"

    def test_guild_message_ignored(self) -> None:
        msg = _dc_adapter()._normalize(
            {
                "id": "555",
                "channel_id": "888",
                "guild_id": "1",
                "content": "hi",
                "author": {"id": "42"},
            }
        )
        assert msg is None

    def test_bot_author_ignored(self) -> None:
        msg = _dc_adapter()._normalize(
            {"id": "5", "channel_id": "8", "content": "x", "author": {"id": "9", "bot": True}}
        )
        assert msg is None


class TestDiscordHandshakeRejection:
    async def test_invalid_status_goes_to_backoff_not_auth_error(self) -> None:
        """Gateway 握手被拒(如 Cloudflare 429/代理 5xx)必须走退避重连。

        握手阶段不携带 token(鉴权发生在 Identify,失败以关闭码 4004 表达),
        把 InvalidStatus 判成 ChannelAuthError 会让账号被误标 stale 永久停摆。
        """
        from websockets.datastructures import Headers
        from websockets.exceptions import InvalidStatus
        from websockets.http11 import Response

        from movieclaw_channel.adapter import ChannelContext

        adapter = _dc_adapter()
        stop = asyncio.Event()
        calls = 0

        async def failing_connect(ctx: ChannelContext, stop_evt: asyncio.Event) -> None:
            nonlocal calls
            calls += 1
            stop.set()  # 首次失败后即请求停止,避免测试真的等待退避窗口
            raise InvalidStatus(Response(429, "Too Many Requests", Headers()))

        adapter._connect_once = failing_connect  # type: ignore[method-assign]

        async def on_inbound(msg) -> None: ...

        async def save_cursor(cursor: str) -> None: ...

        ctx = ChannelContext(
            account_id="bot1", on_inbound=on_inbound, save_cursor=save_cursor, stop=stop
        )
        # 不应抛 ChannelAuthError:run() 的通用异常路径记日志并退避重连
        await asyncio.wait_for(adapter.run(ctx), timeout=5)
        assert calls == 1


async def test_telegram_client_non_json_response() -> None:
    """5xx / 代理错误页返回 HTML：应抛可重试的 TelegramApiError，而非 JSON 解码异常。"""
    import httpx

    from movieclaw_channel.telegram.client import TelegramApiError

    client = TelegramClient("dummy")
    await client._http.aclose()
    client._http = httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda request: httpx.Response(502, text="<html>Bad Gateway</html>")
        )
    )
    try:
        with pytest.raises(TelegramApiError) as exc_info:
            await client.get_me()
        assert not exc_info.value.auth_failed
    finally:
        await client.aclose()
