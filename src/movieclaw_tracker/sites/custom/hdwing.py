from __future__ import annotations

import re
from typing import Any

from parsel import Selector

from movieclaw_tracker.exceptions import TrackerAuthError, TrackerParseError
from movieclaw_tracker.frameworks.nexusphp import NexusPHPSite
from movieclaw_tracker.models import (
    SearchQuery,
    SearchResult,
    TorrentCategory,
    TorrentListPage,
    UserProfile,
)


class HDWingSite(NexusPHPSite):
    """HDWing：异步优惠占位符，以及必须带 UID 的用户资料页。"""

    async def _list_document(self, path: str, params: dict[str, Any]) -> Selector:
        url = self._url(path)
        response = await self.client.get(url, params=params)
        doc = Selector(text=response.text)
        if doc.css("form input[type='password']"):
            raise TrackerAuthError("HDWing session expired")

        placeholders = doc.css("td.discount span.sp_state_placeholder")
        if not placeholders:
            return doc
        ids = [node.attrib.get("id", "") for node in placeholders]
        csrf = doc.css("meta[name='x-csrf']::attr(content)").get("")
        if not csrf or not all(value.isdigit() for value in ids):
            raise TrackerParseError("HDWing promotion query context is missing")

        # 这是列表页自身发起的只读优惠查询，不调用签到或下载接口。
        promotion = await self.client.post(
            self._url("ajax_promotion.php"),
            data={"ids[]": ids, "csrf": csrf},
            headers={"Referer": str(response.url), "X-Requested-With": "XMLHttpRequest"},
        )
        try:
            payload = promotion.json()
            if not isinstance(payload, dict) or payload.get("status") != 200:
                raise ValueError
            entries = payload["message"]
            for node, torrent_id in zip(placeholders, ids, strict=True):
                entry = entries[torrent_id]
                state, timeout = entry["sp_state"], entry["timeout"]
                if not isinstance(state, str) or not isinstance(timeout, str):
                    raise ValueError
                replacement = Selector(text=f"<span>{state}{timeout}</span>").css("body > span")
                node.root.getparent().replace(node.root, replacement[0].root)
        except (ValueError, KeyError, TypeError, IndexError) as exc:
            # 不能把失败或缺项的查询静默当作「无优惠」。错误不携带回包或 CSRF。
            raise TrackerParseError("HDWing promotion response is invalid") from exc
        return doc

    async def list_torrents(
        self, *, categories: list[TorrentCategory] | None = None, page: int = 1
    ) -> TorrentListPage:
        params: dict[str, Any] = {"page": page + self.selectors.page_offset}
        self._apply_category_params(params, categories)
        doc = await self._list_document(self.selectors.torrent_list_path, params)
        return TorrentListPage(
            items=self._parse_torrent_rows(doc), page=page, total_pages=self._parse_total_pages(doc)
        )

    async def search(self, query: SearchQuery) -> SearchResult:
        params: dict[str, Any] = {
            self.selectors.search_keyword_param: query.keyword,
            "page": query.page + self.selectors.page_offset,
        }
        self._apply_category_params(params, query.categories)
        doc = await self._list_document(self.selectors.search_path, params)
        return SearchResult(
            items=self._parse_torrent_rows(doc),
            page=query.page,
            total_pages=self._parse_total_pages(doc),
        )

    def _parse_total_pages(self, doc: Selector) -> int | None:
        pages = [
            int(value)
            for href in doc.css("a[href*='page=']::attr(href)").getall()
            if (value := self._extract_id_from_url(href, "page")).isdigit()
        ]
        return max(pages) + 1 if pages else None

    def _css_text(self, sel: Selector, css: str) -> str | None:
        value = super()._css_text(sel, css)
        if value and css in (
            self.selectors.profile_uploaded_css,
            self.selectors.profile_downloaded_css,
        ):
            # 传输单元格是「: 25.000 TB(本月...)」，只保留累计量。
            return value.lstrip(":： ").split("(", 1)[0].strip()
        if value and css in (
            self.selectors.profile_seeding_css,
            self.selectors.profile_leeching_css,
        ):
            match = re.search(r"(\d+)个种子", value)
            return match.group(1) if match else None
        return value

    async def get_user_profile(self, user_id: str | None = None) -> UserProfile:
        if not user_id:
            response = await self.client.get(self._url("index.php"))
            doc = Selector(text=response.text)
            href = doc.css("#site_header .userinfo a[href^='userdetails.php?id=']::attr(href)").get(
                ""
            )
            user_id = self._extract_id_from_url(href, "id")
            if not user_id:
                raise TrackerParseError(
                    "HDWing current user ID is missing",
                    details={"login_redirect": bool(doc.css("input[type='password']"))},
                )
        return await super().get_user_profile(user_id)
