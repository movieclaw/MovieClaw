"""回调式通道（docs/design/plugin-callbacks.md §4.5）：示例插件「企业微信自建应用」端到端。

真实应用 + 示例插件 ``wecom-channel``（进程内 / 进程外各一遍），对着一个本地起的假企业微信接口：

- 表单绑定：插件用企业 ID + Secret 换 access_token 校验；中枢给这个账号发回调地址、生成配对码；
- 模拟企业微信保存回调 URL 时的验证（GET，echostr 加密），插件解密原样回去；
- 模拟用户在企业微信里发配对码（加密 XML 回调）→ 绑定确认，发码人成为绑定用户；
- 发消息 → 插件验签解密 → 中枢交给 AI 助手（替身）→ 回复经「发送应用消息」接口发出；
- 签名不对 403；解绑后回调地址失效。
"""

from __future__ import annotations

import asyncio
import hashlib
import importlib.util
import os
import shutil
import socket
import sys
import textwrap
import threading
import time
from pathlib import Path

import pytest
import uvicorn
from fastapi.testclient import TestClient
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE

EXAMPLE = (
    Path(__file__).resolve().parents[2]
    / "src"
    / "movieclaw_agent"
    / "builtin-skills"
    / "movieclaw-plugin-dev"
    / "references"
    / "examples"
    / "wecom-channel"
)
CORP = "ww0123456789abcdef"
AGENT = "1000002"
TOKEN = "QDG6eK"
AES_KEY = "jWmYm7qr5nMoAUwZRjGtBxmz3KA1tkAj3ykkR6q2B2C"


def _crypto():
    spec = importlib.util.spec_from_file_location("wecom_example", EXAMPLE / "wecom_channel.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeWecom:
    """最小企业微信接口：换 access_token、发送应用消息。"""

    def __init__(self) -> None:
        self.sent: list[dict] = []
        self.lock = threading.Lock()

    def texts_to(self, user: str) -> list[str]:
        with self.lock:
            return [m["text"]["content"] for m in self.sent if m["touser"] == user]

    def app(self) -> Starlette:
        async def gettoken(request: Request):
            if request.query_params.get("corpsecret") != "s3cret":
                return JSONResponse({"errcode": 40001, "errmsg": "invalid credential"})
            return JSONResponse({"errcode": 0, "access_token": "T1", "expires_in": 7200})

        async def send(request: Request):
            assert request.query_params.get("access_token") == "T1"
            with self.lock:
                self.sent.append(await request.json())
            return JSONResponse({"errcode": 0, "errmsg": "ok"})

        return Starlette(
            routes=[
                Route("/cgi-bin/gettoken", gettoken, methods=["GET"]),
                Route("/cgi-bin/message/send", send, methods=["POST"]),
            ]
        )


@pytest.fixture
def wecom():
    fake = FakeWecom()
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    server = uvicorn.Server(
        uvicorn.Config(fake.app(), host="127.0.0.1", port=port, log_level="warning")
    )
    thread = threading.Thread(target=lambda: asyncio.run(server.serve()), daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        assert time.monotonic() < deadline, "假企业微信接口没起来"
        time.sleep(0.05)
    yield fake, f"http://127.0.0.1:{port}"
    server.should_exit = True
    thread.join(5)


@pytest.fixture(params=["inline", "process"])
def world(request, tmp_path, monkeypatch):
    from movieclaw_api.services import channel_agent
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box
    from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository

    # 配置存储是进程级的：同一进程里先跑的测试若设过对外地址，回调地址会带上它
    reset_setting_store()
    reset_secret_box()
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'wecom.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    (tmp_path / "plugins").mkdir()
    shutil.copy(EXAMPLE / "wecom_channel.py", tmp_path / "plugins" / "wecom_channel.py")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: wecom-channel
              local: true
              module: wecom_channel
              runtime: {request.param}
            """
        ),
        encoding="utf-8",
    )

    async def has_any(self) -> bool:
        return True

    monkeypatch.setattr(LlmProviderRepository, "has_any", has_any)

    async def echo_agent(driver, account, msg, emit) -> None:
        await emit(f"收到：{msg.text}")

    monkeypatch.setattr(channel_agent, "run_agent", echo_agent)
    yield request.param
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    reset_secret_box()
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


def wait(predicate, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("等待条件超时")


def signed(crypto, encrypted: str) -> dict[str, str]:
    timestamp, nonce = str(int(time.time())), "n0nce"
    sig = hashlib.sha1("".join(sorted([TOKEN, timestamp, nonce, encrypted])).encode()).hexdigest()
    return {"msg_signature": sig, "timestamp": timestamp, "nonce": nonce}


def message_xml(crypto, user: str, text: str, msg_id: str) -> tuple[bytes, dict[str, str]]:
    inner = (
        f"<xml><ToUserName><![CDATA[{CORP}]]></ToUserName>"
        f"<FromUserName><![CDATA[{user}]]></FromUserName><CreateTime>1700000000</CreateTime>"
        f"<MsgType><![CDATA[text]]></MsgType><Content><![CDATA[{text}]]></Content>"
        f"<MsgId>{msg_id}</MsgId><AgentID>{AGENT}</AgentID></xml>"
    ).encode()
    encrypted = crypto.encrypt(inner, AES_KEY, CORP, os.urandom(16))
    body = (
        f"<xml><ToUserName><![CDATA[{CORP}]]></ToUserName>"
        f"<Encrypt><![CDATA[{encrypted}]]></Encrypt><AgentID>{AGENT}</AgentID></xml>"
    ).encode()
    return body, signed(crypto, encrypted)


def test_callback_channel_verifies_pairs_and_chats(world, wecom) -> None:
    fake, api = wecom
    crypto = _crypto()
    with make_client() as client:
        assert client.app.state.kernel.fiber("wecom-channel").state.value == "active"
        channels = client.get("/api/v1/channels").json()["data"]["channels"]
        [channel] = [c for c in channels if c["title"] == "企业微信"]
        cid = channel["id"]
        assert channel["webhook"] is True

        fields = {
            "corp_id": CORP,
            "agent_id": AGENT,
            "secret": "wrong",
            "token": TOKEN,
            "aes_key": AES_KEY,
            "api_base": api,
        }
        bad = client.post("/api/v1/channels/bindings", json={"channel_id": cid, "fields": fields})
        assert bad.status_code == 400 and "Secret 不对" in bad.json()["message"]

        fields["secret"] = "s3cret"
        started = client.post(
            "/api/v1/channels/bindings", json={"channel_id": cid, "fields": fields}
        )
        assert started.status_code == 201, started.text
        binding = started.json()["data"]
        assert binding["kind"] == "pairing" and binding["pair_code"]
        url = binding["callback_url"]
        assert url.startswith("/api/v1/hooks/wecom-channel/webhook/")
        assert "回调地址" in binding["message"]

        # 企业微信保存回调 URL：GET 验证，解密 echostr 原样回去；签名不对 403
        echostr = crypto.encrypt(b"echo-1234", AES_KEY, CORP, os.urandom(16))
        verified = client.get(url, params={**signed(crypto, echostr), "echostr": echostr})
        assert (verified.status_code, verified.text) == (200, "echo-1234")
        forged = {**signed(crypto, echostr), "msg_signature": "0" * 40, "echostr": echostr}
        assert client.get(url, params=forged).status_code == 403

        # 用户在企业微信里给应用发配对码 → 绑定确认
        body, params = message_xml(crypto, "zhangsan", binding["pair_code"], "1")
        answer = client.post(url, params=params, content=body)
        assert (answer.status_code, answer.text) == (200, "success")
        wait(
            lambda: (
                client.get(f"/api/v1/channels/bindings/{binding['binding_id']}").json()["data"][
                    "status"
                ]
                == "confirmed"
            )
        )

        # 确认后转正在后台做：等正式账号起来
        def accounts() -> list[dict]:
            return client.get("/api/v1/channels").json()["data"]["accounts"]

        wait(lambda: len(accounts()) == 1 and accounts()[0]["running"])
        [account] = accounts()
        assert account["bound_user_id"] == "zhangsan"
        assert any("绑定成功" in t for t in fake.texts_to("zhangsan"))

        # 聊天：回调进来 → AI 助手 → 应用消息接口发回
        body, params = message_xml(crypto, "zhangsan", "找沙丘", "2")
        assert client.post(url, params=params, content=body).text == "success"
        wait(lambda: "收到：找沙丘" in fake.texts_to("zhangsan"))

        # 企业微信超时会重发同一条：按 MsgId 去重，不重复回复
        assert client.post(url, params=params, content=body).text == "success"
        time.sleep(0.5)
        assert fake.texts_to("zhangsan").count("收到：找沙丘") == 1

        # 解绑：回调地址一起作废
        removed = client.delete(f"/api/v1/channels/{cid}/accounts/{account['account_id']}")
        assert removed.status_code == 200
        body, params = message_xml(crypto, "zhangsan", "还在吗", "3")
        assert client.post(url, params=params, content=body).status_code == 404
