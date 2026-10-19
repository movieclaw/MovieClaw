"""站点搜索后台运行（#920）的隔离浏览器验收：PT 站点用假实现，搜索/历史/快照业务保持真实。

三个假站点：fast 立即返回；slow 卡在实验台的闸门上，放行才返回（模拟慢站，测试据此
在「搜到一半」时离开/刷新）；flaky 第一次搜索报登录过期、之后正常（验证单站重试真的
重新打站）。每站收到的搜索词记进 search_log——打站次数就是它的长度。
"""

import asyncio
from dataclasses import dataclass

import movieclaw_api.services.site_search as site_search
from movieclaw_api.app import create_app
from movieclaw_tracker.models import SearchQuery, SearchResult, TorrentListItem

SITES = ("fast", "slow", "flaky")
search_log: dict[str, list[str]] = {site_id: [] for site_id in SITES}
_gate: asyncio.Event | None = None


def _slow_gate() -> asyncio.Event:
    global _gate
    if _gate is None:
        _gate = asyncio.Event()
        _gate.set()
    return _gate


@dataclass
class _Cred:
    site_id: str
    protected: bool = False


class _FakeSite:
    def __init__(self, site_id: str):
        self._site_id = site_id

    async def search(self, query: SearchQuery) -> SearchResult:
        search_log[self._site_id].append(query.keyword)
        if self._site_id == "slow":
            await _slow_gate().wait()
        if self._site_id == "flaky" and len(search_log["flaky"]) == 1:
            raise RuntimeError("登录已过期")
        title = f"{query.keyword}.2021.1080p.BluRay.x264-{self._site_id.upper()}"
        items = [TorrentListItem(torrent_id=f"{self._site_id}-1", title=title, seeders=10)]
        return SearchResult(items=items, page=query.page, total_pages=1, has_more=False)


class _FakeAccess:
    async def get(self, site_id: str) -> _FakeSite:
        return _FakeSite(site_id)


async def _active_sites():
    return [_Cred(site_id) for site_id in SITES]


site_search._active_sites = _active_sites
site_search.get_site_access = _FakeAccess

app = create_app()


@app.get("/__lab/search-log")
async def get_search_log():
    return search_log


@app.post("/__lab/slow/hold")
async def hold_slow():
    """之后的 slow 搜索都卡住，直到 release。"""
    global _gate
    _gate = asyncio.Event()
    return {"ok": True}


@app.post("/__lab/slow/release")
async def release_slow():
    _slow_gate().set()
    return {"ok": True}
