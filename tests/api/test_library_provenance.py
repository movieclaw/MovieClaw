"""媒体库文件的来源种子（docs/design/plugin-phase2a.md §5.1）。

- 原地下载由扫描入账：按下载记录的「保存目录/内容名」反查下载器任务；
- 再次扫描同一路径（缺失回归、识别重试）不把入库时记下的来源抹掉；
- 迁移回填：旧行按同一条目、同站点同种子编号的订阅下载记录补齐。
入库（监听导入）写来源的测试在 test_library_ingest.py。
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest_asyncio
from alembic import command
from sqlmodel import select

import movieclaw_api.services.library.scan as scan_mod
from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import _build_config, run_migrations
from movieclaw_db.models import (
    DownloaderClient,
    DownloadFileSource,
    FileSource,
    LibraryFile,
    ManualDownloadIntent,
    MediaItem,
    RuleSet,
    Subscription,
    SubscriptionDownloadAttempt,
    utcnow,
)
from movieclaw_db.repositories.library_file_repo import LibraryFileRepository
from movieclaw_db.repositories.library_repo import LibraryRepository


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'provenance.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    monkeypatch.setattr(scan_mod, "NEW_FILE_QUIET_SECONDS", 0)
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


async def _seed_sources(db, root: Path) -> None:
    """一部剧：订阅把季包原地下到库根下；另有一个手动下载的单文件种子。"""
    async with db.session() as session:
        downloader = DownloaderClient(
            name="qb", client_type="qbittorrent", url="http://qb", is_default=True
        )
        item = MediaItem(kind="tv", tmdb_id=1, title="测试剧集", original_title="Test Show")
        movie = MediaItem(kind="movie", tmdb_id=2, title="测试电影", original_title="Test Movie")
        session.add_all([downloader, item, movie])
        await session.flush()
        rule_set = RuleSet(name="默认", spec={})
        session.add(rule_set)
        await session.flush()
        sub = Subscription(media_item_id=item.id, kind="tv", rule_set_id=rule_set.id)
        session.add(sub)
        await session.flush()
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=[str(root)]
        )
        session.add_all(
            [
                SubscriptionDownloadAttempt(
                    subscription_id=sub.id,
                    downloader_id=downloader.id,
                    info_hash="OLDHASH",
                    save_path=str(root),
                    download_name="Test.Show.S01.1080p",
                    last_progress_at=utcnow(),
                ),
                # 同一个内容根后来又投了一次（换源）：取最新一次
                SubscriptionDownloadAttempt(
                    subscription_id=sub.id,
                    downloader_id=downloader.id,
                    info_hash="PACKHASH",
                    save_path=str(root) + "/",
                    download_name="Test.Show.S01.1080p",
                    last_progress_at=utcnow(),
                ),
                ManualDownloadIntent(
                    info_hash="moviehash",
                    media_item_id=movie.id,
                    library_id=library.id,
                    downloader_id=downloader.id,
                    save_path=str(root),
                    download_name="Test.Movie.2024.mkv",
                ),
            ]
        )
        await session.commit()


async def test_download_roots_map_pack_folders_and_single_files(db, tmp_path) -> None:
    root = tmp_path / "media" / "tv"
    await _seed_sources(db, root)
    async with db.session() as session:
        roots = await scan_mod._load_download_roots(session)
    pack = root / "Test.Show.S01.1080p"
    assert scan_mod._download_for(pack / "Season 1" / "E01.mkv", roots) == ("packhash", 1)
    assert scan_mod._download_for(root / "Test.Movie.2024.mkv", roots) == ("moviehash", 1)
    assert scan_mod._download_for(root / "Other" / "E01.mkv", roots) is None
    assert scan_mod._download_for(root / "Test.Show.S01.1080p.extra", roots) is None


async def test_scan_records_source_torrent_of_inplace_downloads(db, tmp_path) -> None:
    root = tmp_path / "media" / "tv"
    pack = root / "Test.Show.S01.1080p"
    pack.mkdir(parents=True)
    (pack / "Test.Show.S01E01.1080p.mkv").write_bytes(b"e1")
    stranger = root / "Unrelated.Show.S01E01.mkv"
    stranger.write_bytes(b"x")
    await _seed_sources(db, root)
    async with db.session() as session:
        library = (await LibraryRepository(session).list_all())[0]
    await scan_mod.scan_library(library.id)

    async with db.session() as session:
        rows = {
            Path(r.file_path).name: r
            for r in (await session.execute(select(LibraryFile))).scalars()
        }
    assert rows["Test.Show.S01E01.1080p.mkv"].info_hash == "packhash"
    assert rows["Test.Show.S01E01.1080p.mkv"].downloader_id == 1
    assert rows["Unrelated.Show.S01E01.mkv"].info_hash is None
    # 种子关联归下载领域（library-boundary.md §5）：扫描同时记一份，不知道来源的不记
    async with db.session() as session:
        sources = {
            s.library_file_id: s
            for s in (await session.execute(select(DownloadFileSource))).scalars()
        }
    pack_row = rows["Test.Show.S01E01.1080p.mkv"]
    assert sources[pack_row.id].info_hash == "packhash"
    assert sources[pack_row.id].downloader_id == 1
    assert rows["Unrelated.Show.S01E01.mkv"].id not in sources


async def test_rescan_does_not_erase_recorded_source(db, tmp_path) -> None:
    root = tmp_path / "media" / "tv"
    root.mkdir(parents=True)
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=[str(root)]
        )
        repo = LibraryFileRepository(session)
        path = str(root / "a.mkv")
        await repo.upsert_by_path(
            LibraryFile(
                library_id=library.id,
                file_path=path,
                size_bytes=1,
                source=FileSource.IMPORTED,
                info_hash="importedhash",
            )
        )
        # 识别重试 / 缺失回归走扫描：不知道来源，不能把已记下的抹掉
        await repo.upsert_by_path(
            LibraryFile(
                library_id=library.id, file_path=path, size_bytes=1, source=FileSource.SCANNED
            )
        )
        assert (await repo.get_by_path(path)).info_hash == "importedhash"
        # 同一路径被新版本覆盖（入库知道新来源）：更新
        await repo.upsert_by_path(
            LibraryFile(
                library_id=library.id,
                file_path=path,
                size_bytes=2,
                source=FileSource.IMPORTED,
                info_hash="newhash",
            )
        )
        assert (await repo.get_by_path(path)).info_hash == "newhash"


# ---------------------------------------------------------------------- 迁移回填
_BEFORE = "b3f1c7a9e2d4"


def _insert(conn: sqlite3.Connection, table: str, **values: object) -> int:
    """按表结构补齐 NOT NULL 且无默认值的列，只为造一行能插进去的旧数据。"""
    filler = {"INTEGER": 0, "BOOLEAN": 0, "FLOAT": 0.0, "DATETIME": "2026-01-01 00:00:00"}
    for _cid, name, col_type, notnull, default, pk in conn.execute(f"PRAGMA table_info({table})"):
        if name in values or pk or not notnull or default is not None:
            continue
        upper = (col_type or "").upper()
        if upper == "JSON":
            values[name] = "[]"
        else:
            values[name] = next((v for k, v in filler.items() if k in upper), "x")
    cols = ", ".join(values)
    marks = ", ".join("?" for _ in values)
    return conn.execute(
        f"INSERT INTO {table} ({cols}) VALUES ({marks})", list(values.values())
    ).lastrowid


def test_migration_backfills_source_torrent_from_attempts(tmp_path, monkeypatch) -> None:
    database = tmp_path / "backfill.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{database}")
    get_settings.cache_clear()
    config = _build_config()
    command.upgrade(config, _BEFORE)

    with sqlite3.connect(database) as conn:
        downloader = _insert(conn, "downloader_client", name="qb")
        item = _insert(
            conn,
            "media_item",
            kind="tv",
            source="tmdb",
            tmdb_id=1,
            external_id="1",
            title="甲",
            original_title="A",
        )
        other = _insert(
            conn,
            "media_item",
            kind="tv",
            source="tmdb",
            tmdb_id=2,
            external_id="2",
            title="乙",
            original_title="B",
        )
        library = _insert(conn, "library", name="剧集库", root_paths="[]")
        rules = _insert(conn, "rule_set", name="默认", spec="{}")
        sub = _insert(conn, "subscription", media_item_id=item, kind="tv", rule_set_id=rules)
        other_sub = _insert(conn, "subscription", media_item_id=other, kind="tv", rule_set_id=rules)
        for sub_id, info_hash in ((sub, "OLD"), (sub, "NEW"), (other_sub, "WRONG")):
            _insert(
                conn,
                "subscription_download_attempt",
                subscription_id=sub_id,
                downloader_id=downloader,
                info_hash=info_hash,
                site_id="ssd",
                torrent_id="t1",
                units="[]",
            )
        matched = _insert(
            conn,
            "library_file",
            library_id=library,
            media_item_id=item,
            file_path="/m/a.mkv",
            site_id="ssd",
            torrent_id="t1",
            source="imported",
        )
        scanned = _insert(
            conn,
            "library_file",
            library_id=library,
            media_item_id=item,
            file_path="/m/b.mkv",
            source="scanned",
        )
        _insert(
            conn, "manual_download_intent", info_hash="m", media_item_id=item, library_id=library
        )

    command.upgrade(config, "head")
    with sqlite3.connect(database) as conn:
        rows = dict(
            (r[0], (r[1], r[2]))
            for r in conn.execute("SELECT id, info_hash, downloader_id FROM library_file")
        )
        owners = [r[0] for r in conn.execute("SELECT owner FROM manual_download_intent")]
    # 同一条目、同站点同种子编号的最近一次投递；别的条目的同号投递不算
    assert rows[matched] == ("new", downloader)
    assert rows[scanned] == (None, None)
    assert owners == ["manual"]
    get_settings.cache_clear()


async def test_scan_commits_the_source_right_away(db, tmp_path, monkeypatch) -> None:
    """来源记录当场提交，不靠扫描后段顺带提交：没有 ffprobe 时补探整段跳过，
    之前就这样把最后一个文件的来源丢了（CI 上复现）。"""
    from movieclaw_api.services import media_probe

    monkeypatch.setattr(media_probe, "ffprobe_available", lambda: False)
    root = tmp_path / "media" / "tv"
    pack = root / "Test.Show.S01.1080p"
    pack.mkdir(parents=True)
    (pack / "Test.Show.S01E01.1080p.mkv").write_bytes(b"e1")
    await _seed_sources(db, root)
    async with db.session() as session:
        library = (await LibraryRepository(session).list_all())[0]
    await scan_mod.scan_library(library.id)

    async with db.session() as session:
        [row] = (await session.execute(select(LibraryFile))).scalars()
        [source] = (await session.execute(select(DownloadFileSource))).scalars()
    assert source.library_file_id == row.id and source.info_hash == "packhash"
