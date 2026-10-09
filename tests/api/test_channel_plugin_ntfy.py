"""第三方通道插件（docs/design/plugin-channels.md §8、§10）。

真实应用 + 示例插件 ``ntfy-channel``（只依赖 SDK 与开放契约），
进程内 / 进程外各跑一遍，对着一个本地起的假 ntfy 服务器：
- 通道出现在通道列表里（带插件前缀的通道 id），表单绑定时往「发消息的主题」发欢迎消息；
- 往「收消息的主题」发消息 → 插件收到 → 中枢交给 AI 助手（替身）→ 回复发回「发消息的主题」；
- 测试推送走插件；重启后从游标续读，不重放旧消息；
- 解绑停掉收消息循环（进程外经「取消调用」让插件退出订阅）。
"""

from __future__ import annotations

import asyncio
import json
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
from starlette.responses import JSONResponse, StreamingResponse
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
    / "ntfy-channel"
)


class FakeNtfy:
    """最小 ntfy：GET /{topic}/json 流式订阅（支持 since），POST /{topic} 发布。"""

    def __init__(self) -> None:
        self.messages: list[dict] = []
        self.subscribers: dict[str, list[asyncio.Queue]] = {}
        self.loop: asyncio.AbstractEventLoop | None = None
        self.lock = threading.Lock()
        self.ids = 0

    def published(self, topic: str) -> list[str]:
        with self.lock:
            return [m["message"] for m in self.messages if m["topic"] == topic]

    def live(self, topic: str) -> int:
        return len(self.subscribers.get(topic, []))

    def post(self, topic: str, text: str) -> None:
        assert self.loop is not None
        asyncio.run_coroutine_threadsafe(self._store(topic, text), self.loop).result(5)

    async def _store(self, topic: str, text: str) -> dict:
        with self.lock:
            self.ids += 1
            event = {
                "id": f"m{self.ids}",
                "time": int(time.time()),
                "event": "message",
                "topic": topic,
                "message": text,
            }
            self.messages.append(event)
        for queue in self.subscribers.get(topic, []):
            queue.put_nowait(event)
        return event

    def app(self) -> Starlette:
        async def subscribe(request: Request):
            topic = request.path_params["topic"]
            since = request.query_params.get("since")
            queue: asyncio.Queue = asyncio.Queue()
            if since:
                with self.lock:
                    backlog = [m for m in self.messages if m["topic"] == topic]
                ids = [m["id"] for m in backlog]
                for m in backlog[ids.index(since) + 1 :] if since in ids else []:
                    queue.put_nowait(m)
            self.subscribers.setdefault(topic, []).append(queue)

            async def stream():
                try:
                    yield json.dumps({"event": "open", "topic": topic}) + "\n"
                    while True:
                        try:
                            event = await asyncio.wait_for(queue.get(), 1.0)
                        except TimeoutError:
                            yield json.dumps({"event": "keepalive"}) + "\n"
                            continue
                        yield json.dumps(event) + "\n"
                finally:
                    self.subscribers[topic].remove(queue)

            return StreamingResponse(stream(), media_type="application/x-ndjson")

        async def publish(request: Request):
            event = await self._store(request.path_params["topic"], (await request.body()).decode())
            return JSONResponse(event)

        return Starlette(
            routes=[
                Route("/{topic}/json", subscribe, methods=["GET"]),
                Route("/{topic}", publish, methods=["POST"]),
            ]
        )


@pytest.fixture
def ntfy():
    fake = FakeNtfy()
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    server = uvicorn.Server(
        uvicorn.Config(fake.app(), host="127.0.0.1", port=port, log_level="warning")
    )

    def run() -> None:
        loop = asyncio.new_event_loop()
        fake.loop = loop
        loop.run_until_complete(server.serve())

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        assert time.monotonic() < deadline, "假 ntfy 服务器没起来"
        time.sleep(0.05)
    yield fake, f"http://127.0.0.1:{port}"
    server.should_exit = True
    thread.join(5)


@pytest.fixture(params=["inline", "process"])
def world(request, tmp_path, monkeypatch):
    from movieclaw_api.services import channel_agent
    from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'ntfy.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    (tmp_path / "plugins").mkdir()
    shutil.copy(EXAMPLE / "ntfy_channel.py", tmp_path / "plugins" / "ntfy_channel.py")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: examples.ntfy
              local: true
              module: ntfy_channel
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


def test_third_party_channel_binds_chats_and_pushes(world, ntfy) -> None:
    fake, server = ntfy
    with make_client() as client:
        assert client.app.state.kernel.fiber("examples.ntfy").state.value == "active"
        channels = client.get("/api/v1/channels").json()["data"]["channels"]
        [channel] = [c for c in channels if c["title"] == "ntfy"]
        cid = channel["id"]
        assert cid.endswith("ntfy") and cid != "ntfy", "第三方通道 id 带插件前缀"
        assert channel["entry_id"] == "examples.ntfy"
        assert [f["key"] for f in channel["binding"]["fields"]] == [
            "server",
            "inbox",
            "outbox",
            "token",
        ]

        # 表单校验在插件里做，错误原样给用户看
        bad = client.post(
            "/api/v1/channels/bindings",
            json={"channel_id": cid, "fields": {"server": server, "inbox": "a", "outbox": "a"}},
        )
        assert bad.status_code == 400 and "不能相同" in bad.json()["message"]

        fields = {"server": server, "inbox": "mc-in-7f3a", "outbox": "mc-out-7f3a"}
        bound = client.post("/api/v1/channels/bindings", json={"channel_id": cid, "fields": fields})
        assert bound.status_code == 201, bound.text
        assert bound.json()["data"]["status"] == "confirmed"
        assert any("已接入" in m for m in fake.published("mc-out-7f3a"))
        wait(lambda: fake.live("mc-in-7f3a") == 1)

        fake.post("mc-in-7f3a", "找沙丘")
        wait(lambda: "收到：找沙丘" in fake.published("mc-out-7f3a"))

        pushed = client.post("/api/v1/channels/im/push-test", json={"text": "新片入库"})
        assert pushed.status_code == 200 and pushed.json()["data"]["sent"] == 1
        wait(lambda: "新片入库" in fake.published("mc-out-7f3a"))

    # 重启：游标存在插件私有状态里，续读不重放
    wait(lambda: fake.live("mc-in-7f3a") == 0)
    fake.post("mc-in-7f3a", "离线时发的")
    with make_client() as client:
        wait(lambda: "收到：离线时发的" in fake.published("mc-out-7f3a"))
        time.sleep(0.5)
        assert fake.published("mc-out-7f3a").count("收到：找沙丘") == 1

        [account] = client.get("/api/v1/channels").json()["data"]["accounts"]
        assert account["running"] and account["display_name"] == "ntfy · mc-out-7f3a"
        removed = client.delete(f"/api/v1/channels/{cid}/accounts/{account['account_id']}")
        assert removed.status_code == 200
        wait(lambda: fake.live("mc-in-7f3a") == 0)
        assert client.get("/api/v1/channels").json()["data"]["accounts"] == []
