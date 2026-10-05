"""命名模板新占位符的端到端验证（issue #577）。

只问两件事，全部跑真实链路（真实建库、真实入库落盘、真实整理改名）：

1. 配了新占位符，**磁盘上的名字**真的带上了对应的值；
2. **命名同源**：入库算出的名字，整理再算一遍必须一模一样（零改名）——
   入库侧的值来自探测结果与来源戳，整理侧来自台账行，两侧任何一处格式化
   口径不一致，整理就会把刚入库的文件再改一次名。
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest
import pytest_asyncio
from sqlmodel import select

import movieclaw_api.services.library.ingest as ingest_mod
from movieclaw_api.core.config import get_settings
from movieclaw_api.services import jobs
from movieclaw_api.services.library.organize import organize_library
from movieclaw_api.services.scrape_config import reset_scrape_config
from movieclaw_api.settings import MetadataScrapeSetting
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    FileSource,
    FileState,
    ImportWatch,
    LibraryFile,
    ManualDownloadIntent,
    MediaEpisode,
    MediaItem,
    MediaSeason,
)
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_downloader import TorrentBrief

_SPEC = SimpleNamespace(
    resolution="2160p",
    video_codec="hevc",
    hdr="Dolby Vision",
    bit_depth=10,
    duration_seconds=2700,
    bit_rate=None,
    frame_rate=23.976,
    color_space="BT.2020",
    audio_streams=[
        {
            "codec": "eac3",
            "profile": "Dolby Digital Plus + Dolby Atmos",
            "channels": 6,
            "channel_layout": "5.1(side)",
            "language": "eng",
            "default": True,
        },
    ],
    subtitle_streams=[],
    chapters=[],
)


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'naming.db'}")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    get_settings.cache_clear()
    reset_scrape_config()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    monkeypatch.setattr(ingest_mod, "_stability", {})
    monkeypatch.setattr(ingest_mod, "_deferred", {})
    monkeypatch.setattr(ingest_mod, "_failed_retry", {})
    monkeypatch.setattr(ingest_mod, "_last_swept", {})
    monkeypatch.setattr(ingest_mod, "QUIET_SECONDS", 0)
    monkeypatch.setattr(ingest_mod, "_briefs_cache", (float("-inf"), None))
    monkeypatch.setattr(ingest_mod, "probe_media", lambda _p: _SPEC)
    yield get_database()
    await jobs.close_job_dispatcher()
    await dispose_db()
    reset_scrape_config()
    get_settings.cache_clear()


def _apply_setting(**fields) -> None:
    """全局刮削设置灌进运行时快照（等价于设置页保存后的状态）。"""
    import movieclaw_api.services.scrape_config as cfg

    cfg._current_scrape = MetadataScrapeSetting(**fields)


def _stub_units(monkeypatch) -> None:
    """季集解析依赖 NER 模型：按文件名里的 E 号打桩，全部落第 1 季。"""

    def resolve(files, **_kwargs):
        return {
            f: ingest_mod.FileUnit(season=1, episode=int(f.stem.split("E")[-1][:2])) for f in files
        }

    monkeypatch.setattr(ingest_mod, "resolve_units", resolve)


async def _tv_item(db) -> MediaItem:
    """一部剧：中文名、原名、英文名、豆瓣 ID 齐全，第 1 季有季名与集名。"""
    async with db.session() as session:
        item = MediaItem(
            kind="tv",
            tmdb_id=94997,
            title="龙之家族",
            original_title="House of the Dragon",
            english_title="House of the Dragon",
            douban_id="34845342",
            year=2022,
        )
        session.add(item)
        await session.commit()
        await session.refresh(item)
        session.add(MediaSeason(media_item_id=item.id, season_number=1, name="第 1 季"))
        session.add_all(
            [
                MediaEpisode(
                    media_item_id=item.id, season_number=1, episode_number=1, name="龙王的继承人"
                ),
                MediaEpisode(
                    media_item_id=item.id, season_number=1, episode_number=2, name="叛逆王子"
                ),
            ]
        )
        await session.commit()
        return item


@pytest.mark.asyncio
async def test_ingest_renders_every_new_token_and_organize_agrees(db, tmp_path, monkeypatch):
    _apply_setting(
        naming_entry_dir=(
            "{title} ({original_title}) ({english_title}) ({year}) [douban-{douban_id}]"
        ),
        naming_season_dir="Season {season:02d} {season_name}",
        naming_episode_file=(
            "{title} - S{season:02d}E{episode:02d} - {episode_title} "
            "[{resolution} {video_codec} {hdr} {bit_depth} {audio}] [{site}] {release_name}"
        ),
    )
    root, watch = tmp_path / "tv", tmp_path / "watch"
    root.mkdir()
    watch.mkdir()
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=[str(root)]
        )
        library_id = library.id
    item = await _tv_item(db)
    _stub_units(monkeypatch)

    async def identify_none(*_args):
        return None

    monkeypatch.setattr(ingest_mod, "_identify", identify_none)
    async with db.session() as session:
        session.add(
            ManualDownloadIntent(
                info_hash="hotd", media_item_id=item.id, library_id=library_id, site_id="hdsky"
            )
        )
        await session.commit()
    release = "House.of.the.Dragon.S01.2160p.WEB-DL.DV.DDP5.1.Atmos-FRDS"

    async def briefs():
        return [TorrentBrief(name=release, content_name=release, completed=True, info_hash="hotd")]

    monkeypatch.setattr(ingest_mod, "_downloader_briefs", briefs)
    entry = watch / release
    entry.mkdir()
    for ep in (1, 2):
        (entry / f"House.of.the.Dragon.S01E0{ep}.2160p-FRDS.mkv").write_bytes(b"ep%d" % ep)

    rule = ImportWatch(source_path=str(watch), strategy="hardlink", library_id=None, kind="tv")
    await ingest_mod._sweep_dir(rule, None, execute_inline=True)

    # ① 片名去重：英文名与原名同值只留一个；片名三类各取其值
    entry_dir = root / "龙之家族 (House of the Dragon) (2022) [douban-34845342]"
    season_dir = entry_dir / "Season 01 第 1 季"
    expected = (
        "龙之家族 - S01E01 - 龙王的继承人 [2160p HEVC DV 10bit DDP Atmos 5.1] [hdsky] "
        "House.of.the.Dragon.S01E01.2160p-FRDS.mkv"
    )
    assert (season_dir / expected).read_bytes() == b"ep1", sorted(
        p.relative_to(root).as_posix() for p in root.rglob("*")
    )
    assert (
        season_dir
        / expected.replace("E01 - 龙王的继承人", "E02 - 叛逆王子").replace(
            "S01E01.2160p", "S01E02.2160p"
        )
    ).read_bytes() == b"ep2"

    # ② 台账记下原始文件名（整理改名后它就是 {release_name} 的唯一来源）
    async with db.session() as session:
        rows = list((await session.execute(select(LibraryFile))).scalars().all())
    assert sorted(r.release_name for r in rows) == [
        "House.of.the.Dragon.S01E01.2160p-FRDS",
        "House.of.the.Dragon.S01E02.2160p-FRDS",
    ]

    # ③ 命名同源：整理按台账行重算，必须零改名
    summary = await organize_library(library_id)
    assert summary.errors == []
    assert (summary.renamed, summary.already_ok) == (0, 2)


@pytest.mark.asyncio
async def test_organize_fills_episode_title(db, tmp_path):
    """{episode_title} 此前声明可用却没人供值，整理出来永远是空——回归锚。"""
    _apply_setting(naming_episode_file="{title} S{season:02d}E{episode:02d} {episode_title}")
    root = tmp_path / "tv"
    root.mkdir()
    async with db.session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=[str(root)]
        )
        library_id = library.id
    item = await _tv_item(db)
    src = root / "乱名" / "x.mkv"
    src.parent.mkdir()
    src.write_bytes(b"v")
    async with db.session() as session:
        session.add(
            LibraryFile(
                library_id=library_id,
                media_item_id=item.id,
                season_number=1,
                episode_number=2,
                file_path=str(src),
                size_bytes=1,
                source=FileSource.SCANNED,
                state=FileState.IN_PLACE,
            )
        )
        await session.commit()

    summary = await organize_library(library_id)
    assert summary.errors == []
    target = root / "龙之家族 (2022)" / "Season 01" / "龙之家族 S01E02 叛逆王子.mkv"
    assert target.read_bytes() == b"v"
    # 存量扫描的文件没有来源与原名：{site}/{release_name} 渲染为空，不报错不留残渣
    _apply_setting(
        naming_episode_file=(
            "{title} S{season:02d}E{episode:02d} {episode_title} [{site}] {release_name}"
        )
    )
    summary = await organize_library(library_id)
    assert (summary.renamed, summary.already_ok) == (0, 1)
