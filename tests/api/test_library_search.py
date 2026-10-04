"""媒体库搜索接口（GET /search/library）的端到端测试。

三端（Web、iPhone、Apple TV）共用的唯一媒体库搜索契约。覆盖：标题/原名匹配
（忽略英文大小写）、拼音与人物检索、相关度排序、跨库去重、未识别文件不参与搜索、
权限/分级实时核验与稳定分页。
"""

from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import LibraryFile, MediaItem
from movieclaw_db.repositories import LibraryRepository


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'search.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


@pytest_asyncio.fixture
async def client(db):
    """走 ASGITransport 直连应用（不跑 lifespan——db fixture 已建好库）。

    与 db fixture 共用同一个事件循环，测试里才能直接用 db.session()
    造数据、再发 HTTP 请求验证接口。
    """
    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    app.dependency_overrides[require_login] = lambda: Principal(kind="admin", name="tester")
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://testserver"
    ) as async_client:
        yield async_client


async def _seed(db) -> None:
    """两个库各挂几部片：电影库（沙丘/奥本海默）+ 剧集库（沙丘：预言）。"""
    async with db.session() as session:
        movie_lib = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=["/media/movies"]
        )
        tv_lib = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=["/media/tv"]
        )
        dune = MediaItem(
            kind="movie", tmdb_id=1, title="沙丘", original_title="Dune", year=2021, aliases=[]
        )
        oppenheimer = MediaItem(
            kind="movie", tmdb_id=2, title="奥本海默", original_title="Oppenheimer", aliases=[]
        )
        prophecy = MediaItem(
            kind="tv", tmdb_id=3, title="沙丘：预言", original_title="Dune: Prophecy", aliases=[]
        )
        session.add_all([dune, oppenheimer, prophecy])
        await session.flush()
        session.add_all(
            [
                LibraryFile(
                    library_id=movie_lib.id,
                    media_item_id=dune.id,
                    file_path="/media/movies/沙丘/Dune.2021.mkv",
                    size_bytes=100,
                    source="scanned",
                ),
                LibraryFile(
                    library_id=movie_lib.id,
                    media_item_id=oppenheimer.id,
                    file_path="/media/movies/奥本海默/Oppenheimer.mkv",
                    size_bytes=200,
                    source="scanned",
                ),
                LibraryFile(
                    library_id=tv_lib.id,
                    media_item_id=prophecy.id,
                    season_number=1,
                    episode_number=1,
                    file_path="/media/tv/沙丘：预言/S01E01.mkv",
                    size_bytes=300,
                    source="scanned",
                ),
                # 未识别文件：没有可靠标题，不该出现在搜索结果里
                LibraryFile(
                    library_id=movie_lib.id,
                    media_item_id=None,
                    file_path="/media/movies/未识别/dune.leak.mkv",
                    size_bytes=1,
                    source="scanned",
                ),
            ]
        )
        await session.commit()


async def _titles(client: AsyncClient, keyword: str) -> list[str]:
    resp = await client.get("/api/v1/search/library", params={"q": keyword})
    assert resp.status_code == 200
    return [hit["item"]["title"] for hit in resp.json()["data"]["items"]]


@pytest.mark.asyncio
async def test_search_spans_libraries_with_inventory(db, client) -> None:
    await _seed(db)
    resp = await client.get("/api/v1/search/library", params={"q": "沙丘"})
    hits = resp.json()["data"]["items"]
    # 准确片名排在前缀命中之前；每条结果自带所在库，客户端不必再对库列表
    assert [h["item"]["title"] for h in hits] == ["沙丘", "沙丘：预言"]
    assert [h["library_ids"] for h in hits] == [[1], [2]]
    assert hits[0]["item"]["file_count"] == 1
    assert hits[0]["item"]["total_size_bytes"] == 100


@pytest.mark.asyncio
async def test_search_matches_original_title_case_insensitive(db, client) -> None:
    await _seed(db)
    # 原名 Dune / Dune: Prophecy 都命中；未识别文件（文件名含 dune）不出现
    assert await _titles(client, "DUNE") == ["沙丘", "沙丘：预言"]


@pytest.mark.asyncio
async def test_search_no_match_returns_empty(db, client) -> None:
    await _seed(db)
    assert await _titles(client, "星际穿越") == []


@pytest.mark.parametrize("indexed", [False, True])
async def test_initials_title_ranks_before_cast_prefix(db, client, indexed) -> None:
    """回归：搜「ST」想找三体，演员 Stephen Lang 带出的阿凡达不能排到前面。

    旧的按库分组接口把相关度结果按标题拼音重排，「阿凡达」(a) 因此压过
    「三体」(s)；统一到相关度接口后，片名首字母准确命中必须排第一。
    """
    from movieclaw_api.services.library.search_index import refresh_index_batch
    from movieclaw_db.models.person import MediaItemPerson, Person

    async with db.session() as session:
        lib = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=["/media/movies"]
        )
        avatar = MediaItem(
            kind="movie", tmdb_id=19995, title="阿凡达", original_title="Avatar", aliases=[]
        )
        three_body = MediaItem(
            kind="tv", tmdb_id=204541, title="三体", original_title="三体", aliases=[]
        )
        actor = Person(tmdb_person_id=32747, name="史蒂芬·朗", original_name="Stephen Lang")
        session.add_all([avatar, three_body, actor])
        await session.flush()
        session.add_all(
            [
                LibraryFile(
                    library_id=lib.id,
                    media_item_id=item.id,
                    file_path=f"/media/movies/{item.title}.mkv",
                    size_bytes=1,
                    source="scanned",
                )
                for item in (avatar, three_body)
            ]
            + [MediaItemPerson(media_item_id=avatar.id, person_id=actor.id, department="cast")]
        )
        await session.commit()
    if indexed:
        while await refresh_index_batch():
            pass
    assert await _titles(client, "ST") == ["三体", "阿凡达"]


async def _seed_advanced(db):
    from movieclaw_db.models import MediaMetadata
    from movieclaw_db.models.person import MediaItemPerson, Person

    await _seed(db)
    async with db.session() as session:
        movie = MediaItem(
            kind="movie",
            tmdb_id=157336,
            title="星际穿越",
            original_title="Interstellar",
            aliases=["星际效应"],
            year=2014,
        )
        person = Person(
            tmdb_person_id=525, name="克里斯托弗·诺兰", original_name="Christopher Nolan"
        )
        session.add_all([movie, person])
        await session.flush()
        session.add_all(
            [
                LibraryFile(
                    library_id=1,
                    media_item_id=movie.id,
                    file_path="/media/interstellar.mkv",
                    resolution="2160p",
                    size_bytes=500,
                    source="scanned",
                ),
                # 同一作品在两个库：新 API 只出现一张海报，落点仍是可见库。
                LibraryFile(
                    library_id=2,
                    media_item_id=movie.id,
                    file_path="/other/interstellar.mkv",
                    size_bytes=500,
                    source="scanned",
                ),
                MediaMetadata(media_item_id=movie.id, content_rating="PG-13"),
                MediaItemPerson(media_item_id=movie.id, person_id=person.id, department="director"),
            ]
        )
        await session.commit()
        return movie.id, person.id


async def _ranked(client, query="", **params):
    response = await client.get("/api/v1/search/library", params={"q": query, **params})
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["success"] is True and payload["code"] == "OK"
    return payload["data"]


@pytest.mark.parametrize(
    "query",
    [
        "星际穿越",
        "星際穿越",
        "星际效应",
        "Interstellar",
        "INTERSTELLAR",
        "ＩＮＴＥＲＳＴＥＬＬＡＲ",
        "xjcy",
        "XJC",
        "xingji",
        "xing ji chuan yue",
        "星际cy",
        "xj穿越",
        "xingjicy",
        "xjchuanyue",
        "穿越",
        "cy",
    ],
)
@pytest.mark.parametrize("indexed", [False, True])
async def test_ranked_title_forms(db, client, query, indexed):
    from movieclaw_api.services.library.search_index import refresh_index_batch

    movie_id, _ = await _seed_advanced(db)
    if indexed:
        while await refresh_index_batch():
            pass
    data = await _ranked(client, query)
    ids = [hit["item"]["media_item_id"] for hit in data["items"]]
    assert movie_id in ids
    if query != "cy":
        assert ids == [movie_id]
    hit = next(hit for hit in data["items"] if hit["item"]["media_item_id"] == movie_id)
    assert hit["library_ids"] == [1, 2]
    assert data["index_pending"] is not indexed


@pytest.mark.parametrize("indexed", [False, True])
async def test_people_search_and_drilldown(db, client, indexed):
    from movieclaw_api.services.library.search_index import refresh_index_batch

    movie_id, person_id = await _seed_advanced(db)
    if indexed:
        while await refresh_index_batch():
            pass
    for query in ("诺兰", "nl", "nolan", "克里斯托弗nl"):
        data = await _ranked(client, query)
        assert data["people"][0]["id"] == person_id
        assert data["people"][0]["item_count"] == 1
        assert data["items"][0]["item"]["media_item_id"] == movie_id
        assert data["items"][0]["match"]["person_id"] == person_id
    assert (await _ranked(client, person_id=person_id))["items"][0]["item"][
        "media_item_id"
    ] == movie_id
    assert (await _ranked(client, person_id=9999))["items"] == []


async def test_index_rename_alias_update_and_delete(db, client):
    from sqlalchemy import text

    from movieclaw_api.services.library.search_index import refresh_index_batch
    from movieclaw_db.models.person import Person

    movie_id, person_id = await _seed_advanced(db)
    while await refresh_index_batch():
        pass
    async with db.session() as session:
        item = await session.get(MediaItem, movie_id)
        item.title = "新片名"
        item.original_title = "New Movie"
        item.aliases = ["新别名"]
        person = await session.get(Person, person_id)
        person.name = "新导演"
        person.original_name = None
        await session.commit()
    # 后台尚未消费时，旧索引不能命中旧名，新名称与人物应立即可搜。
    assert (await _ranked(client, "xjcy"))["items"] == []
    assert (await _ranked(client, "新别名"))["items"][0]["item"]["title"] == "新片名"
    assert (await _ranked(client, "新导演"))["people"][0]["id"] == person_id
    while await refresh_index_batch():
        pass
    assert (await _ranked(client, "xbm"))["items"]
    async with db.session() as session:
        await session.execute(
            text("DELETE FROM library_file WHERE media_item_id=:id"), {"id": movie_id}
        )
        await session.commit()
    assert (await _ranked(client, "新导演"))["people"] == []
    assert (await _ranked(client, "新片名"))["items"] == []


async def test_hidden_library_rating_missing_and_provisional(db, client):
    from movieclaw_api.api.deps import require_login
    from movieclaw_api.services.auth import Principal
    from movieclaw_db.models import Library, Member

    movie_id, _ = await _seed_advanced(db)
    async with db.session() as session:
        for library_id in (1, 2):
            lib = await session.get(Library, library_id)
            lib.admin_visible = False
        await session.commit()
    assert (await _ranked(client, "诺兰"))["items"] == []
    assert (await _ranked(client, "诺兰"))["people"] == []
    assert (await _ranked(client, "xjcy"))["suggestions"] == []
    async with db.session() as session:
        lib = await session.get(Library, 1)
        lib.admin_visible = True
        member = Member(
            username="child",
            password_hash="test",
            all_libraries=True,
            content_age_limit=7,
            allow_unrated=False,
        )
        session.add(member)
        await session.commit()
    # 成员权限走真实的库白名单与分级解析，只替换登录主体。
    client._transport.app.dependency_overrides[require_login] = lambda: Principal(
        kind="member",
        name="child",
        member_id=member.id,
        member=member,
        is_admin=False,
    )
    assert (await _ranked(client, "xjcy"))["items"] == []


async def test_stable_cursor_and_live_inventory(db, client):
    from sqlalchemy import text

    await _seed(db)
    first = await _ranked(client, "沙丘", limit=1)
    assert first["next_cursor"]
    first_id = first["items"][0]["item"]["media_item_id"]
    second = await _ranked(client, "沙丘", limit=1, cursor=first["next_cursor"])
    assert second["items"][0]["item"]["media_item_id"] != first_id
    wrong = await client.get(
        "/api/v1/search/library", params={"q": "其他", "cursor": first["next_cursor"]}
    )
    assert wrong.status_code == 400
    again = await _ranked(client, "沙丘", limit=1)
    async with db.session() as session:
        await session.execute(
            text("UPDATE library_file SET state='trashed' WHERE media_item_id != :id"),
            {"id": again["items"][0]["item"]["media_item_id"]},
        )
        await session.commit()
    assert (await _ranked(client, "沙丘", cursor=again["next_cursor"]))["items"] == []


async def test_cursor_uses_current_person_department(db, client):
    """刮削更正人物身份后，后续页保留顺序，但展示当前的演员/导演关系。"""
    from sqlalchemy import text

    from movieclaw_db.models.person import MediaItemPerson

    _, person_id = await _seed_advanced(db)
    async with db.session() as session:
        session.add(MediaItemPerson(media_item_id=2, person_id=person_id, department="director"))
        await session.commit()
    first = await _ranked(client, "诺兰", limit=1)
    assert first["next_cursor"]
    async with db.session() as session:
        await session.execute(
            text("UPDATE media_item_person SET department='cast' WHERE person_id=:id"),
            {"id": person_id},
        )
        await session.commit()
    second = await _ranked(client, "诺兰", limit=1, cursor=first["next_cursor"])
    assert len(second["items"]) == 1
    assert second["items"][0]["match"]["label"].startswith("演员：")


async def test_last_file_removed_during_search_returns_empty(db, client, monkeypatch):
    """模拟转移/清理恰在库存核验和海报聚合之间提交：不能因空库存返回 500。"""
    from sqlalchemy import delete

    from movieclaw_api.services.library import search

    await _seed(db)
    original = search._aggregate_wall_views

    async def remove_then_aggregate(*args, **kwargs):
        async with db.session() as session:
            await session.execute(delete(LibraryFile).where(LibraryFile.media_item_id == 2))
            await session.commit()
        return await original(*args, **kwargs)

    monkeypatch.setattr(search, "_aggregate_wall_views", remove_then_aggregate)
    assert (await _ranked(client, "奥本海默"))["items"] == []


async def test_cursor_owner_and_expiry(db, client):
    from movieclaw_api.api.deps import require_login
    from movieclaw_api.services.auth import Principal
    from movieclaw_api.services.library import search

    await _seed(db)
    first = await _ranked(client, "沙丘", limit=1)
    client._transport.app.dependency_overrides[require_login] = lambda: Principal(
        kind="admin", name="another-account"
    )
    response = await client.get(
        "/api/v1/search/library", params={"q": "沙丘", "cursor": first["next_cursor"]}
    )
    assert response.status_code == 400
    client._transport.app.dependency_overrides[require_login] = lambda: Principal(
        kind="admin", name="tester"
    )
    token = first["next_cursor"].rsplit(":", 1)[0]
    search._sessions[token].expires = 0
    response = await client.get(
        "/api/v1/search/library", params={"q": "沙丘", "cursor": first["next_cursor"]}
    )
    assert response.status_code == 400


@pytest.mark.parametrize(
    "params, status",
    [
        ({}, 400),
        ({"q": "  "}, 400),
        ({"q": "%_"}, 400),
        ({"q": "x" * 101}, 422),
        ({"q": "x", "limit": 0}, 422),
        ({"q": "x", "limit": 101}, 422),
        ({"person_id": 0}, 422),
        ({"q": "x", "cursor": "invalid"}, 400),
    ],
)
async def test_ranked_invalid_input(client, params, status):
    response = await client.get("/api/v1/search/library", params=params)
    assert response.status_code == status
    assert response.json()["success"] is False


async def test_ranked_requires_login(client):
    from movieclaw_api.api.deps import require_login

    client._transport.app.dependency_overrides.pop(require_login)
    response = await client.get("/api/v1/search/library", params={"q": "沙丘"})
    assert response.status_code == 401


async def test_exact_person_before_weak_title_and_exact_title_first(db, client):
    movie_id, _ = await _seed_advanced(db)
    async with db.session() as session:
        item = await session.get(MediaItem, 1)
        item.title = "诺兰传记"
        await session.commit()
    data = await _ranked(client, "诺兰")
    assert data["items"][0]["item"]["media_item_id"] == 1  # 片名前缀优先
    assert data["items"][1]["item"]["media_item_id"] == movie_id
    async with db.session() as session:
        item = await session.get(MediaItem, 1)
        item.title = "关于诺兰的传记"
        await session.commit()
    assert (await _ranked(client, "诺兰"))["items"][0]["item"]["media_item_id"] == movie_id


async def test_no_cross_alias_match_and_nonexistent_inventory(db, client):
    from movieclaw_api.services.library.search_index import refresh_index_batch

    movie_id, _ = await _seed_advanced(db)
    async with db.session() as session:
        item = await session.get(MediaItem, movie_id)
        item.aliases = ["未来", "战争"]
        await session.commit()
    while await refresh_index_batch():
        pass
    assert (await _ranked(client, "未来战争"))["items"] == []
    async with db.session() as session:
        from sqlmodel import select

        files = (
            (
                await session.execute(
                    select(LibraryFile).where(LibraryFile.media_item_id == movie_id)
                )
            )
            .scalars()
            .all()
        )
        files[0].state = "missing"
        files[1].unidentified_code = "未确认"
        await session.commit()
    assert (await _ranked(client, "xjcy"))["items"] == []
    assert (await _ranked(client, "诺兰"))["people"] == []
    # LIKE 通配符不当成「匹配一切」：归一化后为空，按无效输入拒绝
    wildcard = await client.get("/api/v1/search/library", params={"q": "%_"})
    assert wildcard.status_code == 400


async def test_index_revision_preserves_concurrent_rename(db, client, monkeypatch):
    import asyncio
    import threading

    from sqlalchemy import text

    from movieclaw_api.services.library import search_index

    movie_id, _ = await _seed_advanced(db)
    started, resume = threading.Event(), threading.Event()
    original = search_index._prepare

    def paused(names):
        started.set()
        assert resume.wait(5)
        return original(names)

    monkeypatch.setattr(search_index, "_prepare", paused)
    worker = asyncio.create_task(search_index.refresh_index_batch())
    try:
        assert await asyncio.to_thread(started.wait, 5)
        async with db.session() as session:
            item = await session.get(MediaItem, movie_id)
            item.title = "并发新名称"
            await session.commit()
    finally:
        resume.set()
    await worker
    async with db.session() as session:
        assert (
            await session.execute(
                text(
                    "SELECT revision FROM library_search_dirty "
                    "WHERE entity_kind='media' AND entity_id=:id"
                ),
                {"id": movie_id},
            )
        ).scalar_one() == 2
    assert (await _ranked(client, "并发新名称"))["items"]
    monkeypatch.setattr(search_index, "_prepare", original)
    while await search_index.refresh_index_batch():
        pass
    assert (await _ranked(client, "并发新名称"))["index_pending"] is False


async def test_index_write_failure_rolls_back_claim(db, client):
    from sqlalchemy import text
    from sqlalchemy.exc import IntegrityError

    from movieclaw_api.services.library.search_index import refresh_index_batch

    await _seed_advanced(db)
    async with db.session() as session:
        await session.execute(
            text(
                "CREATE TRIGGER test_search_failure BEFORE INSERT ON library_search_name "
                "BEGIN SELECT RAISE(ABORT, '模拟索引写入失败'); END"
            )
        )
        await session.commit()
    with pytest.raises(IntegrityError):
        await refresh_index_batch()
    async with db.session() as session:
        assert (
            await session.execute(text("SELECT COUNT(*) FROM library_search_dirty"))
        ).scalar_one() == 5
        assert (
            await session.execute(text("SELECT COUNT(*) FROM library_search_document"))
        ).scalar_one() == 0
        await session.execute(text("DROP TRIGGER test_search_failure"))
        await session.commit()
    assert (await _ranked(client, "xjcy"))["items"]
    while await refresh_index_batch():
        pass
    assert (await _ranked(client, "xjcy"))["index_pending"] is False


async def test_outdated_index_uses_current_names(db, client):
    from sqlalchemy import text

    from movieclaw_api.services.library.search_index import refresh_index_batch

    await _seed_advanced(db)
    while await refresh_index_batch():
        pass
    async with db.session() as session:
        await session.execute(text("UPDATE library_search_document SET index_version=0"))
        await session.execute(text("UPDATE library_search_name SET raw_name='旧算法的错误名称'"))
        await session.commit()
    data = await _ranked(client, "xjcy")
    assert data["items"][0]["item"]["title"] == "星际穿越"
    assert data["index_pending"] is True


@pytest.mark.parametrize("query", ["cqsl", "chongqing", "重庆sl"])
async def test_phrase_pinyin_and_numbers(db, client, query):
    from movieclaw_api.services.library.search_index import refresh_index_batch

    await _seed(db)
    async with db.session() as session:
        item = await session.get(MediaItem, 1)
        item.title = "重庆森林2046"
        await session.commit()
    while await refresh_index_batch():
        pass
    assert (await _ranked(client, query))["items"][0]["item"]["media_item_id"] == 1
    assert (await _ranked(client, "2046"))["items"][0]["item"]["media_item_id"] == 1


@pytest.mark.parametrize("indexed", [False, True])
async def test_word_order_and_search_within_person_works(db, client, indexed):
    from movieclaw_api.services.library.search_index import refresh_index_batch

    movie_id, person_id = await _seed_advanced(db)
    async with db.session() as session:
        item = await session.get(MediaItem, movie_id)
        item.english_title = "The Dark Knight"
        await session.commit()
    if indexed:
        while await refresh_index_batch():
            pass
    data = await _ranked(client, "knight dark", person_id=person_id)
    assert [h["item"]["media_item_id"] for h in data["items"]] == [movie_id]
    assert data["items"][0]["match"]["type"] == "words"
    assert (await _ranked(client, "xjcy", person_id=person_id))["items"][0]["item"][
        "media_item_id"
    ] == movie_id
    # 另一部可见作品仍须受人物条件约束，不能只按名称召回。
    assert not (await _ranked(client, "shaqiu", person_id=person_id))["items"]


@pytest.mark.asyncio
@pytest.mark.parametrize("query", ["nl", "n", "ＮＬ", "n l"])
async def test_short_query_best_name_preserves_indexed_results(db, client, query):
    """数据库内选最佳名称须保留原排名、别名证据及 JSON 中的特殊字符。"""
    from movieclaw_api.services.library.search_index import refresh_index_batch
    from movieclaw_db.models.person import MediaItemPerson, Person

    await _seed_advanced(db)
    async with db.session() as session:
        movies = [
            MediaItem(
                kind="movie", tmdb_id=800 + i, title=title, original_title=title, aliases=aliases
            )
            for i, (title, aliases) in enumerate(
                [
                    ("Nolan 长名称", ["nl", "Nolan", "ＮＬ"]),
                    ('南陆 "引号" \\ 路径\n✨', ["NL", "南陆"]),
                    ("某作品", ["N L", "nolan long", "nl"]),
                ]
            )
        ]
        person = Person(
            tmdb_person_id=800, name='南陆 "姓名" \\ 路径\n✨', original_name="Nolan Long"
        )
        session.add_all([*movies, person])
        await session.flush()
        session.add_all(
            LibraryFile(
                library_id=1,
                media_item_id=m.id,
                file_path=f"/media/short-query-{m.id}.mkv",
                source="scanned",
            )
            for m in movies
        )
        session.add(
            MediaItemPerson(media_item_id=movies[0].id, person_id=person.id, department="cast")
        )
        await session.commit()
    before = await _ranked(client, query)
    while await refresh_index_batch():
        pass
    after = await _ranked(client, query)
    before.pop("index_pending")
    after.pop("index_pending")
    assert before == after
    assert len(after["items"]) >= 3


@pytest.mark.asyncio
async def test_broad_person_query_reads_display_info_only_for_top_people(db, client):
    """关系/排名覆盖所有候选；人物头像只读取实际显示的八个人。"""
    from sqlalchemy import event

    from movieclaw_api.services.library.search_index import refresh_index_batch
    from movieclaw_db.models.person import MediaItemPerson, Person

    movie_id, _ = await _seed_advanced(db)
    async with db.session() as session:
        people = [
            Person(tmdb_person_id=1000 + i, name=f"诺兰{i}", profile_path=f"/{i}.jpg")
            for i in range(40)
        ]
        session.add_all(people)
        await session.flush()
        session.add_all(
            MediaItemPerson(media_item_id=movie_id, person_id=p.id, department="cast")
            for p in people
        )
        await session.commit()
    while await refresh_index_batch():
        pass
    queries = []

    def record(conn, cursor, statement, parameters, context, executemany):
        if "person.profile_path" in statement and "FROM person" in statement:
            queries.append(parameters)

    event.listen(db.engine.sync_engine, "before_cursor_execute", record)
    try:
        data = await _ranked(client, "nl")
    finally:
        event.remove(db.engine.sync_engine, "before_cursor_execute", record)
    assert len(data["people"]) == 8
    assert len(queries) == 1 and len(queries[0]) == 8
    assert data["items"][0]["item"]["media_item_id"] == movie_id


@pytest.mark.asyncio
async def test_bulk_scalar_rows_preserves_types_order_and_empty_result(db):
    """批量封装须保留日期、枚举、JSON、空值、布尔和 SQL 的排序/分页语义。"""
    from datetime import datetime

    from sqlalchemy import and_
    from sqlmodel import select

    from movieclaw_api.services.library.bulk import scalar_rows

    await _seed_advanced(db)
    statement = (
        select(
            LibraryFile.id,
            LibraryFile.created_at,
            LibraryFile.state,
            LibraryFile.resolution,
            and_(LibraryFile.unidentified_code.is_(None), LibraryFile.size_bytes > 100),
            MediaItem.aliases,
        )
        .join(MediaItem, LibraryFile.media_item_id == MediaItem.id)
        .order_by(LibraryFile.id.desc())
        .limit(4)
    )
    async with db.session() as session:
        expected = [tuple(row) for row in (await session.execute(statement)).all()]
        actual = await scalar_rows(session, statement)
        assert actual == expected
        assert isinstance(actual[0][1], datetime)
        assert isinstance(actual[0][4], bool)
        assert isinstance(actual[0][5], list)
        assert any(row[3] is None for row in actual)
        assert await scalar_rows(session, statement.where(LibraryFile.id < 0)) == []


@pytest.mark.parametrize("indexed", [False, True])
async def test_initials_ties_rank_leads_before_bit_parts(db, client, indexed) -> None:
    """回归：搜「lyt」找不到李一桐。

    片库里首字母同为 lyt 的人很多、作品数又都是 1，旧排序打平后按人物 id 取前 8 个，
    主演李一桐（id 最大）被挤出人物行，她的作品也排在一串龙套作品后面。
    同档人物改按「担任主创的作品数」等本地分量排序。
    """
    from movieclaw_api.services.library.search_index import refresh_index_batch
    from movieclaw_db.models.person import MediaItemPerson, Person

    bit_parts = [
        "刘奕铁",
        "郎月婷",
        "李言廷",
        "李英涛",
        "梁雍婷",
        "李元泰",
        "吕艳婷",
        "李祐汀",
        "罗雨桐",
        "林雅婷",
    ]
    async with db.session() as session:
        lib = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=["/media/movies"]
        )
        cast = [(name, 20) for name in bit_parts] + [("李一桐", 1)]
        for index, (name, credit_order) in enumerate(cast, start=1):
            person = Person(tmdb_person_id=50000 + index, name=name)
            item = MediaItem(
                kind="movie",
                tmdb_id=60000 + index,
                title=f"影片{index:02d}",
                original_title=f"Film {index}",
                aliases=[],
            )
            session.add_all([person, item])
            await session.flush()
            session.add_all(
                [
                    LibraryFile(
                        library_id=lib.id,
                        media_item_id=item.id,
                        file_path=f"/media/movies/{index}.mkv",
                        size_bytes=1,
                        source="scanned",
                    ),
                    MediaItemPerson(
                        media_item_id=item.id,
                        person_id=person.id,
                        department="cast",
                        credit_order=credit_order,
                    ),
                ]
            )
        await session.commit()
    if indexed:
        while await refresh_index_batch():
            pass
    data = await _ranked(client, "lyt")
    assert data["people"][0]["name"] == "李一桐"
    assert data["items"][0]["match"]["label"] == "演员：李一桐"
