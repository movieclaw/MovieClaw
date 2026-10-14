"""Exa Search API。文档：https://docs.exa.ai/reference/search"""

from __future__ import annotations

from typing import Any

from movieclaw_agent.web_search.http import clip_text, normalize_date, request_json
from movieclaw_agent.web_search.types import SearchProvider, WebSearchHit

_URL = "https://api.exa.ai/search"
_SNIPPET = 500


class ExaProvider(SearchProvider):
    id = "exa"
    label = "Exa"
    signup_url = "https://exa.ai"
    note = "返回标题、链接和摘要"
    probe_url = _URL

    async def search(
        self,
        query: str,
        *,
        max_results: int,
        domain: str | None = None,
    ) -> list[WebSearchHit]:
        body: dict[str, Any] = {
            "query": query,
            "type": "auto",
            "numResults": max_results,
            "contents": {"highlights": {"maxCharacters": _SNIPPET}},
        }
        if domain:
            body["includeDomains"] = [domain]
        headers = {"x-api-key": self.api_key}
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
    highlights = item.get("highlights") or []
    if isinstance(highlights, list):
        snippet = clip_text(" ".join(str(part) for part in highlights if part), _SNIPPET)
    else:
        snippet = ""
    return WebSearchHit(
        title=clip_text(str(item.get("title") or ""), 200),
        url=url,
        snippet=snippet,
        date=normalize_date(item.get("publishedDate")),
    )
