"""条目详情页「相似推荐」：打分规则的单元测试 + 扫描入库后经路由取数的端到端测试。

TMDB 为假实现；片库是六部虚构电影，各自只在一两个维度上与目标片相同，
用来钉住「同主创 > 同类型」「硬边界不跨越」「毫无共同点不推」这几条。
"""

from __future__ import annotations

import httpx
import pytest_asyncio
from sqlmodel import select

import movieclaw_api.services.library.scan as scan_mod
import movieclaw_api.services.media_discover as discover_mod
from movieclaw_api.api.routes.libraries import list_similar_items
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.access import ContentLimit
from movieclaw_api.services.library.scan import scan_library
from movieclaw_api.services.library.similar import (
    SimilarProfile,
    build_similar_wall,
    rank_similar,
)
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import MediaItem, MediaMetadata
from movieclaw_db.repositories.library_repo import LibraryRepository

_KEY = "0123456789abcdef0123456789abcdef"
_ADMIN = Principal(kind="admin", name="admin", member_id=0, is_admin=True)

DRAMA, CRIME, COMEDY, ANIMATION, DOC = 18, 80, 35, 16, 99


# ---- 打分规则 ---------------------------------------------------------------


def test_shared_director_outranks_shared_genre() -> None:
    target = SimilarProfile(genres=frozenset({DRAMA, CRIME}), directors=frozenset({1}))
    candidates = {
        10: SimilarProfile(genres=frozenset({DRAMA, CRIME})),
        11: SimilarProfile(genres=frozenset({DRAMA}), directors=frozenset({1})),
    }
    assert rank_similar(target, candidates, 10) == [11, 10]


def test_hard_boundaries_are_never_crossed() -> None:
    """动画、纪录片、真人秀与正片互不推荐，哪怕别的维度全对上。"""
    target = SimilarProfile(genres=frozenset({DRAMA}), cast=frozenset({7}))
    candidates = {
        20: SimilarProfile(genres=frozenset({DRAMA, ANIMATION}), cast=frozenset({7})),
        21: SimilarProfile(genres=frozenset({DRAMA, DOC}), cast=frozenset({7})),
        22: SimilarProfile(genres=frozenset({10764}), cast=frozenset({7})),
        23: SimilarProfile(genres=frozenset({DRAMA})),
    }
    assert rank_similar(target, candidates, 10) == [23]


def test_no_substantive_overlap_is_not_recommended() -> None:
    """只同年代、同语言、同国家凑不成「相似」；都没有系列（库里存空串）也不算同系列。"""
    target = SimilarProfile(
        genres=frozenset({DRAMA}),
        countries=frozenset({"CN"}),
        language="zh",
        year=2020,
        series_key="",
    )
    candidates = {
        30: SimilarProfile(
            genres=frozenset({COMEDY}),
            countries=frozenset({"CN"}),
            language="zh",
            year=2020,
            series_key="",
        )
    }
    assert rank_similar(target, candidates, 10) == []


def test_rare_genre_counts_more_than_common_one() -> None:
    """人人都有的「剧情」重合，不如少见的「犯罪」重合说明问题。"""
    target = SimilarProfile(genres=frozenset({DRAMA, CRIME}))
    candidates = {
        40: SimilarProfile(genres=frozenset({DRAMA, COMEDY})),
        41: SimilarProfile(genres=frozenset({CRIME, COMEDY})),
        **{100 + i: SimilarProfile(genres=frozenset({DRAMA})) for i in range(20)},
    }
    ranked = rank_similar(target, candidates, 30)
    assert ranked.index(41) < ranked.index(40)


def test_same_series_comes_first() -> None:
    target = SimilarProfile(genres=frozenset({DRAMA}), series_key="tmdb:1")
    candidates = {
        50: SimilarProfile(genres=frozenset({DRAMA}), directors=frozenset({3})),
        51: SimilarProfile(genres=frozenset({COMEDY}), series_key="tmdb:1"),
    }
    assert rank_similar(target, candidates, 10)[0] == 51


def test_lead_pair_outranks_supporting_overlap() -> None:
    """同一个人当主角的片最像：《三个老枪手》的摩根·弗里曼在《黑暗骑士》里是第 7 位，
    两人同框只算一点；在《遗愿清单》里也是主角，与同导演同分。"""
    target = SimilarProfile(
        genres=frozenset({COMEDY}), cast=frozenset({1, 2}), leads=frozenset({1, 2})
    )
    candidates = {
        60: SimilarProfile(genres=frozenset({CRIME}), cast=frozenset({1, 2})),  # 两位都是配角
        61: SimilarProfile(genres=frozenset({DRAMA}), cast=frozenset({1}), leads=frozenset({1})),
    }
    assert rank_similar(target, candidates, 10) == [61, 60]


def test_country_and_language_only_count_with_genre() -> None:
    """同国家同语言要类型对得上才加分：国产科幻片先推外国科幻片，不先推国产剧情片。"""
    scifi, action = 878, 28
    target = SimilarProfile(
        genres=frozenset({scifi, action, DRAMA}), countries=frozenset({"CN"}), language="zh"
    )
    candidates = {
        70: SimilarProfile(genres=frozenset({DRAMA}), countries=frozenset({"CN"}), language="zh"),
        71: SimilarProfile(
            genres=frozenset({scifi, action}), countries=frozenset({"US"}), language="en"
        ),
    }
    assert rank_similar(target, candidates, 10) == [71, 70]


def test_family_and_adult_titles_are_kept_apart() -> None:
    """合家欢片不推成人片：同类型时，分级同档的排前，跨两档的扣分垫底。"""
    target = SimilarProfile(genres=frozenset({COMEDY}), audience=0)
    candidates = {
        80: SimilarProfile(genres=frozenset({COMEDY}), audience=2),
        81: SimilarProfile(genres=frozenset({COMEDY}), audience=0),
        82: SimilarProfile(genres=frozenset({COMEDY})),  # 未分级：不加不减
    }
    assert rank_similar(target, candidates, 10) == [81, 82, 80]


def test_rare_studio_counts_more_than_common_one() -> None:
    """厂牌越少见越说明风格：同是 Blumhouse 比同是环球更像。"""
    target = SimilarProfile(
        genres=frozenset({DRAMA}), studios=frozenset({"Blumhouse", "Universal"})
    )
    candidates = {
        90: SimilarProfile(genres=frozenset({DRAMA}), studios=frozenset({"Universal"})),
        91: SimilarProfile(genres=frozenset({DRAMA}), studios=frozenset({"Blumhouse"})),
        **{
            200 + i: SimilarProfile(genres=frozenset({COMEDY}), studios=frozenset({"Universal"}))
            for i in range(10)
        },
    }
    assert rank_similar(target, candidates, 2) == [91, 90]


def test_episode_length_separates_sitcoms_from_dramas() -> None:
    """二十来分钟一集与一小时一集的剧不是一种看法。"""
    target = SimilarProfile(genres=frozenset({COMEDY, DRAMA}), episode_minutes=22)
    candidates = {
        95: SimilarProfile(genres=frozenset({COMEDY, DRAMA}), episode_minutes=60),
        96: SimilarProfile(genres=frozenset({COMEDY, DRAMA}), episode_minutes=25),
        97: SimilarProfile(genres=frozenset({COMEDY, DRAMA})),  # 没有单集时长：不加不减
    }
    assert rank_similar(target, candidates, 10) == [96, 97, 95]


# ---- 扫描入库 → 路由 ---------------------------------------------------------


def _movie(
    tmdb_id: int,
    title: str,
    *,
    genres: list[int],
    year: int,
    country: str,
    directors: list[int] = (),  # type: ignore[assignment]
    cast: list[int] = (),  # type: ignore[assignment]
) -> dict:
    return {
        "id": tmdb_id,
        "title": title,
        "original_title": title,
        "original_language": "zh" if country == "CN" else "en",
        "release_date": f"{year}-06-01",
        "status": "Released",
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
        "overview": "简介。",
        "vote_average": 7.5,
        "runtime": 120,
        "genres": [{"id": g, "name": str(g)} for g in genres],
        "production_countries": [{"iso_3166_1": country}],
        "credits": {
            "cast": [
                {"id": p, "name": f"演员{p}", "character": "某", "order": i}
                for i, p in enumerate(cast)
            ],
            "crew": [{"id": p, "name": f"导演{p}", "job": "Director"} for p in directors],
        },
        "images": {"posters": [], "backdrops": []},
        "release_dates": {"results": []},
    }


_MOVIES = {
    501: _movie(501, "目标片", genres=[DRAMA, CRIME], year=2020, country="CN",
                directors=[9001], cast=[9101, 9102]),
    502: _movie(502, "同导演", genres=[DRAMA], year=2015, country="CN", directors=[9001]),
    503: _movie(503, "同主演", genres=[CRIME, DRAMA], year=2010, country="US", cast=[9101]),
    504: _movie(504, "只同剧情", genres=[DRAMA], year=1990, country="US"),
    505: _movie(505, "动画犯罪", genres=[ANIMATION, CRIME], year=2020, country="CN",
                directors=[9001]),
    506: _movie(506, "喜剧", genres=[COMEDY], year=2020, country="CN"),
}  # fmt: skip


def _fake_tmdb() -> httpx.AsyncClient:
    def handler(request: httpx.Request) -> httpx.Response:
        tmdb_id = int(request.url.path.rsplit("/", 1)[-1])
        body = _MOVIES.get(tmdb_id)
        if body is None:
            return httpx.Response(404, json={"status_message": "not found"})
        return httpx.Response(200, json=body)

    from movieclaw_media.tmdb import TmdbClient

    return TmdbClient(api_key=_KEY, transport=httpx.MockTransport(handler))


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'similar.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    client = _fake_tmdb()
    monkeypatch.setattr(discover_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "get_tmdb_client", lambda: client)
    monkeypatch.setattr(scan_mod, "NEW_FILE_QUIET_SECONDS", 0)
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


async def _scan(db, tmp_path) -> tuple[int, dict[str, int]]:
    """建库 + 放六部片 + 扫描入库；返回 (library_id, 片名 → 条目 id)。"""
    root = tmp_path / "media" / "movies"
    for tmdb_id, body in _MOVIES.items():
        name = f"{body['title']} ({body['release_date'][:4]})"
        entry = root / name
        entry.mkdir(parents=True)
        (entry / f"{name}.1080p.mkv").write_bytes(b"m")
        (entry / "movie.nfo").write_text(
            f"<movie><title>{body['title']}</title><tmdbid>{tmdb_id}</tmdbid></movie>",
            encoding="utf-8",
        )
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="电影库", kind="movie", root_paths=[str(root)]
        )
    await scan_library(library.id)
    async with db.session() as session:
        ids = {item.title: item.id for item in (await session.execute(select(MediaItem))).scalars()}
    return library.id, ids


async def test_similar_route_ranks_library_items(db, tmp_path) -> None:
    library_id, ids = await _scan(db, tmp_path)

    async with db.session() as session:
        views = (await list_similar_items(library_id, ids["目标片"], 12, session, _ADMIN)).data

    # 同一位主角（第一番对第一番）且类型全对上的排第一，同导演（类型只对上一半）次之；
    # 只同「剧情」的垫底；动画（硬边界）与毫无共同点的喜剧不出现；目标片自己不出现
    assert [v.title for v in views] == ["同主演", "同导演", "只同剧情"]
    assert all(v.library_id == library_id for v in views)


async def test_similar_respects_content_limit(db, tmp_path) -> None:
    """儿童档案看不到的片，相似推荐里同样出不来。"""
    library_id, ids = await _scan(db, tmp_path)
    async with db.session() as session:
        meta = (
            await session.execute(
                select(MediaMetadata).where(MediaMetadata.media_item_id == ids["同导演"])
            )
        ).scalar_one()
        meta.content_rating = "R"
        session.add(meta)
        await session.commit()

    async with db.session() as session:
        views = await build_similar_wall(
            session,
            ids["目标片"],
            library_ids=frozenset({library_id}),
            member_id=0,
            content_limit=ContentLimit(max_age=12, allow_unrated=True),
            limit=12,
        )
    assert [v.title for v in views] == ["同主演", "只同剧情"]


async def test_similar_outside_scope_is_empty(db, tmp_path) -> None:
    """候选只在给定的库范围里挑：范围里没有它的库，就什么都不出。"""
    _library_id, ids = await _scan(db, tmp_path)
    async with db.session() as session:
        views = await build_similar_wall(
            session,
            ids["目标片"],
            library_ids=frozenset({999}),
            member_id=0,
            content_limit=None,
            limit=12,
        )
    assert views == []
