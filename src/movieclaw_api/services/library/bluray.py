"""蓝光原盘 MPLS 主播放列表、CLPI 元数据解析与 ffprobe 结果合并。

BDMV 的 m2ts 是 MPEG-TS 流文件，ffprobe 能稳定拿到编码、声道与流 PID，
但不少原盘没有把语言描述符写进 TS；真实语言位于同编号的
``BDMV/CLIPINF/<clip_id>.clpi``。本模块只读 CLPI 的 ProgramInfo 小节，并用
PID 关联两边的轨道，绝不按数组下标猜测——播放列表裁剪、交互图形轨或工具
识别差异都可能让两边数量不同，错一位就会把整组语言写错。

本模块同时承担原盘**播放**所需的两样结构化数据（docs/design/disc-playback.md）：

- MPLS 的 PlayListMark（章节入口标记）——原盘章节的唯一来源，m2ts 本身没有
  章节；
- CLPI 的 EP_map（蓝光自带的 I 帧入口表：PTS 与源包号）——原盘的天然关键帧
  索引。77 GB 的 m2ts 用 ffprobe 列包要顺序读完整个文件，EP_map 只有几十 KB。

解析失败属于可选元数据缺失：调用方保留原 ffprobe 结果，扫描照常完成。
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
from collections.abc import AsyncIterator, Iterable, Mapping
from contextlib import asynccontextmanager
from dataclasses import dataclass, replace
from pathlib import Path

from movieclaw_api.services.media_probe import MediaSpec

logger = logging.getLogger("movieclaw_api.bluray")

#: MPLS / CLPI 的时间戳单位（33 位 90 kHz PTS 的高 32 位，即 45 kHz）
MPLS_CLOCK_HZ = 45_000
_MPLS_CLOCK_HZ = MPLS_CLOCK_HZ

#: 蓝光主视频流的固定 PID。EP_map 可能给多路流各建一张表（Dolby Vision 双层
#: 盘的增强层也有），关键帧索引只认主视频这一张。
_PRIMARY_VIDEO_PID = 0x1011

#: PlayListMark 的 mark_type：1 = 章节入口（entry mark），2 = 链接点（link
#: point，给 BD-J/菜单跳转用，不是给人看的章节）
_MARK_TYPE_ENTRY = 1


class MplsParseError(ValueError):
    """MPLS 结构不完整或字段越界。"""


@dataclass(frozen=True)
class MplsPlayItem:
    """播放列表里的一个剪辑及有效播放区间。"""

    clip_id: str
    in_time: int
    out_time: int

    @property
    def duration_seconds(self) -> float:
        return max(0, self.out_time - self.in_time) / _MPLS_CLOCK_HZ


@dataclass(frozen=True)
class MplsPlaylist:
    """可用于选主片的 MPLS 播放列表。

    ``marks`` 是章节入口标记，元素为**播放列表时间轴**上的毫秒起点（各
    PlayItem 的时长累加，与播放时 concat 拼接出来的时间轴同一口径）。
    """

    path: Path
    items: tuple[MplsPlayItem, ...]
    marks: tuple[int, ...] = ()

    @property
    def duration_seconds(self) -> int:
        return round(sum(item.duration_seconds for item in self.items))

    @property
    def clip_ids(self) -> tuple[str, ...]:
        return tuple(item.clip_id for item in self.items)

    @property
    def has_loops(self) -> bool:
        """同一剪辑以同一 IN_time 出现两次即为循环列表。

        这是 BDInfo（Jellyfin 选主片所用的库）``TSPlaylistFile.HasLoops`` 的
        同款判据。防拷贝诱饵列表把同一剪辑循环引用几百次、时长虚高数倍，只按
        时长取最长必然中招——实测 141 张盘约 50 张选错，台账时长错一倍以上。
        """
        seen: set[tuple[str, int]] = set()
        for item in self.items:
            key = (item.clip_id, item.in_time)
            if key in seen:
                return True
            seen.add(key)
        return False

    def chapters(self) -> list[dict]:
        """章节入口标记 → 台账 ``chapters`` 列的元素形态（与 ffprobe 章节同构）。

        原盘的 m2ts 没有内嵌章节，MPLS 的 PlayListMark 是唯一来源。起点取播放
        列表时间轴；标题恒 None（蓝光不给章节命名，展示层按序号补「第 N 章」）。
        """
        return [{"start_ms": start_ms, "end_ms": None, "title": None} for start_ms in self.marks]


@dataclass(frozen=True)
class MainPlaylistReadResult:
    """主播放列表读取结果。

    ``retryable`` 表示本轮没有可信结论、需要保留旧行后重试；没有
    ``snapshot_changed`` 时是瞬时 I/O 失败，后者则明确表示读前、读后指纹均可取
    但已确认换盘。``audit_failed`` 是字节完整读到、但有 MPLS 永久解析失败或没有
    可用主片，可按文件指纹记账，避免坏盘每次启动都重读。``fingerprint`` 仅在完整
    读取前后盘面一致时携带。
    """

    playlist: MplsPlaylist | None
    retryable: bool = False
    snapshot_changed: bool = False
    audit_failed: bool = False
    fingerprint: dict | None = None


def parse_mpls_playlist(data: bytes, *, path: Path = Path("unknown.mpls")) -> MplsPlaylist:
    """解析 MPLS 的 PlayList 与 PlayListMark 小节。

    PlayList 只读取选择主片所需的 clip id 与 IN/OUT 时间；STN、角度和 SubPath
    都保留在完整原盘目录中，不需要为了入库而解释或改写。PlayListMark 解析
    失败只丢章节不丢列表——章节是可选元数据。
    """
    if len(data) < 20 or data[:4] != b"MPLS":
        # i18n-ignore: parser diagnostic, logged only
        raise MplsParseError("文件签名不是 MPLS 或文件头过短")
    playlist_offset = int.from_bytes(data[8:12], "big")
    if playlist_offset + 10 > len(data):
        # i18n-ignore: parser diagnostic, logged only
        raise MplsParseError("PlayList 偏移越界")
    section_length = int.from_bytes(data[playlist_offset : playlist_offset + 4], "big")
    section_end = playlist_offset + 4 + section_length
    if section_end > len(data):
        # i18n-ignore: parser diagnostic, logged only
        raise MplsParseError("PlayList 长度越界")
    pos = playlist_offset + 4
    _require(pos, 6, section_end, "PlayList header", error=MplsParseError)
    pos += 2  # reserved
    play_item_count = int.from_bytes(data[pos : pos + 2], "big")
    pos += 4  # number_of_play_items + number_of_sub_paths
    items: list[MplsPlayItem] = []
    for _ in range(play_item_count):
        _require(pos, 2, section_end, "PlayItem length", error=MplsParseError)
        item_length = int.from_bytes(data[pos : pos + 2], "big")
        item_start = pos + 2
        item_end = item_start + item_length
        _require(item_start, item_length, section_end, "PlayItem", error=MplsParseError)
        # clip id(5) + codec id(4) + flags(2) + stc id(1) + in/out(8)
        _require(item_start, 20, item_end, "PlayItem core", error=MplsParseError)
        clip_raw = data[item_start : item_start + 5]
        codec_raw = data[item_start + 5 : item_start + 9]
        try:
            clip_id = clip_raw.decode("ascii")
            codec = codec_raw.decode("ascii")
        except UnicodeDecodeError as exc:
            # i18n-ignore: parser diagnostic, logged only
            raise MplsParseError("PlayItem 标识不是 ASCII") from exc
        if not clip_id.isdigit() or codec != "M2TS":
            # i18n-ignore: parser diagnostic, logged only
            raise MplsParseError("PlayItem 的 clip/codec 标识无效")
        in_time = int.from_bytes(data[item_start + 12 : item_start + 16], "big")
        out_time = int.from_bytes(data[item_start + 16 : item_start + 20], "big")
        if out_time < in_time:
            # i18n-ignore: parser diagnostic, logged only
            raise MplsParseError("PlayItem 的 OUT_time 早于 IN_time")
        items.append(MplsPlayItem(clip_id=clip_id, in_time=in_time, out_time=out_time))
        pos = item_end
    if not items:
        # i18n-ignore: parser diagnostic, logged only
        raise MplsParseError("播放列表没有 PlayItem")
    try:
        marks = _parse_playlist_marks(data, tuple(items))
    except MplsParseError as exc:
        logger.warning("蓝光 MPLS 章节标记解析失败，按无章节处理：%s（%s）", path, exc)
        marks = ()
    return MplsPlaylist(path=path, items=tuple(items), marks=marks)


def _parse_playlist_marks(data: bytes, items: tuple[MplsPlayItem, ...]) -> tuple[int, ...]:
    """PlayListMark 小节 → 播放列表时间轴上的章节起点（毫秒，升序去重）。

    文件头 ``0x0c`` 是 PlayListMark 的绝对偏移。每个标记 14 字节：保留(1)、
    mark_type(1)、ref_to_PlayItem_id(2)、mark_time_stamp(4)、entry_ES_PID(2)、
    duration(4)。只收 entry mark；时间戳是所属 PlayItem 的剪辑时间，减去该
    PlayItem 的 IN_time 再加上前面各段的累计时长，才是播放列表时间轴。
    """
    mark_offset = int.from_bytes(data[12:16], "big")
    if mark_offset == 0:
        return ()
    if mark_offset + 6 > len(data):
        # i18n-ignore: parser diagnostic, logged only
        raise MplsParseError("PlayListMark 偏移越界")
    section_length = int.from_bytes(data[mark_offset : mark_offset + 4], "big")
    section_end = mark_offset + 4 + section_length
    if section_end > len(data):
        # i18n-ignore: parser diagnostic, logged only
        raise MplsParseError("PlayListMark 长度越界")
    pos = mark_offset + 4
    _require(pos, 2, section_end, "PlayListMark header", error=MplsParseError)
    mark_count = int.from_bytes(data[pos : pos + 2], "big")
    pos += 2
    # 各 PlayItem 在播放列表时间轴上的起点（45 kHz）
    offsets: list[int] = []
    cursor = 0
    for item in items:
        offsets.append(cursor)
        cursor += max(0, item.out_time - item.in_time)
    marks: set[int] = set()
    for _ in range(mark_count):
        _require(pos, 14, section_end, "PlayListMark entry", error=MplsParseError)
        mark_type = data[pos + 1]
        item_index = int.from_bytes(data[pos + 2 : pos + 4], "big")
        timestamp = int.from_bytes(data[pos + 4 : pos + 8], "big")
        pos += 14
        if mark_type != _MARK_TYPE_ENTRY or item_index >= len(items):
            continue
        item = items[item_index]
        relative = min(max(timestamp, item.in_time), item.out_time) - item.in_time
        marks.add(round((offsets[item_index] + relative) * 1000 / _MPLS_CLOCK_HZ))
    return tuple(sorted(marks))


#: 台账 ``library_file.disc_playlist`` 的版本。字段集或选主片的规则变了就 +1，
#: 补探会把旧版本的行重算一遍（与 CLPI 语言版本戳同一思路）。
#: 2 = 长度相近时比字节（见 ``select_main_playlist``），字段集没变。
#: 3 = 用完整性状态重读 v2 清单，修正历史上部分读取落账的候选。
DISC_PLAYLIST_VERSION = 3
_AUDIT_KEY = "audit"
_FINGERPRINT_UNSET = object()
#: 同库锁只在有持有者或等待者时存在，用完即删：asyncio.Lock 首次争用会绑定
#: 当时的事件循环，常驻会让后来的事件循环（测试每个用例一个）拿到旧循环的锁。
_audit_mutexes: dict[int, tuple[asyncio.Lock, int]] = {}


@asynccontextmanager
async def disc_playlist_audit_mutex(library_id: int) -> AsyncIterator[None]:
    """同一媒体库的启动自愈与手动扫描共用一把主片审计锁。"""
    lock, users = _audit_mutexes.get(library_id, (asyncio.Lock(), 0))
    _audit_mutexes[library_id] = (lock, users + 1)
    try:
        async with lock:
            yield
    finally:
        lock, users = _audit_mutexes[library_id]
        if users == 1:
            del _audit_mutexes[library_id]
        else:
            _audit_mutexes[library_id] = (lock, users - 1)


def disc_playlist_fingerprint(path: Path) -> dict | None:
    """ISO 或 BDMV 选主片相关文件的 ``(size, mtime)`` 指纹。"""
    try:
        if path.is_file():
            stat = path.stat()
            return {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns}
        if not (path / "BDMV").is_dir():
            return None
        rows: list[tuple[str, int, int]] = []
        missing: list[str] = []
        for subdir, suffix in (("PLAYLIST", ".mpls"), ("STREAM", ".m2ts")):
            directory = path / "BDMV" / subdir
            try:
                children = sorted(directory.iterdir())
            except FileNotFoundError:
                missing.append(subdir)
                continue
            for child in children:
                if not child.is_file() or child.suffix.lower() != suffix:
                    continue
                stat = child.stat()
                rows.append((f"{subdir}/{child.name}", stat.st_size, stat.st_mtime_ns))
    except OSError:
        return None
    digest = hashlib.sha256()
    for subdir in missing:
        digest.update(f"{subdir}\0missing\n".encode())
    for name, size, mtime_ns in rows:
        digest.update(f"{name}\0{size}\0{mtime_ns}\n".encode())
    return {
        "files": len(rows),
        "size": sum(size for _name, size, _mtime in rows),
        "digest": digest.hexdigest(),
    }


def disc_playlist_audit_failed(record: object) -> bool:
    return isinstance(record, dict) and (record.get(_AUDIT_KEY) or {}).get("state") == "failed"


def disc_playlist_probe_pending(record: object) -> bool:
    return (
        isinstance(record, dict) and (record.get(_AUDIT_KEY) or {}).get("state") == "pending_probe"
    )


def _disc_playlist_fingerprint(path: Path, fingerprint: object) -> dict | None:
    if fingerprint is _FINGERPRINT_UNSET:
        return disc_playlist_fingerprint(path)
    return fingerprint if isinstance(fingerprint, dict) else None


def disc_playlist_pending_matches(
    record: object,
    path: Path,
    *,
    fingerprint: object = _FINGERPRINT_UNSET,
) -> bool:
    """pending 台账是否仍属于当前这张盘；指纹取不到时也不能复用。"""
    if not disc_playlist_probe_pending(record):
        return False
    assert isinstance(record, dict)
    current = _disc_playlist_fingerprint(path, fingerprint)
    return current is not None and current == (record.get(_AUDIT_KEY) or {}).get("fingerprint")


def disc_playlist_audit_due(record: object, path: Path, *, force: bool = False) -> bool:
    """失败指纹没变就不重做完整审计；显式重试可传 ``force=True``。"""
    if force or not disc_playlist_audit_failed(record):
        return True
    assert isinstance(record, dict)
    fingerprint = disc_playlist_fingerprint(path)
    return fingerprint is None or fingerprint != (record.get(_AUDIT_KEY) or {}).get("fingerprint")


def disc_playlist_failure_record(
    record: object,
    path: Path,
    *,
    fingerprint: object = _FINGERPRINT_UNSET,
) -> dict | None:
    """保留旧清单并记下永久审计失败；取不到指纹时按瞬时失败处理。"""
    fingerprint = _disc_playlist_fingerprint(path, fingerprint)
    if fingerprint is None:
        return dict(record) if isinstance(record, dict) else None
    failed = dict(record) if isinstance(record, dict) else {}
    failed.pop("version", None)
    failed[_AUDIT_KEY] = {
        "state": "failed",
        "version": DISC_PLAYLIST_VERSION,
        "fingerprint": fingerprint,
    }
    return failed


def disc_playlist_pending_record(
    playlist: MplsPlaylist,
    path: Path,
    *,
    fingerprint: object = _FINGERPRINT_UNSET,
) -> dict:
    """完整选主已成功、但新主片规格尚未探测成功。"""
    record = disc_playlist_record(playlist)
    return disc_playlist_pending_ledger(
        record["name"], record["clips"], path, fingerprint=fingerprint
    )


def disc_playlist_pending_ledger(
    name: str | None,
    clips: list[dict],
    path: Path,
    *,
    fingerprint: object = _FINGERPRINT_UNSET,
) -> dict:
    """任意完整主片读取结果 → 等待规格重探的台账。"""
    return {
        "name": name,
        "clips": clips,
        _AUDIT_KEY: {
            "state": "pending_probe",
            "version": DISC_PLAYLIST_VERSION,
            "fingerprint": _disc_playlist_fingerprint(path, fingerprint),
        },
    }


def disc_playlist_success_record(
    record: object,
    path: Path,
    *,
    fingerprint: object = _FINGERPRINT_UNSET,
) -> dict | None:
    """把 ``pending_probe`` 清单转为 v3 成功台账。"""
    fingerprint = _disc_playlist_fingerprint(path, fingerprint)
    if not disc_playlist_pending_matches(record, path, fingerprint=fingerprint):
        return None
    assert isinstance(record, dict)
    return {
        "version": DISC_PLAYLIST_VERSION,
        "name": record.get("name"),
        "clips": list(record.get("clips") or []),
        _AUDIT_KEY: {
            "state": "success",
            "version": DISC_PLAYLIST_VERSION,
            "fingerprint": fingerprint,
        },
    }


def pending_disc_playlist(
    record: object,
    disc_dir: Path,
    *,
    fingerprint: object = _FINGERPRINT_UNSET,
) -> MplsPlaylist | None:
    """从已完整审计的 pending 台账恢复探测目标，不再重读全部 MPLS。"""
    if not disc_playlist_pending_matches(record, disc_dir, fingerprint=fingerprint):
        return None
    assert isinstance(record, dict)
    try:
        items = tuple(
            MplsPlayItem(
                clip_id=str(clip["id"]), in_time=int(clip["in"]), out_time=int(clip["out"])
            )
            for clip in record.get("clips") or []
        )
    except (KeyError, TypeError, ValueError):
        return None
    if not items:
        return None
    return MplsPlaylist(
        path=disc_dir / "BDMV" / "PLAYLIST" / str(record.get("name") or ""), items=items
    )


def disc_playlist_record(playlist: MplsPlaylist | None, *, fingerprint: dict | None = None) -> dict:
    """主播放列表 → 台账 ``disc_playlist`` 列（docs/design/disc-playback.md §3.2）。

    只落播放所需的最小事实：列表名、各剪辑 id 与 IN/OUT（45 kHz 整数）；扫描
    路径可附带稳定读取指纹，供后续自愈识别换盘。播放时据此构造 concat 清单与
    关键帧索引，不必再读盘上成百上千个 MPLS——诱饵盘动辄上千个列表，NFS 上
    每次全读要一到三秒。

    ``playlist=None`` 写「读过但没有主播放列表」的哨兵（剪辑清单为空）：残缺盘
    不该每轮补探都重读一遍，播放时播放源解析器见到空清单会再试一次读盘。
    """
    if playlist is None:
        record = {"version": DISC_PLAYLIST_VERSION, "name": None, "clips": []}
    else:
        record = {
            "version": DISC_PLAYLIST_VERSION,
            "name": playlist.path.name,
            "clips": [
                {"id": item.clip_id, "in": item.in_time, "out": item.out_time}
                for item in playlist.items
            ],
        }
    if fingerprint is not None:
        record[_AUDIT_KEY] = {
            "state": "success",
            "version": DISC_PLAYLIST_VERSION,
            "fingerprint": fingerprint,
        }
    return record


def disc_playlist_stale(record: object, path: Path | None = None) -> bool:
    """清单是否缺失、版本落后，或成功审计指纹已变化，需要补探重算。"""
    if not isinstance(record, dict) or record.get("version") != DISC_PLAYLIST_VERSION:
        return True
    audit = record.get(_AUDIT_KEY) or {}
    if path is None or audit.get("state") != "success":
        return False
    fingerprint = audit.get("fingerprint")
    return fingerprint is not None and disc_playlist_fingerprint(path) != fingerprint


def read_main_playlist(disc_dir: Path) -> MplsPlaylist | None:
    """从完整 BDMV 中选择主播放列表；损坏/伪列表只降级，不阻断扫描。

    候选必须引用实际存在的 STREAM 文件，且**不含循环剪辑**（``has_loops``，
    防拷贝诱饵列表的判据，与 Jellyfin/BDInfo 同口径）。按有效播放时长优先，
    同一剪辑序列只保留一个，避免不同语言/菜单入口的等价 MPLS 放大候选数量。
    长度相近时字节明显更多的才是正片（见 ``select_main_playlist``）。
    """
    return read_main_playlist_result(disc_dir).playlist


def read_main_playlist_result(disc_dir: Path) -> MainPlaylistReadResult:
    """读取主播放列表，只返回读前后盘面未变化的完整结论。"""
    before = disc_playlist_fingerprint(disc_dir)
    if before is None:
        return MainPlaylistReadResult(None, retryable=True)
    result = _read_main_playlist_result(disc_dir)
    after = disc_playlist_fingerprint(disc_dir)
    if after is None:
        return MainPlaylistReadResult(None, retryable=True)
    if after != before:
        return MainPlaylistReadResult(None, retryable=True, snapshot_changed=True)
    return replace(result, fingerprint=before)


def _read_main_playlist_result(disc_dir: Path) -> MainPlaylistReadResult:
    """读取主播放列表，区分瞬时 I/O 与稳定的坏盘结论。"""
    playlist_dir = disc_dir / "BDMV" / "PLAYLIST"
    stream_dir = disc_dir / "BDMV" / "STREAM"
    if not playlist_dir.is_dir() or not stream_dir.is_dir():
        return MainPlaylistReadResult(None, audit_failed=True)
    try:
        paths = sorted(
            path
            for path in playlist_dir.iterdir()
            if path.is_file() and path.suffix.lower() == ".mpls"
        )
        stream_sizes = {
            path.stem: path.stat().st_size
            for path in stream_dir.iterdir()
            if path.is_file() and path.suffix.lower() == ".m2ts"
        }
    except OSError:
        return MainPlaylistReadResult(None, retryable=True)
    playlists = []
    retryable = False
    parse_failed = False
    for path in paths:
        try:
            data = path.read_bytes()
            if len(data) != path.stat().st_size:
                retryable = True
                logger.warning("蓝光 MPLS 短读，跳过候选：%s", path)
                continue
            playlists.append(parse_mpls_playlist(data, path=path))
        except OSError as exc:
            retryable = True
            logger.warning("蓝光 MPLS 读取失败，跳过候选：%s（%s）", path, exc)
        except MplsParseError as exc:
            parse_failed = True
            logger.warning("蓝光 MPLS 解析失败，跳过候选：%s（%s）", path, exc)
    playlist = select_main_playlist(playlists, stream_sizes)
    return MainPlaylistReadResult(
        playlist,
        retryable=retryable,
        audit_failed=parse_failed or (not retryable and playlist is None),
    )


#: 长度差多少秒以内才比字节。NAS 上 186 张蓝光盘：同一部片的不同拷贝差 0～32 秒，
#: 不同剪辑版至少差 310 秒（后者字节再多也不该改选，用户要的可能是加长版）
_SIMILAR_LENGTH_S = 60
#: 字节要到最长候选的多少倍才改选。同一部片的等价列表（语言分支、片头不同）字节只差 0.07% 以内，
#: 解说版、分镜版只有正片的三分之一到五分之一
_LARGER_COPY_RATIO = 1.5


def select_main_playlist(
    playlists: Iterable[MplsPlaylist], stream_sizes: Mapping[str, int]
) -> MplsPlaylist | None:
    """在已解析的候选里选主播放列表（原盘目录与光盘镜像共用的规则，见 ``read_main_playlist``）。

    只比时长会选错同一部片的小拷贝：《沉默的羔羊》盘上的 480i 画中画解说版比 1080p 正片长 6 秒，
    吉卜力日版盘的全片分镜版与正片分秒不差、靠列表名排在后面才胜出，放出来全是铅笔稿。所以长度
    相近的候选里，字节明显多的优先。

    ``stream_sizes`` 是盘上各 m2ts 的字节数（读不出的记 0）。同一剪辑被引用多次只算一份。
    """
    by_sequence: dict[tuple[str, ...], MplsPlaylist] = {}
    for playlist in playlists:
        if not all(clip_id in stream_sizes for clip_id in playlist.clip_ids):
            continue
        if playlist.has_loops:
            continue
        current = by_sequence.get(playlist.clip_ids)
        if current is None or playlist.duration_seconds > current.duration_seconds:
            by_sequence[playlist.clip_ids] = playlist
    if not by_sequence:
        return None

    def rank(row: MplsPlaylist) -> tuple[int, int, str]:
        return (row.duration_seconds, len(row.items), row.path.name)

    def size(row: MplsPlaylist) -> int:
        return sum(stream_sizes[clip_id] for clip_id in set(row.clip_ids))

    longest = max(by_sequence.values(), key=rank)
    largest = max(
        (
            row
            for row in by_sequence.values()
            if longest.duration_seconds - row.duration_seconds <= _SIMILAR_LENGTH_S
        ),
        key=lambda row: (size(row), rank(row)),
    )
    return largest if size(largest) >= size(longest) * _LARGER_COPY_RATIO else longest


# 写进音轨/字幕 JSON 的内部版本戳。API 会显式投影公开字段，因此不会把它暴露
# 给前端；存量补探靠它区分“旧数据尚未读 CLPI”和“读过但语言确实未知”。
CLPI_LANGUAGE_VERSION = 1
_VERSION_KEY = "clpi_language_version"

_AUDIO_TYPES = {
    0x03,  # MPEG-1 Audio
    0x04,  # MPEG-2 Audio
    0x80,  # LPCM
    0x81,  # AC-3
    0x82,  # DTS
    0x83,  # Dolby TrueHD
    0x84,  # E-AC-3
    0x85,  # DTS-HD
    0x86,  # DTS-HD MA
    0xA1,  # secondary E-AC-3
    0xA2,  # secondary DTS-HD
}
# 0x91 是菜单交互图形，不是用户可选择的影片字幕；0xA0 虽也带
# language 字段，但不是标准 PGS/TextST 字幕类型。两者都不回填到
# subtitle_streams，避免与 ffprobe 的影片字幕误关联。
_SUBTITLE_TYPES = {0x90, 0x92}  # PGS、TextST


class ClpiParseError(ValueError):
    """CLPI 结构不完整或字段越界；错误文本可直接写入中文日志。"""


@dataclass(frozen=True)
class ClpiLanguages:
    """按 MPEG-TS PID 分组的语言表；只包含可用于音轨/字幕的流。"""

    audio: dict[int, str]
    subtitles: dict[int, str]


def clpi_path_for_stream(stream_path: Path) -> Path | None:
    """主 m2ts → 同编号 CLPI；路径不是标准 BDMV/STREAM 布局时返回 None。"""
    if stream_path.suffix.lower() != ".m2ts":
        return None
    stream_dir = stream_path.parent
    bdmv_dir = stream_dir.parent
    if stream_dir.name.upper() != "STREAM" or bdmv_dir.name.upper() != "BDMV":
        return None
    return bdmv_dir / "CLIPINF" / f"{stream_path.stem}.clpi"


def read_clpi_languages(stream_path: Path) -> ClpiLanguages | None:
    """读取主流对应的 CLPI；主副本都不可用时才降级为 None。

    标准蓝光会在 ``BDMV/BACKUP/CLIPINF`` 保留一份镜像。部分盘面或
    网盘拷贝的主 CLPI 缺失/损坏，此时仍应尝试备份，不阻断扫描。
    """
    primary_path = clpi_path_for_stream(stream_path)
    if primary_path is None:
        return None
    backup_path = primary_path.parent.parent / "BACKUP" / "CLIPINF" / primary_path.name
    for clpi_path in (primary_path, backup_path):
        if not clpi_path.is_file():
            continue
        try:
            return parse_clpi_languages(clpi_path.read_bytes())
        except (OSError, ClpiParseError) as exc:
            logger.warning(
                "蓝光 CLPI 语言元数据解析失败，继续尝试降级路径：%s（%s）", clpi_path, exc
            )
    return None


def parse_clpi_languages(data: bytes) -> ClpiLanguages:
    """解析 CLPI ProgramInfo，返回 PID → ISO 639-2 三字码。

    文件头 ``0x0c`` 保存 ProgramInfo 的绝对偏移。每条流先给 PID，再给带长度
    的 StreamCodingInfo；不同编码的语言偏移不同，因此始终尊重条目长度并做
    边界校验。一个 PID 在多个 program sequence 中声明冲突语言时将其丢弃，
    宁可保持未知也不写入不确定结果。
    """
    if len(data) < 16:
        # i18n-ignore: parser diagnostic, logged only
        raise ClpiParseError("文件头不足 16 字节")
    if data[:4] != b"HDMV":
        # i18n-ignore: parser diagnostic, logged only
        raise ClpiParseError("文件签名不是 HDMV")

    program_offset = int.from_bytes(data[12:16], "big")
    if program_offset + 6 > len(data):
        # i18n-ignore: parser diagnostic, logged only
        raise ClpiParseError("ProgramInfo 偏移越界")

    section_length = int.from_bytes(data[program_offset : program_offset + 4], "big")
    section_end = program_offset + 4 + section_length
    if section_end > len(data):
        # i18n-ignore: parser diagnostic, logged only
        raise ClpiParseError("ProgramInfo 长度越界")

    pos = program_offset + 4
    _require(pos, 2, section_end, "ProgramInfo header")
    pos += 1  # reserved
    program_count = data[pos]
    pos += 1

    audio: dict[int, str] = {}
    subtitles: dict[int, str] = {}
    audio_conflicts: set[int] = set()
    subtitle_conflicts: set[int] = set()

    for _ in range(program_count):
        _require(pos, 8, section_end, "program sequence")
        pos += 4  # spn_program_sequence_start
        pos += 2  # program_map_pid
        stream_count = data[pos]
        pos += 1
        pos += 1  # number_of_groups

        for _ in range(stream_count):
            _require(pos, 3, section_end, "stream entry")
            pid = int.from_bytes(data[pos : pos + 2], "big")
            coding_length = data[pos + 2]
            pos += 3
            _require(pos, coding_length, section_end, "StreamCodingInfo")
            if coding_length < 1:
                # i18n-ignore: parser diagnostic, logged only
                raise ClpiParseError("StreamCodingInfo 长度为 0")

            coding_type = data[pos]
            language: str | None = None
            target: dict[int, str] | None = None
            conflicts: set[int] | None = None
            if coding_type in _AUDIO_TYPES:
                language = _language_at(data, pos + 2, pos + coding_length)
                target, conflicts = audio, audio_conflicts
            elif coding_type in _SUBTITLE_TYPES:
                language_offset = 2 if coding_type == 0x92 else 1
                language = _language_at(data, pos + language_offset, pos + coding_length)
                target, conflicts = subtitles, subtitle_conflicts

            if language is not None and target is not None and conflicts is not None:
                _record_language(target, conflicts, pid, language)
            pos += coding_length

    return ClpiLanguages(audio=audio, subtitles=subtitles)


def read_clpi_keyframes(stream_path: Path) -> list[int] | None:
    """读取剪辑的关键帧 PTS 表（45 kHz，升序）；CLPI 缺失/损坏/无 EP_map 时 None。

    与 ``read_clpi_languages`` 同样先主 CLPI 后 ``BDMV/BACKUP`` 镜像。返回 None
    时调用方退回「关键帧未知」——网页播放器保守不走 remux，Jellyfin 层的多剪辑
    HLS 退回会话式播放，都不阻断。
    """
    primary_path = clpi_path_for_stream(stream_path)
    if primary_path is None:
        return None
    backup_path = primary_path.parent.parent / "BACKUP" / "CLIPINF" / primary_path.name
    for clpi_path in (primary_path, backup_path):
        if not clpi_path.is_file():
            continue
        try:
            keyframes = parse_clpi_keyframes(clpi_path.read_bytes())
        except (OSError, ClpiParseError) as exc:
            logger.warning("蓝光 CLPI 关键帧表解析失败，继续尝试降级路径：%s（%s）", clpi_path, exc)
            continue
        return keyframes or None
    return None


def parse_clpi_keyframes(data: bytes) -> list[int]:
    """解析 CLPI 的 CPI/EP_map，返回主视频流每个入口点的 PTS（45 kHz，升序去重）。

    结构说明见 ``parse_clpi_entry_points``；这里只取 PTS。
    """
    return sorted({pts for pts, _ in parse_clpi_entry_points(data)})


def read_clpi_entry_points(clpi_data: bytes) -> list[tuple[int, int]] | None:
    """``parse_clpi_entry_points`` 的容错版：解析失败返回 None（可选元数据缺失）。"""
    try:
        return parse_clpi_entry_points(clpi_data) or None
    except ClpiParseError as exc:
        logger.warning("蓝光 CLPI 入口点表解析失败：%s", exc)
        return None


def parse_clpi_entry_points(data: bytes) -> list[tuple[int, int]]:
    """解析 CLPI 的 CPI/EP_map，返回主视频流每个入口点的 (PTS, 源包号)，按 PTS 升序。

    源包号（SPN）× 192 是入口点在 m2ts 里的字节位置——刷片挑点用相邻入口点的字节差
    估码率（与 Matroska / MP4 的关键帧字节位置同一用法）。

    文件头 ``0x10`` 是 CPI 的绝对偏移。CPI 先给长度（0 = 没有 EP_map，返回空表）
    与类型，随后是 EP_map：每路流一条 12 字节索引（PID、类型、粗/细表条目数、
    该流表的相对起址），流表以粗表（8 字节：ref_to_EP_fine_id 18 位、
    PTS_EP_coarse 14 位、SPN 32 位）和细表（4 字节：角度标志 1 位、I 帧尾偏移
    3 位、PTS_EP_fine 11 位、SPN 17 位）两级组织。完整 PTS 的拼法照抄 libbluray
    ``clpi_access_point``：``((coarse & ~1) << 18) + (fine << 8)``——粗表最低位与
    细表最高位是同一位，低 8 位丢失（约 5.7 毫秒，切片边界判定可以接受）。

    有多路视频（Dolby Vision 双层）时只取主视频 PID 0x1011 的表；没有它就取
    PID 最小的一路。
    """
    if len(data) < 20:
        # i18n-ignore: parser diagnostic, logged only
        raise ClpiParseError("文件头不足 20 字节")
    if data[:4] != b"HDMV":
        # i18n-ignore: parser diagnostic, logged only
        raise ClpiParseError("文件签名不是 HDMV")
    cpi_offset = int.from_bytes(data[16:20], "big")
    if cpi_offset == 0:
        return []
    if cpi_offset + 4 > len(data):
        # i18n-ignore: parser diagnostic, logged only
        raise ClpiParseError("CPI 偏移越界")
    cpi_length = int.from_bytes(data[cpi_offset : cpi_offset + 4], "big")
    if cpi_length == 0:
        return []
    cpi_end = cpi_offset + 4 + cpi_length
    if cpi_end > len(data):
        # i18n-ignore: parser diagnostic, logged only
        raise ClpiParseError("CPI 长度越界")
    # 2 字节：12 位保留 + 4 位 cpi_type；EP_map 内的相对地址以其后为基准
    ep_map_pos = cpi_offset + 4 + 2
    _require(ep_map_pos, 2, cpi_end, "EP_map header")
    stream_count = data[ep_map_pos + 1]
    pos = ep_map_pos + 2
    entries: list[tuple[int, int, int, int]] = []  # (pid, coarse 数, fine 数, 起址)
    for _ in range(stream_count):
        _require(pos, 12, cpi_end, "EP_map stream entry")
        raw = int.from_bytes(data[pos : pos + 12], "big")
        pid = raw >> 80
        coarse_count = (raw >> 50) & 0xFFFF
        fine_count = (raw >> 32) & 0x3FFFF
        start = raw & 0xFFFFFFFF
        entries.append((pid, coarse_count, fine_count, start))
        pos += 12
    if not entries:
        return []
    chosen = next((e for e in entries if e[0] == _PRIMARY_VIDEO_PID), None) or min(
        entries, key=lambda e: e[0]
    )
    _, coarse_count, fine_count, start = chosen
    stream_pos = ep_map_pos + start
    _require(stream_pos, 4, cpi_end, "EP_map stream table")
    fine_start = int.from_bytes(data[stream_pos : stream_pos + 4], "big")
    coarse_pos = stream_pos + 4
    _require(coarse_pos, coarse_count * 8, cpi_end, "EP_map coarse table")
    # (ref_to_EP_fine_id, PTS_EP_coarse, SPN_EP_coarse)
    coarse: list[tuple[int, int, int]] = []
    for i in range(coarse_count):
        raw = int.from_bytes(data[coarse_pos + i * 8 : coarse_pos + i * 8 + 8], "big")
        coarse.append((raw >> 46, (raw >> 32) & 0x3FFF, raw & 0xFFFFFFFF))
    fine_pos = stream_pos + fine_start
    _require(fine_pos, fine_count * 4, cpi_end, "EP_map fine table")
    fine: list[tuple[int, int]] = []  # (PTS_EP_fine, SPN_EP_fine)
    for i in range(fine_count):
        raw = int.from_bytes(data[fine_pos + i * 4 : fine_pos + i * 4 + 4], "big")
        fine.append(((raw >> 17) & 0x7FF, raw & 0x1FFFF))
    points: dict[int, int] = {}
    for i, (fine_from, pts_coarse, spn_coarse) in enumerate(coarse):
        fine_to = coarse[i + 1][0] if i + 1 < len(coarse) else fine_count
        for j in range(fine_from, min(fine_to, fine_count)):
            pts_fine, spn_fine = fine[j]
            # SPN 拼法同 libbluray：粗表 SPN 去掉低 17 位，再加细表的低 17 位
            pts = ((pts_coarse & ~1) << 18) + (pts_fine << 8)
            points.setdefault(pts, (spn_coarse & ~0x1FFFF) + spn_fine)
    return sorted(points.items())


def enrich_spec_with_clpi(spec: MediaSpec, languages: ClpiLanguages) -> MediaSpec:
    """按 PID 给缺语言的 ffprobe 流回填 CLPI，并给所有流写完成版本戳。

    列表顺序保持原样：字幕抽取和播放器使用数组下标生成 ``0:s:<k>`` 引用，
    为了“对齐”而重排会让已保存的轨引用失效。已有语言只标记来源为 ffprobe，
    绝不被 CLPI 覆盖。
    """

    def enrich(raw: dict, fallback: dict[int, str]) -> dict:
        stream = dict(raw)
        language = stream.get("language")
        # ffprobe 常用 und 或空字符串表示“未知”，语义上与 None 相同，
        # 不应阻止 CLPI 回填。只保护确实有效的 ffprobe 语言。
        has_language = isinstance(language, str) and language.strip().lower() not in {"", "und"}
        pid = stream.get("pid")
        if not has_language and isinstance(pid, int) and pid in fallback:
            stream["language"] = fallback[pid]
            stream["language_source"] = "clpi"
        elif has_language:
            stream.setdefault("language_source", "ffprobe")
        stream[_VERSION_KEY] = CLPI_LANGUAGE_VERSION
        return stream

    return replace(
        spec,
        audio_streams=[enrich(stream, languages.audio) for stream in spec.audio_streams],
        subtitle_streams=[enrich(stream, languages.subtitles) for stream in spec.subtitle_streams],
    )


def streams_have_clpi_metadata(audio_streams: list | None, subtitle_streams: list | None) -> bool:
    """这组持久化流是否已由当前版本检查过 CLPI。"""
    if audio_streams is None or subtitle_streams is None:
        return False
    streams = [*audio_streams, *subtitle_streams]
    return all(stream.get(_VERSION_KEY) == CLPI_LANGUAGE_VERSION for stream in streams)


def _require(
    pos: int, size: int, end: int, field: str, *, error: type[ValueError] = ClpiParseError
) -> None:
    if size < 0 or pos < 0 or pos + size > end:
        # i18n-ignore: parser diagnostic, logged only
        raise error(f"{field} 数据越界")


def _language_at(data: bytes, pos: int, end: int) -> str | None:
    if pos + 3 > end:
        # i18n-ignore: parser diagnostic, logged only
        raise ClpiParseError("语言码数据越界")
    raw = data[pos : pos + 3]
    if not all(65 <= byte <= 90 or 97 <= byte <= 122 for byte in raw):
        return None
    language = raw.decode("ascii").lower()
    return None if language == "und" else language


def _record_language(target: dict[int, str], conflicts: set[int], pid: int, language: str) -> None:
    if pid in conflicts:
        return
    current = target.get(pid)
    if current is None:
        target[pid] = language
    elif current != language:
        target.pop(pid, None)
        conflicts.add(pid)
