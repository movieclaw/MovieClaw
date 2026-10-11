"""网盘条目的探测记录（docs/design/plugin-strm-prefetch.md §4）。

- 连续失败按 1 小时、6 小时、1 天、封顶 3 天退避；后台探测遵守，首播不受限；
- 成功清零并记下直链的主机 + 路径；直链换了文件，之前的失败不算；
- 扫描发现 .strm 改写：换了文件清空规格待重探，只换签名参数规格照旧。
"""

from __future__ import annotations

import os
from datetime import timedelta
from pathlib import Path

import pytest

from movieclaw_api.services.media_probe import MediaSpec
from movieclaw_api.services.playback import strm_probe
from movieclaw_api.services.playback.strm_probe import (
    backoff_after,
    ensure_strm_spec,
    probe_file,
    refresh_rewritten_strm,
    strm_target,
)
from movieclaw_db.engine import get_database
from movieclaw_db.models import FileSource, FileState, LibraryFile, StrmProbeState
from movieclaw_db.models.base import utcnow
from movieclaw_db.repositories.library_repo import LibraryRepository

SPEC = MediaSpec(
    resolution="1080p",
    video_codec="h264",
    hdr=None,
    bit_depth=8,
    duration_seconds=30,
    bit_rate=4_000_000,
    audio_streams=[{"codec": "aac"}],
)


def _strm(tmp_path: Path, url: str, name: str = "movie.strm") -> Path:
    path = tmp_path / name
    path.write_text(url + "\n", encoding="utf-8")
    return path


async def _row(tmp_path: Path, seeded_db, strm: Path) -> int:
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name="网盘电影", kind="movie", root_paths=[str(tmp_path)]
        )
        st = strm.stat()
        row = LibraryFile(
            library_id=library.id,
            media_item_id=seeded_db["movie"],
            file_path=str(strm),
            size_bytes=st.st_size,
            file_mtime_ns=st.st_mtime_ns,
            source=FileSource.SCANNED,
            state=FileState.IN_PLACE,
            container="strm",
        )
        session.add(row)
        await session.commit()
        await session.refresh(row)
        return row.id


async def _state(file_id: int) -> StrmProbeState | None:
    async with get_database().session() as session:
        return await session.get(StrmProbeState, file_id)


async def _file(file_id: int) -> LibraryFile:
    async with get_database().session() as session:
        return await session.get(LibraryFile, file_id)


def test_backoff_steps_and_cap() -> None:
    assert [backoff_after(n) for n in (1, 2, 3, 4, 9)] == [
        timedelta(hours=1),
        timedelta(hours=6),
        timedelta(days=1),
        timedelta(days=3),
        timedelta(days=3),
    ]


def test_target_ignores_signature_parameters() -> None:
    assert strm_target("https://Pan.Example.com/d/a.mkv?sign=1&t=2") == "pan.example.com/d/a.mkv"


async def test_failures_back_off_for_background_probes_but_not_for_playback(
    tmp_path, seeded_db, monkeypatch
):
    calls = []
    monkeypatch.setattr(strm_probe, "probe_media", lambda *a, **k: calls.append(a) or None)
    file_id = await _row(tmp_path, seeded_db, _strm(tmp_path, "https://pan.example.com/d/a.mkv"))

    result = await probe_file(file_id)
    assert result.status == "failed" and "直链失效" in result.error
    state = await _state(file_id)
    assert state.failures == 1 and state.target == "pan.example.com/d/a.mkv"
    assert timedelta(minutes=59) < state.next_retry_at - utcnow() <= timedelta(hours=1)

    # 后台预探遵守退避：不探
    result = await probe_file(file_id)
    assert result.status == "backoff" and result.next_retry_at == state.next_retry_at
    assert len(calls) == 1

    # 首播不受退避限制（一分钟的内存冷却过了之后）
    strm_probe._failed_at.clear()
    row = await _file(file_id)
    assert await ensure_strm_spec(row) is False
    assert len(calls) == 2
    state = await _state(file_id)
    assert state.failures == 2
    assert timedelta(hours=5) < state.next_retry_at - utcnow() <= timedelta(hours=6)


async def test_success_clears_failures_and_new_target_resets_the_count(
    tmp_path, seeded_db, monkeypatch
):
    outcomes = [None, None, SPEC]
    monkeypatch.setattr(strm_probe, "probe_media", lambda *a, **k: outcomes.pop(0))
    strm = _strm(tmp_path, "https://pan.example.com/d/a.mkv")
    file_id = await _row(tmp_path, seeded_db, strm)

    assert (await probe_file(file_id)).status == "failed"
    # 直链换了文件：之前的失败不算在新链头上；退避照常按这一次失败算
    strm.write_text("https://pan.example.com/d/b.mkv?sign=x\n", encoding="utf-8")
    assert (await probe_file(file_id, respect_backoff=False)).status == "failed"
    state = await _state(file_id)
    assert state.failures == 1 and state.target == "pan.example.com/d/b.mkv"

    assert (await probe_file(file_id, respect_backoff=False)).status == "probed"
    state = await _state(file_id)
    assert state.failures == 0 and state.next_retry_at is None and state.last_error is None
    row = await _file(file_id)
    assert row.video_codec == "h264" and row.container == "mkv"
    assert (await probe_file(file_id)).status == "ready"
    assert (await probe_file(10_000)).status == "missing"


async def _rewrite(strm: Path, url: str) -> None:
    strm.write_text(url + "\n", encoding="utf-8")
    st = strm.stat()
    os.utime(strm, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))


async def _refresh(file_id: int, strm: Path) -> bool:
    async with get_database().session() as session:
        row = await session.get(LibraryFile, file_id)
        changed = await refresh_rewritten_strm(session, row, strm)
        await session.commit()
        return changed


@pytest.mark.parametrize(
    ("new_url", "keeps_spec"),
    [
        ("https://pan.example.com/d/a.mkv?sign=new&t=9", True),
        ("https://pan.example.com/d/other.mkv", False),
        ("https://mirror.example.com/d/a.mkv", False),
    ],
)
async def test_rewritten_strm_keeps_spec_only_when_the_target_is_the_same(
    tmp_path, seeded_db, monkeypatch, new_url, keeps_spec
):
    monkeypatch.setattr(strm_probe, "probe_media", lambda *a, **k: SPEC)
    strm = _strm(tmp_path, "https://pan.example.com/d/a.mkv?sign=old")
    file_id = await _row(tmp_path, seeded_db, strm)
    assert (await probe_file(file_id)).status == "probed"

    assert await _refresh(file_id, strm) is False  # 没改：不动
    await _rewrite(strm, new_url)
    assert await _refresh(file_id, strm) is True
    row = await _file(file_id)
    assert row.size_bytes == strm.stat().st_size
    if keeps_spec:
        assert row.video_codec == "h264"
        assert await _state(file_id) is not None
    else:
        assert row.video_codec is None and row.container is None and row.audio_streams is None
        assert await _state(file_id) is None
        assert (await probe_file(file_id)).status == "probed"


async def test_rewritten_strm_without_a_probe_record_is_reprobed(tmp_path, seeded_db):
    """旧版本首播探出的规格没有直链指纹：按换了文件处理。"""
    strm = _strm(tmp_path, "https://pan.example.com/d/a.mkv")
    file_id = await _row(tmp_path, seeded_db, strm)
    async with get_database().session() as session:
        row = await session.get(LibraryFile, file_id)
        row.video_codec = "hevc"
        await session.commit()
    await _rewrite(strm, "https://pan.example.com/d/a.mkv?sign=2")
    assert await _refresh(file_id, strm) is True
    assert (await _file(file_id)).video_codec is None


async def test_probe_state_rows_go_with_the_file(tmp_path, seeded_db, monkeypatch):
    monkeypatch.setattr(strm_probe, "probe_media", lambda *a, **k: None)
    file_id = await _row(tmp_path, seeded_db, _strm(tmp_path, "https://pan.example.com/d/a.mkv"))
    await probe_file(file_id)
    async with get_database().session() as session:
        await session.delete(await session.get(LibraryFile, file_id))
        await session.commit()
    assert await _state(file_id) is None
