"""跳过片头 / 片尾：整季音频指纹比对（docs/design/skip-intro.md §2）。

纯计算模块，无数据库、无网络。输入是一季里每集「片头窗」「片尾窗」的 chromaprint
原始哈希（ffmpeg ``-f chromaprint -fp_format raw``，每 0.124 秒一个 32 位整数），
输出每集的片头、片尾与「其他重复段」的起止秒数。

为什么这样认（每一条都来自 NAS 片库实测，数字见设计文档）：

1. **两集之间的共享段**：照抄 intro-skipper（Jellyfin 最常用的跳片头插件）的参数——
   先用哈希倒排找两段指纹可能的对齐位移，再在每个位移上逐帧比汉明距离（≤6 位算像），
   允许 3.5 秒的断点，连续 ≥15 秒算一段。
2. **整季比，不是只比相邻几集**：同一部剧的片头可能有好几个配乐版本交替出现
   （华语剧 A第 17 集的片头只和第 10、11、13、18、23、24 集对得上），所以每集与
   前后各 ``NEIGHBORS`` 集比。比的是缓存好的指纹，不读媒体文件，一季一两秒。
3. **对齐质量过滤**：整季比会把片中复用的配乐也认出来。早期样本中，真片头片尾
   对齐质量为 72%～97%，有对白的配乐复用为 30%～64%；这不是普遍成立的分界。
   韩剧 A的剧情配乐也可达 77%～81%，音乐延续进剧情时更无法只凭音频找边界。
   候选段被接受的两条路，满足任一即可：
   - 「对得很像」（占比 ≥ ``GOOD_MATCH``）的伙伴 ≥2 个——救下片头有多个版本、
     每个版本只出现在少数几集的季；
   - 对上的伙伴占比 ≥ ``MAJORITY`` 且 ≥2 个——救下配乐安静、指纹噪声大但每集都有
     的片头（英剧 A对齐质量只有 0.22～0.47）。
4. **片头窗里的短段**（2026-10 国产剧实验，设计文档 §2.9）：国产剧开头常见 6～15 秒的
   平台厂标、发行许可证、片头后的冠名广告，15 秒门槛认不出。片头窗的共享段放宽到
   ``SHORT_SEGMENT_S``，但短段只在三重约束下成立，免得把剧情配乐的零碎重复认进来：
   - 长候选（≥15 秒）只认长匹配的票，判定与放宽前完全一致；
   - 短候选走「对得很像」这条路时，门槛提到 ``SHORT_GOOD_MATCH``（厂标、许可证各集
     是同一份音频，剧情配乐有对白和环境声盖着）；
   - 短候选要么落在文件开头 ``HEAD_ZONE_S`` 秒内，要么紧挨一个已接受的长段
     （≤ ``ADJACENT_S`` 秒，片头前后的冠名广告）。
5. **整理**：首尾相接的段合并（冠名广告 + 发行许可 + 片头一个按钮跳完）；片头窗里
   最长的一段是片头，其余是「其他」；片尾窗只认最后一段（片中每集都响一遍的固定
   配乐场景不当片尾），终点离文件结尾 ≤5 秒的标「到结尾」，客户端直接给「下一集」。

子进程入口：``python -m movieclaw_playback.skip_segments``，标准输入一行 JSON，
标准输出一行 JSON（见 ``_main``）。服务端在独立进程里跑它——一季的比对是纯 Python
的 CPU 活，放在服务进程里会抢 GIL、拖慢同时在跑的接口与取流。
"""

from __future__ import annotations

import contextlib
import json
import os
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field

import numpy as np

#: 每个哈希覆盖的时长（秒）：chromaprint 默认算法 11025 Hz、帧长 4096、步长 1/3 帧
HASH_SECONDS = 4096.0 / 11025.0 / 3.0
#: 两个哈希「像」的汉明距离上限（intro-skipper 同值）
MAX_BIT_DIFF = 6
#: 连续段里允许的最长断点（秒）
MAX_GAP_S = 3.5
#: 找对齐位移时，哈希值允许相差的范围（±2，intro-skipper 同值）
SHIFT_TOLERANCE = 2
#: 一段至少多长才算（秒）
MIN_SEGMENT_S = 15.0
#: 片头窗 / 片尾窗里一段最长多长（更长的是同一集的另一个版本或整段重播，不是片头片尾）
MAX_SEGMENT_S = {"intro": 180.0, "outro": 460.0}
#: 每集与前后各多少集比对
NEIGHBORS = 12
#: 「对得很像」的门槛：对齐区间里 ≤ MAX_BIT_DIFF 的帧占比
GOOD_MATCH = 0.65
#: 「季里多数集都有」的门槛：对上的伙伴 / 比对的伙伴
MAJORITY = 0.5
#: 首尾相接多近算一段（秒）
MERGE_GAP_S = 3.0
#: 片尾终点离文件结尾多近算「到结尾」（秒）
TO_END_S = 5.0
#: 片头窗里短段的最短长度（秒）：平台厂标、发行许可证、冠名广告多在 6～15 秒
SHORT_SEGMENT_S = 6.0
#: 短候选「对得很像」的门槛：比长段的 GOOD_MATCH 严，剧情配乐的零碎重复多在 0.7～0.8
SHORT_GOOD_MATCH = 0.85
#: 短段可以独立成立的开头区（文件秒）：厂标、许可证、冠名广告都在这里
HEAD_ZONE_S = 60.0
#: 开头区以外的短段必须离一个已接受的长段多近（秒）：片头后紧跟的冠名广告
ADJACENT_S = 3.0
#: 算法版本：改了上面任何规则就加一，服务端据此把旧结果全部重算一遍
#: （7：候选位移按升序遍历，等长共享段的取舍确定下来；8：服务端按画面演职员表修正片尾；
#: 9：服务端按画面文字给开头段标广告、片尾后单独标出下集预告）
ALGO_VERSION = 9

_POPCOUNT8 = np.array([bin(i).count("1") for i in range(256)], dtype=np.uint8)


def window_bounds(duration_s: float) -> dict[str, tuple[float, float]]:
    """片头窗与片尾窗（起点秒, 时长秒）：片头取前 10 分钟、片尾取后 7 分钟，短片各取 1/4。

    实测片头终点 P90 300 秒、最大 514 秒；片尾起点离结尾 P90 170 秒、最大 363 秒。
    """
    head = min(0.25 * duration_s, 600.0)
    tail = min(0.25 * duration_s, 420.0)
    return {"intro": (0.0, head), "outro": (max(0.0, duration_s - tail), tail)}


def _popcount(x: np.ndarray) -> np.ndarray:
    return _POPCOUNT8[x.view(np.uint8).reshape(-1, 4)].sum(axis=1)


@dataclass
class Window:
    """一集的一个指纹窗。``start`` 是窗口起点在文件里的秒数。"""

    hashes: np.ndarray
    start: float


@dataclass
class Episode:
    """一季里的一个文件。同一集的多个版本是多个 Episode（集号相同）。"""

    file_id: int
    episode: int
    duration: float
    windows: dict[str, Window] = field(default_factory=dict)


@dataclass(frozen=True)
class Segment:
    """识别结果。``kind``：intro 片头 / outro 片尾 / other 其他重复段（冠名广告等）。"""

    kind: str
    start: float
    end: float
    #: 有几个伙伴集也有这一段（诊断用）
    support: int
    #: 片尾一直放到文件结尾：客户端可以直接给「下一集」
    to_end: bool = False

    def as_dict(self) -> dict:
        return {
            "type": self.kind,
            "start_ms": int(round(self.start * 1000)),
            "end_ms": int(round(self.end * 1000)),
            "support": self.support,
            "to_end": self.to_end,
        }


# ---------------------------------------------------------------------------
# 两集之间
# ---------------------------------------------------------------------------


def _contiguous(
    lhs: np.ndarray, rhs: np.ndarray, shift: int, min_s: float = MIN_SEGMENT_S
) -> list[tuple[int, int, int, int]]:
    """在给定位移下找全部连续相似区间，返回 (lhs 起, lhs 止, rhs 起, rhs 止) 帧号。

    ``shift`` = rhs 帧号 - lhs 帧号。相似 = 汉明距离 ≤ MAX_BIT_DIFF；断点 ≤ MAX_GAP_S 不打断。
    广告和片头在各集里的位置经常完全相同（或整体平移），共享同一个位移；只取最长段
    会丢掉短广告，片尾窗里还会让较长的配乐剧情挤掉真正的片尾。这里保留所有够长的段，
    跨位移去重、跨集共识和片尾只取最后一段仍由后面的步骤负责。
    """
    lo = -shift if shift < 0 else 0
    ro = shift if shift > 0 else 0
    n = min(len(lhs) - lo, len(rhs) - ro)
    if n <= 0:
        return []
    idx = np.nonzero(_popcount(lhs[lo : lo + n] ^ rhs[ro : ro + n]) <= MAX_BIT_DIFF)[0]
    if len(idx) == 0:
        return []
    breaks = np.nonzero(np.diff(idx) * HASH_SECONDS > MAX_GAP_S)[0]
    starts = np.concatenate(([0], breaks + 1))
    ends = np.concatenate((breaks, [len(idx) - 1]))
    regions = []
    for first, last in zip(starts, ends, strict=True):
        a, b = int(idx[first]) + lo, int(idx[last]) + lo
        if (b - a) * HASH_SECONDS >= min_s:
            regions.append((a, b, a + shift, b + shift))
    return regions


#: 一个窗口的倒排索引：(升序的唯一哈希值, 每个值最后一次出现的帧号)
ValueIndex = tuple[np.ndarray, np.ndarray]


def _value_index(hashes: np.ndarray) -> ValueIndex:
    """每个哈希值最后一次出现的帧号，按值升序。

    重复值取最后一次，与 intro-skipper 的倒排写法一致。
    """
    values, first_in_reversed = np.unique(hashes[::-1], return_index=True)
    return values, (len(hashes) - 1 - first_in_reversed).astype(np.int64)


def _candidate_shifts(left: ValueIndex, right: ValueIndex) -> list[int]:
    """哈希值相同（±SHIFT_TOLERANCE）的帧对给出的全部候选位移，升序。

    两侧都是升序唯一值，按容差平移后求交集，全程向量化。逐帧查 Python 字典的旧写法
    占了整季比对 87% 的时间（同一集的窗口在 24 次配对里还要反复建字典），全库实测
    改写后快 3.4 倍，候选位移集合与旧写法完全相同。
    """
    lv, li = left
    rv, ri = right
    shifts: set[int] = set()
    for delta in range(-SHIFT_TOLERANCE, SHIFT_TOLERANCE + 1):
        moved = ((lv.astype(np.int64) + delta) & 0xFFFFFFFF).astype(np.uint32)
        # 平移可能在 0 / 2^32 处回绕，打乱升序；唯一性不变
        order = np.argsort(moved, kind="stable")
        _, a, b = np.intersect1d(moved[order], rv, assume_unique=True, return_indices=True)
        shifts.update((ri[b] - li[order][a]).tolist())
    return sorted(shifts)


def shared_regions(
    lhs: np.ndarray,
    rhs: np.ndarray,
    min_s: float = MIN_SEGMENT_S,
    indexes: tuple[ValueIndex, ValueIndex] | None = None,
) -> list[tuple[int, int, int, int]]:
    """两段指纹之间互不重叠的、至少 ``min_s`` 秒的全部共享段（帧号），长的优先。

    ``indexes``：两侧窗口的倒排索引（整季比对时每个窗口只建一次）；不给就现建。
    候选位移按升序遍历，等长共享段的取舍才是确定的：按集合遍历顺序时，同样的输入
    换一种建集合的顺序，全库有 1045 集边界变化（大多 1 帧，最大 31 秒）。
    """
    left, right = indexes if indexes is not None else (_value_index(lhs), _value_index(rhs))
    found = [r for s in _candidate_shifts(left, right) for r in _contiguous(lhs, rhs, s, min_s)]
    found.sort(key=lambda r: -(r[1] - r[0]))
    kept: list[tuple[int, int, int, int]] = []
    for r in found:
        if any(min(r[1], k[1]) - max(r[0], k[0]) > 0 for k in kept):
            continue
        kept.append(r)
    return kept


def _match_quality(lhs: np.ndarray, rhs: np.ndarray, region: tuple[int, int, int, int]) -> float:
    """对齐区间里「像」的帧占比——区分真片头（同一份音频）与配乐复用（有对白盖着）。"""
    a, b, c, _ = region
    n = min(b - a, len(rhs) - c)
    if n <= 0:
        return 0.0
    return float((_popcount(lhs[a : a + n] ^ rhs[c : c + n]) <= MAX_BIT_DIFF).mean())


# ---------------------------------------------------------------------------
# 一季
# ---------------------------------------------------------------------------


def _overlap(a: tuple[float, float], b: tuple[float, float]) -> float:
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


class _Season:
    """一季的比对上下文：缓存两两比对结果（A 比 B 与 B 比 A 只算一次）。"""

    def __init__(self, episodes: Sequence[Episode]):
        self.episodes = list(episodes)
        self._pairs: dict[tuple[int, int, str], list[tuple[tuple[float, float], float]]] = {}
        self._indexes: dict[tuple[int, str], ValueIndex] = {}

    def _index(self, episode: Episode, mode: str) -> ValueIndex:
        """窗口的倒排索引：每集每个窗口只建一次，供它参与的全部配对复用。"""
        key = (episode.file_id, mode)
        if key not in self._indexes:
            self._indexes[key] = _value_index(episode.windows[mode].hashes)
        return self._indexes[key]

    def pair(self, a: Episode, b: Episode, mode: str) -> list[tuple[tuple[float, float], float]]:
        """a 上与 b 共享的段（文件秒数）及对齐质量。"""
        key = (a.file_id, b.file_id, mode)
        if key in self._pairs:
            return self._pairs[key]
        wa, wb = a.windows.get(mode), b.windows.get(mode)
        if wa is None or wb is None or len(wa.hashes) == 0 or len(wb.hashes) == 0:
            self._pairs[key] = self._pairs[(b.file_id, a.file_id, mode)] = []
            return []
        mine: list[tuple[tuple[float, float], float]] = []
        theirs: list[tuple[tuple[float, float], float]] = []
        # 片头窗放宽到短段（厂标、许可证、冠名广告），由 raw_segments 再加约束；片尾窗不变
        min_s = SHORT_SEGMENT_S if mode == "intro" else MIN_SEGMENT_S
        indexes = (self._index(a, mode), self._index(b, mode))
        for region in shared_regions(wa.hashes, wb.hashes, min_s, indexes):
            sa, ea = region[0] * HASH_SECONDS, region[1] * HASH_SECONDS
            if ea - sa > MAX_SEGMENT_S[mode]:
                continue
            q = _match_quality(wa.hashes, wb.hashes, region)
            mine.append(((sa + wa.start, ea + wa.start), q))
            sb, eb = region[2] * HASH_SECONDS, region[3] * HASH_SECONDS
            # 质量按各自的视角算（对齐长度取自己这一侧），两边各存一份
            back = (region[2], region[3], region[0], region[1])
            q_back = _match_quality(wb.hashes, wa.hashes, back)
            theirs.append(((sb + wb.start, eb + wb.start), q_back))
        if mode == "outro":
            # 片尾先选每对里最后的共享段，再验证跨集共识。不能先淘汰弱匹配再往前找：
            # 华语剧 A E01 后段未过共识时，会退回 2368–2385 秒的重复配乐剧情并误标片尾。
            # 两侧分别按自己的时间线选；片头窗仍保留全部段，以识别分开的广告和片头。
            mine = sorted(mine, key=lambda item: item[0][0])[-1:]
            theirs = sorted(theirs, key=lambda item: item[0][0])[-1:]
        self._pairs[key] = mine
        self._pairs[(b.file_id, a.file_id, mode)] = theirs
        return mine

    def partners(self, episode: Episode) -> list[Episode]:
        """前后各 NEIGHBORS 个**别的集**（同一集的其他版本不算：它们处处都一样）。"""
        numbers = sorted({e.episode for e in self.episodes})
        first: dict[int, Episode] = {}
        for e in sorted(self.episodes, key=lambda e: e.file_id):
            first.setdefault(e.episode, e)
        i = numbers.index(episode.episode)
        picked = numbers[max(0, i - NEIGHBORS) : i] + numbers[i + 1 : i + 1 + NEIGHBORS]
        return [first[n] for n in picked]

    def raw_segments(self, episode: Episode, mode: str) -> list[tuple[float, float, int]]:
        """episode 上被接受的重复段（起, 止, 支持数），未整理。"""
        # 不同集号也可能装了同一份音轨。华语剧 J E02/E03 的十分钟开头指纹完全
        # 相同，重复投票会把 E01 的剧情配乐当成“多数集共有”。超过最大可跳长度
        # 的完整窗口才去重：短窗可能正好只覆盖正常片头，不能把真片头的票也合掉。
        partners: list[Episode] = []
        seen: set[bytes] = set()
        for item in [episode, *self.partners(episode)]:
            window = item.windows.get(mode)
            if window is not None and len(window.hashes) * HASH_SECONDS > MAX_SEGMENT_S[mode]:
                key = window.hashes.tobytes()
                if key in seen:
                    continue
                seen.add(key)
            if item is not episode:
                partners.append(item)
        per = [self.pair(episode, q, mode) for q in partners]
        candidates = sorted({r for regs in per for r, _ in regs}, key=lambda r: -(r[1] - r[0]))
        accepted: list[tuple[float, float, int]] = []
        for r in candidates:
            short = r[1] - r[0] < MIN_SEGMENT_S
            support: list[tuple[tuple[float, float], float]] = []
            for regs in per:
                # 长候选只认长匹配的票：片头窗放宽到短段后，伙伴里零碎的短重复（剧情
                # 配乐的一小截）不能把原本票数不够的长候选抬过门槛。华语剧 F E08
                # 28–44 秒的剧情就是靠一段 11 秒短匹配凑够了第二票。
                hits = [
                    (x, q)
                    for x, q in regs
                    if _overlap(r, x) >= 0.5 * (r[1] - r[0])
                    and (short or x[1] - x[0] >= MIN_SEGMENT_S)
                ]
                if hits:
                    support.append(max(hits, key=lambda h: _overlap(r, h[0])))
            good = [x for x, q in support if q >= (SHORT_GOOD_MATCH if short else GOOD_MATCH)]
            if len(good) >= 2:
                used = good
            elif len(support) >= 2 and len(support) >= MAJORITY * len(partners):
                used = [x for x, _ in support]
            else:
                continue
            # 长匹配只能为当前候选的重叠部分投票，不能借用它在候选外的边界。
            # 例如候选 125–144 秒得到 0–154 秒和 125–144 秒两个伙伴支持，直接取
            # 中位数会凭空扩成 62–149 秒，跨过未匹配内容，或被其他候选的去重误删。
            used = [(max(r[0], a), min(r[1], b)) for a, b in used]
            s = float(np.median([x[0] for x in used]))
            e = float(np.median([x[1] for x in used]))
            if any(_overlap((s, e), (a, b)) > 0.5 * min(e - s, b - a) for a, b, _ in accepted):
                continue
            # 开头区以外的短段必须紧挨一个已接受的长段（候选按长度从长到短处理，长段
            # 已经都在 accepted 里）。片头后的冠名广告满足；片中零碎的配乐重复一般不贴着
            # 片头，全窗放宽实测有三分之一是剧情。
            if (
                short
                and s >= HEAD_ZONE_S
                and not any(
                    b - a >= MIN_SEGMENT_S
                    and (abs(s - b) <= ADJACENT_S or abs(a - e) <= ADJACENT_S)
                    for a, b, _ in accepted
                )
            ):
                continue
            accepted.append((s, e, len(support)))
        return sorted(accepted)


def _merge(segments: list[tuple[float, float, int]]) -> list[tuple[float, float, int]]:
    """首尾相接（间隔 ≤ MERGE_GAP_S）或重叠的段合并成一段。"""
    out: list[tuple[float, float, int]] = []
    for s, e, n in sorted(segments):
        if out and s <= out[-1][1] + MERGE_GAP_S:
            ps, pe, pn = out[-1]
            out[-1] = (ps, max(pe, e), max(pn, n))
        else:
            out.append((s, e, n))
    return out


def label(
    intro: list[tuple[float, float, int]],
    outro: list[tuple[float, float, int]],
    duration: float,
) -> list[Segment]:
    """把两个窗里的重复段整理成最终结果（片头 / 其他 / 片尾）。"""
    result: list[Segment] = []
    heads = _merge(intro)
    if heads:
        main = max(heads, key=lambda x: x[1] - x[0])
        for s, e, n in heads:
            result.append(Segment("intro" if (s, e, n) == main else "other", s, e, n))
    tails = _merge(outro)
    if tails:
        s, e, n = tails[-1]
        # 片头窗与片尾窗在短片里可能重叠：片尾段已经算作片头的部分不再重复给
        if not any(_overlap((s, e), (x.start, x.end)) > 0.5 * (e - s) for x in result):
            result.append(Segment("outro", s, e, n, to_end=duration - e <= TO_END_S))
    return sorted(result, key=lambda x: x.start)


def detect_season(episodes: Sequence[Episode]) -> dict[int, list[Segment]]:
    """一季的识别结果：{file_id: [Segment, ...]}。少于 3 个不同集号时不认（全部为空）。"""
    result: dict[int, list[Segment]] = {e.file_id: [] for e in episodes}
    if len({e.episode for e in episodes}) < 3:
        return result
    season = _Season(episodes)
    for e in season.episodes:
        result[e.file_id] = label(
            season.raw_segments(e, "intro"), season.raw_segments(e, "outro"), e.duration
        )
    return result


# ---------------------------------------------------------------------------
# 指纹文件与子进程入口
# ---------------------------------------------------------------------------

#: 指纹文件格式版本
FINGERPRINT_VERSION = 1


def encode_fingerprint(meta: dict, windows: dict[str, bytes]) -> bytes:
    """指纹文件 = 一行 JSON 元数据 + 各窗口的原始哈希字节（按 meta 里登记的顺序与长度）。"""
    layout = []
    for name, raw in windows.items():
        layout.append({"name": name, "bytes": len(raw), **meta.get("windows", {}).get(name, {})})
    head = dict(meta, v=FINGERPRINT_VERSION, layout=layout)
    head.pop("windows", None)
    return json.dumps(head, ensure_ascii=False).encode() + b"\n" + b"".join(windows.values())


def decode_fingerprint(raw: bytes) -> tuple[dict, dict[str, Window]] | None:
    """解析指纹文件；版本不对或格式坏了返回 None。"""
    head, sep, body = raw.partition(b"\n")
    if not sep:
        return None
    try:
        meta = json.loads(head)
    except ValueError:
        return None
    if not isinstance(meta, dict) or meta.get("v") != FINGERPRINT_VERSION:
        return None
    windows: dict[str, Window] = {}
    offset = 0
    try:
        for item in meta["layout"]:
            size = int(item["bytes"])
            # 长度必须与头部登记完全一致；截断数据不能被当作“没有匹配”的有效指纹。
            if size < 0 or size % 4 or offset + size > len(body):
                return None
            chunk = body[offset : offset + size]
            offset += size
            windows[str(item["name"])] = Window(
                np.frombuffer(chunk, dtype="<u4").copy(), float(item["start"])
            )
    except (KeyError, TypeError, ValueError):
        return None
    if offset != len(body):
        return None
    return meta, windows


def _main() -> None:
    """子进程入口。

    标准输入：``{"episodes": [{"file_id", "episode", "duration", "path": 指纹文件}]}``；
    标准输出：``{"algo_version", "results": {"文件 id": [段, ...]}, "unreadable": [文件 id]}``。
    """
    with contextlib.suppress(OSError):
        os.nice(10)
    request = json.loads(sys.stdin.read())
    episodes: list[Episode] = []
    unreadable: list[int] = []
    for item in request.get("episodes", []):
        try:
            with open(item["path"], "rb") as f:
                parsed = decode_fingerprint(f.read())
        except OSError:
            parsed = None
        if parsed is None:
            unreadable.append(int(item["file_id"]))
            continue
        _, windows = parsed
        episodes.append(
            Episode(int(item["file_id"]), int(item["episode"]), float(item["duration"]), windows)
        )
    results = detect_season(episodes)
    sys.stdout.write(
        json.dumps(
            {
                "algo_version": ALGO_VERSION,
                "results": {str(k): [s.as_dict() for s in v] for k, v in results.items()},
                "unreadable": unreadable,
            }
        )
    )


if __name__ == "__main__":
    _main()
