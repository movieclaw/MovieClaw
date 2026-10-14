"""三家搜索供应商的适配器：假 HTTP，不访问外网。

放在 tests/unit 而不是 tests/agent：那边的会话夹具要先编出 mclaw，
编不过会把整目录跳过，而这组用例只测适配器。
"""

from __future__ import annotations

import httpx
import pytest

from movieclaw_agent.web_search import WebSearchError
from movieclaw_agent.web_search.brave import BraveProvider
from movieclaw_agent.web_search.exa import ExaProvider
from movieclaw_agent.web_search.tavily import TavilyProvider

_KEY = "super-secret-token-9876"


@pytest.fixture(autouse=True)
def _no_retry_wait(monkeypatch):
    monkeypatch.setattr("movieclaw_agent.web_search.http.RETRY_DELAY_SECONDS", 0)


def _provider(cls, handler):
    return cls(_KEY, transport=httpx.MockTransport(handler))


async def _search(cls, handler, **kwargs):
    provider = _provider(cls, handler)
    return await provider.search(
        "Dune Part Two cast",
        max_results=kwargs.get("max_results", 5),
        include_content=kwargs.get("include_content", False),
    )


def _record(calls: list[httpx.Request]):
    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(200, json=_payload_for(request))

    return handler


def _payload_for(request: httpx.Request) -> dict:
    host = request.url.host
    if host == "api.tavily.com":
        body = request.read().decode()
        include = '"include_raw_content": true' in body or '"include_raw_content":true' in body
        return {
            "results": [
                {
                    "title": "Dune: Part Two",
                    "url": "https://example.com/dune",
                    "content": "Timothée Chalamet stars.",
                    "raw_content": "Full page about the cast." if include else None,
                    "published_date": "2024-03-01T00:00:00Z",
                },
                {"title": "skip", "url": ""},
            ]
        }
    if host == "api.exa.ai":
        return {
            "results": [
                {
                    "title": "Dune: Part Two",
                    "url": "https://example.com/dune",
                    "publishedDate": "2024-03-01T00:00:00.000Z",
                    "highlights": ["Timothée Chalamet stars."],
                    "text": "Full page about the cast.",
                }
            ]
        }
    return {
        "web": {
            "results": [
                {
                    "title": "Dune: <strong>Part Two</strong>",
                    "url": "https://example.com/dune",
                    "description": "Timothée <strong>Chalamet</strong> stars.",
                    "page_age": "2024-03-01T00:00:00",
                }
            ]
        }
    }


@pytest.mark.parametrize(
    "cls, header",
    [
        (TavilyProvider, "authorization"),
        (ExaProvider, "x-api-key"),
        (BraveProvider, "x-subscription-token"),
    ],
)
async def test_each_provider_maps_title_url_snippet_and_date(cls, header):
    calls: list[httpx.Request] = []
    hits = await _search(cls, _record(calls), include_content=True)
    assert len(hits) == 1
    hit = hits[0]
    assert hit.title.startswith("Dune")
    assert "<strong>" not in hit.title
    assert hit.url == "https://example.com/dune"
    assert "Chalamet" in hit.snippet
    assert "<strong>" not in hit.snippet
    assert hit.date == "2024-03-01"
    request = calls[0]
    assert _KEY not in str(request.url)
    assert _KEY in request.headers[header]
    if cls is BraveProvider:
        assert hit.content is None
    else:
        assert hit.content == "Full page about the cast."


async def test_tavily_omits_page_text_unless_asked():
    calls: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(
            200,
            json={
                "results": [
                    {
                        "title": "Dune",
                        "url": "https://example.com/dune",
                        "content": "snippet",
                        "raw_content": "should not be requested",
                    }
                ]
            },
        )

    hits = await _search(TavilyProvider, handler, include_content=False)
    assert hits[0].content is None
    body = calls[0].content
    assert b'"include_raw_content":false' in body or b'"include_raw_content": false' in body


async def test_exa_requests_text_only_when_asked():
    calls: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(200, json={"results": []})

    await _search(ExaProvider, handler, include_content=False)
    assert b'"text"' not in calls[0].content
    await _search(ExaProvider, handler, include_content=True)
    assert b'"text"' in calls[1].content


@pytest.mark.parametrize("cls", [TavilyProvider, ExaProvider, BraveProvider])
async def test_auth_failure_hides_the_key(cls):
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"error": f"invalid {_KEY}"})

    with pytest.raises(WebSearchError, match="API Key 无效") as exc:
        await _search(cls, handler)
    assert exc.value.kind == "auth"
    assert _KEY not in str(exc.value)


async def test_upstream_error_redacts_key_echoed_in_the_body():
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"error": f"rejected {_KEY}"})

    with pytest.raises(WebSearchError, match="HTTP 400") as exc:
        await _search(TavilyProvider, handler)
    assert _KEY not in str(exc.value)
    assert "***" in str(exc.value)


async def test_timeout_is_retried_once_then_succeeds():
    calls = {"n": 0}

    def handler(_request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] == 1:
            raise httpx.TimeoutException("slow")
        return httpx.Response(
            200,
            json={
                "results": [{"title": "Dune", "url": "https://example.com/dune", "content": "ok"}]
            },
        )

    hits = await _search(TavilyProvider, handler)
    assert calls["n"] == 2
    assert hits[0].title == "Dune"


async def test_rate_limit_is_retried_then_explained():
    calls = {"n": 0}

    def handler(_request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return httpx.Response(429, json={"error": "slow down"})

    with pytest.raises(WebSearchError, match="配额") as exc:
        await _search(BraveProvider, handler)
    assert calls["n"] == 2
    assert exc.value.kind == "rate"


async def test_connect_error_is_a_network_failure():
    def handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    with pytest.raises(WebSearchError, match="无法连接") as exc:
        await _search(ExaProvider, handler)
    assert exc.value.kind == "network"


async def test_empty_results_are_not_an_error():
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"results": []})

    assert await _search(ExaProvider, handler) == []
