"""Tavily Search API。文档：https://docs.tavily.com/documentation/api-reference/endpoint/search"""

from __future__ import annotations

from typing import Any

from movieclaw_agent.web_search.http import clip_text, normalize_date, request_json
from movieclaw_agent.web_search.types import SearchProvider, WebSearchHit

_URL = "https://api.tavily.com/search"
_SNIPPET = 500
_CONTENT = 1200


class TavilyProvider(SearchProvider):
    id = "tavily"
    label = "Tavily"
    signup_url = "https://tavily.com"
    note = "返回标题、链接和摘要；需要时可以多带一段网页正文"
    probe_url = _URL

    async def search(
        self, query: str, *, max_results: int, include_content: bool
    ) -> list[WebSearchHit]:
        body = {
            "query": query,
            "max_results": max_results,
            "search_depth": "basic",
            "include_answer": False,
            "include_raw_content": include_content,
        }
        headers = {"Authorization": f"Bearer {self.api_key}"}
        async with self.client() as client:
            data = await request_json(
                client, "POST", _URL, headers=headers, json=body, secret=self.api_key
            )
        hits: list[WebSearchHit] = []
        for item in data.get("results") or []:
            hit = _hit(item, include_content=include_content)
            if hit is not None:
                hits.append(hit)
        return hits


def _hit(item: Any, *, include_content: bool) -> WebSearchHit | None:
    if not isinstance(item, dict):
        return None
    url = str(item.get("url") or "").strip()
    if not url or len(url) > 2000:
        return None
    raw = item.get("raw_content") if include_content else None
    content = clip_text(raw, _CONTENT) if isinstance(raw, str) and raw.strip() else None
    return WebSearchHit(
        title=clip_text(str(item.get("title") or ""), 200),
        url=url,
        snippet=clip_text(str(item.get("content") or ""), _SNIPPET),
        date=normalize_date(item.get("published_date")),
        content=content or None,
    )
