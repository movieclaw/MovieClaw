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
from movieclaw_plugins.feishu.feishu_channel.card import (
    _MAX_SUMMARY,
    LONG_TITLE_HEADER,
    build_card,
    chunk_text,
    layout_card,
)
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
    assert exc_info.value.missing_send_permission is False


@pytest.mark.parametrize(
    ("status", "payload", "code"),
    [
        (400, {"code": 230027, "msg": "Lack of necessary permissions"}, 230027),
        (200, {"code": "99991672", "msg": "scope required"}, 99991672),
    ],
)
async def test_missing_send_permission_codes(status: int, payload: dict, code: int) -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(status, json=payload)

    client = _client_with(json.dumps({"webhook_url": _URL, "secret": "s3cret"}))
    await _swap_transport(client, handler)
    try:
        with pytest.raises(FeishuApiError) as exc_info:
            await client.send_text("hello")
    finally:
        await client.aclose()
    assert exc_info.value.missing_send_permission is True
    assert exc_info.value.code == code
    assert exc_info.value.auth_failed is False


async def test_mute_code_is_not_a_missing_scope() -> None:
    """230035 是禁言/拉黑,不是没开通 im:message。非 200 仍按接口异常。"""

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"code": 230035, "msg": "Send Message Permission deny"})

    client = _client_with(json.dumps({"webhook_url": _URL, "secret": "s3cret"}))
    await _swap_transport(client, handler)
    try:
        with pytest.raises(FeishuApiError, match="接口异常") as exc_info:
            await client.send_text("hello")
    finally:
        await client.aclose()
    assert exc_info.value.missing_send_permission is False


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
        again = await hub.begin_binding("feishu", {"webhook_url": _URL, "secret": "new"})
        assert again.review is False
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


def test_build_card_hands_back_overflow_and_keeps_late_link() -> None:
    late = "https://example.com/late"
    laid = layout_card("标题\n" + ("简" * 5000) + "\n" + late, image_key="img_k")
    assert laid is not None
    card, overflow = laid
    body = card["elements"][1]["text"]["content"]
    assert len(body) == _MAX_SUMMARY
    assert late not in body
    # 卡片没装下的部分原样交回,一个字不丢
    assert body + overflow == ("简" * 5000) + "\n" + late
    assert card["elements"][0]["img_key"] == "img_k"
    assert card["elements"][-1]["actions"][0]["url"] == late
    titled = layout_card(("题" * 250) + "\n正文")
    assert titled is not None
    # 首行超长:标题栏用固定短标题,原文只在正文出现一次
    assert titled[0]["header"]["title"]["content"] == LONG_TITLE_HEADER
    assert titled[0]["elements"][0]["text"]["content"] == ("题" * 250) + "\n正文"
    assert titled[1] == ""
    exact = layout_card("题" * 200)
    assert exact is not None
    assert exact[0]["header"]["title"]["content"] == "题" * 200


def test_single_line_over_200_chars_is_shown_once() -> None:
    """201 字单行消息:卡片里只显示 201 字,不再出现「截断标题 + 完整正文」的重复。"""
    text = "字" * 201
    laid = layout_card(text, image_key="img_k")
    assert laid is not None
    card, overflow = laid
    assert overflow == ""
    assert card["header"]["title"]["content"] == LONG_TITLE_HEADER
    shown = [e["text"]["content"] for e in card["elements"] if e.get("tag") == "div"]
    assert shown == [text]
    assert json.dumps(card, ensure_ascii=False).count("字") == 201


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
    assert seen[1]["request_user_info"] == ["open_id tenant_brand"]
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
        self.open_id = "ou_scanner"
        self.fail_token = False
        self.message_replies: list[httpx.Response] = []
        #: 扫码人所在租户品牌。lark 时飞书域只报告品牌,凭据只在 Lark 域签发
        self.brand = "feishu"
        #: begin 时请求的 user_info 字段;契约:服务端只返回请求过的字段
        self.requested: set[str] = set()

    def _user_info(self) -> dict[str, str]:
        info: dict[str, str] = {}
        if "open_id" in self.requested and self.open_id:
            info["open_id"] = self.open_id
        if "tenant_brand" in self.requested:
            info["tenant_brand"] = self.brand
        return info

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        url = str(request.url)
        if url.endswith("/oauth/v1/app/registration"):
            form = _form(request)
            action = form["action"][0]
            if action == "init":
                return httpx.Response(200, json={"supported_auth_methods": ["client_secret"]})
            if action == "begin":
                assert request.url.host == "accounts.feishu.cn"
                self.requested = set(form["request_user_info"][0].split())
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
            issuer = "accounts.larksuite.com" if self.brand == "lark" else "accounts.feishu.cn"
            if request.url.host != issuer:
                # 跨品牌:签发域之外只报告品牌(且只在被请求时),不给凭据
                info = {k: v for k, v in self._user_info().items() if k == "tenant_brand"}
                body: dict = {"error": "authorization_pending"}
                if info:
                    body["user_info"] = info
                return httpx.Response(200, json=body)
            return httpx.Response(
                200,
                json={
                    "client_id": "cli_app",
                    "client_secret": self.client_secret,
                    "user_info": self._user_info(),
                },
            )
        if url.endswith("/tenant_access_token/internal"):
            body = json.loads(request.content)
            assert body["app_secret"] == self.client_secret
            if self.fail_token:
                return httpx.Response(400, json={"code": 10014, "msg": "app secret invalid"})
            return httpx.Response(
                200, json={"code": 0, "tenant_access_token": "tat-live", "expire": 7200}
            )
        if url.endswith("/im/v1/images"):
            assert b"\x89PNG\r\n\x1a\n" in request.content
            return httpx.Response(200, json={"code": 0, "data": {"image_key": "img_poster"}})
        if "/im/v1/messages" in url:
            if self.message_replies:
                return self.message_replies.pop(0)
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
    assert driver_spec(driver)["capabilities"]["photo_caption_limit"] == 20_000
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
            ready = hub.binding(binding.binding_id)
            assert ready is not None and ready.input_optional is True
            assert ready.prefill == {"app_id": "cli_app"}
            # 续传令牌独立于会进日志的 flow_id,至少 128 bit
            assert ready.resume_token and ready.resume_token != binding.flow_id
            assert binding.flow_id not in ready.resume_token
            assert len(ready.resume_token) >= 32
            assert gateway.client_secret not in json.dumps(ready.prefill)
            done = await hub.binding_input(binding.binding_id, "")
            assert done.status == "confirmed"
            assert done.review is False
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


async def _scan_ready(monkeypatch, gateway: AppGateway | None = None):
    gateway = gateway or AppGateway()
    _install_transport(monkeypatch, gateway.handler)
    driver, hub = _pinned_hub(gateway)
    binding = await hub.begin_binding("feishu", {"flow": "1"})
    await _wait_for(
        lambda: (
            (found := hub.binding(binding.binding_id)) is not None and found.status == "need_input"
        )
    )
    ready = hub.binding(binding.binding_id)
    assert ready is not None
    return gateway, driver, hub, ready


async def test_scan_rejects_bad_targets_and_accepts_long_open_id(db, monkeypatch) -> None:
    gateway, _driver, hub, ready = await _scan_ready(monkeypatch)
    try:
        for bad in ("-", "oc_", "oc_bad-id", "x" * 129):
            stayed = await hub.binding_input(ready.binding_id, bad)
            assert stayed.status == "need_input"
            assert "128" in stayed.message
            assert "留空" in stayed.message
        target = "ou_" + ("a" * 100)
        done = await hub.binding_input(ready.binding_id, target)
        assert done.status == "confirmed"
        from movieclaw_db.engine import get_database
        from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

        async with get_database().session() as session:
            stored = await ChannelAccountRepository(session).get("feishu", "cli_app")
        assert stored is not None
        assert ChannelAccountRepository.credentials(stored)["receive_id"] == target
        assert gateway.client_secret not in stayed.message
    finally:
        await hub.stop()


async def test_scan_without_open_id_requires_a_target(db, monkeypatch) -> None:
    gateway = AppGateway()
    gateway.open_id = ""
    _gateway, _driver, hub, ready = await _scan_ready(monkeypatch, gateway)
    try:
        stayed = await hub.binding_input(ready.binding_id, "")
        assert stayed.status == "need_input"
        assert "open_id" in stayed.message
        done = await hub.binding_input(ready.binding_id, "oc_group1")
        assert done.status == "confirmed"
    finally:
        await hub.stop()


async def test_cancel_keeps_secret_for_form_resume(db, monkeypatch, caplog) -> None:
    from movieclaw_sdk.channels import flow_dict

    gateway, driver, hub, ready = await _scan_ready(monkeypatch)
    secret = gateway.client_secret
    try:
        with caplog.at_level(logging.DEBUG):
            await driver.cancel_flow(ready.flow_id)
            state = await driver.flow_state(ready.flow_id)
            assert state.status == "failed"
            assert "保留" in state.message
            assert state.prefill == {"app_id": "cli_app"}
            token = state.resume_token
            assert token and token == ready.resume_token
            assert secret not in json.dumps(flow_dict(state))
            assert secret not in repr(driver._registry._flows[ready.flow_id])
            assert secret not in repr(driver._registry._held[token])
            assert token not in repr(driver._registry._held[token])
            # flow_id 不能当续传令牌用
            with pytest.raises(ValueError, match="已失效"):
                await hub.begin_binding(
                    "feishu",
                    {
                        "app_id": "cli_app",
                        "receive_id": "ou_scanner",
                        "resume_flow": ready.flow_id,
                    },
                )
            held = driver._registry._held[token]
            held.stored_at -= 31 * 60
            with pytest.raises(ValueError, match="已失效"):
                await hub.begin_binding(
                    "feishu",
                    {
                        "app_id": "cli_app",
                        "receive_id": "ou_scanner",
                        "resume_flow": token,
                    },
                )
            assert token not in driver._registry._held
            assert held.app_secret == ""
        assert secret not in caplog.text
    finally:
        await hub.stop()


async def test_cancel_resume_before_expiry_binds_without_echoing_secret(
    db, monkeypatch, caplog
) -> None:
    gateway, driver, hub, ready = await _scan_ready(monkeypatch)
    secret = gateway.client_secret
    try:
        with caplog.at_level(logging.DEBUG):
            await driver.cancel_flow(ready.flow_id)
            done = await hub.begin_binding(
                "feishu",
                {
                    "app_id": "cli_app",
                    "receive_id": "oc_group9",
                    "resume_flow": ready.resume_token,
                },
            )
            assert done.status == "confirmed" and done.review is False
            assert driver._registry._held == {}
            # 表单续传成功后 flow 一并删掉
            assert ready.flow_id not in driver._registry._flows
            # 同一个令牌不能再用第二次
            with pytest.raises(ValueError, match="已失效"):
                await hub.begin_binding(
                    "feishu",
                    {
                        "app_id": "cli_app",
                        "receive_id": "oc_group9",
                        "resume_flow": ready.resume_token,
                    },
                )
            from movieclaw_db.engine import get_database
            from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

            async with get_database().session() as session:
                stored = await ChannelAccountRepository(session).get("feishu", "cli_app")
            assert stored is not None
            creds = ChannelAccountRepository.credentials(stored)
            assert creds["app_secret"] == secret
            assert creds["receive_id"] == "oc_group9"
        assert secret not in caplog.text
    finally:
        await hub.stop()


async def test_welcome_permission_keeps_credentials_until_retry(db, monkeypatch, caplog) -> None:
    gateway, _driver, hub, ready = await _scan_ready(monkeypatch)
    secret = gateway.client_secret
    try:
        with caplog.at_level(logging.DEBUG):
            gateway.message_replies = [
                httpx.Response(400, json={"code": 230027, "msg": "Lack of necessary permissions"})
            ]
            blocked = await hub.binding_input(ready.binding_id, "")
            assert blocked.status == "need_input"
            assert "im:message" in blocked.message and "发布" in blocked.message
            assert blocked.prefill == {"app_id": "cli_app"}
            assert secret not in blocked.message
            gateway.message_replies = [
                httpx.Response(200, json={"code": "99991672", "msg": "scope required"})
            ]
            blocked = await hub.binding_input(ready.binding_id, "oc_group1")
            assert blocked.status == "need_input"
            assert "im:message" in blocked.message
            gateway.message_replies = [
                httpx.Response(400, json={"code": 230035, "msg": "Send Message Permission deny"})
            ]
            generic = await hub.binding_input(ready.binding_id, "oc_group1")
            assert generic.status == "need_input"
            assert "im:message" not in generic.message
            assert "欢迎消息没发出去" in generic.message
            done = await hub.binding_input(ready.binding_id, "")
            assert done.status == "confirmed"
            assert done.account_id == "cli_app"
        assert secret not in caplog.text
    finally:
        await hub.stop()


async def test_token_failure_keeps_secret_for_form_retry(db, monkeypatch, caplog) -> None:
    gateway = AppGateway()
    gateway.fail_token = True
    _install_transport(monkeypatch, gateway.handler)
    driver, hub = _pinned_hub(gateway)
    secret = gateway.client_secret
    try:
        with caplog.at_level(logging.DEBUG):
            binding = await hub.begin_binding("feishu", {"flow": "1"})
            await _wait_for(
                lambda: (
                    (found := hub.binding(binding.binding_id)) is not None
                    and found.status == "failed"
                )
            )
            failed = hub.binding(binding.binding_id)
            assert failed is not None
            assert "保留" in failed.message
            assert failed.prefill == {"app_id": "cli_app"}
            assert secret not in failed.message
            gateway.fail_token = False
            done = await hub.begin_binding(
                "feishu",
                {
                    "app_id": "cli_app",
                    "receive_id": "ou_scanner",
                    "resume_flow": failed.resume_token,
                },
            )
            assert done.status == "confirmed"
            assert driver._registry.claim(failed.resume_token, "cli_app") is None
            assert driver._registry._held == {}
        assert secret not in caplog.text
    finally:
        await hub.stop()


async def test_same_app_rebind_explains_the_update(db, monkeypatch) -> None:
    _gateway, _driver, hub, ready = await _scan_ready(monkeypatch)
    try:
        first = await hub.binding_input(ready.binding_id, "")
        assert first.review is False
        binding = await hub.begin_binding("feishu", {"flow": "1"})
        await _wait_for(
            lambda: (
                (found := hub.binding(binding.binding_id)) is not None
                and found.status == "need_input"
            )
        )
        again = hub.binding(binding.binding_id)
        assert again is not None and "已绑定" in again.message
        second = await hub.binding_input(again.binding_id, "oc_group2")
        assert second.status == "confirmed" and second.review is True
        assert "已绑定" in second.message and "更新" in second.message
        rows = await _list_feishu()
        assert [row.account_id for row in rows] == ["cli_app"]
        from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

        assert ChannelAccountRepository.credentials(rows[0])["receive_id"] == "oc_group2"
    finally:
        await hub.stop()


async def test_long_push_still_sends_a_card(db, monkeypatch) -> None:
    gateway, _driver, hub, ready = await _scan_ready(monkeypatch)
    photo = b"\x89PNG\r\n\x1a\nposter"
    try:
        assert (await hub.binding_input(ready.binding_id, "")).status == "confirmed"
        await _wait_for(lambda: hub.is_running("feishu", "cli_app"))
        text = "长标题\n" + ("简" * 1500) + "\nhttps://example.com/late"
        assert await hub.push(text, photo=photo) == 1
        await _wait_for(
            lambda: any(str(item.url).endswith("/im/v1/images") for item in gateway.requests)
        )
        cards = [
            json.loads(json.loads(item.content)["content"])
            for item in gateway.requests
            if "/im/v1/messages" in str(item.url)
            and json.loads(item.content)["msg_type"] == "interactive"
        ]
        assert cards
        body = cards[-1]["elements"][1]["text"]["content"]
        assert "简" in body
        assert cards[-1]["elements"][0]["img_key"] == "img_poster"
        assert cards[-1]["elements"][-1]["actions"][0]["url"] == "https://example.com/late"
        before = len(gateway.requests)
        assert await hub.push("超" * 20_001, photo=photo) == 1
        await _wait_for(
            lambda: any(
                "/im/v1/messages" in str(item.url)
                and json.loads(item.content).get("msg_type") == "text"
                and "超" in json.loads(json.loads(item.content)["content"]).get("text", "")
                for item in gateway.requests[before:]
            )
        )
        assert not any(
            str(item.url).endswith("/im/v1/images") for item in gateway.requests[before:]
        )
    finally:
        await hub.stop()


async def test_manual_target_length_and_permission_retry(db, monkeypatch) -> None:
    gateway = AppGateway()
    _install_transport(monkeypatch, gateway.handler)
    _driver, hub = _pinned_hub(gateway)
    fields = {
        "app_id": "cli_form",
        "app_secret": "app-secret-value",
        "receive_id": "ou_" + ("b" * 126),
    }
    try:
        with pytest.raises(ValueError, match="128"):
            await hub.begin_binding("feishu", fields)
        gateway.message_replies = [
            httpx.Response(400, json={"code": 230027, "msg": "Lack of necessary permissions"})
        ]
        fields["receive_id"] = "ou_" + ("b" * 40)
        with pytest.raises(ValueError, match="im:message") as exc_info:
            await hub.begin_binding("feishu", fields)
        assert "发布" in str(exc_info.value)
        assert gateway.client_secret not in str(exc_info.value)
        done = await hub.begin_binding("feishu", fields)
        assert done.status == "confirmed" and done.review is False
        again = await hub.begin_binding("feishu", {**fields, "receive_id": "oc_next"})
        assert again.review is True
        assert "已绑定" in again.message
        rows = await _list_feishu()
        assert [row.account_id for row in rows] == ["cli_form"]
    finally:
        await hub.stop()


# ---------------------------------------------------------------------------
# 长推送:卡片装不下的正文按文本补发,不静默丢字(PR #1251 评审 2)
# ---------------------------------------------------------------------------


def _no_space(text: str) -> str:
    return "".join(text.split())


def _delivered(requests: list[httpx.Request]) -> tuple[str, int, list[int]]:
    """按发送顺序拼出送达的正文。返回 (正文, 卡片数, 每条纯文本长度)。"""
    parts: list[str] = []
    cards = 0
    text_lens: list[int] = []
    for item in requests:
        if "/im/v1/messages" not in str(item.url):
            continue
        payload = json.loads(item.content)
        content = json.loads(payload["content"])
        if payload["msg_type"] == "interactive":
            cards += 1
            header = content["header"]["title"]["content"]
            if header != LONG_TITLE_HEADER:
                parts.append(header)
            for element in content["elements"]:
                if element.get("tag") == "div":
                    body = element["text"]["content"]
                    assert len(body) <= _MAX_SUMMARY
                    parts.append(body)
            assert len(payload["content"].encode()) < 30 * 1024
        else:
            text_lens.append(len(content["text"]))
            parts.append(content["text"])
    return "".join(parts), cards, text_lens


def _long_text(total: int, shape: str) -> str:
    """``lines``:短标题 + 多行正文;``long_body``:短标题 + 一整行正文;``single_line``:整条一行。"""
    if shape == "single_line":
        return "字" * total
    head = "标题\n"
    room = total - len(head)
    if shape == "long_body":
        return head + ("字" * room)
    line = ("段" * 59) + "\n"
    body = (line * (room // len(line) + 1))[:room]
    return head + body


@pytest.mark.parametrize(
    ("total", "shape", "card"),
    [
        (4_000, "lines", True),
        (4_001, "lines", True),
        (4_010, "long_body", True),
        (20_000, "lines", True),
        (20_000, "long_body", True),
        (201, "single_line", True),
        (4_001, "single_line", True),
        (20_000, "single_line", True),
        (20_001, "lines", False),
        (20_001, "single_line", False),
    ],
)
async def test_long_push_delivers_every_character(
    db, monkeypatch, total: int, shape: str, card: bool
) -> None:
    gateway, _driver, hub, ready = await _scan_ready(monkeypatch)
    photo = b"\x89PNG\r\n\x1a\nposter"
    try:
        assert (await hub.binding_input(ready.binding_id, "")).status == "confirmed"
        await _wait_for(lambda: hub.is_running("feishu", "cli_app"))
        text = _long_text(total, shape)
        assert len(text) == total
        before = len(gateway.requests)
        assert await hub.push(text, photo=photo) == 1
        want = _no_space(text)
        await _wait_for(
            lambda: len(_no_space(_delivered(gateway.requests[before:])[0])) >= len(want),
            timeout=5.0,
        )
        await asyncio.sleep(0.05)
        delivered, cards, text_lens = _delivered(gateway.requests[before:])
        assert _no_space(delivered) == want
        assert all(size <= FeishuAdapter.max_text_len for size in text_lens)
        uploaded = any(
            str(item.url).endswith("/im/v1/images") for item in gateway.requests[before:]
        )
        if card:
            assert cards == 1 and uploaded
            # 卡片之后才补发文本,不重复卡片里的内容
            body_len = total if shape == "single_line" else total - len("标题\n")
            assert bool(text_lens) == (body_len > _MAX_SUMMARY)
        else:
            assert cards == 0 and not uploaded
    finally:
        await hub.stop()


async def test_card_failure_falls_back_to_chunked_text(db, monkeypatch) -> None:
    gateway, _driver, hub, ready = await _scan_ready(monkeypatch)
    try:
        assert (await hub.binding_input(ready.binding_id, "")).status == "confirmed"
        await _wait_for(lambda: hub.is_running("feishu", "cli_app"))
        text = _long_text(9_000, "lines")
        before = len(gateway.requests)
        # 第一条(卡片)被拒,之后的纯文本正常
        gateway.message_replies = [httpx.Response(400, json={"code": 230099, "msg": "bad card"})]
        assert await hub.push(text, photo=b"\x89PNG\r\n\x1a\nposter") == 1
        want = _no_space(text)

        def texts() -> str:
            return "".join(
                json.loads(json.loads(item.content)["content"])["text"]
                for item in gateway.requests[before:]
                if "/im/v1/messages" in str(item.url)
                and json.loads(item.content)["msg_type"] == "text"
            )

        await _wait_for(lambda: len(_no_space(texts())) >= len(want), timeout=5.0)
        await asyncio.sleep(0.05)
        assert _no_space(texts()) == want
    finally:
        await hub.stop()


def test_chunk_text_never_drops_characters() -> None:
    assert chunk_text("", 10) == []
    assert chunk_text("a" * 25, 10) == ["a" * 10, "a" * 10, "a" * 5]
    mixed = "第一行\n" + ("长" * 30) + "\n末行"
    chunks = chunk_text(mixed, 12)
    assert all(len(chunk) <= 12 for chunk in chunks)
    assert _no_space("".join(chunks)) == _no_space(mixed)


# ---------------------------------------------------------------------------
# 扫码会话互不影响、续传令牌一次性、Secret 不长期留在内存(PR #1251 评审 1)
# ---------------------------------------------------------------------------


def _secret_in_registry(driver, secret: str) -> bool:
    registry = driver._registry
    for held in registry._held.values():
        if held.app_secret == secret:
            return True
    for flow in registry._flows.values():
        if flow.result is not None and secret in json.dumps(flow.result.credentials):
            return True
    return False


async def test_two_scan_sessions_do_not_cancel_each_other(db, monkeypatch) -> None:
    gateway = AppGateway()
    _install_transport(monkeypatch, gateway.handler)
    driver, hub = _pinned_hub(gateway)
    try:
        first = await hub.begin_binding("feishu", {"flow": "1"})
        second = await hub.begin_binding("feishu", {"flow": "1"})
        assert first.flow_id != second.flow_id
        for binding in (first, second):
            await _wait_for(
                lambda b=binding: (
                    (found := hub.binding(b.binding_id)) is not None
                    and found.status == "need_input"
                )
            )
        a, b = hub.binding(first.binding_id), hub.binding(second.binding_id)
        assert a is not None and b is not None
        assert a.resume_token and b.resume_token and a.resume_token != b.resume_token
        done = await hub.binding_input(first.binding_id, "")
        assert done.status == "confirmed"
        # 另一个标签页的会话仍在输入步,可以继续完成
        still = hub.binding(second.binding_id)
        assert still is not None and still.status == "need_input"
        assert (await hub.binding_input(second.binding_id, "oc_group2")).status == "confirmed"
    finally:
        await hub.stop()


async def test_concurrent_double_submit_sends_one_welcome(db, monkeypatch) -> None:
    gateway, driver, hub, ready = await _scan_ready(monkeypatch)
    try:
        before = len(gateway.requests)
        results = await asyncio.gather(
            hub.binding_input(ready.binding_id, ""),
            driver.flow_input(ready.flow_id, ""),
        )
        welcomes = [
            item
            for item in gateway.requests[before:]
            if "/im/v1/messages" in str(item.url) and json.loads(item.content)["msg_type"] == "text"
        ]
        assert len(welcomes) == 1
        assert all(state.status == "confirmed" for state in results)
    finally:
        await hub.stop()


async def test_concurrent_resume_with_one_token_binds_once(db, monkeypatch) -> None:
    gateway, driver, hub, ready = await _scan_ready(monkeypatch)
    try:
        await driver.cancel_flow(ready.flow_id)
        token = ready.resume_token
        before = len(gateway.requests)
        fields = {"app_id": "cli_app", "receive_id": "oc_group9", "resume_flow": token}
        results = await asyncio.gather(
            hub.begin_binding("feishu", dict(fields)),
            hub.begin_binding("feishu", dict(fields)),
            return_exceptions=True,
        )
        ok = [item for item in results if not isinstance(item, BaseException)]
        failed = [item for item in results if isinstance(item, BaseException)]
        assert len(ok) == 1 and ok[0].status == "confirmed"
        assert len(failed) == 1 and "已失效" in str(failed[0])
        welcomes = [
            item
            for item in gateway.requests[before:]
            if "/im/v1/messages" in str(item.url) and json.loads(item.content)["msg_type"] == "text"
        ]
        assert len(welcomes) == 1
        assert not _secret_in_registry(driver, gateway.client_secret)
    finally:
        await hub.stop()


async def test_failed_resume_puts_the_token_back(db, monkeypatch) -> None:
    gateway, driver, hub, ready = await _scan_ready(monkeypatch)
    try:
        await driver.cancel_flow(ready.flow_id)
        token = ready.resume_token
        gateway.message_replies = [httpx.Response(400, json={"code": 230002, "msg": "no chat"})]
        with pytest.raises(ValueError):
            await hub.begin_binding(
                "feishu", {"app_id": "cli_app", "receive_id": "oc_missing", "resume_flow": token}
            )
        # 校验失败不算用掉:同一个令牌还能再试一次
        done = await hub.begin_binding(
            "feishu", {"app_id": "cli_app", "receive_id": "oc_group9", "resume_flow": token}
        )
        assert done.status == "confirmed"
        assert driver._registry._held == {}
    finally:
        await hub.stop()


async def test_secret_is_wiped_after_confirm(db, monkeypatch) -> None:
    import movieclaw_plugins.feishu.feishu_channel.binding as binding_mod

    monkeypatch.setattr(binding_mod, "_DONE_GRACE_S", 0.05)
    gateway, driver, hub, ready = await _scan_ready(monkeypatch)
    try:
        flow = driver._registry._flows[ready.flow_id]
        done = await hub.binding_input(ready.binding_id, "")
        assert done.status == "confirmed"
        assert driver._registry._held == {}
        await _wait_for(lambda: ready.flow_id not in driver._registry._flows)
        assert flow.result is None
        assert not _secret_in_registry(driver, gateway.client_secret)
    finally:
        await hub.stop()


async def test_held_secret_expires_without_any_access(db, monkeypatch) -> None:
    import movieclaw_plugins.feishu.feishu_channel.binding as binding_mod

    # 中枢每秒轮询一次,扫码到输入步要 1 秒左右;暂存时长取 3 秒
    monkeypatch.setattr(binding_mod, "_HOLD_TTL_S", 3.0)
    monkeypatch.setattr(binding_mod, "_DONE_GRACE_S", 0.05)
    gateway, driver, hub, ready = await _scan_ready(monkeypatch)
    try:
        await driver.cancel_flow(ready.flow_id)
        assert _secret_in_registry(driver, gateway.client_secret)
        # 不访问任何接口,定时器到点主动清
        await _wait_for(lambda: driver._registry._held == {}, timeout=6.0)
        await _wait_for(lambda: ready.flow_id not in driver._registry._flows, timeout=3.0)
        assert not _secret_in_registry(driver, gateway.client_secret)
        with pytest.raises(ValueError, match="已失效"):
            await hub.begin_binding(
                "feishu",
                {"app_id": "cli_app", "receive_id": "oc_g", "resume_flow": ready.resume_token},
            )
    finally:
        await hub.stop()


# ---------------------------------------------------------------------------
# Lark 国际版:显式请求 tenant_brand,域名按品牌切换(PR #1251 评审 3)
# ---------------------------------------------------------------------------


async def test_lark_tenant_scan_binds_on_lark_domains(db, monkeypatch) -> None:
    """契约假服务器只返回请求过的 user_info 字段;Lark 租户的凭据只在 Lark 域签发。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    gateway = AppGateway()
    gateway.brand = "lark"
    _gateway, _driver, hub, ready = await _scan_ready(monkeypatch, gateway)
    try:
        assert gateway.requested == {"open_id", "tenant_brand"}
        done = await hub.binding_input(ready.binding_id, "")
        assert done.status == "confirmed"
        async with get_database().session() as session:
            stored = await ChannelAccountRepository(session).get("feishu", "cli_app")
        assert stored is not None
        assert ChannelAccountRepository.credentials(stored)["domain"] == "lark"
        hosts = [item.url.host for item in gateway.requests]
        assert "accounts.larksuite.com" in hosts
        open_hosts = {item.url.host for item in gateway.requests if "/open-apis/" in str(item.url)}
        assert open_hosts == {"open.larksuite.com"}
    finally:
        await hub.stop()


async def test_registration_without_tenant_brand_request_would_miss_lark() -> None:
    """服务端只返回请求过的字段:不请求 tenant_brand 就拿不到品牌,也就切不到 Lark 域。"""
    gateway = AppGateway()
    gateway.brand = "lark"
    gateway.requested = {"open_id"}
    session = _session(gateway.handler)
    session.deadline = time.monotonic() + 30
    session.device_code = "device-1"
    try:
        outcome = await session.poll_once()
    finally:
        await session.aclose()
    assert outcome.status == "pending" and session.domain == "feishu"
    gateway.requested = {"open_id", "tenant_brand"}
    session = _session(gateway.handler)
    session.deadline = time.monotonic() + 30
    session.device_code = "device-1"
    try:
        outcome = await session.poll_once()
    finally:
        await session.aclose()
    assert outcome.status == "success" and outcome.domain == "lark"


async def test_registration_rejects_contradictory_tenant_brand() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "client_id": "cli_x",
                "client_secret": "s",
                "user_info": {"tenant_brand": "lark", "open_id": "ou_x"},
            },
        )

    session = _session(handler)
    session.deadline = time.monotonic() + 30
    session.device_code = "device-1"
    session.switched = True  # 已切过一次域仍报告另一个品牌
    try:
        outcome = await session.poll_once()
    finally:
        await session.aclose()
    assert outcome.status == "error"
    assert outcome.client_secret == ""


# ---------------------------------------------------------------------------
# 协议版本:新线上字段需要新宿主,旧宿主安装时直接拒绝,不在加载时崩(PR #1251 复审 2)
# ---------------------------------------------------------------------------


def _feishu_manifest():
    from movieclaw_api.plugins import bundled
    from movieclaw_api.plugins import packages as pkg

    package = bundled.bundled()["feishu-channel"]
    manifest = pkg.read_manifest(package.path)
    assert manifest is not None
    return pkg, manifest


def test_feishu_requires_the_channel_protocol_that_carries_its_fields() -> None:
    from movieclaw_kernel.contracts import Version, satisfies
    from movieclaw_plugins.feishu.feishu_channel.driver import FeishuDriver
    from movieclaw_sdk import SDK_VERSION
    from movieclaw_sdk.channels import IM_CHANNELS, driver_spec

    _pkg, manifest = _feishu_manifest()
    # 驱动确实会发出 1.4 新增的线上字段
    spec = driver_spec(FeishuDriver())
    assert "photo_caption_limit" in spec["capabilities"]
    assert spec["binding"].get("scan") is True
    assert IM_CHANNELS.version >= Version.parse("1.4")
    assert Version.parse(SDK_VERSION) >= Version.parse("1.3")
    # 清单的最低要求跟着提高:旧协议 / 旧 SDK 不满足
    assert not satisfies(manifest.requires["im-channels"], Version.parse("1.3"))
    assert not satisfies(manifest.plugin.sdk, Version.parse("1.2"))
    assert satisfies(manifest.requires["im-channels"], IM_CHANNELS.version)
    assert satisfies(manifest.plugin.sdk, Version.parse(SDK_VERSION))


def test_old_host_refuses_new_feishu_package_at_install(monkeypatch) -> None:
    import movieclaw_sdk
    from movieclaw_kernel.contracts import CATALOG, Version

    pkg, manifest = _feishu_manifest()
    pkg.check_compat(manifest, reserved=set(), operations=set())

    # 旧宿主之一:SDK 还是 1.2
    with monkeypatch.context() as patch:
        patch.setattr(movieclaw_sdk, "SDK_VERSION", "1.2")
        with pytest.raises(pkg.PackageError):
            pkg.check_compat(manifest, reserved=set(), operations=set())
    # 旧宿主之二:im-channels 还是 1.3(不认识 photo_caption_limit 等字段)
    with monkeypatch.context() as patch:
        patch.setattr(CATALOG["im-channels"], "version", Version.parse("1.3"))
        with pytest.raises(pkg.PackageError):
            pkg.check_compat(manifest, reserved=set(), operations=set())
