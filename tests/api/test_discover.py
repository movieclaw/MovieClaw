"""发现页接口的端到端测试：鉴权集成、成功链路、未配置 Key 的引导错误。"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.services.media_discover import reset_media_service
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_media import TmdbNetworkError
from movieclaw_media.models import (
    DiscoverLayout,
    DiscoverRowStub,
    MediaCard,
    MediaCastMember,
    MediaCollection,
    MediaDetail,
    MediaFacts,
    MediaKind,
    MediaPage,
    MediaPersonDetail,
    MediaRow,
    MediaSearchItem,
    MediaSource,
    MediaVideo,
)


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    # 显式置空以覆盖代码内置的默认 Key：用例需要「未配置」状态且不许出网
    monkeypatch.setenv("TMDB_API_KEY", "")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    reset_media_service()

    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app, headers={"Accept-Language": "zh-Hans"}) as c:
        # 建号即自动登录，后续请求携带会话 Cookie
        c.post(
            "/api/v1/auth/bootstrap",
            json={"username": "admin", "password": "s3cret-pass"},
        )
        yield c

    reset_media_service()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def _sample_card() -> MediaCard:
    return MediaCard(
        id="42",
        type=MediaKind.MOVIE,
        title="示例电影",
        original_title="Sample",
        year=2026,
        rating=8.0,
        genres=["科幻"],
        overview="……",
        poster_url="https://image.tmdb.org/t/p/w500/x.jpg",
        backdrop_url="https://image.tmdb.org/t/p/w1280/y.jpg",
    )


class _StubService:
    def layout(self, kind: MediaKind) -> DiscoverLayout:
        return DiscoverLayout(
            has_hero=True,
            rows=[DiscoverRowStub(id="popular", title="热门电影")],
        )

    async def discover_hero(self, kind: MediaKind) -> list[MediaCard]:
        return [_sample_card()]

    async def discover_row(self, kind: MediaKind, row_id: str) -> MediaRow | None:
        if row_id != "popular":
            return None
        return MediaRow(id="popular", title="热门电影", items=[_sample_card()])

    async def search(self, keyword: str) -> list[MediaSearchItem]:
        return [
            MediaSearchItem(
                id="26266893",
                source=MediaSource.DOUBAN,
                title=keyword,
                rating=7.9,
                poster_url="https://img3.doubanio.com/a.jpg",
            )
        ]

    async def media_detail(self, douban_id: str):
        card = _sample_card()
        card.id = douban_id
        return MediaDetail(
            card=card,
            facts=MediaFacts(aliases=["示例别名"], source_url="https://m.douban.com/"),
        )


class _StubTmdbService(_StubService):
    """新 Discover 领域接口用的 TMDB 桩，签名与真实 provider 保持一致。"""

    async def search(self, keyword: str) -> list[MediaSearchItem]:
        return [
            MediaSearchItem(
                id="438631",
                source=MediaSource.TMDB,
                type=MediaKind.MOVIE,
                title=keyword,
                year=2021,
                rating=8.1,
                poster_url="https://image.tmdb.org/t/p/w342/dune.jpg",
            )
        ]

    async def discover_page(
        self, kind: MediaKind, row_id: str, page: int = 1
    ) -> MediaPage | None:
        if row_id != "popular":
            return None
        card = _sample_card()
        card.type = kind
        return MediaPage(
            id=row_id,
            title="热门电影",
            items=[card],
            page=page,
            total_pages=3,
            total_results=41,
        )

    async def discovery_genres(self, kind: MediaKind) -> dict[int, str]:
        return {878: "科幻", 28: "动作"}

    async def discover_filtered(self, kind: MediaKind, **kwargs) -> MediaPage:
        card = _sample_card()
        card.type = kind
        return MediaPage(
            id="filtered",
            title="筛选结果",
            items=[card],
            page=kwargs["page"],
            total_pages=2,
            total_results=21,
        )

    async def media_detail(self, kind: MediaKind, tmdb_id: int) -> MediaDetail:
        card = _sample_card()
        card.id = str(tmdb_id)
        card.type = kind
        series_card = _sample_card()
        series_card.id = "43"
        return MediaDetail(
            card=card,
            facts=MediaFacts(
                directors=["示例导演"],
                director_credits=[
                    MediaCastMember(
                        name="示例导演",
                        avatar_url="https://image.tmdb.org/t/p/w185/director.jpg",
                        tmdb_person_id=99,
                    )
                ],
                aliases=["示例别名"],
                source_url="https://www.themoviedb.org/",
            ),
            videos=[
                MediaVideo(
                    key="abc123",
                    name="正式预告",
                    kind="预告片",
                    thumbnail_url="https://i.ytimg.com/vi/abc123/hqdefault.jpg",
                    embed_url="https://www.youtube-nocookie.com/embed/abc123",
                    watch_url="https://www.youtube.com/watch?v=abc123",
                )
            ],
            collection=MediaCollection(id="7", name="示例系列", items=[card, series_card]),
        )

    async def person_detail(self, tmdb_person_id: int) -> MediaPersonDetail:
        movie = _sample_card()
        tv = _sample_card()
        tv.id = "77"
        tv.type = MediaKind.TV
        tv.title = "示例剧集"
        return MediaPersonDetail(
            tmdb_person_id=tmdb_person_id,
            name="示例影人",
            avatar_url="https://image.tmdb.org/t/p/w300/person.jpg",
            credits=[movie, tv],
        )


class _StubDoubanService(_StubService):
    """新 Discover 领域接口用的豆瓣桩。"""

    async def full_collection(self, collection_id: str) -> MediaRow:
        return MediaRow(
            id=collection_id,
            title="完整榜单",
            items=[_sample_card()],
        )


def _patch_title_discovery_providers(monkeypatch) -> None:
    """替换领域服务懒加载的两个 provider，保证新接口测试不出网。"""
    from movieclaw_api.services import media_discover

    monkeypatch.setattr(media_discover, "get_media_service", lambda: _StubTmdbService())
    monkeypatch.setattr(media_discover, "get_douban_media_service", lambda: _StubDoubanService())


def test_search_titles_without_key_returns_guidance(client: TestClient) -> None:
    """TMDB 未配置 Key 时，统一搜索返回中文配置引导。"""
    resp = client.post(
        "/api/v1/search/titles",
        json={"query": "沙丘", "provider": "tmdb", "save_history": False},
    )
    assert resp.status_code == 502
    assert "TMDB_API_KEY" in resp.json()["message"]


def test_discovery_ui_rejects_unknown_media_type(client: TestClient) -> None:
    """展示编排只接受 movie / tv，其余按参数校验拒绝。"""
    assert client.get("/api/v1/ui/discovery/book").status_code == 422


# ---------------------------------------------------------------------------
# 新 Discover 领域契约：片单、统一搜索、稳定引用与详情
# ---------------------------------------------------------------------------


def test_list_collections_returns_stable_refs(client: TestClient, monkeypatch) -> None:
    _patch_title_discovery_providers(monkeypatch)

    resp = client.get(
        "/api/v1/discover/collections",
        params={"media_type": "movie", "provider": "tmdb"},
    )

    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["provider"] == "tmdb"
    assert [item["collection_ref"] for item in data["collections"]] == [
        "tmdb:movie:featured-weekly",
        "tmdb:movie:popular",
    ]
    assert data["collections"][0]["name"] == "本周精选"


def test_browse_collection_returns_titles_with_stable_refs(
    client: TestClient, monkeypatch
) -> None:
    _patch_title_discovery_providers(monkeypatch)

    resp = client.get(
        "/api/v1/discover/collections/tmdb:movie:popular/titles",
        params={"limit": 20},
    )

    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["collection"]["collection_ref"] == "tmdb:movie:popular"
    assert data["titles"][0]["title_ref"] == "tmdb:movie:42"
    assert data["titles"][0]["external_id"] == "42"
    assert data["returned_count"] == 1
    assert data["page"] == 1
    assert data["total_pages"] == 3
    assert data["total_results"] == 41
    assert data["has_more"] is True


def test_filter_options_and_combined_discovery(client: TestClient, monkeypatch) -> None:
    _patch_title_discovery_providers(monkeypatch)

    options = client.get("/api/v1/discover/filters", params={"media_type": "movie"})
    assert options.status_code == 200, options.text
    assert options.json()["data"]["genres"] == [
        {"id": 878, "name": "科幻"},
        {"id": 28, "name": "动作"},
    ]

    result = client.get(
        "/api/v1/discover/titles",
        params=[
            ("media_type", "movie"),
            ("genre_ids", "878"),
            ("genre_ids", "28"),
            ("origin_country", "jp"),
            ("year", "2025"),
            ("rating_gte", "7"),
            ("runtime_lte", "90"),
            ("sort", "rating"),
            ("page", "1"),
        ],
    )
    assert result.status_code == 200, result.text
    data = result.json()["data"]
    assert data["titles"][0]["title_ref"] == "tmdb:movie:42"
    assert data["total_results"] == 21
    assert data["has_more"] is True


def test_search_titles_combines_providers_and_returns_refs(
    client: TestClient, monkeypatch
) -> None:
    _patch_title_discovery_providers(monkeypatch)

    resp = client.post(
        "/api/v1/search/titles",
        json={"query": "沙丘", "provider": "all", "save_history": False},
    )

    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert {item["title_ref"] for item in data["titles"]} == {
        "tmdb:movie:438631",
        "douban:26266893",
    }
    assert data["providers"] == [
        {"provider": "douban", "success": True, "result_count": 1, "message": None},
        {"provider": "tmdb", "success": True, "result_count": 1, "message": None},
    ]


def test_search_titles_can_save_one_combined_history(client: TestClient, monkeypatch) -> None:
    _patch_title_discovery_providers(monkeypatch)

    resp = client.post(
        "/api/v1/search/titles",
        json={"query": "沙丘", "provider": "all", "save_history": True},
    )

    assert resp.status_code == 200, resp.text
    history_id = resp.json()["data"]["history_id"]
    assert isinstance(history_id, int)
    results = client.get(f"/api/v1/search/history/{history_id}/results")
    assert results.status_code == 200, results.text
    assert results.json()["data"]["vertical"] == "titles"
    assert {item["source"] for item in results.json()["data"]["items"]} == {
        "tmdb",
        "douban",
    }


def test_search_titles_preserves_successful_provider_on_partial_failure(
    client: TestClient, monkeypatch
) -> None:
    from movieclaw_api.services import media_discover

    class _UnavailableTmdb(_StubTmdbService):
        async def search(self, keyword: str) -> list[MediaSearchItem]:
            raise TmdbNetworkError("TMDB 暂时不可达")

    monkeypatch.setattr(media_discover, "get_media_service", lambda: _UnavailableTmdb())
    monkeypatch.setattr(media_discover, "get_douban_media_service", lambda: _StubDoubanService())

    resp = client.post(
        "/api/v1/search/titles",
        json={"query": "沙丘", "provider": "all"},
    )

    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert [item["title_ref"] for item in data["titles"]] == ["douban:26266893"]
    assert data["providers"][1] == {
        "provider": "tmdb",
        "success": False,
        "result_count": 0,
        "message": "TMDB 暂时不可达",
    }


def test_get_title_details_consumes_title_ref(client: TestClient, monkeypatch) -> None:
    _patch_title_discovery_providers(monkeypatch)

    resp = client.get("/api/v1/discover/titles/tmdb:movie:438631")

    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["title"]["title_ref"] == "tmdb:movie:438631"
    assert data["metadata"]["aliases"] == ["示例别名"]
    assert data["metadata"]["director_credits"] == [
        {
            "name": "示例导演",
            "role": None,
            "avatar_url": "https://image.tmdb.org/t/p/w185/director.jpg",
            "tmdb_person_id": 99,
        }
    ]
    # 预告片原样透出：播放地址由后端拼好，前端不再拼接 YouTube URL
    assert data["videos"] == [
        {
            "key": "abc123",
            "name": "正式预告",
            "kind": "预告片",
            "thumbnail_url": "https://i.ytimg.com/vi/abc123/hqdefault.jpg",
            "embed_url": "https://www.youtube-nocookie.com/embed/abc123",
            "watch_url": "https://www.youtube.com/watch?v=abc123",
        }
    ]
    assert data["collection"]["name"] == "示例系列"
    assert [item["title_ref"] for item in data["collection"]["titles"]] == [
        "tmdb:movie:438631",
        "tmdb:movie:43",
    ]


def test_get_person_details_returns_complete_tmdb_titles(
    client: TestClient, monkeypatch
) -> None:
    _patch_title_discovery_providers(monkeypatch)

    resp = client.get("/api/v1/discover/people/9340")

    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["tmdb_person_id"] == 9340
    assert data["name"] == "示例影人"
    assert data["avatar_url"].endswith("/w300/person.jpg")
    assert [item["title_ref"] for item in data["titles"]] == [
        "tmdb:movie:42",
        "tmdb:tv:77",
    ]


def test_invalid_stable_refs_return_readable_400(client: TestClient, monkeypatch) -> None:
    _patch_title_discovery_providers(monkeypatch)

    collection = client.get("/api/v1/discover/collections/not-a-ref/titles")
    title = client.get("/api/v1/discover/titles/438631")

    assert collection.status_code == 400
    assert "list-collections" in collection.json()["message"]
    assert title.status_code == 400
    assert "搜索或片单接口" in title.json()["message"]


def test_discovery_ui_manifest_references_domain_collections(
    client: TestClient, monkeypatch
) -> None:
    _patch_title_discovery_providers(monkeypatch)

    resp = client.get("/api/v1/ui/discovery/movie", params={"provider": "tmdb"})

    assert resp.status_code == 200, resp.text
    sections = resp.json()["data"]["sections"]
    assert sections[0] == {
        "collection_ref": "tmdb:movie:featured-weekly",
        "title": "本周精选",
        "presentation": "hero",
        "preview_limit": 6,
        "supports_full_listing": False,
    }
    assert sections[1]["supports_full_listing"] is True
