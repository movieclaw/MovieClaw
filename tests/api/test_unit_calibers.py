"""「已播 / 在位」口径的仓储层唯一实现测试。

订阅预检与海报墙统计共用 list_seasons_many / aired_units_many / owned_units_many，
本文件锚定这些方法自身的口径：季骨架批量返回、已播=air_date≤今天、
特别季开关、在位=跨库且 missing 不算、批量与单条结果一致。
"""

from __future__ import annotations

from datetime import timedelta

import pytest_asyncio

from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import FileState, LibraryFile, MediaItem, MediaSeason
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.media_metadata import MediaEpisode
from movieclaw_db.repositories.library_file_repo import LibraryFileRepository
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_db.repositories.media_repo import MediaItemRepository


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'caliber.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


async def test_aired_and_owned_calibers(db) -> None:
    today = utcnow().date()
    async with db.session() as session:
        lib1 = await LibraryRepository(session).create(
            name="库一", kind="tv", root_paths=["/a"], match_rules=[]
        )
        lib2 = await LibraryRepository(session).create(
            name="库二", kind="tv", root_paths=["/b"], match_rules=[]
        )
        item = MediaItem(kind="tv", tmdb_id=1, title="剧", original_title="Show", aliases=[])
        session.add(item)
        await session.commit()
        await session.refresh(item)
        session.add_all(
            [
                MediaSeason(
                    media_item_id=item.id,
                    season_number=1,
                    name="第 1 季",
                    episode_count=3,
                ),
                # 已播两集 + 未播一集 + 特别季一集（已播）
                MediaEpisode(
                    media_item_id=item.id, season_number=1, episode_number=1, air_date=today
                ),
                MediaEpisode(
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=2,
                    air_date=today - timedelta(days=1),
                ),
                MediaEpisode(
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=3,
                    air_date=today + timedelta(days=7),
                ),
                MediaEpisode(
                    media_item_id=item.id, season_number=0, episode_number=1, air_date=today
                ),
                # 在位一集（库 1）+ 另一库在位一集（跨库）+ missing 一集
                LibraryFile(
                    source="scanned",
                    library_id=lib1.id,
                    file_path="/a/S01E01.mkv",
                    size_bytes=1,
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=1,
                ),
                LibraryFile(
                    source="scanned",
                    library_id=lib2.id,
                    file_path="/b/S01E02.mkv",
                    size_bytes=1,
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=2,
                ),
                LibraryFile(
                    source="scanned",
                    library_id=lib1.id,
                    file_path="/a/S01E04.mkv",
                    size_bytes=1,
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=4,
                    missing_since=utcnow(),
                    state=FileState.MISSING,
                ),
            ]
        )
        await session.commit()

        media_repo = MediaItemRepository(session)
        file_repo = LibraryFileRepository(session)

        seasons = await media_repo.list_seasons_many([item.id])
        assert [row.season_number for row in seasons[item.id]] == [1]
        assert seasons[item.id][0].episode_count == 3

        # 已播：默认排除特别季；include_specials=True 时带上
        aired = await media_repo.aired_units_many([item.id])
        assert aired[item.id] == {(1, 1), (1, 2)}
        aired_all = await media_repo.aired_units_many([item.id], include_specials=True)
        assert aired_all[item.id] == {(1, 1), (1, 2), (0, 1)}

        # 在位：跨库合并、missing 不算；批量与单条一致
        owned_single = await file_repo.owned_units(item.id)
        owned_many = await file_repo.owned_units_many([item.id])
        assert owned_single == {(1, 1), (1, 2)}
        assert owned_many[item.id] == owned_single

        # 计数版（订阅海报墙用）与集合版同一口径：按季数出来的集数就是集合里该季的单元数
        assert await media_repo.aired_counts_by_season_many([item.id]) == {item.id: {1: 2}}
        assert await media_repo.aired_counts_by_season_many(
            [item.id], include_specials=True
        ) == {item.id: {1: 2, 0: 1}}
        assert await file_repo.owned_counts_by_season_many([item.id]) == {item.id: {1: 2}}
        # 缺集数（海报墙用）= 已播 − 在位：两集都在位，不缺
        assert await media_repo.missing_counts_many([item.id]) == {}

        # 空入参不炸
        assert await media_repo.aired_units_many([]) == {}
        assert await media_repo.list_seasons_many([]) == {}
        assert await file_repo.owned_units_many([]) == {}
        assert await media_repo.aired_counts_by_season_many([]) == {}
        assert await media_repo.missing_counts_many([]) == {}
        assert await file_repo.owned_counts_by_season_many([]) == {}


async def test_owned_counts_count_an_episode_once_across_versions(db) -> None:
    """同一集的 1080p 与 2160p 两个版本（甚至分在两个库）只算一集——
    计数版必须与集合版的去重口径一致，否则海报墙会写出「已有 3/2 集」。"""
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="库", kind="tv", root_paths=["/a"], match_rules=[]
        )
        other = await LibraryRepository(session).create(
            name="4K 库", kind="tv", root_paths=["/b"], match_rules=[]
        )
        item = MediaItem(kind="tv", tmdb_id=2, title="剧", original_title="Show", aliases=[])
        session.add(item)
        await session.commit()
        await session.refresh(item)
        for library_id, name in ((library.id, "/a/E01.1080p.mkv"), (other.id, "/b/E01.2160p.mkv")):
            session.add(
                LibraryFile(
                    source="scanned",
                    library_id=library_id,
                    file_path=name,
                    size_bytes=1,
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=1,
                )
            )
        await session.commit()

        file_repo = LibraryFileRepository(session)
        assert await file_repo.owned_units_many([item.id]) == {item.id: {(1, 1)}}
        assert await file_repo.owned_counts_by_season_many([item.id]) == {item.id: {1: 1}}


async def test_missing_counts_match_aired_minus_owned(db) -> None:
    """缺集数在库里算，口径必须与集合版「已播 − 在位」逐条一致：只剩 missing 文件的
    已播集算缺；特别季、未播集不算；另一库在位的不算缺。"""
    today = utcnow().date()
    async with db.session() as session:
        lib1 = await LibraryRepository(session).create(
            name="库一", kind="tv", root_paths=["/a"], match_rules=[]
        )
        lib2 = await LibraryRepository(session).create(
            name="库二", kind="tv", root_paths=["/b"], match_rules=[]
        )
        shows = []
        for tmdb_id in (3, 4):
            show = MediaItem(kind="tv", tmdb_id=tmdb_id, title="剧", original_title="S", aliases=[])
            session.add(show)
            shows.append(show)
        await session.commit()
        for show in shows:
            await session.refresh(show)
        show, complete = shows
        rows: list = [
            MediaEpisode(media_item_id=show.id, season_number=1, episode_number=n, air_date=today)
            for n in (1, 2, 3, 4)
        ]
        rows += [
            MediaEpisode(
                media_item_id=show.id,
                season_number=1,
                episode_number=5,
                air_date=today + timedelta(days=1),
            ),
            MediaEpisode(media_item_id=show.id, season_number=0, episode_number=1, air_date=today),
            MediaEpisode(
                media_item_id=complete.id, season_number=1, episode_number=1, air_date=today
            ),
        ]

        def file(library_id, item_id, episode, path, state=FileState.IN_PLACE):
            return LibraryFile(
                source="scanned",
                library_id=library_id,
                file_path=path,
                size_bytes=1,
                media_item_id=item_id,
                season_number=1,
                episode_number=episode,
                state=state,
                missing_since=None if state == FileState.IN_PLACE else utcnow(),
            )

        rows += [
            file(lib1.id, show.id, 1, "/a/E01.mkv"),
            file(lib2.id, show.id, 2, "/b/E02.mkv"),  # 另一库在位：不缺
            file(lib1.id, show.id, 3, "/a/E03.mkv", FileState.MISSING),  # 只剩失联文件：缺
            file(lib1.id, complete.id, 1, "/a/C01.mkv"),
        ]
        session.add_all(rows)
        await session.commit()

        media_repo = MediaItemRepository(session)
        file_repo = LibraryFileRepository(session)
        ids = [show.id, complete.id]
        aired = await media_repo.aired_units_many(ids)
        owned = await file_repo.owned_units_many(ids)
        expected = {i: len(aired[i] - owned.get(i, set())) for i in aired}
        assert {i: n for i, n in expected.items() if n} == {show.id: 2}  # E03、E04
        assert await media_repo.missing_counts_many(ids) == {show.id: 2}
