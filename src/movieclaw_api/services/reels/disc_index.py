"""光盘的片段索引：原盘目录（BDMV / VIDEO_TS）与光盘镜像（ISO）。

刷片挑点吃的是 ``ContainerIndex``（关键帧的时间与字节位置、章节、片长）。普通文件从容器
读（Matroska Cues / MP4 sample table），光盘没有这样的容器，本模块从盘上的结构拼出同一份：

- **蓝光**（目录或镜像）：主播放列表（MPLS）给出剪辑序列与章节；各剪辑 CLPI 的 EP_map
  是天然的关键帧表——入口点的 PTS 换成播放列表时间轴，源包号 × 192 加上前面各剪辑的大小
  当字节位置（只用来估码率，App 不按它取字节）。时间轴与 App 引擎、正片续播点同一口径
  （disc_source.py：0 秒是第一段的 IN_time）。
- **DVD**（目录或镜像）：没有现成的关键帧表，只按与引擎相同的规则选出主标题、读它 IFO 里最长
  那条节目链的播放时长当片长（ffprobe 对整个镜像猜出来的片长不可信），按时间挑点。

镜像里的文件经 ``udf.UDFReader`` 读；读不出（不是 UDF、结构损坏）返回 None，调用方按台账
片长兜底。全部只读小文件（MPLS 几百字节、CLPI 几十 KB、IFO 几 KB），不碰视频本体。
"""

from __future__ import annotations

import contextlib
import logging
from collections.abc import Callable
from pathlib import Path

from movieclaw_api.services.library import dvd
from movieclaw_api.services.library.bluray import (
    MPLS_CLOCK_HZ,
    MplsParseError,
    MplsPlaylist,
    parse_mpls_playlist,
    read_clpi_entry_points,
    select_main_playlist,
)
from movieclaw_api.services.library.udf import UDFEntry, UDFError, UDFReader
from movieclaw_api.services.playback.disc_source import disc_source_for_file
from movieclaw_db.models import LibraryFile
from movieclaw_playback.container_index import ContainerIndex, KeyframePoint

logger = logging.getLogger("movieclaw_api.reels")

#: 蓝光 m2ts 的源包大小（4 字节时间戳头 + 188 字节 TS 包）
_SOURCE_PACKET = 192
#: EP_map PTS 丢掉的低位（45 kHz 单位）
_PTS_SLACK = 256
#: 镜像里单个小文件的读取上限：MPLS / CLPI / IFO 都远小于它，超了多半是结构读错了
_SMALL_FILE_LIMIT = 16 << 20


def bluray_folder_index(path: str, disc_playlist: object) -> ContainerIndex | None:
    """原盘目录（台账 container=bluray）的索引；主播放列表或 CLPI 读不出返回 None。"""
    source = disc_source_for_file(
        LibraryFile(library_id=0, file_path=path, container="bluray", disc_playlist=disc_playlist)
    )
    if source is None:
        return None
    clpi_dir = source.disc_dir / "BDMV" / "CLIPINF"
    backup_dir = source.disc_dir / "BDMV" / "BACKUP" / "CLIPINF"

    def clpi(clip_id: str) -> bytes | None:
        for folder in (clpi_dir, backup_dir):
            for candidate in (folder / f"{clip_id}.clpi", folder / f"{clip_id}.CLPI"):
                try:
                    return candidate.read_bytes()
                except OSError:
                    continue
        return None

    def size(clip_id: str) -> int | None:
        clip = next(c for c in source.clips if c.clip_id == clip_id)
        try:
            return clip.path.stat().st_size
        except OSError:
            return None

    marks: tuple[int, ...] = ()
    playlist_file = source.disc_dir / "BDMV" / "PLAYLIST" / source.playlist_name
    with contextlib.suppress(OSError, MplsParseError):  # 章节可选
        marks = parse_mpls_playlist(playlist_file.read_bytes(), path=playlist_file).marks
    items = [(c.clip_id, c.in_time, c.out_time) for c in source.clips]
    return _bluray_index(items, marks, clpi, size)


def iso_index(path: str) -> ContainerIndex | None:
    """光盘镜像的索引：蓝光按播放列表与 EP_map，DVD 只有片长；读不出返回 None。"""
    try:
        with open(path, "rb") as fh:
            reader = UDFReader(fh)
            top = {entry.name.upper(): entry for entry in reader.list([])}
            if "BDMV" in top:
                return _bluray_iso_index(reader)
            if "VIDEO_TS" in top:
                entries = {e.name.upper(): e for e in reader.list(["VIDEO_TS"]) if not e.is_dir}
                return _dvd_index(
                    {name: reader.size(e) for name, e in entries.items() if name.endswith(".VOB")},
                    lambda name: reader.read(entries[name], _SMALL_FILE_LIMIT),
                )
    except (OSError, UDFError) as exc:
        logger.info("光盘镜像读不出盘内结构，按台账片长挑点：%s（%s）", path, exc)
    return None


def dvd_folder_index(path: str) -> ContainerIndex | None:
    """DVD 目录（台账 container=dvd）的索引：只有片长。"""
    video_ts = Path(path) / "VIDEO_TS"
    try:
        entries = {p.name.upper(): p for p in video_ts.iterdir()}
        sizes = {name: p.stat().st_size for name, p in entries.items() if name.endswith(".VOB")}
    except OSError:
        return None
    return _dvd_index(sizes, lambda name: entries[name].read_bytes())


# --- 蓝光 -----------------------------------------------------------------------


def _bluray_iso_index(reader: UDFReader) -> ContainerIndex | None:
    def files(folder: str, suffix: str) -> dict[str, UDFEntry]:
        try:
            entries = reader.list(["BDMV", folder])
        except UDFError:
            return {}
        out: dict[str, UDFEntry] = {}
        for entry in entries:
            stem, _, ext = entry.name.rpartition(".")
            if not entry.is_dir and ext.lower() == suffix:
                out[stem] = entry
        return out

    streams = files("STREAM", "m2ts")
    clpis = files("CLIPINF", "clpi")
    playlists: list[MplsPlaylist] = []
    for stem, entry in sorted(files("PLAYLIST", "mpls").items()):
        try:
            data = reader.read(entry, _SMALL_FILE_LIMIT)
            playlists.append(parse_mpls_playlist(data, path=Path(f"{stem}.mpls")))
        except (UDFError, MplsParseError) as exc:
            logger.debug("镜像里的 MPLS 跳过：%s（%s）", entry.name, exc)
    playlist = select_main_playlist(playlists, set(streams))
    if playlist is None:
        return None

    def clpi(clip_id: str) -> bytes | None:
        entry = clpis.get(clip_id)
        if entry is None:
            return None
        try:
            return reader.read(entry, _SMALL_FILE_LIMIT)
        except UDFError:
            return None

    def size(clip_id: str) -> int | None:
        try:
            return reader.size(streams[clip_id])
        except (KeyError, UDFError):
            return None

    items = [(item.clip_id, item.in_time, item.out_time) for item in playlist.items]
    return _bluray_index(items, playlist.marks, clpi, size)


def _bluray_index(
    items: list[tuple[str, int, int]],
    marks: tuple[int, ...],
    clpi: Callable[[str], bytes | None],
    size: Callable[[str], int | None],
) -> ContainerIndex | None:
    """剪辑序列 + 各剪辑的 CLPI 与大小 → 播放列表时间轴上的关键帧表。任一剪辑读不出返回 None。"""
    keyframes: list[KeyframePoint] = []
    time_base = 0.0
    byte_base = 0
    for clip_id, in_time, out_time in items:
        data = clpi(clip_id)
        points = read_clpi_entry_points(data) if data is not None else None
        clip_size = size(clip_id)
        if points is None or clip_size is None:
            logger.info("原盘剪辑 %s 的关键帧表或大小读不出，改按片长挑点", clip_id)
            return None
        for pts, spn in points:
            # EP_map 的 PTS 丢了低 8 位（parse_clpi_entry_points），剪辑起点上的入口点拼回来
            # 可能比 IN_time 早一点点：放宽 256 个单位，时间夹到这一段的起点
            if in_time - _PTS_SLACK <= pts < out_time:
                keyframes.append(
                    KeyframePoint(
                        time_s=time_base + max(0, pts - in_time) / MPLS_CLOCK_HZ,
                        offset=byte_base + spn * _SOURCE_PACKET,
                    )
                )
        time_base += max(0, out_time - in_time) / MPLS_CLOCK_HZ
        byte_base += clip_size
    if len(keyframes) < 2:
        return None
    return ContainerIndex(
        container="bluray",
        file_size=byte_base,
        duration_s=time_base,
        keyframes=tuple(keyframes),
        tracks=(),
        chapters=tuple((ms / 1000, None) for ms in marks),
    )


# --- DVD ------------------------------------------------------------------------


def _dvd_index(
    vob_sizes: dict[str, int], read_ifo: Callable[[str], bytes]
) -> ContainerIndex | None:
    """主标题的片长：主标题与正片节目链的选法见 ``library.dvd``（与 App 引擎一致）。"""
    main = dvd.main_title_set(vob_sizes, read_ifo)
    if main is None:
        return None
    try:
        seconds = dvd.longest_program_chain(read_ifo(f"VTS_{main:02d}_0.IFO")).seconds
    except (KeyError, OSError, ValueError) as exc:
        logger.info("DVD 主标题 IFO 读不出：VTS_%02d（%s）", main, exc)
        return None
    if seconds <= 0:
        return None
    size = sum(
        size
        for name, size in vob_sizes.items()
        if name.upper().startswith(f"VTS_{main:02d}_") and not name.upper().endswith("_0.VOB")
    )
    return ContainerIndex(
        container="dvd", file_size=size, duration_s=seconds, keyframes=(), tracks=()
    )
