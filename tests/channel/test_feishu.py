"""飞书 Webhook 通道:凭据解析、签名、响应解析与「即绑即用」流程测试。

用假的 FeishuClient 驱动真实的飞书驱动 + 通道中枢 + ChannelManager +
dispatcher 链路,验证绑定即推送的全链路;客户端本身用 MockTransport
验证报文形状与飞书响应的错误分类。
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import time
from collections.abc import Callable
from urllib.parse import parse_qs

import httpx
import pytest
from sqlmodel import SQLModel

from movieclaw_channel.adapter import ChannelContext
from movieclaw_channel.types import ReplyContext
from movieclaw_db.engine import dispose_db, init_db
from movieclaw_plugins.feishu.feishu_channel.adapter import FeishuAdapter
from movieclaw_plugins.feishu.feishu_channel.card import build_card
from movieclaw_plugins.feishu.feishu_channel.client import (
    FeishuApiError,
    FeishuClient,
    _token_ttl,
    credential_kind,
    feishu_account_id,
    normalize_webhook_url,
    parse_credentials,
)
from movieclaw_plugins.feishu.feishu_channel.registration import (
    PollOutcome,
    RegistrationError,
    RegistrationSession,
)

_URL = "https://open.feishu.cn/open-apis/bot/v2/hook/abc-123"


@pytest.fixture
async def db(tmp_path):
    """临时 SQLite 库 + 临时密钥的加密器(通道凭据落库前会加密)。"""
    from movieclaw_db.crypto import init_secret_box, reset_secret_box

    reset_secret_box()
    init_secret_box(None, tmp_path / ".secret_key")
    database = init_db(f"sqlite+aiosqlite:///{tmp_path}/test.db")
    async with database.engine.begin() as conn:
        await conn.run_sync(SQLModel.metadata.create_all)
    yield database
    await dispose_db()
    reset_secret_box()


async def _wait_for(predicate: Callable[[], bool], timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        await asyncio.sleep(0.02)
    raise AssertionError("等待条件超时")


# ---------------------------------------------------------------------------
# Webhook 地址与凭据解析
# ---------------------------------------------------------------------------


class TestWebhookUrl:
    def test_accepts_official_hosts(self) -> None:
        assert normalize_webhook_url(f" {_URL} ") == _URL  # 首尾空白归一化(粘贴常见)
        assert (
            normalize_webhook_url("https://open.larksuite.com/open-apis/bot/v2/hook/x1")
            == "https://open.larksuite.com/open-apis/bot/v2/hook/x1"
        )

    @pytest.mark.parametrize(
        "bad",
        [
            "http://open.feishu.cn/open-apis/bot/v2/hook/x1",  # 非 https
            "https://evil.example.com/open-apis/bot/v2/hook/x1",  # 非官方域(SSRF)
            "https://open.feishu.cn/other/path",  # 路径不是机器人 hook
            "https://open.feishu.cn/open-apis/bot/v2/hook/",  # 缺 hook 令牌
            "open.feishu.cn/open-apis/bot/v2/hook/x1",  # 缺协议
            "",
        ],
    )
    def test_rejects_bad_urls(self, bad: str) -> None:
        with pytest.raises(ValueError):
            normalize_webhook_url(bad)

    def test_account_id_extracts_hook_token(self) -> None:
        assert feishu_account_id(_URL) == "abc-123"

    def test_parse_credentials(self) -> None:
        assert parse_credentials(_URL) == (_URL, "")
        assert parse_credentials(json.dumps({"webhook_url": _URL, "secret": "s"})) == (_URL, "s")
        assert parse_credentials(json.dumps({"webhook_url": _URL, "secret": ""}))[1] == ""


# ---------------------------------------------------------------------------
# 客户端:报文形状与响应错误分类
# ---------------------------------------------------------------------------


def _expected_sign(timestamp: str, secret: str) -> str:
    # 飞书口径:string_to_sign(时间戳+换行+密钥)整体作 HMAC-SHA256 密钥,消息为空
    key = f"{timestamp}\n{secret}".encode()
    return base64.b64encode(hmac.new(key, digestmod=hashlib.sha256).digest()).decode()


def _client_with(token: str) -> FeishuClient:
    return FeishuClient(token)


async def _swap_transport(
    client: FeishuClient, handler: Callable[[httpx.Request], httpx.Response]
) -> None:
    await client._http.aclose()
    client._http = httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def test_send_text_payload_without_secret() -> None:
    captured: dict[str, httpx.Request] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["req"] = request
        return httpx.Response(200, json={"code": 0, "msg": "success"})

    client = _client_with(_URL)  # 裸 URL = 无签名
    await _swap_transport(client, handler)
    try:
        await client.send_text("hello")
    finally:
        await client.aclose()
    body = json.loads(captured["req"].content)
    assert body["msg_type"] == "text"
    assert body["content"]["text"] == "hello"
    assert "sign" not in body and "timestamp" not in body


async def test_send_text_signs_when_secret_present() -> None:
    captured: dict[str, httpx.Request] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["req"] = request
        return httpx.Response(200, json={"code": 0, "msg": "success"})

    client = _client_with(json.dumps({"webhook_url": _URL, "secret": "s3cret"}))
    await _swap_transport(client, handler)
    try:
        await client.send_text("hello")
    finally:
        await client.aclose()
    body = json.loads(captured["req"].content)
    assert body["sign"] == _expected_sign(body["timestamp"], "s3cret")


@pytest.mark.parametrize(
    ("status", "payload", "match", "auth_failed"),
    [
        (200, {"code": 19021, "msg": "Sign Match Fail"}, "签名校验失败", True),
        (200, {"code": 19024, "msg": "Key Words Not Found"}, "自定义关键词", False),
        (200, {"code": 9499, "msg": "Bad Request"}, "拒收消息", False),
        (404, {"msg": "not found"}, "机器人不存在", True),
        (502, None, "接口异常", False),
    ],
)
async def test_send_text_error_classification(
    status: int, payload: dict | None, match: str, auth_failed: bool
) -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        if payload is None:
            return httpx.Response(status, text="<html>Bad Gateway</html>")
        return httpx.Response(status, json=payload)

    client = _client_with(json.dumps({"webhook_url": _URL, "secret": "s3cret"}))
    await _swap_transport(client, handler)
    try:
        with pytest.raises(FeishuApiError) as exc_info:
            await client.send_text("hello")
    finally:
        await client.aclose()
    assert match in str(exc_info.value)
    assert exc_info.value.auth_failed is auth_failed


# ---------------------------------------------------------------------------
# 适配器:纯推送语义
# ---------------------------------------------------------------------------


class RecordingClient:
    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send_text(self, text: str) -> None:
        self.sent.append(text)

    async def aclose(self) -> None:
        pass


async def test_adapter_send_text_delegates_to_client() -> None:
    client = RecordingClient()
    adapter = FeishuAdapter(client, "bot1")
    reply = ReplyContext(channel_id="feishu", account_id="bot1", user_id="group")
    await adapter.send_text(reply, "hi")
    assert client.sent == ["hi"]


async def test_adapter_run_idles_until_stop() -> None:
    adapter = FeishuAdapter(RecordingClient(), "bot1")
    stop = asyncio.Event()

    async def on_inbound(msg) -> None: ...
    async def save_cursor(cursor: str) -> None: ...

    ctx = ChannelContext(
        account_id="bot1", on_inbound=on_inbound, save_cursor=save_cursor, stop=stop
    )
    task = asyncio.create_task(adapter.run(ctx))
    await asyncio.sleep(0.02)
    assert not task.done()  # 无收消息循环,空转挂起
    stop.set()
    await asyncio.wait_for(task, timeout=2)


# ---------------------------------------------------------------------------
# 驱动 + 通道中枢:即绑即用全链路
# ---------------------------------------------------------------------------


class FakeFeishuClient:
    """替身客户端:校验与运行各建一个,发送统一记到类列表。"""

    sent: list[str] = []
    instances: list[FakeFeishuClient] = []

    def __init__(self, token: str) -> None:
        self.token = token
        self.closed = False
        FakeFeishuClient.instances.append(self)

    async def send_text(self, text: str) -> None:
        FakeFeishuClient.sent.append(text)

    async def aclose(self) -> None:
        self.closed = True

    @classmethod
    def reset(cls) -> None:
        cls.sent = []
        cls.instances = []


@pytest.fixture
def hub(db, monkeypatch):
    from movieclaw_api.services.channel_hub import ChannelHub
    from movieclaw_plugins.feishu.feishu_channel import driver

    FakeFeishuClient.reset()
    monkeypatch.setattr(driver, "FeishuClient", FakeFeishuClient)
    return ChannelHub(lambda: {"feishu": driver.FeishuDriver()})


async def test_bind_feishu_end_to_end(hub) -> None:
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    try:
        binding = await hub.begin_binding("feishu", {"webhook_url": _URL, "secret": "s3cret"})
        assert (binding.status, binding.account_id) == ("confirmed", "abc-123")
        # 欢迎消息在绑定过程中已发出(连通性校验,群里当场可见)
        assert any("已接入本群" in text for text in FakeFeishuClient.sent)
        await _wait_for(lambda: hub.is_running("feishu", "abc-123"))
        # 没有绑定用户也是推送目标:推送经发送泵送达群机器人
        assert await hub.push("hello") == 1
        await _wait_for(lambda: "hello" in FakeFeishuClient.sent)
        # 落库凭据为 JSON 且加密可逆
        async with get_database().session() as session:
            stored = await ChannelAccountRepository(session).get("feishu", "abc-123")
        assert stored is not None
        assert ChannelAccountRepository.credentials(stored) == {
            "webhook_url": _URL,
            "secret": "s3cret",
        }
        assert json.loads(FakeFeishuClient.instances[-1].token)["secret"] == "s3cret"
    finally:
        await hub.stop()


async def test_bind_feishu_same_bot_rebind_overwrites(hub) -> None:
    try:
        await hub.begin_binding("feishu", {"webhook_url": _URL, "secret": "old"})
        await hub.begin_binding("feishu", {"webhook_url": _URL, "secret": "new"})
        rows = await _list_feishu()
        assert [r.account_id for r in rows] == ["abc-123"]
    finally:
        await hub.stop()


async def _list_feishu():
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    async with get_database().session() as session:
        rows = await ChannelAccountRepository(session).list_by_channel("feishu")
    return rows


async def test_bind_feishu_then_unbind(hub) -> None:
    try:
        await hub.begin_binding("feishu", {"webhook_url": _URL})
        assert await hub.unbind("feishu", "abc-123") is True
        assert not hub.is_running("feishu", "abc-123")
        assert await hub.push("hello") == 0
    finally:
        await hub.stop()


async def test_bind_feishu_rejects_bad_url(hub) -> None:
    # 内网地址必须在进入任何网络/落库动作前被拒(SSRF 防线)
    try:
        with pytest.raises(ValueError, match="不合法"):
            await hub.begin_binding(
                "feishu", {"webhook_url": "https://192.168.1.1/open-apis/bot/v2/hook/x1"}
            )
        assert FakeFeishuClient.instances == []
    finally:
        await hub.stop()


# ---------------------------------------------------------------------------
# 卡片:只使用文案里已经有的标题、正文和链接
# ---------------------------------------------------------------------------


def test_build_card_uses_only_existing_text() -> None:
    card = build_card("星际穿越\n★ 8.7\n详见 [资料](https://example.com/item)。")
    assert card is not None
    assert card["header"]["title"]["content"] == "星际穿越"
    body = card["elements"][0]["text"]["content"]
    assert "★ 8.7" in body
    assert "https://example.com/item" in body
    actions = card["elements"][1]["actions"]
    assert actions == [
        {
            "tag": "button",
            "text": {"tag": "plain_text", "content": "资料"},
            "type": "primary",
            "url": "https://example.com/item",
        }
    ]
    assert "img_key" not in json.dumps(card)


def test_build_card_poster_and_bare_link_limit() -> None:
    text = "\n".join(
        [
            "标题",
            "https://a.example/1",
            "https://b.example/2",
            "https://c.example/3.",
            "https://d.example/4",
        ]
    )
    card = build_card(text, image_key="img_1")
    assert card is not None
    assert card["elements"][0]["img_key"] == "img_1"
    assert card["elements"][0]["alt"]["content"] == "标题"
    urls = [item["url"] for item in card["elements"][2]["actions"]]
    assert urls == ["https://a.example/1", "https://b.example/2", "https://c.example/3"]
    dumped = json.dumps(card, ensure_ascii=False)
    assert "评分" not in dumped


def test_build_card_without_title_is_absent() -> None:
    assert build_card("  \n\t") is None


def test_poll_outcome_repr_omits_secret() -> None:
    outcome = PollOutcome(
        status="success", interval=5, client_id="cli_app", client_secret="super-secret"
    )
    assert "super-secret" not in repr(outcome)


# ---------------------------------------------------------------------------
# 设备码注册
# ---------------------------------------------------------------------------


def _session(handler: Callable[[httpx.Request], httpx.Response]) -> RegistrationSession:
    return RegistrationSession(httpx.AsyncClient(transport=httpx.MockTransport(handler)))


def _form(request: httpx.Request) -> dict[str, list[str]]:
    return parse_qs(request.content.decode())


async def test_registration_begin_fields_and_defaults(monkeypatch) -> None:
    import movieclaw_plugins.feishu.feishu_channel.registration as registration

    monkeypatch.setattr(registration.time, "monotonic", lambda: 5_000.0)
    seen: list[dict[str, list[str]]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        form = _form(request)
        seen.append(form)
        if form["action"] == ["init"]:
            return httpx.Response(200, json={"supported_auth_methods": ["client_secret"]})
        return httpx.Response(
            200,
            json={
                "device_code": "device-1",
                "verification_uri_complete": "https://accounts.feishu.cn/verify?user_code=CODE",
                "user_code": "CODE",
                "interval": 0,
                "expires_in": 600,
            },
        )

    session = _session(handler)
    try:
        started = await session.start()
    finally:
        await session.aclose()
    assert set(seen[0]) == {"action"}
    assert seen[0]["action"] == ["init"]
    assert set(seen[1]) == {"action", "archetype", "auth_method", "request_user_info"}
    assert seen[1]["request_user_info"] == ["open_id"]
    assert seen[1]["archetype"] == ["PersonalAgent"]
    assert seen[1]["auth_method"] == ["client_secret"]
    assert started.qr == "https://accounts.feishu.cn/verify?user_code=CODE"
    assert started.interval == 5
    assert started.expire_in == 600
    assert session.deadline == 5_600.0


async def test_registration_init_requires_client_secret() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"supported_auth_methods": ["redirect"]})

    session = _session(handler)
    try:
        with pytest.raises(RegistrationError) as exc_info:
            await session.start()
    finally:
        await session.aclose()
    assert exc_info.value.code == "unsupported"


@pytest.mark.parametrize(
    ("payload", "status"),
    [
        ({"error": "authorization_pending"}, "pending"),
        ({"error": "slow_down"}, "pending"),
        ({"error": "access_denied"}, "denied"),
        ({"error": "expired_token"}, "expired"),
        ({"error": "invalid_grant"}, "expired"),
        ({"error": "server_error", "error_description": "nope"}, "error"),
    ],
)
async def test_registration_poll_branches(payload: dict, status: str) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        form = _form(request)
        assert set(form) == {"action", "device_code"}
        assert form["action"] == ["poll"]
        return httpx.Response(400, json=payload)

    session = _session(handler)
    session.deadline = time.monotonic() + 30
    session.device_code = "device-1"
    session.interval = 56 if payload.get("error") == "slow_down" else 5
    try:
        outcome = await session.poll_once()
    finally:
        await session.aclose()
    assert outcome.status == status
    if payload.get("error") == "slow_down":
        assert outcome.interval == 60
    if status == "error":
        assert outcome.message == "nope"


async def test_registration_poll_switches_to_lark_and_discards_first_secret() -> None:
    hosts: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        hosts.append(request.url.host or "")
        if request.url.host == "accounts.feishu.cn":
            return httpx.Response(
                200,
                json={
                    "client_id": "cli_discard",
                    "client_secret": "discard-me",
                    "user_info": {"tenant_brand": "lark", "open_id": "ou_discard"},
                },
            )
        return httpx.Response(
            200,
            json={
                "client_id": "cli_keep",
                "client_secret": "keep-me",
                "user_info": {"tenant_brand": "lark", "open_id": "ou_keep"},
            },
        )

    session = _session(handler)
    session.deadline = time.monotonic() + 30
    session.device_code = "device-1"
    try:
        outcome = await session.poll_once()
    finally:
        await session.aclose()
    assert hosts == ["accounts.feishu.cn", "accounts.larksuite.com"]
    assert outcome.status == "success"
    assert outcome.client_secret == "keep-me"
    assert outcome.open_id == "ou_keep"
    assert outcome.domain == "lark"
    assert "discard-me" not in repr(outcome)


async def test_registration_poll_treats_network_and_deadline_as_terminal_or_pending() -> None:
    calls = {"n": 0}

    def handler(_request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            raise httpx.ConnectError("down")
        return httpx.Response(200, text="not-json")

    session = _session(handler)
    session.device_code = "device-1"
    session.deadline = time.monotonic() + 30
    try:
        assert (await session.poll_once()).status == "pending"
        assert (await session.poll_once()).status == "pending"
        session.deadline = time.monotonic() - 1
        assert (await session.poll_once()).status == "expired"
    finally:
        await session.aclose()
    assert calls["n"] == 2


# ---------------------------------------------------------------------------
# 自建应用:令牌、上传、卡片与 Webhook 回退
# ---------------------------------------------------------------------------


def _app_token(**overrides: str) -> str:
    data = {
        "app_id": "cli_app",
        "app_secret": "app-secret",
        "receive_id": "ou_user",
        "receive_id_type": "open_id",
        "domain": "feishu",
    }
    data.update(overrides)
    return json.dumps(data)


def test_credential_kind_prefers_webhook_when_both_exist() -> None:
    both = json.dumps({"webhook_url": _URL, "secret": "s", "app_id": "cli_app"})
    assert credential_kind(both) == "webhook"
    assert credential_kind(_app_token()) == "app"
    assert _token_ttl(7200) == 7080
    assert _token_ttl(90) == 90


async def test_tenant_token_is_cached_until_deadline() -> None:
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        body = json.loads(request.content)
        assert body == {"app_id": "cli_app", "app_secret": "app-secret"}
        assert request.url.host == "open.feishu.cn"
        return httpx.Response(
            200, json={"code": 0, "tenant_access_token": f"tat-{calls['n']}", "expire": 7200}
        )

    client = FeishuClient(_app_token())
    await _swap_transport(client, handler)
    try:
        assert await client.tenant_access_token() == "tat-1"
        assert await client.tenant_access_token() == "tat-1"
        client._access_deadline = time.monotonic() - 1
        assert await client.tenant_access_token() == "tat-2"
    finally:
        await client.aclose()
    assert calls["n"] == 2


async def test_upload_image_and_card_then_stale_token_retries_once() -> None:
    calls: list[tuple[str, str]] = []
    cards = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if url.endswith("/tenant_access_token/internal"):
            name = f"tat-{sum(1 for kind, _ in calls if kind == 'token') + 1}"
            calls.append(("token", name))
            return httpx.Response(
                200, json={"code": 0, "tenant_access_token": name, "expire": 7200}
            )
        auth = request.headers.get("authorization", "")
        if url.endswith("/im/v1/images"):
            calls.append(("image", auth))
            assert b'name="image_type"' in request.content
            assert b"message" in request.content
            assert b"\x89PNG\r\n\x1a\n" in request.content
            return httpx.Response(200, json={"code": 0, "data": {"image_key": "img_key_1"}})
        body = json.loads(request.content)
        calls.append((body["msg_type"], auth))
        if body["msg_type"] == "interactive":
            cards["n"] += 1
            if cards["n"] == 1:
                return httpx.Response(200, json={"code": 99991663, "msg": "token expired"})
        assert request.url.params["receive_id_type"] == "open_id"
        assert body["receive_id"] == "ou_user"
        if body["msg_type"] == "interactive":
            card = json.loads(body["content"])
            assert card["elements"][0]["img_key"] == "img_key_1"
            assert card["header"]["title"]["content"] == "标题"
        return httpx.Response(200, json={"code": 0, "msg": "success"})

    client = FeishuClient(_app_token())
    await _swap_transport(client, handler)
    try:
        await client.send_card("标题\n简介", b"\x89PNG\r\n\x1a\nrest")
    finally:
        await client.aclose()
    assert [kind for kind, _ in calls] == ["token", "image", "interactive", "token", "interactive"]
    assert calls[2][1] == "Bearer tat-1"
    assert calls[4][1] == "Bearer tat-2"


async def test_upload_failure_sends_imageless_card() -> None:
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if url.endswith("/tenant_access_token/internal"):
            return httpx.Response(
                200, json={"code": 0, "tenant_access_token": "tat", "expire": 7200}
            )
        if url.endswith("/im/v1/images"):
            seen.append("image")
            return httpx.Response(200, json={"code": 9999, "msg": "bad image"})
        body = json.loads(request.content)
        seen.append(body["msg_type"])
        card = json.loads(body["content"])
        assert "img" not in {item["tag"] for item in card["elements"]}
        return httpx.Response(200, json={"code": 0, "msg": "success"})

    client = FeishuClient(_app_token(domain="lark"))
    await _swap_transport(client, handler)
    try:
        await client.send_card("标题", b"\xff\xd8\xffrest")
    finally:
        await client.aclose()
    assert seen == ["image", "interactive"]
    assert client._domain == "lark"


async def test_webhook_photo_sends_imageless_card_with_signature() -> None:
    captured: dict[str, httpx.Request] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["req"] = request
        return httpx.Response(200, json={"code": 0, "msg": "success"})

    client = _client_with(json.dumps({"webhook_url": _URL, "secret": "s3cret", "app_id": "cli"}))
    await _swap_transport(client, handler)
    try:
        await client.send_card("标题\nhttps://example.com/a", b"\x89PNG\r\n\x1a\n")
    finally:
        await client.aclose()
    body = json.loads(captured["req"].content)
    assert captured["req"].url == httpx.URL(_URL)
    assert body["msg_type"] == "interactive"
    assert body["sign"] == _expected_sign(body["timestamp"], "s3cret")
    assert "img_key" not in json.dumps(body["card"])
    assert body["card"]["elements"][-1]["actions"][0]["url"] == "https://example.com/a"


async def test_adapter_photo_falls_back_to_text_when_card_is_rejected() -> None:
    kinds: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        kinds.append(body["msg_type"])
        if body["msg_type"] == "interactive":
            return httpx.Response(200, json={"code": 9499, "msg": "rejected"})
        assert body["content"]["text"] == "标题"
        return httpx.Response(200, json={"code": 0, "msg": "success"})

    client = _client_with(json.dumps({"webhook_url": _URL, "secret": ""}))
    await _swap_transport(client, handler)
    adapter = FeishuAdapter(client, "abc-123")
    try:
        await adapter.send_photo(
            ReplyContext(channel_id="feishu", account_id="abc-123", user_id="group"),
            b"\x89PNG\r\n\x1a\n",
            "标题",
        )
    finally:
        await client.aclose()
    assert kinds == ["interactive", "text"]


def _install_transport(monkeypatch, handler) -> None:
    monkeypatch.setattr(
        "movieclaw_sdk.net.http_transport",
        lambda service, **kwargs: httpx.MockTransport(handler),
    )


class AppGateway:
    """扫码注册 + 开放平台的假服务器。成功出现在第一次 poll,测试不必睡 interval。"""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.client_secret = "app-secret-value"

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        url = str(request.url)
        if url.endswith("/oauth/v1/app/registration"):
            form = _form(request)
            action = form["action"][0]
            if action == "init":
                return httpx.Response(200, json={"supported_auth_methods": ["client_secret"]})
            if action == "begin":
                return httpx.Response(
                    200,
                    json={
                        "device_code": "device-1",
                        "verification_uri_complete": "https://accounts.feishu.cn/verify?user_code=CODE",
                        "user_code": "CODE",
                        "interval": 5,
                        "expire_in": 600,
                    },
                )
            assert set(form) == {"action", "device_code"}
            return httpx.Response(
                200,
                json={
                    "client_id": "cli_app",
                    "client_secret": self.client_secret,
                    "user_info": {"open_id": "ou_scanner"},
                },
            )
        if url.endswith("/tenant_access_token/internal"):
            assert json.loads(request.content)["app_secret"] == self.client_secret
            return httpx.Response(
                200, json={"code": 0, "tenant_access_token": "tat-live", "expire": 7200}
            )
        if url.endswith("/im/v1/images"):
            assert b"\x89PNG\r\n\x1a\n" in request.content
            return httpx.Response(200, json={"code": 0, "data": {"image_key": "img_poster"}})
        if "/im/v1/messages" in url:
            return httpx.Response(200, json={"code": 0, "msg": "success"})
        return httpx.Response(404, json={"code": 404, "msg": url})


def _pinned_hub(gateway: AppGateway):
    from movieclaw_api.services.channel_hub import ChannelHub
    from movieclaw_plugins.feishu.feishu_channel.driver import FeishuDriver

    driver = FeishuDriver()
    return driver, ChannelHub(lambda: {"feishu": driver})


async def test_form_bind_app_then_push_card(db, monkeypatch) -> None:
    """手填应用凭据:校验令牌和欢迎消息,再经发送泵把海报打成卡片。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    gateway = AppGateway()
    _install_transport(monkeypatch, gateway.handler)
    _driver, hub = _pinned_hub(gateway)
    photo = b"\x89PNG\r\n\x1a\nposter"
    try:
        with pytest.raises(ValueError, match="请填写"):
            await hub.begin_binding("feishu", {})
        with pytest.raises(ValueError, match="一种接入方式"):
            await hub.begin_binding(
                "feishu", {"webhook_url": _URL, "app_id": "cli_app", "app_secret": "x"}
            )
        binding = await hub.begin_binding(
            "feishu",
            {
                "app_id": "cli_form",
                "app_secret": "app-secret-value",
                "receive_id": "oc_group1",
                "domain": "lark",
            },
        )
        assert (binding.status, binding.account_id) == ("confirmed", "cli_form")
        await _wait_for(lambda: hub.is_running("feishu", "cli_form"))
        async with get_database().session() as session:
            stored = await ChannelAccountRepository(session).get("feishu", "cli_form")
        assert stored is not None
        assert stored.bound_user_id is None
        assert ChannelAccountRepository.credentials(stored)["receive_id_type"] == "chat_id"
        assert await hub.push("手工标题\nhttps://example.com/manual", photo=photo) == 1
        await _wait_for(lambda: any("/im/v1/images" in str(item.url) for item in gateway.requests))
        images = [item for item in gateway.requests if str(item.url).endswith("/im/v1/images")]
        cards = []
        for item in gateway.requests:
            if "/im/v1/messages" not in str(item.url):
                continue
            body = json.loads(item.content)
            if body["msg_type"] == "interactive":
                cards.append((item, body))
        assert images and images[-1].url.host == "open.larksuite.com"
        assert cards
        card = json.loads(cards[-1][1]["content"])
        assert card["header"]["title"]["content"] == "手工标题"
        assert card["elements"][0]["img_key"] == "img_poster"
        assert card["elements"][-1]["actions"][0]["url"] == "https://example.com/manual"
        assert cards[-1][1]["receive_id"] == "oc_group1"
    finally:
        await hub.stop()


async def test_scan_bind_then_push_card(db, monkeypatch, caplog) -> None:
    """扫码创建应用 → 用扫码人 open_id 绑定 → 带海报的推送走卡片。全程不访问真实飞书。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository
    from movieclaw_sdk.channels import driver_spec

    gateway = AppGateway()
    _install_transport(monkeypatch, gateway.handler)
    driver, hub = _pinned_hub(gateway)
    assert driver_spec(driver)["binding"]["scan"] is True
    assert driver_spec(driver)["binding"]["kind"] == "form"
    photo = b"\x89PNG\r\n\x1a\nposter"
    try:
        with caplog.at_level(logging.DEBUG):
            binding = await hub.begin_binding("feishu", {"flow": "1"})
            assert binding.kind == "flow"
            assert binding.qr == "https://accounts.feishu.cn/verify?user_code=CODE"
            assert "CODE" in binding.message
            await _wait_for(
                lambda: (
                    (found := hub.binding(binding.binding_id)) is not None
                    and found.status == "need_input"
                )
            )
            done = await hub.binding_input(binding.binding_id, "-")
            assert done.status == "confirmed"
            assert done.account_id == "cli_app"
            await _wait_for(lambda: hub.is_running("feishu", "cli_app"))
            async with get_database().session() as session:
                stored = await ChannelAccountRepository(session).get("feishu", "cli_app")
            assert stored is not None
            creds = ChannelAccountRepository.credentials(stored)
            assert creds["receive_id"] == "ou_scanner"
            assert creds["app_secret"] == gateway.client_secret
            assert stored.bound_user_id == "ou_scanner"
            assert stored.display_name == "飞书应用机器人"
            assert await hub.push("扫码标题\n一句简介", photo=photo) == 1
            await _wait_for(
                lambda: any(
                    "/im/v1/messages" in str(item.url)
                    and json.loads(item.content)["msg_type"] == "interactive"
                    for item in gateway.requests
                )
            )
        assert gateway.client_secret not in caplog.text
        assert "device-1" not in caplog.text
        welcome = next(
            json.loads(item.content)
            for item in gateway.requests
            if "/im/v1/messages" in str(item.url) and json.loads(item.content)["msg_type"] == "text"
        )
        assert "已接入" in json.loads(welcome["content"])["text"]
        assert welcome["receive_id"] == "ou_scanner"
    finally:
        await hub.stop()
