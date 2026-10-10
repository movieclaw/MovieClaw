"""跨站点聚合搜索接口的端到端测试。

覆盖：多站结果合并、单站失败被隔离成 error、分类过滤参数透传、
关键词留空时改走站点种子浏览页（浏览模式）。
站点访问（活跃站点列表 + 站点实例）被替换为「假实现」，不触库、不发真实网络请求，
使断言可确定。「只搜已启用且验证通过的站点」这条判据与种子同步共用同一实现
（_active_sites），此处不重复覆盖，只覆盖搜索本身的合并与隔离逻辑。
"""
from __future__ import annotations

from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

import movieclaw_api.services.site_search as site_search
from movieclaw_api.core.config import get_settings
from movieclaw_tracker.models import (
    SearchQuery,
    SearchResult,
    TorrentCategory,
    TorrentListItem,
    TorrentListPage,
)


@dataclass
class _Cred:
    """_active_sites 返回值的最小替身——搜索链路只用到 site_id。"""

    site_id: str


class _FakeSite:
    """假站点：记录收到的搜索/浏览参数，按预设返回结果或抛错。"""

    def __init__(self, items: list[TorrentListItem] | None = None, error: Exception | None = None):
        self._items = items or []
        self._error = error
        self.last_query: SearchQuery | None = None
        # 浏览模式收到的参数（分类, 页码）；未被浏览过为 None
        self.last_browse: tuple[list[TorrentCategory] | None, int] | None = None

    async def search(self, query: SearchQuery) -> SearchResult:
        self.last_query = query
        if self._error is not None:
            raise self._error
        return SearchResult(items=self._items, page=query.page, total_pages=1)

    async def list_torrents(
        self,
        *,
        categories: list[TorrentCategory] | None = None,
        page: int = 1,
    ) -> TorrentListPage:
        self.last_browse = (categories, page)
        if self._error is not None:
            raise self._error
        return TorrentListPage(items=self._items, page=page, total_pages=1)


class _FakeManager:
    """假站点访问管理器：按 site_id 返回预设的 _FakeSite。"""

    def __init__(self, sites: dict[str, _FakeSite]):
        self._sites = sites

    async def get(self, site_id: str) -> _FakeSite:
        return self._sites[site_id]


def _item(torrent_id: str, title: str) -> TorrentListItem:
    return TorrentListItem(torrent_id=torrent_id, title=title, seeders=10)


def _wire(monkeypatch, sites: dict[str, _FakeSite]) -> None:
    """把「活跃站点」与「站点实例来源」都替换成假实现。"""
    monkeypatch.setattr(
        site_search, "_active_sites", lambda: _async([_Cred(sid) for sid in sites])
    )
    monkeypatch.setattr(site_search, "get_site_access", lambda: _FakeManager(sites))


async def _async(value):
    return value


@pytest.fixture
def client(tmp_path, monkeypatch):
    db_file = tmp_path / "test.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_file}")
    get_settings.cache_clear()

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    # 本文件只测搜索业务，登录鉴权用依赖覆盖绕过（鉴权本身在 test_auth 覆盖）
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app) as c:  # with 块内触发 lifespan：建库、迁移、加载站点目录
        yield c
    get_settings.cache_clear()


def test_search_merges_results_across_sites(client: TestClient, monkeypatch) -> None:
    _wire(
        monkeypatch,
        {
            "mteam": _FakeSite(items=[_item("m1", "沙丘"), _item("m2", "沙丘2")]),
            "ttg": _FakeSite(items=[_item("t1", "沙丘 REMUX")]),
        },
    )

    data = client.get("/api/v1/search/torrents", params={"keyword": "沙丘"}).json()["data"]

    assert data["total"] == 3
    assert {i["site_id"] for i in data["items"]} == {"mteam", "ttg"}
    # 每条结果都带上了来源站点展示名
    assert all(i["site_name"] for i in data["items"])
    assert {s["site_id"]: s["count"] for s in data["sites"]} == {"mteam": 2, "ttg": 1}


def test_search_isolates_single_site_failure(client: TestClient, monkeypatch) -> None:
    _wire(
        monkeypatch,
        {
            "mteam": _FakeSite(items=[_item("m1", "奥本海默")]),
            "ttg": _FakeSite(error=RuntimeError("boom")),  # 该站崩溃
        },
    )

    data = client.get("/api/v1/search/torrents", params={"keyword": "奥本海默"}).json()["data"]

    # 失败站点不拖垮整体：正常站仍有结果，失败站记 error
    assert data["total"] == 1
    statuses = {s["site_id"]: s for s in data["sites"]}
    assert statuses["mteam"]["error"] is None
    assert statuses["ttg"]["error"] is not None
    assert statuses["ttg"]["count"] == 0


def test_search_passes_multi_category_filter(client: TestClient, monkeypatch) -> None:
    fake_site = _FakeSite(items=[_item("m1", "老友记")])
    _wire(monkeypatch, {"mteam": fake_site})

    resp = client.get(
        "/api/v1/search/torrents",
        params={"keyword": "老友记", "categories": ["tv", "documentary"], "label": "剧集"},
    )
    assert resp.status_code == 200
    # 分类组合原样透传给站点的 SearchQuery（tracker 层原生支持多分类）
    assert fake_site.last_query is not None
    assert [c.value for c in fake_site.last_query.categories] == ["tv", "documentary"]
    assert resp.json()["data"]["categories"] == ["tv", "documentary"]
    assert resp.json()["data"]["label"] == "剧集"


def test_search_filters_site_subset(client: TestClient, monkeypatch) -> None:
    """sites 参数圈定站点子集：只搜勾选的站点，未勾选的不出现在逐站状态里。"""
    mteam, ttg = _FakeSite(items=[_item("m1", "沙丘")]), _FakeSite(items=[_item("t1", "沙丘")])
    _wire(monkeypatch, {"mteam": mteam, "ttg": ttg})

    data = client.get(
        "/api/v1/search/torrents", params={"keyword": "沙丘", "sites": ["mteam"]}
    ).json()["data"]

    assert [s["site_id"] for s in data["sites"]] == ["mteam"]
    assert data["total"] == 1
    assert ttg.last_query is None  # 未勾选的站点根本没被请求


def test_search_unknown_site_subset_yields_empty(client: TestClient, monkeypatch) -> None:
    """勾选的站点全部不可用/不存在时返回空结果，而非报错（与逐站失败隔离口径一致）。"""
    _wire(monkeypatch, {"mteam": _FakeSite(items=[_item("m1", "沙丘")])})

    data = client.get(
        "/api/v1/search/torrents", params={"keyword": "沙丘", "sites": ["ttg"]}
    ).json()["data"]
    assert data["total"] == 0
    assert data["sites"] == []


def test_browse_without_keyword_hits_torrent_list_page(client: TestClient, monkeypatch) -> None:
    """不传关键词 = 浏览模式：走站点的种子列表页而非搜索页，分类与页码照常透传。"""
    fake_site = _FakeSite(items=[_item("m1", "最新发布")])
    _wire(monkeypatch, {"mteam": fake_site})

    data = client.get(
        "/api/v1/search/torrents", params={"categories": ["movie"], "page": 2}
    ).json()["data"]

    assert data["total"] == 1
    assert data["keyword"] == ""
    assert fake_site.last_query is None  # 没有发起搜索
    assert fake_site.last_browse is not None
    categories, page = fake_site.last_browse
    assert [c.value for c in categories] == ["movie"]
    assert page == 2


def test_blank_keyword_is_treated_as_browse(client: TestClient, monkeypatch) -> None:
    """只有空白的关键词等同于不传（前端 URL 残留 q= 时不该退化成搜空串）。"""
    fake_site = _FakeSite(items=[_item("m1", "最新发布")])
    _wire(monkeypatch, {"mteam": fake_site})

    resp = client.get("/api/v1/search/torrents", params={"keyword": "   "})

    assert resp.status_code == 200
    assert fake_site.last_query is None
    assert fake_site.last_browse is not None


def test_browse_is_not_recorded_in_history(client: TestClient, monkeypatch) -> None:
    """浏览不是可复现的搜索，不该占用搜索历史。"""
    _wire(monkeypatch, {"mteam": _FakeSite(items=[_item("m1", "最新发布")])})

    client.get("/api/v1/search/torrents", params={"categories": ["movie"]})

    history = client.get("/api/v1/search/history").json()["data"]
    assert history == []


def test_search_rejects_invalid_category(client: TestClient) -> None:
    r = client.get("/api/v1/search/torrents", params={"keyword": "x", "categories": "不存在"})
    assert r.status_code == 422


async def test_search_offloads_enrichment_to_worker_thread(monkeypatch) -> None:
    """单站结果的扩充必须在工作线程执行——enrich 含同步 NER 推理，在事件循环
    里内联算会卡住 SSE 流、健康检查与其它并发请求（口径与种子同步侧一致）。"""
    import threading

    caller_thread = threading.get_ident()
    worker_threads: list[int] = []
    real_enrich = site_search.enrich

    def spy_enrich(title, subtitle="", category=None):
        worker_threads.append(threading.get_ident())
        return real_enrich(title, subtitle, category)

    monkeypatch.setattr(site_search, "enrich", spy_enrich)
    fake_sites = {"mteam": _FakeSite(items=[_item("m1", "沙丘"), _item("m2", "沙丘2")])}
    monkeypatch.setattr(site_search, "get_site_access", lambda: _FakeManager(fake_sites))

    hits, status = await site_search._fetch_one(_Cred("mteam"), keyword="沙丘")

    assert status.error is None
    assert len(hits) == 2
    assert worker_threads
    assert all(thread_id != caller_thread for thread_id in worker_threads)


def test_search_items_carry_enriched_attrs(client: TestClient, monkeypatch) -> None:
    """搜索结果的每条种子都带数据扩充层产出的结构化属性（端到端）。"""
    rich_item = TorrentListItem(
        torrent_id="d1",
        title="Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.HEVC.DV.HDR10.Atmos-CHD",
        subtitle="沙丘2：预言实现 | 国语中字",
    )
    _wire(monkeypatch, {"mteam": _FakeSite(items=[rich_item])})

    data = client.get("/api/v1/search/torrents", params={"keyword": "dune"}).json()["data"]

    attrs = data["items"][0]["attrs"]
    assert attrs["year"] == 2024
    assert attrs["resolution"] == "2160p"
    assert attrs["media_source"] == "UHD Blu-ray"
    assert attrs["remux"] is True
    assert attrs["video_codec"] == "HEVC"
    assert set(attrs["hdr"]) == {"DV", "HDR10"}
    assert "Atmos" in attrs["audio"]
    assert attrs["release_group"] == "CHD"
    # H&R 未配置选择器时保持三态里的"未知"，不误报成"无考核"
    assert data["items"][0]["hit_and_run"] is None


class _ByKeywordSite:
    """按关键词返回不同结果的假站点；``fail`` 里的词抛错。记录收到的关键词顺序。"""

    def __init__(
        self,
        by_keyword: dict[str, list[TorrentListItem]],
        fail: set[str] | None = None,
        has_more: dict[str, bool | None] | None = None,
    ):
        self._by_keyword = by_keyword
        self._fail = fail or set()
        self._has_more = has_more or {}
        self.keywords: list[str] = []

    async def search(self, query: SearchQuery) -> SearchResult:
        self.keywords.append(query.keyword)
        if query.keyword in self._fail:
            raise RuntimeError("boom")
        return SearchResult(
            items=self._by_keyword.get(query.keyword, []),
            page=query.page,
            total_pages=1,
            has_more=self._has_more.get(query.keyword),
        )


def test_also_keywords_are_searched_per_site_and_merged(client: TestClient, monkeypatch) -> None:
    """详情页带英文名/原名同搜：每站依次搜每个词，同一种子只留一条，合并成该站一份结果。"""
    mteam = _ByKeywordSite(
        {
            "沙丘": [_item("m1", "沙丘 Dune 2021")],
            "Dune": [_item("m1", "沙丘 Dune 2021"), _item("m2", "Dune.2021.2160p")],
        }
    )
    # 只认英文名的站：主词零结果，靠同搜词召回
    english_only = _ByKeywordSite({"Dune": [_item("e1", "Dune.2021.1080p")]})
    _wire(monkeypatch, {"mteam": mteam, "ttg": english_only})

    data = client.get(
        "/api/v1/search/torrents",
        params={"keyword": "沙丘", "also_keywords": ["Dune", "Dune"]},
    ).json()["data"]

    assert mteam.keywords == ["沙丘", "Dune"]
    assert english_only.keywords == ["沙丘", "Dune"]
    assert data["also_keywords"] == ["Dune"]
    assert sorted(i["torrent_id"] for i in data["items"]) == ["e1", "m1", "m2"]
    assert {s["site_id"]: s["count"] for s in data["sites"]} == {"mteam": 2, "ttg": 1}


def test_also_keywords_are_deduped_against_keyword_and_capped(
    client: TestClient, monkeypatch
) -> None:
    """按归一化形式去重（大小写/分隔符不同不算新词），与主词重复的丢掉，连主词至多 3 个。"""
    site = _ByKeywordSite({})
    _wire(monkeypatch, {"mteam": site})

    data = client.get(
        "/api/v1/search/torrents",
        params={
            "keyword": "Dune Part Two",
            "also_keywords": ["dune.part.two", " ", "沙丘2", "Dune: Deux", "第四个词"],
        },
    ).json()["data"]

    assert data["also_keywords"] == ["沙丘2", "Dune: Deux"]
    assert site.keywords == ["Dune Part Two", "沙丘2", "Dune: Deux"]


def test_also_keywords_partial_failure_keeps_site_ok(client: TestClient, monkeypatch) -> None:
    """一个词失败、别的词成功：该站算成功；所有词都失败才降级为该站失败。"""
    partial = _ByKeywordSite({"沙丘": [_item("p1", "沙丘")]}, fail={"Dune"})
    broken = _ByKeywordSite({}, fail={"沙丘", "Dune"})
    _wire(monkeypatch, {"mteam": partial, "ttg": broken})

    data = client.get(
        "/api/v1/search/torrents", params={"keyword": "沙丘", "also_keywords": ["Dune"]}
    ).json()["data"]

    statuses = {s["site_id"]: s for s in data["sites"]}
    assert statuses["mteam"]["error"] is None
    assert statuses["mteam"]["count"] == 1
    assert statuses["ttg"]["error"] is not None
    assert statuses["ttg"]["count"] == 0
    assert broken.keywords == ["沙丘", "Dune"]


def test_also_keywords_has_more_is_true_if_any_keyword_has_more(
    client: TestClient, monkeypatch
) -> None:
    """翻页口径：任一个词还有下一页就是 True；没有 True 但有不确定的就是 None。"""
    _wire(
        monkeypatch,
        {
            "mteam": _ByKeywordSite({}, has_more={"沙丘": False, "Dune": True}),
            "ttg": _ByKeywordSite({}, has_more={"沙丘": False, "Dune": None}),
            "hdsky": _ByKeywordSite({}, has_more={"沙丘": False, "Dune": False}),
        },
    )

    data = client.get(
        "/api/v1/search/torrents", params={"keyword": "沙丘", "also_keywords": ["Dune"]}
    ).json()["data"]

    assert {s["site_id"]: s["has_more"] for s in data["sites"]} == {
        "mteam": True,
        "ttg": None,
        "hdsky": False,
    }


def test_browse_ignores_also_keywords(client: TestClient, monkeypatch) -> None:
    site = _FakeSite(items=[_item("b1", "最新")])
    _wire(monkeypatch, {"mteam": site})

    data = client.get(
        "/api/v1/search/torrents", params={"keyword": "", "also_keywords": ["Dune"]}
    ).json()["data"]

    assert site.last_query is None
    assert site.last_browse is not None
    assert data["also_keywords"] is None
