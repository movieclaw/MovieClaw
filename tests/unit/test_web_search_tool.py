"""web_search 工具：没注入供应商就不存在；注入了才给模型看。

放在 tests/unit 而不是 tests/agent，避免缺 mclaw 二进制时整目录被跳过。
"""

from __future__ import annotations

import inspect

import pytest

from movieclaw_agent.tools.web_search import TOOL_NAME, make_web_search_tool
from movieclaw_agent.web_search import WebSearchError, WebSearchHit
from movieclaw_api.api.routes import agent as agent_routes
from movieclaw_api.services import channel_agent
from movieclaw_api.services.web_search_config import attach_web_search_tool

_KEY = "super-secret-token-9876"


class _Fake:
    id = "tavily"
    api_key = _KEY
    supports_content = True

    def __init__(self) -> None:
        self.calls: list[dict] = []

    async def search(self, query: str, *, max_results: int, include_content: bool):
        self.calls.append(
            {"query": query, "max_results": max_results, "include_content": include_content}
        )
        return [
            WebSearchHit(
                title="Dune: Part Two",
                url="https://example.com/dune",
                snippet="Timothée Chalamet stars.",
                date="2024-03-01",
                content="Full page." if include_content else None,
            )
        ]


@pytest.fixture(autouse=True)
def _no_pace(monkeypatch):
    monkeypatch.setattr("movieclaw_agent.tools.web_search.MIN_INTERVAL_SECONDS", 0)


def test_builtin_agent_tools_omit_web_search_until_a_provider_is_attached(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENT_WORKSPACE_DIR", str(tmp_path))
    agent_routes.get_settings.cache_clear()
    try:
        base = agent_routes.get_agent_tools({})
    finally:
        agent_routes.get_settings.cache_clear()
    assert TOOL_NAME not in {tool.name for tool in base}
    attached = attach_web_search_tool(base, _Fake())
    assert TOOL_NAME in {tool.name for tool in attached}
    assert attach_web_search_tool(base, None) == base


def test_web_and_im_paths_load_the_provider_and_none_profile_does_not():
    profile = inspect.getsource(agent_routes._profile_tools)
    assert profile.index('profile == "none"') < profile.index("load_web_search_provider")
    assert "load_web_search_provider" in inspect.getsource(agent_routes.retry_session_message)
    assert "load_web_search_provider" in inspect.getsource(channel_agent._restricted_tools)
    assert "make_web_search_tool" not in inspect.getsource(agent_routes.get_agent_tools)


async def test_tool_formats_a_citation_and_clamps_the_result_count():
    provider = _Fake()
    tool = make_web_search_tool(provider)  # type: ignore[arg-type]
    text = await tool.handler(
        {"query": "  沙丘2 主演  ", "max_results": 50, "include_content": True}
    )
    assert "Dune: Part Two" in text
    assert "https://example.com/dune" in text
    assert "2024-03-01" in text
    assert "正文摘录" in text
    assert provider.calls[0]["max_results"] == 8
    assert provider.calls[0]["query"] == "沙丘2 主演"


async def test_tool_rejects_an_empty_query_without_calling_the_provider():
    provider = _Fake()
    tool = make_web_search_tool(provider)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="不能为空"):
        await tool.handler({"query": "   "})
    assert provider.calls == []


async def test_logs_redact_the_key_and_errors_stay_readable(caplog):
    provider = _Fake()
    tool = make_web_search_tool(provider)  # type: ignore[arg-type]
    query = f"release date {_KEY}"
    with caplog.at_level("INFO"):
        await tool.handler({"query": query})
    assert _KEY not in caplog.text
    assert "***" in caplog.text

    class _Broken(_Fake):
        async def search(self, query: str, *, max_results: int, include_content: bool):
            raise WebSearchError(f"rejected {_KEY}", kind="auth")

    broken = make_web_search_tool(_Broken())  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="rejected \\*\\*\\*"):
        await broken.handler({"query": "dune cast"})


async def test_brave_style_provider_says_it_has_no_page_text():
    class _Brave(_Fake):
        id = "brave"
        supports_content = False

        async def search(self, query: str, *, max_results: int, include_content: bool):
            return [WebSearchHit(title="Dune", url="https://example.com/dune", snippet="cast")]

    tool = make_web_search_tool(_Brave())  # type: ignore[arg-type]
    text = await tool.handler({"query": "dune", "include_content": True})
    assert "没有网页正文" in text
    assert "正文摘录" not in text
