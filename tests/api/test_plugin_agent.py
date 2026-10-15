"""插件驱动 AI 助手（docs/design/plugin-agent.md），进程内 / 进程外各跑一遍。

真实应用生命周期 + 确定性的假大模型（tests/api/test_agent.py 的流式协议）。
插件是一个最小的「A2A 桥」：管理员区挂同步问答、SSE 流式、发起 / 取消、会话列表；
成员区挂一个问答（应被封顶为不带工具）。
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading
import time

import pytest
from fastapi.testclient import TestClient
from tests.api.test_agent import _StreamProtocol, configure_provider

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events, plugin_runtime
from movieclaw_llm import ChatResponse, ChatStreamEvent
from movieclaw_llm.protocols import PROTOCOLS

BRIDGE = """
import asyncio

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from movieclaw_api.plugins.keys import AGENT, PLUGIN_ROUTES
from movieclaw_sdk import plugin
from movieclaw_sdk.agent import AgentBusy, AgentNotGranted, AgentSessionNotFound

ERRORS = {AgentNotGranted: 403, AgentBusy: 409, AgentSessionNotFound: 404}


class Ask(BaseModel):
    text: str
    session_id: str | None = None
    tools: str | None = None


class Ref(BaseModel):
    session_id: str


@plugin("ENTRY", title="A2A 桥", inject=(AGENT, PLUGIN_ROUTES), permissions=("agent:mclaw",))
async def apply(ctx):
    agent = ctx.use(AGENT).scoped(ctx)
    admin, member = APIRouter(), APIRouter()

    def fail(exc):
        raise HTTPException(ERRORS.get(type(exc), 500), f"{type(exc).__name__}: {exc}")

    async def ask(body):
        try:
            reply = await agent.ask(
                body.text, session_id=body.session_id, tools=body.tools, timeout=30
            )
        except (AgentNotGranted, AgentBusy, AgentSessionNotFound) as exc:
            fail(exc)
        return reply.model_dump()

    @admin.post("/ask", operation_id="plugins.ENTRY.ask")
    async def admin_ask(body: Ask) -> dict:
        return await ask(body)

    @member.post("/member-ask", operation_id="plugins.ENTRY.member-ask")
    async def member_ask(body: Ask) -> dict:
        return await ask(body)

    @admin.post("/stream", operation_id="plugins.ENTRY.stream")
    async def stream(body: Ask):
        try:
            turn = await agent.start(body.text, session_id=body.session_id)
        except (AgentNotGranted, AgentBusy, AgentSessionNotFound) as exc:
            fail(exc)

        async def frames():
            async for event in turn.events(include_thinking=True):
                yield f"event: {event.type}\\ndata: {event.model_dump_json()}\\n\\n"

        return StreamingResponse(
            frames(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache, no-transform"},
        )

    @admin.post("/start", operation_id="plugins.ENTRY.start")
    async def start(body: Ask) -> dict:
        try:
            turn = await agent.start(body.text, session_id=body.session_id)
        except (AgentNotGranted, AgentBusy, AgentSessionNotFound) as exc:
            fail(exc)
        return {"session_id": turn.session_id, "message_id": turn.message_id}

    @admin.post("/cancel", operation_id="plugins.ENTRY.cancel")
    async def cancel(body: Ref) -> dict:
        turn = await agent.attach(body.session_id)
        await turn.cancel()
        return (await turn.result(5)).model_dump()

    @admin.get("/sessions", operation_id="plugins.ENTRY.sessions")
    async def sessions() -> list:
        return [s.model_dump() for s in await agent.sessions()]

    routes = ctx.use(PLUGIN_ROUTES)
    routes.mount(ctx, admin, zone="admin")
    routes.mount(ctx, member, zone="member")
"""

#: 假大模型的闸门：清掉后流式回复卡在半路（会话保持「运行中」），置位放行
gate = threading.Event()
#: 每次模型调用收到的系统提示词
system_prompts: list[str] = []


class _EchoProtocol(_StreamProtocol):
    """回显最后一条用户消息，验证续写会话时历史与本轮输入。"""

    async def chat_stream(self, request, model_id):
        # 轮询而不是在线程里等：取消（停止、插件卸下、应用关闭）能立即生效
        while not gate.is_set():
            await asyncio.sleep(0.02)
        system_prompts.append(request.messages[0].content)
        last = request.messages[-1].content
        text = last if isinstance(last, str) else "?"
        snap = ChatResponse(model=model_id, provider=self.config.name)
        yield ChatStreamEvent(type="start", partial=snap)
        yield ChatStreamEvent(type="text_delta", delta=f"回声：{text}", partial=snap)
        yield ChatStreamEvent(
            type="done",
            partial=ChatResponse(
                content=f"回声：{text}", finish_reason="stop", model=model_id, provider="t"
            ),
        )


ENTRY = "acme-a2a"


@pytest.fixture(params=["inline", "process"])
def bridge(request, tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'agent.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("AGENT_SESSIONS_DIR", str(tmp_path / "agent-sessions"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    from movieclaw_api.services.agent_attachments import reset_agent_attachment_store
    from movieclaw_api.services.agent_sessions import reset_agent_session_store

    reset_agent_session_store()
    reset_agent_attachment_store()
    monkeypatch.setitem(PROTOCOLS, "openai_chat", _EchoProtocol)
    # 大模型路由是进程级单例，配置指纹不变就复用已建好的客户端：换一个新的，
    # 免得沿用同一进程里前面测试建的（另一个假协议）
    from movieclaw_api.services import llm_config
    from movieclaw_llm import LlmRouter

    monkeypatch.setattr(llm_config, "_runtime_router", LlmRouter())
    gate.set()
    (tmp_path / "plugins").mkdir()
    for entry, module in ((ENTRY, "acme_a2a"), ("acme-nogrant", "acme_nogrant")):
        code = BRIDGE.replace("ENTRY", entry)
        (tmp_path / "plugins" / f"{module}.py").write_text(code, encoding="utf-8")
    # 两个插件都声明 agent:mclaw；只有 acme-a2a 获得用户批准
    (tmp_path / "plugins.yaml").write_text(
        f"- id: {ENTRY}\n  local: true\n  module: acme_a2a\n  runtime: {request.param}\n"
        "  grants: ['agent:mclaw']\n"
        f"- id: acme-nogrant\n  local: true\n  module: acme_nogrant\n  runtime: {request.param}\n",
        encoding="utf-8",
    )
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    try:
        with TestClient(app) as client:
            assert app.state.kernel.fiber(ENTRY).state.value == "active"
            if request.param == "process":
                assert ENTRY in plugin_runtime.sessions
            configure_provider(client)
            yield app, client
    finally:
        gate.set()
        durable_events.reset_state()
        get_settings.cache_clear()
        reset_agent_session_store()
        reset_agent_attachment_store()


def url(path: str, entry: str = ENTRY) -> str:
    return f"/api/v1/plugins/{entry}{path}"


def reason(response) -> str:
    """插件路由的错误说明。

    进程外是 FastAPI 的 ``detail``；进程内经宿主的统一错误体，是 ``message``。
    """
    body = response.json()
    return body.get("detail") or body.get("message") or ""


def sse(text: str) -> list[tuple[str, dict]]:
    frames = []
    for block in text.split("\n\n"):
        lines = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line)
        if "event" in lines:
            frames.append((lines["event"], json.loads(lines["data"])))
    return frames


def test_ask_streams_and_continues_a_session(bridge, caplog) -> None:
    app, client = bridge
    caplog.set_level(logging.INFO, logger="movieclaw_api.plugin_agent")
    # 同步：等这一轮跑完
    reply = client.post(url("/ask"), json={"text": "沙丘 2 订阅到哪了"})
    assert reply.status_code == 200, reply.text
    first = reply.json()
    assert first["status"] == "done"
    assert first["text"] == "回声：沙丘 2 订阅到哪了"
    assert "档位=mclaw" in caplog.text
    # 插件驱动的会话没有真人在说话：不写昵称；mclaw 档没有 bash/read，不写源码位置
    assert "当前用户的昵称" not in system_prompts[-1]
    assert "后端源码" not in system_prompts[-1]
    assert "<mclaw_service>" in system_prompts[-1]
    # 流式（SSE）：续写同一个会话，事件按序到达、以终态结束
    with client.stream(
        "POST", url("/stream"), json={"text": "继续", "session_id": first["session_id"]}
    ) as response:
        body = response.read().decode()
        assert response.headers["content-type"].startswith("text/event-stream"), body
        frames = sse(body)
    kinds = [kind for kind, _ in frames]
    assert kinds[0] == "text" and kinds[-1] == "done"
    assert "".join(data["delta"] for kind, data in frames if kind == "text") == "回声：继续"
    seqs = [data["seq"] for _, data in frames]
    assert seqs == sorted(seqs)
    done = frames[-1][1]["reply"]
    assert done["session_id"] == first["session_id"] and done["text"] == "回声：继续"
    # 会话归插件：插件自己列得到；网页列表也看得到，带归属
    mine = client.get(url("/sessions")).json()
    assert [s["id"] for s in mine] == [first["session_id"]]
    listed = client.get("/api/v1/sessions").json()["data"]
    assert [(s["id"], s["owner"]) for s in listed] == [(first["session_id"], f"plugin:{ENTRY}")]


def test_grants_tiers_and_entry_zones(bridge, caplog) -> None:
    app, client = bridge
    caplog.set_level(logging.INFO, logger="movieclaw_api.plugin_agent")
    # 声明了但用户没批准
    denied = client.post(url("/ask", "acme-nogrant"), json={"text": "你好"})
    assert denied.status_code == 403
    assert "AgentNotGranted" in reason(denied)
    # 档位只能往下调，不能超出授权
    over = client.post(url("/ask"), json={"text": "你好", "tools": "full"})
    assert over.status_code == 403 and "超出授权" in reason(over)
    assert client.post(url("/ask"), json={"text": "你好", "tools": "none"}).status_code == 200
    # 成员区进来的：不带工具
    caplog.clear()
    member = client.post(url("/member-ask"), json={"text": "你好"})
    assert member.status_code == 200, member.text
    assert "档位=none" in caplog.text and "档位=mclaw" not in caplog.text


def test_plugins_only_see_their_own_sessions(bridge) -> None:
    app, client = bridge
    web = client.post("/api/v1/sessions", json={"content": "网页上开的会话"})
    assert web.status_code == 202
    web_session = web.json()["data"]["session_id"]
    with client.stream("GET", f"/api/v1/sessions/{web_session}/events") as response:
        response.read()
    # 续写别人的会话：当作不存在
    other = client.post(url("/ask"), json={"text": "接着聊", "session_id": web_session})
    assert other.status_code == 404
    assert client.get(url("/sessions")).json() == []


def test_agent_cannot_reach_itself_through_a_plugin(bridge) -> None:
    """Agent 的工具调用经插件路由再调 Agent：因果链带着 Agent 标记，被拒（防递归）。"""
    from movieclaw_api.services import auth as auth_service

    app, client = bridge
    app.dependency_overrides.clear()
    token = client.portal.call(auth_service.issue_agent_token, "s-agent")
    looped = client.post(
        url("/ask"), json={"text": "再问一遍"}, headers={"Authorization": f"Bearer {token}"}
    )
    assert looped.status_code == 403
    assert "防止递归" in reason(looped)


def test_busy_cancel_and_unload(bridge) -> None:
    app, client = bridge
    gate.clear()  # 回复卡住：轮次一直在进行
    a = client.post(url("/start"), json={"text": "一"}).json()
    b = client.post(url("/start"), json={"text": "二"}).json()
    # 每个插件同时最多两轮；同一会话也不能并发
    third = client.post(url("/start"), json={"text": "三"})
    assert third.status_code == 409 and "上限" in reason(third)
    same = client.post(url("/start"), json={"text": "又一轮", "session_id": a["session_id"]})
    assert same.status_code == 409
    # 显式取消
    cancelled = client.post(url("/cancel"), json={"session_id": a["session_id"]}).json()
    assert cancelled["status"] == "cancelled"
    # 插件卸下：它还在跑的轮次跟着取消
    client.portal.call(app.state.kernel.unmount, ENTRY)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        session = client.get(f"/api/v1/sessions/{b['session_id']}").json()["data"]["session"]
        if not session["running"]:
            break
        time.sleep(0.1)
    assert not session["running"]
