"""网页搜索的统一结果。各供应商适配器都收成这一份，工具层不再关心上游字段名。"""

from __future__ import annotations

from dataclasses import dataclass

import httpx

from movieclaw_agent.web_search.http import TIMEOUT


@dataclass(frozen=True)
class WebSearchHit:
    """一条搜索结果：标题、链接、摘要。不取网页正文。"""

    title: str
    url: str
    snippet: str = ""
    date: str | None = None


class SearchProvider:
    """一个搜索供应商。新增供应商：继承本类，填目录字段，实现 ``search``，
    再登记进 ``movieclaw_agent.web_search.PROVIDERS``。
    """

    id: str
    label: str
    signup_url: str
    note: str
    probe_url: str

    def __init__(self, api_key: str, *, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.api_key = api_key.strip()
        self._transport = transport

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transport, timeout=TIMEOUT)

    async def search(
        self,
        query: str,
        *,
        max_results: int,
        domain: str | None = None,
    ) -> list[WebSearchHit]:
        raise NotImplementedError
