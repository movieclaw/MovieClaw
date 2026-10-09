"""随应用携带的插件包（docs/design/plugin-channels.md §7、§10）。

- 随带插件包只 import SDK 与 SDK 承诺提供的库（不碰主程序内部），清单能通过插件包校验；
- 随带时作为内置插件运行；把它原样打成 .mcplugin 动态安装（独立进程、低权限）即替换随带版本，
  已绑定的账号沿用、照常收发；卸载后随带版本回来。微信对着一个本地起的假 iLink 网关验证。
"""

from __future__ import annotations

import ast
import asyncio
import io
import socket
import sys
import threading
import time
import zipfile
from pathlib import Path

import pytest
import uvicorn
from fastapi.testclient import TestClient
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins import bundled

#: 随带插件包能 import 的第三方库（SDK 承诺提供的运行环境）
ALLOWED = {"movieclaw_sdk", "movieclaw_kernel", "httpx", "cryptography", "pydantic", "websockets"}


def pack(path: Path) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for file in sorted(path.rglob("*")):
            if file.is_file() and "__pycache__" not in file.parts:
                archive.write(file, file.relative_to(path).as_posix())
    return buffer.getvalue()


@pytest.mark.parametrize("package", list(bundled.bundled().values()), ids=lambda p: p.id)
def test_bundled_packages_only_depend_on_the_sdk(package) -> None:
    offenders = []
    for file in package.path.rglob("*.py"):
        tree = ast.parse(file.read_text("utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                names = [node.module]
            elif isinstance(node, ast.Import):
                names = [alias.name for alias in node.names]
            else:
                continue
            for name in names:
                top = name.split(".")[0]
                if top in sys.stdlib_module_names or top in ALLOWED or top == "__future__":
                    continue
                offenders.append(f"{file.relative_to(package.path)}: {name}")
    assert offenders == [], "随带插件包只能依赖 SDK 与它承诺提供的库"


@pytest.mark.parametrize("package", list(bundled.bundled().values()), ids=lambda p: p.id)
def test_bundled_packages_pass_package_validation(package) -> None:
    from movieclaw_api.plugins import packages as pkg

    manifest, _archive = pkg.read_archive(pack(package.path))
    assert manifest.plugin.id == package.id
    # 内置条目与本地插件以外的 id 都可以被插件包占用：随带插件包的 id 本来就要能被替换
    pkg.check_compat(manifest, reserved=set(), operations=set())


# ---------------------------------------------------------------------- 微信：替换与恢复


class FakeILink:
    """最小 iLink：长轮询收消息、发消息、正在输入、启停通知。"""

    def __init__(self) -> None:
        self.sent: list[tuple[str, str, str | None]] = []
        self.polls: list[str] = []
        self.inbox: list[dict] = []
        self.lock = threading.Lock()

    def app(self) -> Starlette:
        async def updates(request: Request):
            self.polls.append(request.headers.get("authorization", ""))
            for _ in range(20):
                if await request.is_disconnected():
                    # 已经走掉的轮询（被卸下的插件进程）不能再把消息领走
                    return JSONResponse({"ret": 0, "msgs": []})
                with self.lock:
                    msgs, self.inbox = self.inbox, []
                if msgs:
                    return JSONResponse({"ret": 0, "msgs": msgs, "get_updates_buf": "buf"})
                await asyncio.sleep(0.05)
            return JSONResponse({"ret": 0, "msgs": [], "get_updates_buf": ""})

        async def send(request: Request):
            msg = (await request.json())["msg"]
            text = msg["item_list"][0]["text_item"]["text"]
            self.sent.append((msg["to_user_id"], text, msg.get("context_token")))
            return JSONResponse({"ret": 0})

        async def ok(_request: Request):
            return JSONResponse({"ret": 0, "typing_ticket": "ticket"})

        return Starlette(
            routes=[
                Route("/ilink/bot/getupdates", updates, methods=["POST"]),
                Route("/ilink/bot/sendmessage", send, methods=["POST"]),
                Route("/ilink/bot/{rest:path}", ok, methods=["POST"]),
            ]
        )


@pytest.fixture
def ilink():
    fake = FakeILink()
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    config = uvicorn.Config(fake.app(), host="127.0.0.1", port=port, log_level="warning")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=lambda: asyncio.run(server.serve()), daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        assert time.monotonic() < deadline, "假 iLink 网关没起来"
        time.sleep(0.05)
    yield fake, f"http://127.0.0.1:{port}"
    server.should_exit = True
    thread.join(5)


@pytest.fixture
def env(tmp_path, monkeypatch):
    from movieclaw_api.services import channel_agent

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'b.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()

    async def echo_agent(driver, account, msg, emit) -> None:
        await emit(f"收到：{msg.text}")

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


def wait(predicate, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("等待条件超时")


def inbound(fake: FakeILink, text: str, seq: int) -> None:
    with fake.lock:
        fake.inbox.append(
            {
                "from_user_id": "me@im.wechat",
                "message_id": f"m{seq}",
                "context_token": f"ctx-{seq}",
                "item_list": [{"type": 1, "text_item": {"text": text}}],
            }
        )


def test_weixin_package_replaces_the_bundled_one_and_uninstall_restores_it(env, ilink) -> None:
    from movieclaw_api.services.channel_hub import get_hub
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository

    fake, gateway = ilink
    with make_client() as client:
        kernel = client.app.state.kernel
        fiber = kernel.fiber("channel.weixin")
        assert (fiber.entry.source, fiber.state.value) == ("builtin", "active")

        async def seed() -> None:
            async with get_database().session() as session:
                await ChannelAccountRepository(session).upsert(
                    channel_id="weixin",
                    account_id="bot-1",
                    credentials={"token": "tok", "base_url": gateway},
                    display_name="微信",
                    bound_user_id="me@im.wechat",
                )

        client.portal.call(seed)
        hub = get_hub()
        assert hub is not None
        client.portal.call(hub.sync)
        wait(lambda: len(fake.polls) > 0)
        inbound(fake, "随带版本", 1)
        wait(lambda: ("me@im.wechat", "收到：随带版本", "ctx-1") in fake.sent)

        # 把随带的插件包原样打包，作为插件包安装：替换随带版本，在独立进程里运行
        package = bundled.bundled()["channel.weixin"]
        uploaded = client.post(
            "/api/v1/app/plugins/packages",
            files={"file": ("weixin.mcplugin", pack(package.path), "application/zip")},
        )
        assert uploaded.status_code == 200, uploaded.text
        approved = client.post(
            "/api/v1/app/plugins/packages/channel.weixin/approve",
            json={"version": package.manifest.plugin.version, "operations": []},
        )
        assert approved.status_code == 200, approved.text
        assert approved.json()["data"]["status"] == "active"
        fiber = kernel.fiber("channel.weixin")
        assert fiber.entry.source == "package"
        plugins = {p["id"]: p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}
        assert plugins["channel.weixin"]["runtime"] == "process"

        # 通道 id 沿用 weixin，已绑定账号由插件包接着跑
        channels = client.get("/api/v1/channels").json()["data"]
        assert [c["id"] for c in channels["channels"] if c["title"] == "微信"] == ["weixin"]
        assert [(a["account_id"], a["channel_available"]) for a in channels["accounts"]] == [
            ("bot-1", True)
        ]
        wait(lambda: client.get("/api/v1/channels").json()["data"]["accounts"][0]["running"])
        inbound(fake, "插件包版本", 2)
        wait(lambda: ("me@im.wechat", "收到：插件包版本", "ctx-2") in fake.sent)
        pushed = client.post("/api/v1/channels/im/push-test", json={"text": "新片入库"})
        assert pushed.status_code == 200
        wait(lambda: ("me@im.wechat", "新片入库", "ctx-2") in fake.sent)

        # 卸载：随带版本回来，账号照常
        removed = client.delete(
            "/api/v1/app/plugins/packages/channel.weixin", params={"purge_data": "true"}
        )
        assert removed.status_code == 200, removed.text
        fiber = kernel.fiber("channel.weixin")
        assert (fiber.entry.source, fiber.state.value) == ("builtin", "active")
        plugins = {p["id"]: p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}
        assert plugins["channel.weixin"]["runtime"] == "inline"
        wait(lambda: client.get("/api/v1/channels").json()["data"]["accounts"][0]["running"])
        inbound(fake, "又回到随带版本", 3)
        wait(lambda: ("me@im.wechat", "收到：又回到随带版本", "ctx-3") in fake.sent)


@pytest.mark.parametrize("entry_id", sorted(bundled.bundled()), ids=str)
def test_every_bundled_package_installs_out_of_process_and_restores(env, entry_id) -> None:
    """每个随带插件包都能原样打包、作为插件包在独立进程里跑起来（替换随带版本），卸载即恢复。"""
    package = bundled.bundled()[entry_id]
    channel = package.path.name
    with make_client() as client:
        kernel = client.app.state.kernel
        assert kernel.fiber(entry_id).entry.source == "builtin"
        uploaded = client.post(
            "/api/v1/app/plugins/packages",
            files={"file": (f"{entry_id}.mcplugin", pack(package.path), "application/zip")},
        )
        assert uploaded.status_code == 200, uploaded.text
        assert uploaded.json()["data"]["replaces_builtin"] is True
        approved = client.post(
            f"/api/v1/app/plugins/packages/{entry_id}/approve",
            json={"version": package.manifest.plugin.version, "operations": []},
        )
        assert approved.json()["data"]["status"] == "active", approved.text
        fiber = kernel.fiber(entry_id)
        assert fiber.entry.source == "package"
        listed = client.get("/api/v1/channels").json()["data"]["channels"]
        assert channel in {c["id"] for c in listed}, "替换后沿用随带版本的通道 id"
        removed = client.delete(f"/api/v1/app/plugins/packages/{entry_id}")
        assert removed.status_code == 200
        assert kernel.fiber(entry_id).entry.source == "builtin"
        listed = client.get("/api/v1/channels").json()["data"]["channels"]
        assert channel in {c["id"] for c in listed}
