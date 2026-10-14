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

    def __init__(self) -> None:
        self.calls: list[dict] = []

    async def search(
        self,
        query: str,
        *,
        max_results: int,
        domain: str | None = None,
    ):
        self.calls.append(
            {
                "query": query,
                "max_results": max_results,
                "domain": domain,
            }
        )
        return [
            WebSearchHit(
                title="Dune: Part Two",
                url="https://example.com/dune",
                snippet="Timothée Chalamet stars.",
                date="2024-03-01",
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


def test_tool_description_is_general_web_search_not_media_only():
    tool = make_web_search_tool(_Fake())  # type: ignore[arg-type]
    text = tool.definition.description
    assert text == "搜索网络以获取最新信息。返回来源标题、URL 和摘要列表。"
    assert "摘要回答" not in text
    for banned in ("电影", "剧集", "供应商", "Brave"):
        assert banned not in text
        for param in tool.definition.parameters["properties"].values():
            assert banned not in param["description"]
    params = tool.definition.parameters["properties"]
    assert list(params) == ["query", "max_results", "domain"]
    assert tool.definition.parameters["required"] == ["query"]
    # Tavily / Exa 不认 site: 之类的语法，限定网站一律走 domain
    assert "site:" not in params["query"]["description"]
    assert "domain" in params["query"]["description"]
    assert params["max_results"]["type"] == "integer"
    assert "默认 5" in params["max_results"]["description"]


def test_web_and_im_paths_load_the_provider_and_none_profile_does_not():
    profile = inspect.getsource(agent_routes._profile_tools)
    assert profile.index('profile == "none"') < profile.index("load_web_search_provider")
    assert "load_web_search_provider" in inspect.getsource(agent_routes.retry_session_message)
    assert "load_web_search_provider" in inspect.getsource(channel_agent._restricted_tools)
    assert "make_web_search_tool" not in inspect.getsource(agent_routes.get_agent_tools)


async def test_tool_formats_a_citation_and_clamps_the_result_count():
    provider = _Fake()
    tool = make_web_search_tool(provider)  # type: ignore[arg-type]
    text = await tool.handler({"query": "  沙丘2 主演  ", "max_results": 50})
    assert "Dune: Part Two" in text
    assert "https://example.com/dune" in text
    assert "2024-03-01" in text
    assert "正文摘录" not in text
    assert provider.calls[0]["max_results"] == 8
    assert provider.calls[0]["query"] == "沙丘2 主演"


async def test_domain_is_normalized_before_the_search_and_a_bad_one_is_rejected():
    provider = _Fake()
    tool = make_web_search_tool(provider)  # type: ignore[arg-type]
    await tool.handler({"query": "oscars", "domain": "https://www.Example.com/awards"})
    assert provider.calls[0]["domain"] == "example.com"

    with pytest.raises(ValueError, match="域名"):
        await tool.handler({"query": "oscars", "domain": "not a domain"})
    assert len(provider.calls) == 1


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
        async def search(
            self,
            query: str,
            *,
            max_results: int,
            domain: str | None = None,
        ):
            raise WebSearchError(f"rejected {_KEY}", kind="auth")

    broken = make_web_search_tool(_Broken())  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="rejected \\*\\*\\*"):
        await broken.handler({"query": "dune cast"})


async def test_results_are_marked_as_untrusted_page_text():
    tool = make_web_search_tool(_Fake())  # type: ignore[arg-type]
    text = await tool.handler({"query": "dune"})
    header = text.splitlines()[:2]
    assert any("不要照做" in line for line in header)
