"""按 Matroska Cues 只读字幕块（docs/design/subtitle-cues.md）。

夹具 ``fixtures/subtitle_cues/subtitles.mkv``：20 秒小视频 + 两条内封字幕（SRT 3 条、ASS 2 条），
ffmpeg 封装（Cluster 里先写 CRC-32，Cues 给每条字幕记了块内偏移）。不依赖 ffmpeg 的用例只验
读块与拼装；转换后与整片抽取逐字节一致的用例标 integration。
"""

from __future__ import annotations

import dataclasses
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from movieclaw_api.services import media_extract
from movieclaw_db.models import FileSource, FileState, LibraryFile
from movieclaw_playback import subtitle_cues
from movieclaw_playback.subtitle_cues import build_subtitle_mkv

FIXTURE = Path(__file__).parent / "fixtures" / "subtitle_cues" / "subtitles.mkv"

needs_ffmpeg = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="需要系统 ffmpeg")


def _build(path: Path, reads: list[tuple[int, int]] | None = None):
    with path.open("rb") as f:
        fd = f.fileno()

        def read_at(length: int, offset: int) -> bytes:
            if reads is not None:
                reads.append((offset, length))
            return os.pread(fd, length, offset)

        return build_subtitle_mkv(f, read_at, path.stat().st_size, str(path), workers=4)


def test_reads_only_the_subtitle_blocks():
    reads: list[tuple[int, int]] = []
    tracks = _build(FIXTURE, reads)
    assert tracks is not None
    assert tracks.blocks == {2: 3, 3: 2}  # 字幕轨号 → 块数，与内封的条数一致
    assert tracks.start_s == 0.0
    assert tracks.data.startswith(b"\x1a\x45\xdf\xa3")
    # 除了文件头 / Tracks / Cues（走文件对象），按位置读的只有 Cluster 头与各块附近的小窗口
    # （相邻的块合并成一次读；夹具很小，五个块合成了一两次）
    assert len(reads) <= 2 + 5
    assert max(length for _, length in reads) <= subtitle_cues._MERGE_MAX


def test_missing_cues_falls_back(monkeypatch):
    """某条字幕轨在 Cues 里没有索引点：不走快路径（宁可整片读，不能漏字幕）。"""
    real = subtitle_cues._track_cues
    monkeypatch.setattr(
        subtitle_cues,
        "_track_cues",
        lambda *a: [cue for cue in real(*a) if cue.track != 3],
    )
    assert _build(FIXTURE) is None


def test_block_of_another_track_is_rejected(monkeypatch):
    """索引指向的块不是这条轨的（解析错位）：返回 None，不拼出错的字幕。"""
    real = subtitle_cues._track_cues

    def swapped(*args):
        cues = real(*args)
        first = cues[0]
        other = 5 - first.track  # 2 ↔ 3
        return [dataclasses.replace(first, track=other), *cues[1:]]

    monkeypatch.setattr(subtitle_cues, "_track_cues", swapped)
    assert _build(FIXTURE) is None


def test_not_matroska_is_skipped_quietly(tmp_path):
    mp4 = tmp_path / "a.mp4"
    mp4.write_bytes(b"\x00\x00\x00\x20ftypisom" + b"\x00" * 64)
    assert media_extract._sparse_tracks(mp4) is None


def _file(path: Path) -> LibraryFile:
    return LibraryFile(
        id=7,
        library_id=1,
        media_item_id=1,
        file_path=str(path),
        size_bytes=path.stat().st_size,
        source=FileSource.SCANNED,
        state=FileState.IN_PLACE,
        container="mkv",
        subtitle_streams=[
            {"codec": "subrip", "language": "chi"},
            {"codec": "ass", "language": "eng"},
        ],
    )


@pytest.mark.integration
@needs_ffmpeg
async def test_cue_extraction_matches_a_full_read(tmp_path, monkeypatch):
    """快路径产出的 SRT / ASS 与整片 ffmpeg 抽取逐字节一致，且整片通读一次都没跑。"""
    monkeypatch.setattr(media_extract, "cache_dir", lambda: tmp_path / "cache")
    full_reads = []

    async def no_full_read(*args, **kwargs):
        full_reads.append(args)
        return True

    monkeypatch.setattr(media_extract, "_run_ffmpeg", no_full_read)
    video = tmp_path / "movie.mkv"
    shutil.copy(FIXTURE, video)
    file = _file(video)
    srt = await media_extract.extract_track_async(file, 0)
    ass = await media_extract.extract_track_async(file, 1)
    assert srt is not None and ass is not None
    assert full_reads == []

    for index, (track, codec) in enumerate(((srt, "srt"), (ass, "copy"))):
        expected = tmp_path / f"full{index}.{track.format}"
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", str(video), "-map", f"0:s:{index}",
             "-c:s", codec, str(expected)],  # fmt: skip
            check=True,
        )
        assert track.path.read_bytes() == expected.read_bytes()
    assert "第三句" in srt.path.read_text(encoding="utf-8")


@pytest.mark.integration
@needs_ffmpeg
async def test_without_cues_the_full_read_still_runs(tmp_path, monkeypatch):
    monkeypatch.setattr(media_extract, "cache_dir", lambda: tmp_path / "cache")
    monkeypatch.setattr(media_extract, "_sparse_tracks", lambda _video: None)
    video = tmp_path / "movie.mkv"
    shutil.copy(FIXTURE, video)
    srt = await media_extract.extract_track_async(_file(video), 0)
    assert srt is not None and "第一句" in srt.path.read_text(encoding="utf-8")
