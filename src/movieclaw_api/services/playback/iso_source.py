"""光盘镜像（ISO）的服务端播放源：给不能自己读镜像的播放器换封装 / 转码用。

原来服务端读不了镜像的盘内结构，ISO 只能原字节直推给能读镜像的播放器（App 的自研引擎、
Infuse），其余客户端（Android TV、网页）一律「放不了」。镜像里的正片其实就是镜像上的一段
连续字节：蓝光主片的 m2ts、DVD 正片标题集的 VOB 都由母盘工具顺序写入。这里用只读 UDF 读取器
（``udf.UDFReader``，刷片挑点已在用）找出这段字节，装成与原盘目录同一种 ``DiscSource``——
ffmpeg 经 ``subfile`` 协议把区间当文件读，远程 Worker 按区间取字节，转码管线一行不改。

- **蓝光镜像**：主播放列表（与原盘目录同一套选法，排除诱饵列表）的每段剪辑一个区间，
  CLPI 一并读出供关键帧表（VOD 分片、能否 remux 的判断都靠它）。
- **DVD 镜像**：主标题（选法见 ``library.dvd``，与 App 引擎一致）正片节目链各单元覆盖的扇区
  区间——不是整个标题集：标题集末尾常挂着花絮单元，时间戳从头再来，ffmpeg 会把片长估成那一段、
  按时间跳转直接跳到末尾（NAS 实测《金枝玉叶》估成 99 秒）。按节目链裁掉后片长、跳转都正常。

读不出（不是 UDF、结构损坏、正片在镜像里不连续）返回 None，调用方按「放不了」处理。
"""

from __future__ import annotations

import contextlib
import logging
from pathlib import Path

from movieclaw_api.services.library import dvd
from movieclaw_api.services.library.bluray import (
    MPLS_CLOCK_HZ,
    MplsParseError,
    MplsPlaylist,
    parse_mpls_playlist,
    select_main_playlist,
)
from movieclaw_api.services.library.udf import SECTOR, UDFEntry, UDFError, UDFReader
from movieclaw_api.services.playback.disc_source import (
    DiscClip,
    DiscSource,
    disc_source_for_file,
)
from movieclaw_db.models import LibraryFile

logger = logging.getLogger("movieclaw_api.iso_source")

#: 镜像里单个小文件（MPLS / CLPI / IFO）的读取上限：超了多半是结构读错了
_SMALL_FILE_LIMIT = 16 << 20
_CACHE_MAX = 64
#: (路径, 大小, 修改时间) → 解析结果（None 也缓存：读不出的镜像不必每次开会话都重读）
_cache: dict[tuple[str, int, int], DiscSource | None] = {}


def iso_disc_source(path: str | Path) -> DiscSource | None:
    """光盘镜像 → 服务端可读的播放源；读不出返回 None。结果按镜像的大小与修改时间缓存。"""
    path = Path(path)
    try:
        stat = path.stat()
    except OSError:
        return None
    key = (str(path), stat.st_size, stat.st_mtime_ns)
    if key in _cache:
        return _cache[key]
    try:
        with open(path, "rb") as fh:
            source = _read(path, UDFReader(fh))
    except (OSError, UDFError) as exc:
        logger.info("光盘镜像读不出盘内结构：%s（%s）", path, exc)
        source = None
    if len(_cache) >= _CACHE_MAX:
        _cache.clear()
    _cache[key] = source
    return source


def _read(path: Path, reader: UDFReader) -> DiscSource | None:
    top = {entry.name.upper(): entry for entry in reader.list([])}
    if "BDMV" in top:
        return _bluray(path, reader)
    if "VIDEO_TS" in top:
        return _dvd(path, reader)
    return None


# --- 蓝光 -----------------------------------------------------------------------


def _bluray(path: Path, reader: UDFReader) -> DiscSource | None:
    streams = _files(reader, ["BDMV", "STREAM"], "m2ts")
    playlists: list[MplsPlaylist] = []
    for stem, entry in sorted(_files(reader, ["BDMV", "PLAYLIST"], "mpls").items()):
        try:
            data = reader.read(entry, _SMALL_FILE_LIMIT)
            playlists.append(parse_mpls_playlist(data, path=Path(f"{stem}.mpls")))
        except (UDFError, MplsParseError) as exc:
            logger.debug("镜像里的 MPLS 跳过：%s（%s）", entry.name, exc)
    playlist = select_main_playlist(playlists, set(streams))
    if playlist is None:
        logger.info("蓝光镜像里没有可用的主播放列表：%s", path)
        return None
    clpis = _files(reader, ["BDMV", "CLIPINF"], "clpi")
    clips: list[DiscClip] = []
    clpi_data: dict[str, bytes] = {}
    for item in playlist.items:
        ranges = reader.byte_ranges(streams[item.clip_id])
        if len(ranges) != 1:
            logger.info(
                "蓝光镜像的剪辑 %s 在镜像里不连续（%d 段），不能按区间读：%s",
                item.clip_id,
                len(ranges),
                path,
            )
            return None
        start, length = ranges[0]
        clips.append(
            DiscClip(
                clip_id=item.clip_id,
                path=path,
                in_time=item.in_time,
                out_time=item.out_time,
                byte_range=(start, start + length),
            )
        )
        entry = clpis.get(item.clip_id)
        if entry is not None and item.clip_id not in clpi_data:
            with contextlib.suppress(UDFError):
                clpi_data[item.clip_id] = reader.read(entry, _SMALL_FILE_LIMIT)
    return DiscSource(
        disc_dir=path,
        playlist_name=playlist.path.name,
        clips=tuple(clips),
        clpi=clpi_data,
        image="bluray",
    )


# --- DVD ------------------------------------------------------------------------


def _dvd(path: Path, reader: UDFReader) -> DiscSource | None:
    entries = {e.name.upper(): e for e in reader.list(["VIDEO_TS"]) if not e.is_dir}

    def read_ifo(name: str) -> bytes:
        return reader.read(entries[name], _SMALL_FILE_LIMIT)

    vobs = {name: e for name, e in entries.items() if name.endswith(".VOB")}
    main = dvd.main_title_set({name: reader.size(e) for name, e in vobs.items()}, read_ifo)
    if main is None:
        return None
    try:
        chain = dvd.longest_program_chain(read_ifo(f"VTS_{main:02d}_0.IFO"))
    except (KeyError, ValueError) as exc:
        logger.info("DVD 镜像主标题 IFO 读不出：%s VTS_%02d（%s）", path, main, exc)
        return None
    if chain.seconds <= 0 or not chain.cells:
        return None
    # 正片 VOB（VTS_NN_1、_2…）在镜像里必须首尾相接，扇区号才能当成一整段连续字节
    prefix = f"VTS_{main:02d}_"
    parts = sorted(
        (name for name in vobs if name.startswith(prefix) and not name.endswith("_0.VOB")),
        key=lambda name: int(name.removesuffix(".VOB").rsplit("_", 1)[1]),
    )
    ranges: list[tuple[int, int]] = []
    for name in parts:
        ranges.extend(reader.byte_ranges(vobs[name]))
    merged: list[tuple[int, int]] = []
    for start, length in ranges:
        if merged and merged[-1][0] + merged[-1][1] == start:
            merged[-1] = (merged[-1][0], merged[-1][1] + length)
        else:
            merged.append((start, length))
    if len(merged) != 1:
        logger.info(
            "DVD 镜像的正片 VOB 在镜像里不连续（%d 段），不能按区间读：%s", len(merged), path
        )
        return None
    base, total = merged[0]
    first = min(cell[0] for cell in chain.cells)
    last = max(cell[1] for cell in chain.cells)
    start, end = base + first * SECTOR, base + (last + 1) * SECTOR
    if end > base + total:
        logger.info("DVD 镜像的节目链越过了正片 VOB 的范围：%s", path)
        return None
    return DiscSource(
        disc_dir=path,
        playlist_name=f"VTS_{main:02d}",
        clips=(
            DiscClip(
                clip_id=f"VTS_{main:02d}",
                path=path,
                in_time=0,
                out_time=int(chain.seconds * MPLS_CLOCK_HZ),
                byte_range=(start, end),
                timed=False,
            ),
        ),
        image="dvd",
    )


def _files(reader: UDFReader, folder: list[str], suffix: str) -> dict[str, UDFEntry]:
    try:
        entries = reader.list(folder)
    except UDFError:
        return {}
    out: dict[str, UDFEntry] = {}
    for entry in entries:
        stem, _, ext = entry.name.rpartition(".")
        if not entry.is_dir and ext.lower() == suffix:
            out[stem] = entry
    return out


def clear_cache() -> None:
    """测试用：清掉解析缓存。"""
    _cache.clear()


def transcode_disc_source(file: LibraryFile) -> DiscSource | None:
    """服务端换封装 / 转码时这个文件的原盘播放源：原盘目录照旧，光盘镜像按区间解析。

    只给会话起播与远程 Worker 的取源接口用。兼容层、目录直推、详情 DTO 仍用
    ``disc_source_for_file``——那几处对 ISO 的语义是「原字节交给播放器自己读」，不能变。
    """
    if (file.container or "") == "iso":
        return iso_disc_source(file.file_path)
    return disc_source_for_file(file) if file.is_disc() else None
