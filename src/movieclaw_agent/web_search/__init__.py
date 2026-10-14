"""智能体网页搜索的供应商层。

适配器只负责一家 API 的请求和字段映射，统一收成 ``WebSearchHit``
（title / url / snippet / date，以及可选的 content）。
要加新供应商：写一个 ``SearchProvider`` 子类，放进 ``PROVIDERS``。
"""

from __future__ import annotations

from movieclaw_agent.web_search.brave import BraveProvider
from movieclaw_agent.web_search.exa import ExaProvider
from movieclaw_agent.web_search.http import WebSearchError
from movieclaw_agent.web_search.tavily import TavilyProvider
from movieclaw_agent.web_search.types import SearchProvider, WebSearchHit

PROVIDERS: tuple[type[SearchProvider], ...] = (TavilyProvider, ExaProvider, BraveProvider)


def provider_ids() -> frozenset[str]:
    return frozenset(provider.id for provider in PROVIDERS)


def get_provider(provider_id: str) -> type[SearchProvider]:
    for provider in PROVIDERS:
        if provider.id == provider_id:
            return provider
    raise KeyError(provider_id)


def provider_catalog() -> list[dict[str, str]]:
    return [
        {
            "id": provider.id,
            "label": provider.label,
            "signup_url": provider.signup_url,
            "note": provider.note,
        }
        for provider in PROVIDERS
    ]


def probe_url_for(provider_id: str) -> str:
    """网络设置里「网页搜索」的连通性探测地址。没选供应商时用 Tavily 的主机。"""
    try:
        return get_provider(provider_id).probe_url
    except KeyError:
        return TavilyProvider.probe_url


__all__ = [
    "PROVIDERS",
    "SearchProvider",
    "WebSearchError",
    "WebSearchHit",
    "get_provider",
    "probe_url_for",
    "provider_catalog",
    "provider_ids",
]
