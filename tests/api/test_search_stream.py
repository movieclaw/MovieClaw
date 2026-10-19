"""SSE 流式搜索端点（GET /search/torrents/stream）的端到端测试。

覆盖：事件序列完整性（start → site_start × N → site_result/site_error × N → done）、
快站先于慢站出结果（流式的核心价值）、单站失败被隔离成 site_error、
以及与阻塞版一致的历史落库行为。站点访问同 test_search 用假实现替换。
"""
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

import movieclaw_api.services.site_search as site_search
from movieclaw_api.core.config import get_settings
from movieclaw_tracker.models import SearchQuery, SearchResult, TorrentListItem


@dataclass
class _Cred:
    site_id: str


class _FakeSite:
    """假站点：可设 delay 模拟慢站，按预设返回结果或抛错。"""

    def __init__(
        self,
        items: list[TorrentListItem] | None = None,
        error: Exception | None = None,
        delay: float = 0.0,
        has_more: bool | None = None,
    ):
        self._items = items or []
        self._error = error
        self._delay = delay
        self._has_more = has_more

    async def search(self, query: SearchQuery) -> SearchResult:
        if self._delay:
            await asyncio.sleep(self._delay)
        if self._error is not None:
            raise self._error
        return SearchResult(
            items=self._items, page=query.page, total_pages=1, has_more=self._has_more
        )


class _FakeManager:
    def __init__(self, sites: dict[str, _FakeSite]):
        self._sites = sites

    async def get(self, site_id: str) -> _FakeSite:
        return self._sites[site_id]


def _item(torrent_id: str, title: str) -> TorrentListItem:
    return TorrentListItem(torrent_id=torrent_id, title=title, seeders=10)


async def _async(value):
    return value


def _wire(monkeypatch, sites: dict[str, _FakeSite]) -> None:
    monkeypatch.setattr(
        site_search, "_active_sites", lambda: _async([_Cred(sid) for sid in sites])
    )
    monkeypatch.setattr(site_search, "get_site_access", lambda: _FakeManager(sites))


def _parse_sse(body: str) -> list[tuple[str, dict]]:
    """把 SSE 响应体解析成 (event, data) 列表，顺序即推送顺序。"""
    events: list[tuple[str, dict]] = []
    for block in body.split("\n\n"):
        if not block.strip():
            continue
        event, data = None, None
        for line in block.splitlines():
            if line.startswith("event: "):
                event = line[len("event: "):]
            elif line.startswith("data: "):
                data = json.loads(line[len("data: "):])
        assert event is not None and data is not None, f"SSE 块格式非法：{block!r}"
        events.append((event, data))
    return events


@pytest.fixture
def client(tmp_path, monkeypatch):
    db_file = tmp_path / "test.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_file}")
    get_settings.cache_clear()

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app) as c:
        yield c
    get_settings.cache_clear()


def test_stream_event_sequence(client: TestClient, monkeypatch) -> None:
    """事件序列完整：start（含站点清单）→ 每站 site_start → 每站结果 → done 汇总。"""
    _wire(
        monkeypatch,
        {
            "mteam": _FakeSite(items=[_item("m1", "沙丘"), _item("m2", "沙丘2")]),
            "ttg": _FakeSite(items=[_item("t1", "沙丘 REMUX")]),
        },
    )

    resp = client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘"})
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/event-stream")

    events = _parse_sse(resp.text)
    names = [e for e, _ in events]

    assert names[0] == "start"
    assert names.count("site_start") == 2
    assert names.count("site_result") == 2
    assert names[-1] == "done"

    start = events[0][1]
    assert start["keyword"] == "沙丘"
    assert {s["site_id"] for s in start["sites"]} == {"mteam", "ttg"}

    results = {d["site_id"]: d for e, d in events if e == "site_result"}
    assert results["mteam"]["count"] == 2
    assert [i["torrent_id"] for i in results["mteam"]["items"]] == ["m1", "m2"]
    # 每条结果带来源站点标识与扩充属性字段（与阻塞版 TorrentHit 同构）
    assert results["ttg"]["items"][0]["site_name"]
    assert "attrs" in results["ttg"]["items"][0]

    done = events[-1][1]
    assert done["total"] == 3
    assert {s["site_id"]: s["count"] for s in done["sites"]} == {"mteam": 2, "ttg": 1}


def test_stream_fast_site_arrives_before_slow(client: TestClient, monkeypatch) -> None:
    """快站先出结果——流式搜索的核心价值：不被最慢的站点拖住。"""
    _wire(
        monkeypatch,
        {
            "slow": _FakeSite(items=[_item("s1", "沙丘")], delay=0.2),
            "fast": _FakeSite(items=[_item("f1", "沙丘")]),
        },
    )

    events = _parse_sse(
        client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘"}).text
    )
    result_order = [d["site_id"] for e, d in events if e == "site_result"]
    assert result_order == ["fast", "slow"]
    # 慢站耗时被如实记录（≥ 人为延迟）
    slow = next(d for e, d in events if e == "site_result" and d["site_id"] == "slow")
    assert slow["elapsed_ms"] >= 200


def test_stream_isolates_single_site_failure(client: TestClient, monkeypatch) -> None:
    """单站失败只产生 site_error 事件，不中断流；done 汇总里记为 error。"""
    _wire(
        monkeypatch,
        {
            "mteam": _FakeSite(items=[_item("m1", "奥本海默")]),
            "ttg": _FakeSite(error=RuntimeError("boom")),
        },
    )

    events = _parse_sse(
        client.get("/api/v1/search/torrents/stream", params={"keyword": "奥本海默"}).text
    )
    names = [e for e, _ in events]
    assert names.count("site_result") == 1
    assert names.count("site_error") == 1
    assert names[-1] == "done"

    error = next(d for e, d in events if e == "site_error")
    assert error["site_id"] == "ttg"
    assert error["error"]  # 可读中文原因非空

    done = events[-1][1]
    assert done["total"] == 1
    statuses = {s["site_id"]: s for s in done["sites"]}
    assert statuses["ttg"]["error"] is not None
    assert statuses["mteam"]["error"] is None


def test_stream_no_active_sites_yields_empty_done(client: TestClient, monkeypatch) -> None:
    """没有可用站点时也走完整序列：start 站点清单为空，直接 done。"""
    _wire(monkeypatch, {})

    events = _parse_sse(
        client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘"}).text
    )
    assert [e for e, _ in events] == ["start", "done"]
    assert events[0][1]["sites"] == []
    assert events[-1][1]["total"] == 0


def test_stream_records_search_history(client: TestClient, monkeypatch) -> None:
    """流式搜索与阻塞版同口径落搜索历史（仅第 1 页）。"""
    _wire(monkeypatch, {"mteam": _FakeSite(items=[_item("m1", "沙丘")])})

    client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘", "label": "电影"})
    client.get(
        "/api/v1/search/torrents/stream",
        params={"keyword": "沙丘", "label": "电影", "page": 2},
    )

    history = client.get("/api/v1/search/history").json()["data"]
    assert len(history) == 1
    assert history[0]["keyword"] == "沙丘"
    assert history[0]["search_count"] == 1  # 第 2 页不重复计数


def test_stream_no_history_skips_recording(client: TestClient, monkeypatch) -> None:
    """无痕搜索（no_history=true）：搜索照常执行，但不写入搜索历史。"""
    _wire(monkeypatch, {"mteam": _FakeSite(items=[_item("m1", "沙丘")])})

    resp = client.get(
        "/api/v1/search/torrents/stream",
        params={"keyword": "沙丘", "label": "隐私分类", "no_history": "true"},
    )
    events = _parse_sse(resp.text)
    assert events[-1][0] == "done"  # 搜索本身正常完成

    assert client.get("/api/v1/search/history").json()["data"] == []


def test_stream_reports_whether_each_site_has_more_pages(
    client: TestClient, monkeypatch
) -> None:
    """站点明确说没有下一页时 done 里带 has_more=False；说不准的站为 null，失败的站也是 null。"""
    _wire(
        monkeypatch,
        {
            "demo": _FakeSite(items=[_item("d1", "Charge")], has_more=False),
            "mteam": _FakeSite(items=[_item("m1", "Charge")]),
            "ttg": _FakeSite(error=RuntimeError("超时")),
        },
    )
    resp = client.get("/api/v1/search/torrents/stream", params={"keyword": "Charge"})
    done = _parse_sse(resp.text)[-1][1]
    assert {s["site_id"]: s["has_more"] for s in done["sites"]} == {
        "demo": False,
        "mteam": None,
        "ttg": None,
    }


class _ByKeywordSite:
    """按关键词返回不同结果的假站点。"""

    def __init__(self, by_keyword: dict[str, list[TorrentListItem]]):
        self._by_keyword = by_keyword

    async def search(self, query: SearchQuery) -> SearchResult:
        return SearchResult(
            items=self._by_keyword.get(query.keyword, []), page=query.page, total_pages=1
        )


def test_stream_also_keywords_merge_into_one_site_result(
    client: TestClient, monkeypatch
) -> None:
    """同搜词不改变事件结构：start 回显清洗后的同搜词，每站仍只一个 site_result（已合并），
    历史记下同搜词，快照回放也带回它们。"""
    _wire(
        monkeypatch,
        {
            "mteam": _ByKeywordSite(
                {"沙丘": [_item("m1", "沙丘")], "Dune": [_item("m1", "沙丘"), _item("m2", "Dune")]}
            )
        },
    )

    resp = client.get(
        "/api/v1/search/torrents/stream",
        params={"keyword": "沙丘", "also_keywords": ["Dune", "沙丘"]},
    )
    events = _parse_sse(resp.text)

    assert events[0][0] == "start"
    assert events[0][1]["also_keywords"] == ["Dune"]
    results = [data for name, data in events if name == "site_result"]
    assert len(results) == 1
    assert results[0]["count"] == 2
    assert events[-1] == ("done", events[-1][1])
    assert events[-1][1]["total"] == 2

    history = client.get("/api/v1/search/history").json()["data"]
    assert history[0]["also_keywords"] == ["Dune"]
    snapshot = client.get(f"/api/v1/search/history/{history[0]['id']}/results").json()["data"]
    assert snapshot["also_keywords"] == ["Dune"]
    assert snapshot["total"] == 2


# ---- 后台运行（#920）：离开页面不作废、同一搜索不重复打站 -----------------------


class _CountingSite(_FakeSite):
    """记录被搜了几次——每次都是一轮真实打站。"""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.calls = 0

    async def search(self, query: SearchQuery) -> SearchResult:
        self.calls += 1
        return await super().search(query)


def _parse_ids(body: str) -> list[int]:
    return [int(line[4:]) for line in body.splitlines() if line.startswith("id: ")]


def _wait_snapshot(client: TestClient, timeout: float = 5.0) -> dict | None:
    """后台运行跑完才写快照：轮询最近一条历史直到它有快照。"""
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rows = client.get("/api/v1/search/history").json()["data"]
        if rows and rows[0]["has_snapshot"]:
            return client.get(f"/api/v1/search/history/{rows[0]['id']}/results").json()["data"]
        time.sleep(0.05)
    return None


def _leave_after(client: TestClient, params: dict[str, str], marker: bytes) -> None:
    """模拟页面中途离开：在应用的事件循环里直接驱动 ASGI，收到 ``marker`` 即发
    ``http.disconnect``。TestClient 会把整个响应读完，测不出「中途断开」。"""
    from urllib.parse import urlencode

    async def drive() -> None:
        leave = asyncio.Event()
        received = b""
        requested = False

        async def receive():
            nonlocal requested
            if not requested:
                requested = True
                return {"type": "http.request", "body": b"", "more_body": False}
            await leave.wait()
            return {"type": "http.disconnect"}

        async def send(message):
            nonlocal received
            if message["type"] == "http.response.body":
                received += message.get("body", b"")
                if marker in received:
                    leave.set()

        scope = {
            "type": "http",
            "asgi": {"version": "3.0", "spec_version": "2.3"},
            "http_version": "1.1",
            "method": "GET",
            "scheme": "http",
            "path": "/api/v1/search/torrents/stream",
            "raw_path": b"/api/v1/search/torrents/stream",
            "query_string": urlencode(params).encode(),
            "root_path": "",
            "headers": [(b"host", b"testserver"), (b"accept", b"text/event-stream")],
            "client": ("testclient", 50000),
            "server": ("testserver", 80),
            "state": {},
        }
        await asyncio.wait_for(client.app(scope, receive, send), timeout=5)
        assert leave.is_set(), "没等到离开的时机"

    client.portal.call(drive)


def test_stream_disconnect_keeps_search_running_and_saves_snapshot(
    client: TestClient, monkeypatch
) -> None:
    """页面中途离开（连接断开）：慢站照常搜完，快照照常回写。"""
    slow = _CountingSite(items=[_item("s1", "沙丘")], delay=0.5)
    _wire(monkeypatch, {"fast": _FakeSite(items=[_item("f1", "沙丘")]), "slow": slow})

    _leave_after(client, {"keyword": "沙丘"}, b"event: site_result")  # 快站结果到了就离开

    snapshot = _wait_snapshot(client)
    assert snapshot is not None, "断开后搜索应在后台跑完并写快照"
    assert {i["torrent_id"] for i in snapshot["items"]} == {"f1", "s1"}
    assert slow.calls == 1
    # 回到搜索页：接上已跑完的这次，完整回放且不再打站
    events = _parse_sse(
        client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘"}).text
    )
    assert [e for e, _ in events].count("site_result") == 2
    assert slow.calls == 1


def test_stream_same_search_reuses_run_without_hitting_sites_again(
    client: TestClient, monkeypatch
) -> None:
    """回到搜索页 / 刷新：同一个搜索直接回放上次的完整事件，不重新打站，也不重复计历史。"""
    site = _CountingSite(items=[_item("m1", "沙丘")])
    _wire(monkeypatch, {"mteam": site})

    first = client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘"}).text
    again = client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘"}).text

    assert site.calls == 1
    assert _parse_sse(again) == _parse_sse(first)
    assert _parse_ids(again) == list(range(1, len(_parse_sse(first)) + 1))
    assert client.get("/api/v1/search/history").json()["data"][0]["search_count"] == 1

    # 范围不同就是另一个搜索
    client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘", "page": 2})
    assert site.calls == 2


def test_stream_fresh_searches_again(client: TestClient, monkeypatch) -> None:
    """fresh（重新搜索 / 单站重试）：不复用刚跑完的结果，重新打站并计一次历史。"""
    site = _CountingSite(items=[_item("m1", "沙丘")])
    _wire(monkeypatch, {"mteam": site})

    client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘"})
    events = _parse_sse(
        client.get(
            "/api/v1/search/torrents/stream", params={"keyword": "沙丘", "fresh": "true"}
        ).text
    )
    assert site.calls == 2
    assert events[-1][0] == "done"
    assert client.get("/api/v1/search/history").json()["data"][0]["search_count"] == 2


def test_stream_resumes_after_last_event_id(client: TestClient, monkeypatch) -> None:
    """断线重连带 Last-Event-ID：只补发其后的事件，不重复已收到的结果。"""
    _wire(
        monkeypatch,
        {
            "mteam": _FakeSite(items=[_item("m1", "沙丘")]),
            "ttg": _FakeSite(items=[_item("t1", "沙丘")]),
        },
    )
    full = client.get("/api/v1/search/torrents/stream", params={"keyword": "沙丘"}).text
    resumed = client.get(
        "/api/v1/search/torrents/stream",
        params={"keyword": "沙丘"},
        headers={"Last-Event-ID": "3"},
    ).text

    assert _parse_ids(resumed) == _parse_ids(full)[3:]
    assert _parse_sse(resumed) == _parse_sse(full)[3:]
