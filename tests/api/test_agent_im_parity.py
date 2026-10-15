"""IM 通道与网页会话的 AI 助手完全一致：同一份系统提示词、同一套工具（只差卡片绘制）。

真实应用 + 示例通道插件 ``ntfy-channel`` + 本地假 ntfy 服务器，模型换成记录请求的
假协议：网页发一条、IM 发一条，都走完真实链路，比对两边实际发给模型的内容。
"""

from __future__ import annotations

import shutil
import sys
import textwrap

import pytest
from tests.api.test_channel_plugin_ntfy import EXAMPLE, make_client, ntfy, wait

from movieclaw_agent.tools.media_ui import TOOL_NAME as MEDIA_UI_TOOL
from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_llm import ChatResponse, ProviderInfo
from movieclaw_llm.base import BaseLlmProtocol
from movieclaw_llm.models import ChatStreamEvent
from movieclaw_llm.protocols import PROTOCOLS

__all__ = ["ntfy"]  # 假 ntfy 服务器夹具复用通道插件测试的那一份

#: 每次模型调用收到的 (系统提示词, 工具名列表)
_CALLS: list[tuple[str, list[str]]] = []


class _RecordingProtocol(BaseLlmProtocol):
    async def chat(self, request, model_id):
        return ChatResponse(content="pong", finish_reason="stop")

    async def chat_stream(self, request, model_id):
        system = next(m.content for m in request.messages if m.role == "system")
        _CALLS.append((system, [tool.name for tool in request.tools or []]))
        snap = ChatResponse(model=model_id, provider=self.config.name)
        yield ChatStreamEvent(type="start", partial=snap)
        # IM 的分步回复按逐字输出攒正文，没有 text_delta 就什么都推不出去
        yield ChatStreamEvent(type="text_delta", delta="已找到资源", partial=snap)
        yield ChatStreamEvent(
            type="done",
            partial=ChatResponse(content="已找到资源", finish_reason="stop", model=model_id),
        )

    async def test_connection(self):
        return ProviderInfo(models=[])

    async def close(self):
        pass


@pytest.fixture
def world(tmp_path, monkeypatch):
    from movieclaw_api.services.agent_attachments import reset_agent_attachment_store
    from movieclaw_api.services.agent_sessions import reset_agent_session_store

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'parity.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("AGENT_SESSIONS_DIR", str(tmp_path / "agent-sessions"))
    monkeypatch.setenv("AGENT_WORKSPACE_DIR", str(tmp_path / "agent-workspace"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_agent_session_store()
    reset_agent_attachment_store()
    (tmp_path / "plugins").mkdir()
    shutil.copy(EXAMPLE / "ntfy_channel.py", tmp_path / "plugins" / "ntfy_channel.py")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: ntfy-channel
              local: true
              module: ntfy_channel
              runtime: inline
            """
        ),
        encoding="utf-8",
    )
    monkeypatch.setitem(PROTOCOLS, "openai_chat", _RecordingProtocol)
    _CALLS.clear()
    yield
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    get_settings.cache_clear()
    reset_agent_session_store()
    reset_agent_attachment_store()


def test_im_channel_runs_the_same_agent_as_the_web(world, ntfy) -> None:
    fake, server = ntfy
    with make_client() as client:
        client.put("/api/v1/app/config", json={"port": 0, "external_url": "http://nas.local:3000"})
        client.post("/api/v1/auth/bootstrap", json={"username": "admin", "password": "s3cret-pass"})
        client.put("/api/v1/auth/profile", json={"nickname": "小鹏"})
        created = client.post(
            "/api/v1/llm/providers",
            json={
                "name": "百炼",
                "provider_type": "bailian",
                "api_key": "sk-t",
                "default_model": "qwen3.7-max",
            },
        )
        assert created.status_code == 200, created.text

        # 网页会话
        started = client.post("/api/v1/sessions", json={"content": "找沙丘"})
        assert started.status_code == 202, started.text
        wait(lambda: len(_CALLS) == 1)

        # IM 通道
        [channel] = [
            c
            for c in client.get("/api/v1/channels").json()["data"]["channels"]
            if c["title"] == "ntfy"
        ]
        fields = {"server": server, "inbox": "mc-in-parity", "outbox": "mc-out-parity"}
        bound = client.post(
            "/api/v1/channels/bindings", json={"channel_id": channel["id"], "fields": fields}
        )
        assert bound.status_code == 201, bound.text
        wait(lambda: fake.live("mc-in-parity") == 1)
        fake.post("mc-in-parity", "找沙丘")
        wait(lambda: "已找到资源" in fake.published("mc-out-parity"))

    (web_prompt, web_tools), (im_prompt, im_tools) = _CALLS
    assert im_prompt == web_prompt
    # 两边都是完整提示词：源码与日志、页面链接、技能清单、服务目录收尾
    sections = (
        "后端源码",
        "运行日志目录",
        "本应用的外部访问地址：http://nas.local:3000",
        "当前用户的昵称：小鹏",
        "# 技能",
    )
    for section in sections:
        assert section in im_prompt
    assert im_prompt.endswith("</mclaw_service>")
    # 工具只差卡片绘制：IM 里画不出卡片
    assert web_tools == [*im_tools, MEDIA_UI_TOOL]
    assert {"bash", "read", "write", "edit", "mclaw"} <= set(im_tools)
