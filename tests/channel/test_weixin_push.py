"""微信主动推送的会话令牌(context_token)兜底测试。

背景:iLink 网关的发送接口必须绑定一条会话,令牌只随入站消息下发。订阅投递、
入库完成这类主动推送没有对应的入站消息,构造出的 ReplyContext 是空 token
——不兜底的话消息发出去定位不到会话,用户什么也收不到。
"""

from __future__ import annotations

from typing import Any

from movieclaw_channel.types import InboundMessage, ReplyContext
from movieclaw_plugins.weixin.weixin_channel.adapter import CHANNEL_ID, WeixinAdapter


class _StubClient:
    """只记录 send_text 入参的假客户端(不发真请求)。"""

    def __init__(self) -> None:
        self.sent: list[tuple[str, str, str | None]] = []

    async def send_text(self, to_user_id: str, text: str, context_token: str | None) -> None:
        self.sent.append((to_user_id, text, context_token))


def _inbound(context_token: str, user_id: str = "u1") -> dict[str, Any]:
    """一条 iLink 原始入站消息(仅保留归一化用得上的字段)。"""
    return {
        "from_user_id": user_id,
        "message_id": f"m-{user_id}-{context_token}",
        "context_token": context_token,
        "item_list": [{"type": 1, "text_item": {"text": "帮我找沙丘2"}}],
    }


def _adapter(client: _StubClient, **kwargs: Any) -> WeixinAdapter:
    """被测适配器:绑定人固定为 u1(与 _inbound / _push_reply 的默认值一致)。"""
    kwargs.setdefault("bound_user_id", "u1")
    return WeixinAdapter(client, "bot1", **kwargs)  # type: ignore[arg-type]


def _push_reply() -> ReplyContext:
    """主动推送侧构造的收件人:只有 user_id,没有会话令牌。"""
    return ReplyContext(channel_id=CHANNEL_ID, account_id="bot1", user_id="u1")


class TestContextTokenFallback:
    async def test_push_reuses_last_inbound_token(self) -> None:
        """主动推送没有自己的令牌时,复用最近一次入站记住的那个。"""
        client = _StubClient()
        adapter = _adapter(client)

        msg = adapter._normalize(_inbound("ctx-1"))
        assert msg is not None
        await adapter._remember_context_token(msg)

        await adapter.send_text(_push_reply(), "《沙丘2》已开始下载")
        assert client.sent == [("u1", "《沙丘2》已开始下载", "ctx-1")]

    async def test_push_without_any_inbound_sends_none(self) -> None:
        """从没收到过入站消息时没有令牌可用:如实传 None,由客户端记警告日志。"""
        client = _StubClient()
        adapter = _adapter(client)

        await adapter.send_text(_push_reply(), "测试推送")
        assert client.sent == [("u1", "测试推送", None)]

    async def test_restart_seeds_token_from_db(self) -> None:
        """重启后由 initial_context_token 读回,首次推送不至于必然失联。"""
        client = _StubClient()
        adapter = _adapter(client, initial_context_token="ctx-db")

        await adapter.send_text(_push_reply(), "入库完成")
        assert client.sent == [("u1", "入库完成", "ctx-db")]

    async def test_inbound_reply_prefers_own_token(self) -> None:
        """回复入站消息仍用该消息自己的令牌,不被记住的旧值顶掉。"""
        client = _StubClient()
        adapter = _adapter(client, initial_context_token="ctx-old")

        msg = adapter._normalize(_inbound("ctx-new"))
        assert msg is not None
        await adapter.send_text(msg.reply, "找到了")
        assert client.sent == [("u1", "找到了", "ctx-new")]


class TestBoundUserScoping:
    """令牌只能来自绑定人、只能发给绑定人——陌生人也能给 bot 发消息。"""

    async def test_stranger_token_not_remembered(self) -> None:
        """陌生人的会话令牌不入库也不进内存,否则推送会带错会话。"""
        saved: list[str] = []

        async def on_token(token: str) -> None:
            saved.append(token)

        client = _StubClient()
        adapter = _adapter(client, initial_context_token="ctx-mine", on_context_token=on_token)

        msg = adapter._normalize(_inbound("ctx-stranger", user_id="intruder"))
        assert msg is not None
        await adapter._remember_context_token(msg)

        assert saved == []
        await adapter.send_text(_push_reply(), "推送")
        assert client.sent == [("u1", "推送", "ctx-mine")]

    async def test_fallback_not_applied_to_other_recipients(self) -> None:
        """收件人不是绑定人时不套用兜底令牌,避免把消息发进别人的会话。"""
        client = _StubClient()
        adapter = _adapter(client, initial_context_token="ctx-mine")

        other = ReplyContext(channel_id=CHANNEL_ID, account_id="bot1", user_id="intruder")
        await adapter.send_text(other, "不该带令牌")
        assert client.sent == [("intruder", "不该带令牌", None)]


class TestContextTokenPersistence:
    async def test_saves_only_on_change(self) -> None:
        """令牌不变不写库:入站是高频路径,同一会话只该落一次。"""
        saved: list[str] = []

        async def on_token(token: str) -> None:
            saved.append(token)

        adapter = _adapter(_StubClient(), on_context_token=on_token)

        for raw in (_inbound("ctx-1"), _inbound("ctx-1"), _inbound("ctx-2")):
            msg = adapter._normalize(raw)
            assert msg is not None
            await adapter._remember_context_token(msg)

        assert saved == ["ctx-1", "ctx-2"]

    async def test_save_failure_does_not_break_inbound(self) -> None:
        """落库失败只影响重启后的首次推送,本进程内的令牌照常可用。"""

        async def failing(_token: str) -> None:
            raise RuntimeError("数据库不可用")

        client = _StubClient()
        adapter = _adapter(client, on_context_token=failing)

        msg = adapter._normalize(_inbound("ctx-1"))
        assert msg is not None
        await adapter._remember_context_token(msg)  # 不应抛出

        await adapter.send_text(_push_reply(), "推送")
        assert client.sent == [("u1", "推送", "ctx-1")]


class TestPushMessage:
    def test_inbound_without_token_keeps_previous(self) -> None:
        """异常消息(缺 context_token)不该把已记住的令牌清空。"""
        adapter = _adapter(_StubClient(), initial_context_token="ctx-keep")
        raw = _inbound("ctx-1")
        del raw["context_token"]
        msg = adapter._normalize(raw)
        assert msg is not None
        assert isinstance(msg, InboundMessage)
        assert msg.reply.token == {}
        assert adapter._context_token == "ctx-keep"
