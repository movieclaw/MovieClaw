"""show_media_cards 工具的装配开关（docs/design/agent-generative-ui.md §2）。

卡片只有网页会话能画：开关默认关、网页会话显式开、IM 通道永远不含它——
三条各一个守护测试，新接通道忘了关也会被拦下。
"""

from __future__ import annotations

import inspect

from movieclaw_agent.tools.media_ui import TOOL_NAME
from movieclaw_api.api.routes import agent as agent_routes
from movieclaw_api.services import agent_toolkit, channel_agent


def _names(tools) -> set[str]:
    return {tool.name for tool in tools}


def test_generative_ui_is_off_by_default(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("AGENT_WORKSPACE_DIR", str(tmp_path / "ws"))
    agent_toolkit.get_settings.cache_clear()
    try:
        assert TOOL_NAME not in _names(agent_toolkit.get_agent_tools({}))
        assert TOOL_NAME in _names(agent_toolkit.get_agent_tools({}, generative_ui=True))
    finally:
        agent_toolkit.get_settings.cache_clear()


def test_web_session_paths_opt_in_explicitly() -> None:
    """网页会话的两条装配路径（发消息 / 改写重问）都走 web 档，web 档显式打开开关。"""
    profile = inspect.getsource(agent_toolkit.profile_tools)
    retry = inspect.getsource(agent_routes.retry_session_message)
    assert profile.count("generative_ui=True") == 1
    assert "generative_ui=False" not in profile
    assert 'profile_tools("web"' in retry


def test_im_channels_never_carry_the_tool() -> None:
    """IM 通道无法渲染卡片：走不带卡片的 full 档，模块里连绘制工具的 import 都不该有。"""
    source = inspect.getsource(channel_agent)
    assert "make_media_ui_tool" not in source
    assert "generative_ui=True" not in source
    assert 'profile_tools("full"' in source
