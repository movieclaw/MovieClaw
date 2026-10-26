"""订阅链路的收藏范围路由测试（docs/design/library-routing.md R2）。

覆盖：
- 创建订阅不选库 → 按收藏范围路由并**定格** subscription.library_id，
  时间线活动带中文理由；
- 显式选库 → 完全尊重，不走路由；
- 粘性：定格后修改库的收藏范围，既有订阅的 library_id 不变；
- dispatch-preview 带 tmdb_id → 返回路由结论（预选库 + 理由徽标）；
  显式 library_id 时路由字段为 null。
"""

from __future__ import annotations

import httpx
import pytest
import pytest_asyncio
from fastapi.testclient import TestClient
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import ActivityType, SubscriptionActivity
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"

_ANIME_RULES = [{"field": "genres", "op": "any_of", "values": [16]}]

# 日本动画剧：genres/origin_country 会随建档写进 media_metadata，
# 路由事实直接来自库内档案（gather_facts 第一级来源）
_ROUTES = {
    "/3/tv/300": {
        "id": 300,
        "name": "测试动画",
        "original_name": "Test Anime",
        "first_air_date": "2024-01-01",
        "status": "Returning Series",
        "genres": [{"id": 16, "name": "动画"}],
        "origin_country": ["JP"],
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 1}],
    },
    "/3/tv/300/season/1": {
        "name": "第 1 季",
        "air_date": "2024-01-01",
        "episodes": [{"episode_number": 1, "name": "E1", "air_date": "2024-01-01"}],
    },
}


def _fake_tmdb() -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        payload = _ROUTES.get(request.url.path)
        return httpx.Response(200 if payload is not None else 404, json=payload or {})

    return TmdbClient(_KEY, transport=httpx.MockTransport(handler))


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'subroute.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


def _service(session) -> SubscriptionService:
    return SubscriptionService(session, MediaLibraryService(session, _fake_tmdb()))


async def _make_libraries(session) -> tuple[int, int]:
    repo = LibraryRepository(session)
    default = await repo.create(name="剧集库", kind="tv", root_paths=["/media/tv"])
    anime = await repo.create(
        name="动漫库", kind="tv", root_paths=["/media/anime"], match_rules=_ANIME_RULES
    )
    return default.id, anime.id


@pytest.mark.asyncio
async def test_create_routes_and_pins_library(db) -> None:
    """不选库创建：路由命中动漫库并定格，活动写明理由。"""
    async with db.session() as session:
        _default_id, anime_id = await _make_libraries(session)
        sub = await _service(session).create(MediaKind.TV, 300, selected_seasons=[1])
        assert sub.library_id == anime_id

        created = (
            (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == sub.id,
                        SubscriptionActivity.type == ActivityType.CREATED,
                    )
                )
            )
            .scalars()
            .one()
        )
        assert "命中「动漫库」" in created.message and "动画" in created.message


@pytest.mark.asyncio
async def test_create_explicit_library_skips_routing(db) -> None:
    """显式选库：规则退让，定格用户手选的库。"""
    async with db.session() as session:
        default_id, _anime_id = await _make_libraries(session)
        sub = await _service(session).create(
            MediaKind.TV, 300, selected_seasons=[1], library_id=default_id
        )
        assert sub.library_id == default_id


@pytest.mark.asyncio
async def test_pinned_library_survives_rule_changes(db) -> None:
    """粘性：定格后改收藏范围，既有订阅不重路由（规则变更只影响新作品）。"""
    async with db.session() as session:
        _default_id, anime_id = await _make_libraries(session)
        sub = await _service(session).create(MediaKind.TV, 300, selected_seasons=[1])
        assert sub.library_id == anime_id

        # 把动漫库的收藏范围改成"纪录片"——按新规则本剧不再命中
        repo = LibraryRepository(session)
        await repo.update(
            anime_id,
            name="动漫库",
            root_paths=["/media/anime"],
            match_rules=[{"field": "genres", "op": "any_of", "values": [99]}],
        )
        await session.refresh(sub)
        assert sub.library_id == anime_id  # 定格值不动


# ---------------------------------------------------------------------------
# dispatch-preview 的路由结论（API 层）
# ---------------------------------------------------------------------------


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'preview.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()

    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    with TestClient(app, headers={"Accept-Language": "zh-Hans"}) as c:
        yield c
    get_settings.cache_clear()


def _create_lib(client, *, name: str, root: str, rules: list | None = None) -> int:
    r = client.post(
        "/api/v1/libraries",
        json={"name": name, "kind": "tv", "root_paths": [root], "match_rules": rules or []},
    )
    assert r.status_code == 200
    return r.json()["data"]["id"]


def test_dispatch_preview_routes_by_tmdb(client, monkeypatch) -> None:
    default_id = _create_lib(client, name="剧集库", root="/media/tv")
    anime_id = _create_lib(client, name="动漫库", root="/media/anime", rules=_ANIME_RULES)
    # 条目未建档：路由走 TMDB 轻量详情（route_for_tmdb 的临时条目路径）
    monkeypatch.setattr(
        "movieclaw_api.services.media_discover.get_tmdb_client", lambda: _fake_tmdb()
    )

    data = client.get(
        "/api/v1/subscriptions/download-routing-preview",
        params={"kind": "tv", "tmdb_id": 300},
    ).json()["data"]
    assert data["library_id"] == anime_id
    assert data["route_matched"] is True
    assert "命中「动漫库」" in data["route_reason"]

    # 显式选库：不走路由，路由字段为 null
    data = client.get(
        "/api/v1/subscriptions/download-routing-preview",
        params={"kind": "tv", "tmdb_id": 300, "library_id": default_id},
    ).json()["data"]
    assert data["library_id"] == default_id
    assert data["route_matched"] is None and data["route_reason"] is None

    # 未命中收藏范围的条目（404 的 tmdb 详情 → 事实不可得）→ 默认库兜底 + 理由
    data = client.get(
        "/api/v1/subscriptions/download-routing-preview",
        params={"kind": "tv", "tmdb_id": 999},
    ).json()["data"]
    assert data["library_id"] == default_id
    assert data["route_matched"] is False
    assert "默认库" in data["route_reason"]
