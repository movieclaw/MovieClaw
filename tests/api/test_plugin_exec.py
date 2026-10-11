"""非 Python 插件（exec 运行时，docs/design/plugin-ipc-http.md §9）：Go 写的 A2A 桥驱动 AI 助手。

插件源码在插件开发技能的示例里（references/examples/go-a2a-bridge）。二进制来源依次是：环境变量
``MOVIECLAW_GO_A2A_BIN``、本机 ``go build``；都没有就跳过（CI 的 Python 作业没有 Go 工具链）。

真实应用生命周期 + 确定性的假大模型：宿主经可信启动器拉起 Go 进程，
Go 进程经网关报就绪、调 ``agent`` 服务，宿主把用户请求反代给它。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from tests.api.test_agent import configure_provider
from tests.api.test_plugin_agent import _EchoProtocol, gate

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events, plugin_runtime
from movieclaw_llm.protocols import PROTOCOLS

SOURCE = (
    Path(__file__).resolve().parents[2]
    / "src/movieclaw_agent/builtin-skills/movieclaw-plugin-dev/references/examples/go-a2a-bridge"
)
ENTRY = "go-a2a"


@pytest.fixture(scope="module")
def binary(tmp_path_factory) -> Path:
    given = os.environ.get("MOVIECLAW_GO_A2A_BIN")
    if given:
        return Path(given)
    if shutil.which("go") is None:
        pytest.skip("没有 Go 工具链，也没有指定 MOVIECLAW_GO_A2A_BIN")
    out = tmp_path_factory.mktemp("go") / "bridge"
    subprocess.run(
        ["go", "build", "-o", str(out), "."],
        cwd=SOURCE,
        check=True,
        env={**os.environ, "CGO_ENABLED": "0"},
    )
    return out


@pytest.fixture
def app_client(binary, tmp_path, monkeypatch, caplog):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'exec.db'}")
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
    target = tmp_path / "plugins" / "go_a2a" / "bridge"
    target.parent.mkdir(parents=True)
    shutil.copy2(binary, target)
    target.chmod(0o755)
    (tmp_path / "plugins.yaml").write_text(
        f"- id: {ENTRY}\n  local: true\n  runtime: exec\n  command: go_a2a/bridge\n"
        "  grants: ['agent:mclaw']\n",
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
            fiber = app.state.kernel.fiber(ENTRY)
            assert fiber.state.value == "active", fiber.error
            assert "不认识的字段" not in caplog.text  # plugins.yaml 的 command 是认识的字段
            configure_provider(client)
            yield app, client
    finally:
        durable_events.reset_state()
        get_settings.cache_clear()
        reset_agent_session_store()
        reset_agent_attachment_store()


def a2a(method: str, text: str, context: str | None = None) -> dict:
    message: dict = {"role": "user", "parts": [{"kind": "text", "text": text}], "messageId": "m1"}
    if context:
        message["contextId"] = context
    return {"jsonrpc": "2.0", "id": 7, "method": method, "params": {"message": message}}


def test_go_plugin_bridges_a2a_to_the_agent(app_client) -> None:
    app, client = app_client
    url = f"/api/v1/plugins/{ENTRY}"
    session = plugin_runtime.sessions[ENTRY]
    assert session.serving and session.title == "A2A 桥（Go）"

    card = client.get(f"{url}/card").json()
    assert card["capabilities"]["streaming"] is True and card["url"] == f"{url}/a2a"

    # message/send：同步一轮
    sent = client.post(f"{url}/a2a", json=a2a("message/send", "沙丘 2 订阅到哪了")).json()
    assert sent["id"] == 7, sent
    result = sent["result"]
    assert result["parts"] == [{"kind": "text", "text": "回声：沙丘 2 订阅到哪了"}]
    context = result["contextId"]

    # message/stream：带上 contextId 续写同一个会话，SSE 逐个推送
    with client.stream("POST", f"{url}/a2a", json=a2a("message/stream", "继续", context)) as r:
        assert r.headers["content-type"].startswith("text/event-stream")
        frames = [
            json.loads(line[len("data: ") :])["result"]
            for line in r.read().decode().splitlines()
            if line.startswith("data: ")
        ]
    assert frames[0]["kind"] == "status-update" and frames[0]["status"]["state"] == "working"
    assert frames[-1]["final"] and frames[-1]["status"]["state"] == "completed"
    chunks = [f["artifact"]["parts"][0]["text"] for f in frames if f["kind"] == "artifact-update"]
    assert "".join(chunks) == "回声：继续"
    assert {f["contextId"] for f in frames} == {context}
    listed = client.get("/api/v1/sessions").json()["data"]
    assert [(s["id"], s["owner"]) for s in listed] == [(context, f"plugin:{ENTRY}")]


def test_go_plugin_keeps_the_guards_and_exits_cleanly(app_client) -> None:
    from movieclaw_api.services import auth as auth_service

    app, client = app_client
    url = f"/api/v1/plugins/{ENTRY}"
    # 调用号原样带回宿主：Agent 经插件接口再调 Agent 照样被递归闸拦下
    app.dependency_overrides.clear()
    token = client.portal.call(auth_service.issue_agent_token, "s-agent")
    looped = client.post(
        f"{url}/a2a",
        json=a2a("message/send", "再问一遍"),
        headers={"Authorization": f"Bearer {token}"},
    ).json()
    assert "防止递归" in looped["error"]["message"]
    # 卸下：SIGTERM，Go 进程体面退出
    proc = plugin_runtime.sessions[ENTRY]._proc
    client.portal.call(app.state.kernel.unmount, ENTRY)
    assert proc.returncode == 0
