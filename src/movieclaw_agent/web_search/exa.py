"""Exa Search API。文档：https://docs.exa.ai/reference/search"""

from __future__ import annotations

from typing import Any

from movieclaw_agent.web_search.http import clip_text, normalize_date, request_json
from movieclaw_agent.web_search.types import SearchProvider, WebSearchHit

_URL = "https://api.exa.ai/search"
_SNIPPET = 500
_CONTENT = 1200


class ExaProvider(SearchProvider):
    id = "exa"
    label = "Exa"
    signup_url = "https://exa.ai"
    note = "返回标题、链接和摘要；需要时可以多带一段网页正文"
    probe_url = _URL

    async def search(
        self, query: str, *, max_results: int, include_content: bool
    ) -> list[WebSearchHit]:
        contents: dict[str, Any] = {"highlights": {"maxCharacters": _SNIPPET}}
        if include_content:
            contents["text"] = {"maxCharacters": _CONTENT}
        body = {
            "query": query,
            "type": "auto",
            "numResults": max_results,
            "contents": contents,
        }
        headers = {"x-api-key": self.api_key}
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
    highlights = item.get("highlights") or []
    if isinstance(highlights, list):
        snippet = clip_text(" ".join(str(part) for part in highlights if part), _SNIPPET)
    else:
        snippet = ""
    text = item.get("text") if include_content else None
    content = clip_text(text, _CONTENT) if isinstance(text, str) and text.strip() else None
    if not snippet and isinstance(text, str):
        snippet = clip_text(text, _SNIPPET)
    return WebSearchHit(
        title=clip_text(str(item.get("title") or ""), 200),
        url=url,
        snippet=snippet,
        date=normalize_date(item.get("publishedDate")),
        content=content or None,
    )
