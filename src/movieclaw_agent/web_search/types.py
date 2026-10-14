"""网页搜索的统一结果。各供应商适配器都收成这一份，工具层不再关心上游字段名。"""

from __future__ import annotations

from dataclasses import dataclass

import httpx

from movieclaw_agent.web_search.http import TIMEOUT


@dataclass(frozen=True)
class WebSearchHit:
    """一条搜索结果。``content`` 只有调用方要求摘录正文、且供应商提供时才有。"""

    title: str
    url: str
    snippet: str = ""
    date: str | None = None
    content: str | None = None


class SearchProvider:
    """一个搜索供应商。新增供应商：继承本类，填目录字段，实现 ``search``，
    再登记进 ``movieclaw_agent.web_search.PROVIDERS``。
    """

    id: str
    label: str
    signup_url: str
    note: str
    probe_url: str
    #: False 的供应商（如 Brave）没有网页正文，工具会告诉模型只有摘要
    supports_content: bool = True

    def __init__(self, api_key: str, *, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.api_key = api_key.strip()
        self._transport = transport

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transport, timeout=TIMEOUT)

    async def search(
        self, query: str, *, max_results: int, include_content: bool
    ) -> list[WebSearchHit]:
        raise NotImplementedError
