"""IM 通道接口端到端（docs/design/plugin-channels.md §6）。

真实应用 + 真实通道插件（微信驱动、中枢、dispatcher），只把 iLink 网关换成脚本化的假网关：
- 通道列表来自注册表，每个通道带它的绑定方式；
- 微信扫码全流程：发起 → 二维码 → 需要配对数字 → 提交 → 确认落库 → 收发循环启动；
- 收到消息驱动 AI 助手（替身）并回复，「正在输入」开了又关；测试推送带上记住的会话令牌；
- 关掉微信插件：账号照常列出（通道不可用），发起绑定给明确的 409，不再 500。
"""

from __future__ import annotations

import asyncio
import textwrap
import time
from typing import Any

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings


class FakeGateway:
    """脚本化的 iLink：扫码状态按队列吐出；收消息队列由测试塞入。"""

    def __init__(self) -> None:
        self.qr_statuses: list[dict[str, Any]] = []
        self.inbox: asyncio.Queue[dict[str, Any]] | None = None
        self.sent: list[tuple[str, str, str | None]] = []
        self.typing: list[bool] = []
        self.tokens: list[str] = []


GATEWAY = FakeGateway()


class FakeWeixinClient:
    def __init__(self, base_url: str, token: str) -> None:
        GATEWAY.tokens.append(f"{base_url}|{token}")

    async def notify_start(self) -> None: ...

    async def notify_stop(self) -> None: ...

    async def aclose(self) -> None: ...

    async def get_updates(self, cursor: str, *, stop=None, timeout_s: float = 35.0):
        if GATEWAY.inbox is None:
            GATEWAY.inbox = asyncio.Queue()
        getter = asyncio.ensure_future(GATEWAY.inbox.get())
        stopper = asyncio.ensure_future(stop.wait())
        done, _ = await asyncio.wait({getter, stopper}, return_when=asyncio.FIRST_COMPLETED)
        for task in (getter, stopper):
            if task not in done:
                task.cancel()
        if getter not in done:
            return {"ret": 0, "msgs": [], "get_updates_buf": ""}
        return {"ret": 0, "msgs": [getter.result()], "get_updates_buf": f"buf-{time.time()}"}

    async def send_text(self, to_user_id: str, text: str, context_token: str | None) -> None:
        GATEWAY.sent.append((to_user_id, text, context_token))

    async def get_config(self, user_id: str, context_token: str | None) -> str:
        return "ticket-1"

    async def send_typing(self, user_id: str, ticket: str, *, typing: bool) -> None:
        GATEWAY.typing.append(typing)


async def fake_fetch_qrcode(base_url: str, tokens: list[str]) -> dict[str, Any]:
    return {"qrcode": "qr-1", "qrcode_img_content": "https://weixin.example/qr-1"}


async def fake_poll(base_url: str, qrcode: str, verify_code: str | None = None) -> dict[str, Any]:
    await asyncio.sleep(0.02)
    if verify_code == "73":
        return {
            "status": "confirmed",
            "ilink_bot_id": "bot-1",
            "bot_token": "secret-token",
            "ilink_user_id": "me@im.wechat",
            "baseurl": "https://gw.example",
        }
    if GATEWAY.qr_statuses:
        return GATEWAY.qr_statuses.pop(0)
    return {"status": "wait"}


@pytest.fixture
def app_env(tmp_path, monkeypatch):
    from movieclaw_api.services import channel_agent
    from movieclaw_channel.weixin import binding, driver
    from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'ch.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    global GATEWAY
    GATEWAY = FakeGateway()
    monkeypatch.setattr(driver, "WeixinClient", FakeWeixinClient)
    monkeypatch.setattr(binding, "fetch_qrcode", fake_fetch_qrcode)
    monkeypatch.setattr(binding, "poll_qr_status", fake_poll)

    async def has_any(self) -> bool:
        return True

    monkeypatch.setattr(LlmProviderRepository, "has_any", has_any)

    async def echo_agent(drv, account, msg, emit) -> None:
        await drv.typing(account, msg.reply, True)
        await emit(f"收到：{msg.text}")
        await drv.typing(account, msg.reply, False)

    monkeypatch.setattr(channel_agent, "run_agent", echo_agent)
    yield tmp_path
    get_settings.cache_clear()


def make_client() -> TestClient:
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    get_settings.cache_clear()
    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    return TestClient(app)


def wait(predicate, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("等待条件超时")


def test_weixin_scan_binding_chat_and_push(app_env) -> None:
    with make_client() as client:
        listed = client.get("/api/v1/channels").json()["data"]
        kinds = {
            c["id"]: (c["binding"]["kind"], c["binding"]["pairing"]) for c in listed["channels"]
        }
        assert kinds == {
            "weixin": ("flow", "none"),
            "telegram": ("form", "code"),
            "discord": ("form", "code"),
            "feishu": ("form", "none"),
        }
        entries = {c["id"]: c["entry_id"] for c in listed["channels"]}
        assert entries["weixin"] == "channel.weixin"
        assert listed["accounts"] == []

        GATEWAY.qr_statuses = [{"status": "scaned"}, {"status": "need_verifycode"}]
        started = client.post("/api/v1/channels/bindings", json={"channel_id": "weixin"})
        assert started.status_code == 201, started.text
        binding = started.json()["data"]
        assert binding["kind"] == "flow"
        assert binding["qr_image"].startswith("data:image/svg+xml;base64,")
        binding_id = binding["binding_id"]

        def status() -> dict:
            return client.get(f"/api/v1/channels/bindings/{binding_id}").json()["data"]

        wait(lambda: status()["status"] == "need_input")
        assert status()["input_label"]
        submitted = client.post(
            f"/api/v1/channels/bindings/{binding_id}/input", json={"value": "73"}
        )
        assert submitted.status_code == 200
        wait(lambda: status()["status"] == "confirmed")
        account = status()["account"]
        assert account["channel_id"] == "weixin" and account["account_id"] == "bot-1"
        assert account["bound_user_id"] == "me@im.wechat" and account["channel_available"]
        wait(lambda: "https://gw.example|secret-token" in GATEWAY.tokens)

        # 绑定人发来消息：AI 助手（替身）回复，回复带上入站的会话令牌，正在输入开了又关
        wait(lambda: GATEWAY.inbox is not None)
        message = {
            "from_user_id": "me@im.wechat",
            "message_id": "m1",
            "context_token": "ctx-1",
            "item_list": [{"type": 1, "text_item": {"text": "找沙丘"}}],
        }
        client.portal.call(GATEWAY.inbox.put, message)  # type: ignore[union-attr]
        wait(lambda: ("me@im.wechat", "收到：找沙丘", "ctx-1") in GATEWAY.sent)
        assert GATEWAY.typing == [True, False]

        # 主动推送：没有入站消息，复用记住的会话令牌
        pushed = client.post("/api/v1/channels/im/push-test", json={"text": "新片入库"})
        assert pushed.status_code == 200 and pushed.json()["data"]["sent"] == 1
        wait(lambda: ("me@im.wechat", "新片入库", "ctx-1") in GATEWAY.sent)
        assert client.get("/api/v1/channels/im/push-config").status_code == 200

    # 重启后照常：凭据、会话令牌从库里读回，账号自动拉起
    GATEWAY.sent.clear()
    GATEWAY.inbox = None  # 队列绑在上一个应用的事件循环上
    with make_client() as client:
        accounts = client.get("/api/v1/channels").json()["data"]["accounts"]
        assert [(a["account_id"], a["running"]) for a in accounts] == [("bot-1", True)]
        assert client.post("/api/v1/channels/im/push-test", json={}).status_code == 200
        wait(lambda: any(token == "ctx-1" for _u, _t, token in GATEWAY.sent))

        removed = client.delete("/api/v1/channels/weixin/accounts/bot-1")
        assert removed.status_code == 200
        assert client.get("/api/v1/channels").json()["data"]["accounts"] == []
        assert client.post("/api/v1/channels/im/push-test", json={}).status_code == 400


def test_disabled_channel_plugin_is_reported_not_500(app_env) -> None:
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    (app_env / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: channel.weixin
              disabled: true
            """
        ),
        encoding="utf-8",
    )
    with make_client() as client:

        async def seed() -> None:
            async with get_database().session() as session:
                await ChannelAccountRepository(session).upsert(
                    channel_id="weixin",
                    account_id="bot-1",
                    credentials={"token": "t"},
                    display_name="微信",
                    bound_user_id="me",
                )

        client.portal.call(seed)
        listed = client.get("/api/v1/channels")
        assert listed.status_code == 200
        data = listed.json()["data"]
        assert "weixin" not in {c["id"] for c in data["channels"]}
        [account] = data["accounts"]
        assert account["channel_available"] is False and account["running"] is False
        refused = client.post("/api/v1/channels/bindings", json={"channel_id": "weixin"})
        assert refused.status_code == 409
        assert "未启用" in refused.json()["message"]
        assert client.get("/api/v1/channels/bindings/nope").status_code == 404


def test_endpoints_of_released_apps_still_work(app_env) -> None:
    """已发布的 iPhone / Mac App 还在调旧路径：形状不变，内部走通道中枢。"""
    with make_client() as client:
        GATEWAY.qr_statuses = [{"status": "need_verifycode"}]
        started = client.post("/api/v1/channels/weixin/bindings")
        assert started.status_code == 201, started.text
        start = started.json()["data"]
        assert set(start) == {"challenge_id", "qrcode_url", "qrcode_image", "message"}
        assert start["qrcode_url"] == "https://weixin.example/qr-1"
        challenge = start["challenge_id"]

        def status() -> dict:
            return client.get(f"/api/v1/channels/weixin/bindings/{challenge}").json()["data"]

        wait(lambda: status()["status"] == "need_verify_code")
        verified = client.post(
            f"/api/v1/channels/weixin/bindings/{challenge}/verify-code", json={"code": "73"}
        )
        assert verified.status_code == 200
        wait(lambda: status()["status"] == "confirmed")
        assert status()["account"]["account_id"] == "bot-1"
        accounts = client.get("/api/v1/channels/weixin/accounts").json()["data"]
        assert [(a["account_id"], a["running"]) for a in accounts] == [("bot-1", True)]
        assert client.get("/api/v1/channels/im/telegram/accounts").json()["data"] == []
        assert client.get("/api/v1/channels/im/wechat/accounts").status_code == 404
        refused = client.post("/api/v1/channels/im/feishu/bindings-x", json={})
        assert refused.status_code in (404, 405)
        assert client.delete("/api/v1/channels/weixin/accounts/bot-1").status_code == 200
        assert client.get("/api/v1/channels/weixin/accounts").json()["data"] == []
