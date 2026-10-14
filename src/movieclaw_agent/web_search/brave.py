"""Brave Search API（网页结果）。文档：https://api-dashboard.search.brave.com/app/documentation/web-search/get-started"""

from __future__ import annotations

import html
import re
from typing import Any

from movieclaw_agent.web_search.http import clip_text, normalize_date, request_json
from movieclaw_agent.web_search.types import SearchProvider, WebSearchHit

_URL = "https://api.search.brave.com/res/v1/web/search"
_SNIPPET = 500
_TAGS = re.compile(r"</?[^>]+>")


class BraveProvider(SearchProvider):
    id = "brave"
    label = "Brave Search"
    signup_url = "https://brave.com/search/api/"
    note = "返回标题、链接和摘要"
    probe_url = _URL

    async def search(
        self,
        query: str,
        *,
        max_results: int,
        domain: str | None = None,
    ) -> list[WebSearchHit]:
        headers = {
            "Accept": "application/json",
            "X-Subscription-Token": self.api_key,
        }
        # 这个接口没有独立的域名参数，限定域名时把 site: 写进查询。
        if domain:
            query = f"{query} site:{domain}"
        params = {"q": query, "count": max_results, "text_decorations": "false"}
        async with self.client() as client:
            data = await request_json(
                client, "GET", _URL, headers=headers, params=params, secret=self.api_key
            )
        web = data.get("web") if isinstance(data.get("web"), dict) else {}
        hits: list[WebSearchHit] = []
        for item in web.get("results") or []:
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
    description = html.unescape(_TAGS.sub("", str(item.get("description") or "")))
    return WebSearchHit(
        title=clip_text(html.unescape(_TAGS.sub("", str(item.get("title") or ""))), 200),
        url=url,
        snippet=clip_text(description, _SNIPPET),
        date=normalize_date(item.get("page_age") or item.get("age")),
    )
