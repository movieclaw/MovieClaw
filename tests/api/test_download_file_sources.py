"""媒体库文件的下载来源归下载领域（docs/design/library-boundary.md §5）。

- 迁移把台账上已有的来源拷进 ``download_file_source``；
- 写入规则：知道什么更新什么，扫描重试不抹掉入库时记下的来源；
- 谁的数据谁清理：库文件删了记录还在（下载模块据此处理删除），清扫先记发现时间、满 7 天删除。
"""

from __future__ import annotations

import sqlite3
from datetime import timedelta

import pytest
import pytest_asyncio
from alembic import command
from sqlmodel import select
from tests.api.test_domain_events import seed_show
from tests.api.test_library_provenance import _insert

from movieclaw_api.api.routes.download_sources import list_file_sources
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services.download_sources import ORPHAN_GRACE, record_source, sweep_orphans
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import _build_config, run_migrations
from movieclaw_db.models import DownloadFileSource, FileSource, LibraryFile, utcnow
from movieclaw_db.repositories.library_repo import LibraryRepository

_BEFORE = "087d01dfcecb"


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'sources.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


async def _file(session, library_id: int, name: str) -> LibraryFile:
    row = LibraryFile(
        library_id=library_id, file_path=f"/m/{name}", size_bytes=1, source=FileSource.IMPORTED
    )
    session.add(row)
    await session.flush()
    return row


async def _source(session, file_id: int) -> DownloadFileSource | None:
    return (
        await session.execute(
            select(DownloadFileSource).where(DownloadFileSource.library_file_id == file_id)
        )
    ).scalar_one_or_none()


async def test_record_source_updates_only_what_it_knows(db) -> None:
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="库", kind="movie", root_paths=["/m"]
        )
        row = await _file(session, library.id, "a.mkv")
        stranger = await _file(session, library.id, "b.mkv")

        await record_source(
            session, row.id, info_hash="ABC", downloader_id=None, site_id="ssd", torrent_id="t1"
        )
        # 扫描重试不知道来源：什么都不改
        await record_source(
            session, row.id, info_hash=None, downloader_id=None, site_id=None, torrent_id=None
        )
        # 什么都不知道、也没有旧记录：不写
        await record_source(
            session, stranger.id, info_hash=None, downloader_id=None, site_id=None, torrent_id=None
        )
        await session.commit()

        source = await _source(session, row.id)
        assert (source.info_hash, source.site_id, source.torrent_id) == ("abc", "ssd", "t1")
        assert await _source(session, stranger.id) is None

        # 同一路径被新版本覆盖，入库知道新来源：更新
        await record_source(
            session, row.id, info_hash="new", downloader_id=None, site_id="ttg", torrent_id="t9"
        )
        await session.commit()
        source = await _source(session, row.id)
        assert (source.info_hash, source.site_id, source.torrent_id) == ("new", "ttg", "t9")


async def test_records_outlive_deleted_files_until_the_sweep(db) -> None:
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="库", kind="movie", root_paths=["/m"]
        )
        kept = await _file(session, library.id, "kept.mkv")
        gone = await _file(session, library.id, "gone.mkv")
        for row in (kept, gone):
            await record_source(
                session, row.id, info_hash="h", downloader_id=None, site_id=None, torrent_id=None
            )
        await session.commit()
        gone_id = gone.id
        # 媒体库删文件不级联删别人的记录
        await session.delete(gone)
        await session.commit()
        assert await _source(session, gone_id) is not None

        # 第一次清扫只记下发现时间
        assert await sweep_orphans(session) == 0
        source = await _source(session, gone_id)
        assert source.orphaned_at is not None
        assert (await _source(session, kept.id)).orphaned_at is None

        # 满 7 天删除；还在的文件不受影响
        source.orphaned_at = utcnow() - ORPHAN_GRACE - timedelta(minutes=1)
        await session.commit()
        assert await sweep_orphans(session) == 1
        assert await _source(session, gone_id) is None
        assert await _source(session, kept.id) is not None


def test_migration_copies_existing_provenance(tmp_path, monkeypatch) -> None:
    database = tmp_path / "copy.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, _BEFORE)

    with sqlite3.connect(database) as conn:
        downloader = _insert(conn, "downloader_client", name="qb")
        library = _insert(conn, "library", name="库", root_paths="[]")
        imported = _insert(
            conn,
            "library_file",
            library_id=library,
            file_path="/m/a.mkv",
            source="imported",
            info_hash="ABC",
            downloader_id=downloader,
            site_id="ssd",
            torrent_id="t1",
        )
        site_only = _insert(
            conn,
            "library_file",
            library_id=library,
            file_path="/m/b.mkv",
            source="imported",
            site_id="ssd",
            torrent_id="t2",
        )
        scanned = _insert(
            conn, "library_file", library_id=library, file_path="/m/c.mkv", source="scanned"
        )
        conn.commit()

    command.upgrade(config, "head")
    with sqlite3.connect(database) as conn:
        rows = {
            r[0]: r[1:]
            for r in conn.execute(
                "SELECT library_file_id, info_hash, downloader_id, site_id, torrent_id"
                " FROM download_file_source"
            )
        }
    get_settings.cache_clear()
    assert rows[imported] == ("abc", downloader, "ssd", "t1")
    assert rows[site_only] == (None, None, "ssd", "t2")
    assert scanned not in rows


async def test_file_sources_still_answer_after_the_files_are_deleted(db, tmp_path) -> None:
    seeded = await seed_show(db, tmp_path, info_hash="a" * 40)
    first, second = seeded["file_ids"]
    async with db.session() as session:
        # 媒体库删了第一集：来源记录不随之删除，删片后的清理照样查得到
        await session.delete(await session.get(LibraryFile, first))
        await session.commit()
        reply = await list_file_sources(file_ids=str(first), session=session)
        [torrent] = reply.data
        assert torrent.info_hash == "a" * 40 and torrent.file_ids == [first]
        assert torrent.source == "subscription" and torrent.subscription_id == seeded["sub_id"]
        assert torrent.owned_by_movieclaw is True and torrent.hit_and_run is False
        assert torrent.downloader_name == "qb"
        # 季包还供着第二集
        assert torrent.other_file_ids == [second]

        # 两集一起问：没有别的文件了
        [both] = (await list_file_sources(file_ids=f"{first},{second}", session=session)).data
        assert both.other_file_ids == []

        assert (await list_file_sources(file_ids="999", session=session)).data == []
        with pytest.raises(BadRequestException):
            await list_file_sources(file_ids="x", session=session)
