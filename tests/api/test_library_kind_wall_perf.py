"""按类型的跨库墙（首页「全部电影」行）的端到端性能守卫。

跨库墙把单库墙的 ``library_id = ?`` 换成 ``library_id IN (...)``，查询形状
其余逐字相同（docs/design/library-home-perspective.md §8）。这里造两组「同类型
两个库、部分作品两库都有」的数据，**故意不刷新查询统计**（最坏情形，与
test_library_facets_perf 同一前提），走真实 HTTP 接口锁两件事：

1. **结果正确**：概况里的作品数是跨库去重后的数，与逐页翻完的墙一致；
2. **不随库数爆炸**：首页每一档排序的一行、墙页深翻页都在宽松上限内。

上限远高于实测（本机此规模下每个请求几十毫秒，更大的 5 万部 / 36 万文件
也在 30~300ms），远低于任何退化成"每条目扫一遍文件"的写法，CI 机器慢也不会误报。
"""

from __future__ import annotations

import time

import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import FileSource, FileState, LibraryFile, MediaItem, PlaybackState, utcnow
from movieclaw_db.repositories.library_repo import LibraryRepository

_MOVIES_PER_LIBRARY = 3000
_SHOWS_PER_LIBRARY = 150
_EPISODES = 40
#: 两个库之间重叠的比例：重叠的作品两库各有一份文件，墙上只能出现一次
_OVERLAP = 0.3
#: 宽松上限（秒）
_BUDGET = 3.0
#: 真实台账行带音轨/字幕/章节 JSON（几 KB 一行），行太瘦会低估回表的代价
_STREAMS = [{"index": i, "codec": "eac3", "language": "jpn", "title": "x" * 40} for i in range(6)]
_CHAPTERS = [{"start": k * 100, "title": f"Chapter {k}"} for k in range(12)]


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'kind-perf.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


@pytest_asyncio.fixture
async def client(db):
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="管理员")
    app.dependency_overrides[require_login] = lambda: admin
    app.dependency_overrides[require_admin] = lambda: admin
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://testserver") as c:
        # 预热：进程内第一个请求要付一次 schema 构建代价，与查询无关
        await c.get("/api/v1/libraries")
        yield c


async def _seed_pair(db, kind: str, per_library: int, episodes: int) -> int:
    """同一类型的两个库，前后两段各 per_library 部、中间重叠 _OVERLAP。返回去重后的作品数。"""
    total = int(per_library * (2 - _OVERLAP))
    async with db.session() as s:
        repo = LibraryRepository(s)
        first = await repo.create(name=f"{kind}-A", kind=kind, root_paths=[f"/{kind}a"])
        second = await repo.create(name=f"{kind}-B", kind=kind, root_paths=[f"/{kind}b"])
        items = [
            MediaItem(
                kind=kind,
                tmdb_id=(1 if kind == "movie" else 2) * 1_000_000 + n,
                title=f"{kind}{n:05d}",
                original_title=f"T{n}",
            )
            for n in range(total)
        ]
        s.add_all(items)
        await s.flush()
        now = utcnow()
        rows = []
        for library, members in (
            (first, items[:per_library]),
            (second, items[total - per_library :]),
        ):
            for item in members:
                for e in range(episodes):
                    rows.append(
                        dict(
                            library_id=library.id,
                            media_item_id=item.id,
                            season_number=1 if kind == "tv" else 0,
                            episode_number=e + 1 if kind == "tv" else 0,
                            file_path=f"/{library.id}/{item.id}/{e}.mkv",
                            size_bytes=1000 + e,
                            source=FileSource.SCANNED,
                            state=FileState.IN_PLACE,
                            audio_streams=_STREAMS,
                            subtitle_streams=_STREAMS,
                            chapters=_CHAPTERS,
                            created_at=now,
                            updated_at=now,
                        )
                    )
        for i in range(0, len(rows), 3000):
            await s.execute(LibraryFile.__table__.insert(), rows[i : i + 3000])
        await s.commit()
    return total


async def _get(client, url: str):
    started = time.perf_counter()
    resp = await client.get(url)
    elapsed = time.perf_counter() - started
    assert resp.status_code == 200, resp.text
    assert elapsed < _BUDGET, f"{url} 用了 {elapsed:.1f}s"
    return resp.json()["data"]


async def test_kind_walls_correct_and_fast_without_query_stats(db, client) -> None:
    expected = {
        "movie": await _seed_pair(db, "movie", _MOVIES_PER_LIBRARY, 1),
        "tv": await _seed_pair(db, "tv", _SHOWS_PER_LIBRARY, _EPISODES),
    }
    base = "/api/v1/libraries/kinds"
    for kind, total in expected.items():
        summary = await _get(client, f"{base}/{kind}")
        assert summary["item_count"] == total, "同一部片跨库只算一部"
        assert len(summary["library_ids"]) == 2
        pending = await _get(client, f"{base}/{kind}?w=unfinished")
        assert pending["item_count"] == total

        # 首页一行（limit=20）：每一档排序都要快
        for query in (
            "sort=added_at",
            "sort=release_date",
            "sort=rating",
            "sort=last_played&w=seen",
            "sort=random",
            "sort=title",
            "sort=added_at&w=unwatched",
            "sort=title&w=unfinished",
        ):
            await _get(client, f"{base}/{kind}/items?{query}&limit=20")

        # 墙页翻到底：不重不漏、每页都快
        seen: list[int] = []
        offset = 0
        while True:
            page = await _get(client, f"{base}/{kind}/items?sort=title&limit=200&offset={offset}")
            seen += [row["media_item_id"] for row in page]
            if len(page) < 200:
                break
            offset += 200
        assert len(seen) == len(set(seen)) == total


async def test_unfinished_http_excludes_completed_show_with_resume_point(db, client) -> None:
    """24 集都有已看勾、23 集残留旧进度：首页概况与展开列表都应排除。"""
    total = await _seed_pair(db, "tv", 2, 24)
    async with db.session() as session:
        item = (await session.execute(select(MediaItem).order_by(MediaItem.id))).scalars().first()
        item_id = item.id
        for episode in range(1, 25):
            session.add(
                PlaybackState(
                    member_id=0,
                    media_item_id=item_id,
                    season_number=1,
                    episode_number=episode,
                    played=True,
                    position_ms=2_265_318 if episode == 23 else 0,
                )
            )
        await session.commit()

    base = "/api/v1/libraries/kinds/tv"
    summary = await _get(client, f"{base}?w=unfinished")
    assert summary["item_count"] == total - 1
    rows = await _get(client, f"{base}/items?w=unfinished")
    assert len(rows) == total - 1
    assert item_id not in {row["media_item_id"] for row in rows}
    # 明确取消一集的已看勾后，该剧应重新出现。
    async with db.session() as session:
        state = (
            await session.execute(
                select(PlaybackState).where(
                    PlaybackState.media_item_id == item_id, PlaybackState.episode_number == 24
                )
            )
        ).scalar_one()
        state.played = False
        await session.commit()
    assert (await _get(client, f"{base}?w=unfinished"))["item_count"] == total
    rows = await _get(client, f"{base}/items?w=unfinished")
    assert item_id in {row["media_item_id"] for row in rows}
