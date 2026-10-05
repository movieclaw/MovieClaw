"""影视条目搜索历史（公开 vertical=titles）的端到端测试。

覆盖：/search/titles 的 save_history 开关、影视历史的语义化类型与结果快照、
影视/种子同关键词互不去重，以及统一结果端点的类型判别字段。
豆瓣服务用假实现替换，不出网。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_media.models import MediaSearchItem, MediaSource


@pytest.fixture
def client(tmp_path, monkeypatch):
    db_file = tmp_path / "test.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_file}")
    get_settings.cache_clear()

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services import media_discover
    from movieclaw_api.services.auth import Principal

    app = create_app()
    # 本文件只测历史业务：登录鉴权用依赖覆盖绕过（鉴权本身在 test_auth 覆盖）
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    # 豆瓣搜索换成假实现：固定返回两条候选
    monkeypatch.setattr(media_discover, "get_douban_media_service", lambda: _StubDouban())
    with TestClient(app) as c:  # with 块内触发 lifespan：建库、迁移
        yield c
    get_settings.cache_clear()


class _StubDouban:
    async def search(self, keyword: str) -> list[MediaSearchItem]:
        return [
            MediaSearchItem(
                id="1",
                source=MediaSource.DOUBAN,
                title=f"{keyword} 2",
                rating=8.3,
                poster_url="https://img.douban/a.jpg",
            ),
            MediaSearchItem(
                id="2",
                source=MediaSource.DOUBAN,
                title=keyword,
                rating=7.9,
                poster_url="https://img.douban/b.jpg",
            ),
        ]


def _history(client: TestClient) -> list[dict]:
    resp = client.get("/api/v1/search/history")
    assert resp.status_code == 200
    return resp.json()["data"]


def _search_titles(client: TestClient, query: str, save_history: bool = True):
    resp = client.post(
        "/api/v1/search/titles",
        json={"query": query, "provider": "douban", "save_history": save_history},
    )
    assert resp.status_code == 200
    return resp.json()["data"]


def test_title_search_records_history_with_results(client: TestClient) -> None:
    _search_titles(client, "沙丘")

    items = _history(client)
    assert len(items) == 1
    assert items[0]["keyword"] == "沙丘"
    assert items[0]["vertical"] == "titles"
    # 媒体搜索没有分类/站点维度
    assert items[0]["categories"] == []
    assert items[0]["site_ids"] == []
    assert items[0]["has_snapshot"] is True


def test_title_search_without_flag_not_recorded(client: TestClient) -> None:
    """调用方明确不保存时，不产生历史记录。"""
    _search_titles(client, "沙丘", save_history=False)
    assert _history(client) == []


def test_title_results_roundtrip(client: TestClient) -> None:
    _search_titles(client, "沙丘")
    history_id = _history(client)[0]["id"]

    resp = client.get(f"/api/v1/search/history/{history_id}/results")
    assert resp.status_code == 200
    snap = resp.json()["data"]
    assert snap["vertical"] == "titles"
    assert snap["keyword"] == "沙丘"
    assert snap["total"] == 2
    assert snap["items"][0]["title"] == "沙丘 2"
    assert snap["items"][0]["poster_url"] == "https://img.douban/a.jpg"
    assert snap["snapshot_at"].endswith("+00:00")


def test_titles_and_torrents_history_kept_apart(client: TestClient) -> None:
    """同一关键词分别搜影视和种子是两条独立历史，重复影视搜索只累加计数。"""
    _search_titles(client, "沙丘")
    _search_titles(client, "沙丘")
    # 资源搜索（测试环境无站点，结果为空，但历史照记）
    client.get("/api/v1/search/torrents", params={"keyword": "沙丘"})

    items = _history(client)
    assert len(items) == 2
    by_vertical = {i["vertical"]: i for i in items}
    assert by_vertical["titles"]["search_count"] == 2
    assert by_vertical["torrents"]["search_count"] == 1


def test_unified_results_endpoint_discriminates_vertical(client: TestClient) -> None:
    """同一个结果端点按 vertical 返回可判别的影视或种子结构。"""
    _search_titles(client, "沙丘")
    client.get("/api/v1/search/torrents", params={"keyword": "奥本海默"})
    items = {i["vertical"]: i for i in _history(client)}

    title_result = client.get(f"/api/v1/search/history/{items['titles']['id']}/results").json()[
        "data"
    ]
    torrent_result = client.get(f"/api/v1/search/history/{items['torrents']['id']}/results").json()[
        "data"
    ]
    assert title_result["vertical"] == "titles"
    assert torrent_result["vertical"] == "torrents"


@pytest.mark.parametrize("vertical", ["titles", "torrents"])
def test_history_limit_applies_within_vertical(client: TestClient, vertical: str) -> None:
    """先按搜索类型过滤再取最近组，同词的其他类型与更新的记录都不能混入。"""
    _search_titles(client, "沙丘")
    client.get("/api/v1/search/torrents", params={"keyword": "沙丘"})
    client.get(
        "/api/v1/search/torrents",
        params={"keyword": "沙丘", "categories": ["movie"]},
    )
    if vertical == "titles":
        client.get("/api/v1/search/torrents", params={"keyword": "星际穿越"})
    else:
        _search_titles(client, "星际穿越")

    resp = client.get("/api/v1/search/history", params={"vertical": vertical, "limit": 1})
    assert resp.status_code == 200
    items = resp.json()["data"]
    assert len(items) == (1 if vertical == "titles" else 2)
    assert {item["keyword"] for item in items} == {"沙丘"}
    assert {item["vertical"] for item in items} == {vertical}


@pytest.mark.parametrize("vertical", ["titles", "torrents"])
def test_clear_history_only_removes_current_vertical(client: TestClient, vertical: str) -> None:
    """清空包含未在最近列表展示的记录，但保留另一个搜索类型的历史与快照。"""
    _search_titles(client, "沙丘")
    _search_titles(client, "星际穿越")
    client.get("/api/v1/search/torrents", params={"keyword": "沙丘"})
    client.get("/api/v1/search/torrents", params={"keyword": "奥本海默"})

    resp = client.delete("/api/v1/search/history", params={"vertical": vertical})
    assert resp.status_code == 200
    assert resp.json()["message"] == "已清空 2 条搜索历史"
    items = _history(client)
    assert len(items) == 2
    assert all(item["vertical"] != vertical for item in items)
    for item in items:
        assert client.get(f"/api/v1/search/history/{item['id']}/results").status_code == 200


@pytest.mark.parametrize("method", ["get", "delete"])
def test_history_rejects_unsupported_vertical(client: TestClient, method: str) -> None:
    """媒体库不记录历史；无效类型不能悄悄退化成查询或清空全部。"""
    _search_titles(client, "沙丘")
    resp = getattr(client, method)("/api/v1/search/history", params={"vertical": "library"})
    assert resp.status_code == 422
    assert len(_history(client)) == 1
