"""媒体库路由（库自述收藏范围）的引擎与配置测试。

覆盖（docs/design/library-routing.md R1）：
- evaluate 纯函数：AND 语义、any_of 交集、空声明/空事实/未知字段与算子的
  保守不命中；
- route 选库：特异性（条件条数）优先、打平取创建更早、未命中落默认库、
  事实不可得落默认库、无库返回 None——三个出口都有可读中文理由；
- gather_facts 三级来源：刮削档案优先 → TMDB 轻量详情兜底 → 都不可得为 None；
- validate_match_rules 写入校验与库 CRUD 携带 match_rules；
- 刮削口径：genre_ids 与 genres 同源提取。
"""

from __future__ import annotations

import time

import httpx
import pytest
import pytest_asyncio
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services.library.routing import (
    RoutingFacts,
    evaluate,
    gather_facts,
    route,
    validate_match_rules,
)
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import MediaItem, MediaMetadata
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_media.library import extract_genre_ids, extract_origin_countries
from movieclaw_media.tmdb import TmdbClient

# 常用条件速记：动画（genre 16）/ 日韩（JP/KR）
_ANIME = {"field": "genres", "op": "any_of", "values": [16]}
_JP_KR = {"field": "origin_countries", "op": "any_of", "values": ["JP", "KR"]}

_ANIME_JP_FACTS = RoutingFacts(genre_ids=(16, 10759), origin_countries=("JP",))


# ---------------------------------------------------------------------------
# evaluate 纯函数
# ---------------------------------------------------------------------------


def test_evaluate_and_semantics() -> None:
    # 条件间 AND：动画+日韩的库，只有两条都命中才算
    rules = [_ANIME, _JP_KR]
    assert evaluate(rules, _ANIME_JP_FACTS) is True
    # 美国动画：区域不中 → 整体不中
    assert evaluate(rules, RoutingFacts(genre_ids=(16,), origin_countries=("US",))) is False
    # 日本的非动画剧：类型不中 → 整体不中
    assert evaluate(rules, RoutingFacts(genre_ids=(18,), origin_countries=("JP",))) is False


def test_evaluate_any_of_intersection() -> None:
    # 条件内 any_of：作品多类型/多国家，与取值有交集即满足
    assert evaluate([_JP_KR], RoutingFacts(genre_ids=(), origin_countries=("KR", "US"))) is True


def test_evaluate_conservative_cases() -> None:
    # 空声明不参与命中；事实缺失不命中；未知字段/算子保守不命中（前向兼容）
    assert evaluate([], _ANIME_JP_FACTS) is False
    assert evaluate([_ANIME], None) is False
    assert (
        evaluate([{"field": "directors", "op": "any_of", "values": [1]}], _ANIME_JP_FACTS) is False
    )
    assert evaluate([{"field": "genres", "op": "all_of", "values": [16]}], _ANIME_JP_FACTS) is False


# ---------------------------------------------------------------------------
# validate_match_rules 写入校验
# ---------------------------------------------------------------------------


def test_validate_match_rules_normalizes() -> None:
    cleaned = validate_match_rules([{"field": "origin_countries", "values": ["jp", "JP", " kr "]}])
    # 补全 op、去重、国家码统一大写
    assert cleaned == [{"field": "origin_countries", "op": "any_of", "values": ["JP", "KR"]}]
    assert validate_match_rules(None) == []


@pytest.mark.parametrize(
    "raw",
    [
        [{"field": "language", "values": ["ja"]}],  # 不支持的字段
        [{"field": "genres", "values": []}],  # 空取值
        [{"field": "genres", "values": ["动画"]}],  # genre 必须是 ID 不是名字
        [{"field": "origin_countries", "values": [16]}],  # 国家必须是码
        [{"field": "genres", "op": "none_of", "values": [16]}],  # 未知算子
        [_ANIME, {"field": "genres", "values": [99]}],  # 同字段重复出现
    ],
)
def test_validate_match_rules_rejects(raw: list) -> None:
    with pytest.raises(BadRequestException):
        validate_match_rules(raw)


# ---------------------------------------------------------------------------
# route 选库（数据库内）
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'routing.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


async def _lib(session, *, name: str, kind: str = "tv", rules: list | None = None):
    return await LibraryRepository(session).create(
        name=name, kind=kind, root_paths=[f"/media/{name}"], match_rules=rules or []
    )


@pytest.mark.asyncio
async def test_route_specificity_and_tiebreak(db) -> None:
    async with db.session() as session:
        await _lib(session, name="剧集库")  # 首库自动默认
        anime = await _lib(session, name="动漫库", rules=[_ANIME])
        anime_jp = await _lib(session, name="日韩动漫库", rules=[_ANIME, _JP_KR])

        # 日本动画：两库都命中，特异性（2 条件）更高的赢
        decision = await route(session, "tv", _ANIME_JP_FACTS)
        assert decision.matched and decision.library.id == anime_jp.id
        assert "日韩动漫库" in decision.reason and "动画" in decision.reason

        # 美国动画：只有单条件库命中
        us_facts = RoutingFacts(genre_ids=(16,), origin_countries=("US",))
        decision = await route(session, "tv", us_facts)
        assert decision.matched and decision.library.id == anime.id

        # 打平（两库各 1 条件都命中）：取创建更早（id 更小）者
        chinese = await _lib(
            session,
            name="华语剧库",
            rules=[{"field": "origin_countries", "op": "any_of", "values": ["CN", "HK", "TW"]}],
        )
        await _lib(
            session, name="犯罪剧库", rules=[{"field": "genres", "op": "any_of", "values": [80]}]
        )
        cn_crime = RoutingFacts(genre_ids=(80,), origin_countries=("CN",))
        decision = await route(session, "tv", cn_crime)
        assert decision.matched and decision.library.id == chinese.id


@pytest.mark.asyncio
async def test_route_fallback_reasons(db) -> None:
    async with db.session() as session:
        # 无任何库：library=None，理由可读
        decision = await route(session, "tv", _ANIME_JP_FACTS)
        assert decision.library is None and not decision.matched
        assert "没有可用的媒体库" in decision.reason

        default = await _lib(session, name="剧集库")
        await _lib(session, name="动漫库", rules=[_ANIME])

        # 未命中任何收藏范围 → 默认库，理由写明
        drama = RoutingFacts(genre_ids=(18,), origin_countries=("CN",))
        decision = await route(session, "tv", drama)
        assert not decision.matched and decision.library.id == default.id
        assert "未命中任何收藏范围" in decision.reason

        # 事实不可得 → 默认库，理由写明
        decision = await route(session, "tv", None)
        assert not decision.matched and decision.library.id == default.id
        assert "元数据暂不可得" in decision.reason


@pytest.mark.asyncio
async def test_route_without_declarations_quiet_reason(db) -> None:
    # 没有任何库声明收藏范围时（老用户升级后的常态），理由不提"未命中"
    async with db.session() as session:
        default = await _lib(session, name="剧集库")
        decision = await route(session, "tv", _ANIME_JP_FACTS)
        assert decision.library.id == default.id
        assert "默认库" in decision.reason and "未命中" not in decision.reason


# ---------------------------------------------------------------------------
# gather_facts 三级来源
# ---------------------------------------------------------------------------


def _tmdb_client(payload: dict | None) -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        if payload is None:
            return httpx.Response(500, json={})
        return httpx.Response(200, json=payload)

    return TmdbClient("0123456789abcdef0123456789abcdef", transport=httpx.MockTransport(handler))


async def _item(session, *, tmdb_id: int = 100) -> MediaItem:
    item = MediaItem(kind="tv", tmdb_id=tmdb_id, title="测试剧", original_title="Test", aliases=[])
    session.add(item)
    await session.commit()
    await session.refresh(item)
    return item


@pytest.mark.asyncio
async def test_gather_facts_prefers_metadata(db, monkeypatch) -> None:
    async with db.session() as session:
        item = await _item(session)
        session.add(
            MediaMetadata(
                media_item_id=item.id, genre_ids=[16], origin_countries=["JP"], genres=["动画"]
            )
        )
        await session.commit()
        # 刮削档案在库：不发起任何 TMDB 请求（打桩成一调用就炸）
        monkeypatch.setattr(
            "movieclaw_api.services.media_discover.get_tmdb_client",
            lambda: (_ for _ in ()).throw(AssertionError("不应触网")),
        )
        facts = await gather_facts(session, item)
        assert facts == RoutingFacts(genre_ids=(16,), origin_countries=("JP",))


@pytest.mark.asyncio
async def test_gather_facts_tmdb_fallback_and_failure(db, monkeypatch) -> None:
    async with db.session() as session:
        item = await _item(session)
        # 无档案 → TMDB 轻量详情兜底（电影口径 production_countries 同函数覆盖）
        payload = {"genres": [{"id": 16, "name": "动画"}], "origin_country": ["KR"]}
        monkeypatch.setattr(
            "movieclaw_api.services.media_discover.get_tmdb_client",
            lambda: _tmdb_client(payload),
        )
        facts = await gather_facts(session, item)
        assert facts == RoutingFacts(genre_ids=(16,), origin_countries=("KR",))

        # TMDB 不可达 → None（route 落默认库），不抛出
        monkeypatch.setattr(
            "movieclaw_api.services.media_discover.get_tmdb_client",
            lambda: _tmdb_client(None),
        )
        assert await gather_facts(session, item) is None


# ---------------------------------------------------------------------------
# 刮削口径：genre_ids 与 genres 同源
# ---------------------------------------------------------------------------


def test_extract_helpers_share_scrape_semantics() -> None:
    movie = {
        "genres": [{"id": 16, "name": "动画"}, {"id": 878, "name": "科幻"}],
        "production_countries": [{"iso_3166_1": "JP"}],
    }
    assert extract_genre_ids(movie) == [16, 878]
    assert extract_origin_countries(movie) == ["JP"]
    tv = {"genres": [], "origin_country": ["CN", "HK"]}
    assert extract_origin_countries(tv) == ["CN", "HK"]


# ---------------------------------------------------------------------------
# 库 CRUD 携带收藏范围（API 层）
# ---------------------------------------------------------------------------


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'api.db'}")
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


def test_library_crud_with_match_rules(client) -> None:
    r = client.post(
        "/api/v1/libraries",
        json={
            "name": "动漫库",
            "kind": "tv",
            "root_paths": ["/media/anime"],
            "match_rules": [{"field": "genres", "values": [16]}],
        },
    )
    assert r.status_code == 200
    row = r.json()["data"]
    assert row["match_rules"] == [{"field": "genres", "op": "any_of", "values": [16]}]

    # 更新可清空（回到"只作兜底"）
    r = client.put(
        f"/api/v1/libraries/{row['id']}",
        json={"name": "动漫库", "kind": "tv", "root_paths": ["/media/anime"], "match_rules": []},
    )
    assert r.status_code == 200
    assert r.json()["data"]["match_rules"] == []

    # 非法条件保存被拒（中文报错）
    r = client.post(
        "/api/v1/libraries",
        json={
            "name": "坏库",
            "kind": "tv",
            "root_paths": ["/media/bad"],
            "match_rules": [{"field": "genres", "values": ["动画"]}],
        },
    )
    assert r.status_code == 400
    assert "类型 ID" in r.json()["message"]


def test_routing_options_endpoint(client) -> None:
    data = client.get("/api/v1/libraries/routing-options").json()["data"]
    assert {"id": 16, "label": "动画"} in data["tv_genres"]
    assert any(
        p["key"] == "jp_kr" and p["countries"] == ["JP", "KR"] for p in data["region_presets"]
    )
    assert data["country_names"]["CN"] == "中国大陆"


def test_manual_scan_is_a_persistent_job(client, tmp_path) -> None:
    """手动扫描回传 Job id，完成结论在进程状态之外仍可从库详情读取。"""
    root = tmp_path / "movies"
    root.mkdir()
    created = client.post(
        "/api/v1/libraries",
        json={"name": "作业电影库", "kind": "movie", "root_paths": [str(root)]},
    ).json()["data"]

    response = client.post(f"/api/v1/libraries/{created['id']}/scan")
    assert response.status_code == 202
    job_id = response.json()["data"]["job_id"]
    assert job_id.startswith("job_")

    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        job = client.get(f"/api/v1/jobs/{job_id}").json()["data"]
        if job["status"] == "succeeded":
            break
        time.sleep(0.01)
    assert job["status"] == "succeeded"
    assert job["job_type"] == "library.scan"
    assert job["resources"] == [
        {"resource_type": "library", "resource_id": str(created["id"]), "relation": "target"}
    ]
    detail = client.get(f"/api/v1/libraries/{created['id']}").json()["data"]
    assert detail["scanning"] is False
    assert detail["last_scan"]["cancelled"] is False
