"""图片资产补齐不占着数据库连接等图床（#1327）。

每次认领/入库挂锚都会在后台起一次 ``ensure_assets``。``download_item_assets``
以前读完库就带着那条连接去排全局图床闸（2 路）、逐张下图、再逐集抓帧——
连续认领时排队中的每个后台任务各压着一条连接，池子（5+10）很快被占满，
全站写接口 30 秒超时 500。这里用合成数据、少量并发（远低于池子容量）
验证：下载/抓帧进行时不持有连接，结果仍照常落库。
"""

from __future__ import annotations

import asyncio
import threading
from pathlib import Path

import pytest_asyncio

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import media_scrape
from movieclaw_api.services.library import thumbs
from movieclaw_api.services.media_scrape import download_item_assets
from movieclaw_api.services.scrape_config import reset_scrape_config
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaEpisode,
    MediaItem,
    MediaMetadata,
)
from movieclaw_db.repositories.library_repo import LibraryRepository


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'pool.db'}")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    get_settings.cache_clear()
    reset_scrape_config()
    # 模块级闸在争用后会绑定到上一条用例的事件循环：每条用例换一把新的（容量同生产）
    monkeypatch.setattr(media_scrape, "_asset_semaphore", asyncio.Semaphore(2))
    monkeypatch.setattr(thumbs, "FRAME_GRAB_GATE", asyncio.Semaphore(2))
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    reset_scrape_config()
    get_settings.cache_clear()


async def _seed(session, root: Path, count: int) -> list[int]:
    """``count`` 部单集剧：E1 有 TMDB 剧照（走下载），E2 没有（走抓帧）。"""
    library = await LibraryRepository(session).create(
        name="剧集库", kind="tv", root_paths=[str(root)], generate_thumbnails=True
    )
    ids: list[int] = []
    for n in range(count):
        item = MediaItem(
            kind="tv",
            tmdb_id=1000 + n,
            title=f"剧{n}",
            original_title="Show",
            year=2020,
            poster_path=f"/p{n}.jpg",
        )
        session.add(item)
        await session.commit()
        await session.refresh(item)
        session.add(MediaMetadata(media_item_id=item.id))
        for ep, still in ((1, f"/s{n}e1.jpg"), (2, None)):
            session.add(
                MediaEpisode(
                    media_item_id=item.id, season_number=1, episode_number=ep, still_path=still
                )
            )
            video = root / f"剧{n}" / f"剧{n}.S01E{ep:02d}.mkv"
            video.parent.mkdir(parents=True, exist_ok=True)
            video.write_bytes(b"video")
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=item.id,
                    season_number=1,
                    episode_number=ep,
                    file_path=str(video),
                    size_bytes=5,
                    source=FileSource.SCANNED,
                    state=FileState.IN_PLACE,
                    duration_seconds=1200,
                )
            )
        await session.commit()
        ids.append(item.id)
    return ids


async def _held_while_stalled(pool, ready) -> int:  # noqa: ANN001
    """等任务卡进慢操作（``ready``），再给闸外排队的任务留够读库的时间，返回仍借出的连接数。

    不用固定睡眠判定：修复前排队的任务会一直借着连接直到放行，轮询到 0 只可能是修复后。
    """
    for _ in range(500):
        if ready():
            break
        await asyncio.sleep(0.01)
    assert ready(), "任务没有走到慢操作，用例前提不成立"
    for _ in range(200):
        if pool.checkedout() == 0:
            break
        await asyncio.sleep(0.01)
    return pool.checkedout()


async def test_asset_download_releases_connection_while_waiting_on_image_host(
    db, tmp_path, monkeypatch
) -> None:
    async with db.session() as session:
        ids = await _seed(session, tmp_path / "media", 4)

    pool = db.engine.pool
    downloading = 0
    release_download = asyncio.Event()
    grabs_started: list[Path] = []
    release_grab = threading.Event()

    async def slow_sync_asset(base, size, path, dest, current, sources, key, **kwargs):
        # 图床慢：每张图都在这里等
        nonlocal downloading
        downloading += 1
        await release_download.wait()
        if not path:
            return current
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"img")
        return dest.relative_to(media_scrape.assets_root()).as_posix()

    def slow_grab(video, dest, *, duration_seconds, hdr=None):
        # 解码慢：在线程里卡住，直到测试放行
        grabs_started.append(video)
        release_grab.wait(timeout=10)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"frame")
        return (640, 360)

    monkeypatch.setattr(media_scrape, "_sync_asset", slow_sync_asset)
    monkeypatch.setattr(thumbs, "build_episode_still", slow_grab)

    # 四次连续认领的后台补齐同时在跑：两个进了图床闸，两个在闸外排队
    tasks = [asyncio.create_task(download_item_assets(i)) for i in ids]
    held_while_downloading = await _held_while_stalled(pool, lambda: downloading >= 2)
    release_download.set()

    # 抓帧闸同样 2 路：两个在解码，其余排队
    held_while_grabbing = await _held_while_stalled(pool, lambda: len(grabs_started) >= 2)
    release_grab.set()
    await asyncio.gather(*tasks)

    assert held_while_downloading == 0, f"等图床期间仍借着 {held_while_downloading} 条连接"
    assert held_while_grabbing == 0, f"抓帧期间仍借着 {held_while_grabbing} 条连接"

    # 行为不变：海报、TMDB 剧照、抓帧剧照都照常落库
    async with db.session() as session:
        for item_id in ids:
            meta = await session.get(MediaMetadata, item_id)
            assert meta is not None and meta.poster_file
            episodes = sorted(
                (
                    await session.execute(
                        MediaEpisode.__table__.select().where(MediaEpisode.media_item_id == item_id)
                    )
                ).all(),
                key=lambda r: r.episode_number,
            )
            assert [bool(e.still_file) for e in episodes] == [True, True]
    assert pool.checkedout() == 0


async def test_local_assets_release_connection_while_grabbing(db, tmp_path, monkeypatch) -> None:
    """本地来源条目（含影视库里未识别文件的临时条目）抓帧补主图同理：排闸解码时不占连接。"""
    from movieclaw_db.models import MediaSource

    root = tmp_path / "media"
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="其他库", kind="tv", root_paths=[str(root)], generate_thumbnails=True
        )
        ids: list[int] = []
        for n in range(3):
            item = MediaItem(
                kind="tv",
                source=MediaSource.LOCAL,
                external_id=f"local-{n}",
                title=f"本地{n}",
                original_title=f"本地{n}",
            )
            session.add(item)
            await session.commit()
            await session.refresh(item)
            video = root / f"本地{n}.mkv"
            video.parent.mkdir(parents=True, exist_ok=True)
            video.write_bytes(b"video")
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=item.id,
                    file_path=str(video),
                    size_bytes=5,
                    source=FileSource.SCANNED,
                    state=FileState.IN_PLACE,
                    duration_seconds=1200,
                )
            )
            await session.commit()
            ids.append(item.id)

    pool = db.engine.pool
    started: list[Path] = []
    release = threading.Event()

    def slow_thumbnail(video, dest, **kwargs):
        started.append(video)
        release.wait(timeout=10)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"thumb")
        return (320, 480)

    monkeypatch.setattr(thumbs, "build_thumbnail", slow_thumbnail)
    monkeypatch.setattr(thumbs, "build_backdrop", lambda video, dest: False)
    monkeypatch.setattr(thumbs, "blur_placeholder", lambda path: None)

    tasks = [asyncio.create_task(thumbs.ensure_local_assets(i)) for i in ids]
    # 两个在解码，第三个在抓帧闸外排队
    held = await _held_while_stalled(pool, lambda: len(started) >= 2)
    release.set()
    await asyncio.gather(*tasks)

    assert held == 0, f"抓帧期间仍借着 {held} 条连接"
    async with db.session() as session:
        for item_id in ids:
            meta = await session.get(MediaMetadata, item_id)
            assert meta is not None and meta.poster_file
