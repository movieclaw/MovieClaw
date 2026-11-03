"""#1123：下载完成 → 季集解析 → 入库作业 → 待处理 HTTP 清单。

生成真实 MKV，使用真实 ffprobe、数据库、作业调度与 HTTP 路由；下载器完成
信号和 TMDB 元数据在边界打桩。不依赖前端或真实 BT/TMDB 服务。
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import httpx
import pytest
from fastapi import FastAPI
from sqlmodel import select
from tests.api.test_library_ingest import (
    _get_library,
    _make_library,
    _make_rule,
    _wait_job_status,
)
from tests.api.test_library_ingest import db as db

from movieclaw_api.api.routes.import_watch import router
from movieclaw_api.services import acquisition_ingest, jobs
from movieclaw_api.services.library import ingest
from movieclaw_db.engine import get_session
from movieclaw_db.models import (
    ImportWatch,
    IngestEntry,
    IngestStatus,
    Job,
    JobStatus,
    LibraryFile,
    ManualDownloadIntent,
    MediaEpisode,
    MediaItem,
    MediaSeason,
)
from movieclaw_downloader import TorrentBrief
from movieclaw_media.models import MediaKind

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not (shutil.which("ffmpeg") and shutil.which("ffprobe")),
        reason="需要 ffmpeg / ffprobe 生成和探测真实视频",
    ),
]


@pytest.mark.asyncio
@pytest.mark.parametrize("marker", ["S03E00", "S00E00", "S00E84"])
async def test_manual_download_completion_to_library_or_pending(db, tmp_path, monkeypatch, marker):
    root, watch = tmp_path / "tv", tmp_path / "watch"
    watch.mkdir()
    library_id = await _make_library(db, kind=MediaKind.TV, root=root)
    await _make_rule(db, library_id=library_id, source=watch)
    filename = f"音乐缘计划.Melody.Journey.{marker}.2026.1080p.iQIYI.WEB-DL.H264.AAC-ADWeb.mkv"
    source = watch / filename
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=320x180:r=1",
            "-t",
            "1",
            "-c:v",
            "libx264",
            str(source),
        ],
        check=True,
        timeout=30,
    )
    original = source.read_bytes()

    # 等价 TMDB 数据：先导片在 S00E84，没有 E00；手动下载已锚定作品身份。
    async with db.session() as session:
        item = MediaItem(
            kind="tv",
            tmdb_id=261394,
            title="音乐缘计划",
            original_title="音乐缘计划",
            year=2024,
        )
        session.add(item)
        await session.commit()
        await session.refresh(item)
        for number in (0, 1, 2, 3):
            session.add(MediaSeason(media_item_id=item.id, season_number=number))
        session.add(
            MediaEpisode(
                media_item_id=item.id,
                season_number=0,
                episode_number=84,
                name="先导片",
            )
        )
        session.add(
            ManualDownloadIntent(
                info_hash="1123manual",
                media_item_id=item.id,
                library_id=library_id,
                download_name=filename,
                save_path=str(watch),
            )
        )
        await session.commit()
        rule = (await session.execute(select(ImportWatch))).scalar_one()

    brief = TorrentBrief(
        name=filename,
        content_name=filename,
        info_hash="1123manual",
        completed=False,
    )

    async def briefs():
        return [brief]

    async def unexpected_identify(*args, **kwargs):
        pytest.fail("应通过真实 infohash 身份锚匹配手动下载")

    async def no_assets(*args, **kwargs):
        pass

    monkeypatch.setattr(acquisition_ingest, "downloader_briefs", briefs)
    monkeypatch.setattr(ingest, "_identify", unexpected_identify)
    monkeypatch.setattr("movieclaw_api.services.media_scrape.ensure_assets", no_assets)
    library = await _get_library(db, library_id)
    await ingest._sweep_dir(rule, library)
    async with db.session() as session:
        assert not (await session.execute(select(Job))).scalars().all()
        assert not (await session.execute(select(IngestEntry))).scalars().all()

    brief.completed = True
    await ingest._sweep_dir(rule, library)
    async with db.session() as session:
        job = (
            await session.execute(select(Job).where(Job.job_type == "library.ingest"))
        ).scalar_one()
    pilot = marker.endswith("E00")
    await jobs.init_job_dispatcher(max_parallel=1)
    await _wait_job_status(job.id, JobStatus.BLOCKED if pilot else JobStatus.SUCCEEDED, timeout=30)
    await jobs.close_job_dispatcher()

    async def session_override():
        async with db.session() as session:
            yield session

    app = FastAPI()
    app.include_router(router, prefix="/api/v1")
    app.dependency_overrides[get_session] = session_override
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        pending = await client.get(f"/api/v1/import-watch/{rule.id}/entries?status=pending")
        history = await client.get(f"/api/v1/import-watch/{rule.id}/entries?status=imported")
        assert pending.status_code == history.status_code == 200
        [entry] = (pending if pilot else history).json()["data"]["entries"]
        assert (history if pilot else pending).json()["data"]["entries"] == []
        assert entry["status"] == (IngestStatus.PENDING if pilot else IngestStatus.IMPORTED)
        assert entry["imported_count"] == (0 if pilot else 1)
        async with db.session() as session:
            files = (await session.execute(select(LibraryFile))).scalars().all()
            intents = (await session.execute(select(ManualDownloadIntent))).scalars().all()
        if pilot:
            assert files == []
            assert len(intents) == 1  # 未入库，身份锚不能被当作成功消费
            assert "第 0 集（先导/特辑），暂不自动入库" in entry["message"]
            assert "无需整理" not in entry["message"]
            # 复用已有人工处理操作；不需要新 UI 或新接口。
            ignored = await client.post(f"/api/v1/import-watch/entries/{entry['id']}/ignore")
            assert ignored.status_code == 200
            assert ignored.json()["data"]["status"] == IngestStatus.IGNORED
        else:
            [file] = files
            assert (file.season_number, file.episode_number) == (0, 84)
            assert "Season 00" in file.file_path
            assert Path(file.file_path).read_bytes() == original
            assert intents == []
    assert source.read_bytes() == original
