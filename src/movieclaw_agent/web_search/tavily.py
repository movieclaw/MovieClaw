"""Tavily Search API。文档：https://docs.tavily.com/documentation/api-reference/endpoint/search"""

from __future__ import annotations

from typing import Any

from movieclaw_agent.web_search.http import clip_text, normalize_date, request_json
from movieclaw_agent.web_search.types import SearchProvider, WebSearchHit

_URL = "https://api.tavily.com/search"
_SNIPPET = 500


class TavilyProvider(SearchProvider):
    id = "tavily"
    label = "Tavily"
    signup_url = "https://tavily.com"
    note = "专为 AI 智能体设计的搜索，结果自带摘要"
    probe_url = _URL

    async def search(
        self,
        query: str,
        *,
        max_results: int,
        domain: str | None = None,
    ) -> list[WebSearchHit]:
        body = {
            "query": query,
            "max_results": max_results,
            "search_depth": "basic",
            "include_answer": False,
            "include_raw_content": False,
            # 不开这个只有 news 话题才回日期
            "include_published_date": True,
        }
        if domain:
            body["include_domains"] = [domain]
        headers = {"Authorization": f"Bearer {self.api_key}"}
        async with self.client() as client:
            data = await request_json(
                client, "POST", _URL, headers=headers, json=body, secret=self.api_key
            )
        hits: list[WebSearchHit] = []
        for item in data.get("results") or []:
            hit = _hit(item)
            if hit is not None:
                hits.append(hit)
        return hits


def _hit(item: Any) -> WebSearchHit | None:
    if not isinstance(item, dict):
        return None
    url = str(item.get("url") or "").strip()
    if not url or len(url) > 2000:
        return None
    return WebSearchHit(
        title=clip_text(str(item.get("title") or ""), 200),
        url=url,
        snippet=clip_text(str(item.get("content") or ""), _SNIPPET),
        date=normalize_date(item.get("published_date")),
    )
