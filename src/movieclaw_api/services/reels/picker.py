"""刷片挑点：给一部片（或一集）挑一段 30～60 秒的片段。纯函数，无 IO。

输入是 ``movieclaw_playback.container_index`` 读出的容器索引，输出片段的起止时间、
挑法与 App 该预取的字节范围。设计与实测依据见 docs/design/reels.md，要点：

1. **只在「不剧透」的区间里挑**：电影取全片 5%～75%，剧集取单集 10%～80%（避开
   前情提要、片头曲、片尾曲与下集预告）。一期不看观看状态，看没看过一样挑。
2. **首选码率信号**：相邻关键帧之间的字节数 ÷ 时间差就是那一段的码率。编码器给
   运动大、剪辑快、画面复杂的镜头分更多字节，所以 45 秒窗口码率最高的那一段，
   多半是全片最「热闹」的地方（NAS 实测：动作片、动画片命中率高）。
3. **信号平就退回章节**：网络平台下载的剧集常是近乎恒定码率（实测《黑袍纠察队》
   每个窗口都在 17.0～17.1 Mbps），窗口最高码率比中位数高不到 8% 就不信码率，
   改取离区间前三分之一处最近的章节起点；连章节都没有就直接取那个位置。
4. **起止点卡在对白空隙**：字幕事件近似「有人在说话」。起点优先落在章节起点
   （场景开头）附近，其次落在前后都没有台词的关键帧上；终点落在目标长度附近的
   空隙里，不切在半句话中间。
5. **预取范围**：文件头（引擎打开时要读）、索引（跳转时要读）、起点后约 4 秒的数据
   （出第一个画面要读），App 在上一条播放期间把这三段先下到本机。
"""

from __future__ import annotations

from bisect import bisect_left, bisect_right
from collections.abc import Sequence
from dataclasses import dataclass
from statistics import median

from movieclaw_playback.container_index import ContainerIndex

#: 片段目标长度与上下限（秒）
TARGET_S = 45.0
MIN_S = 30.0
MAX_S = 60.0

#: 各类内容的可挑区间（占全长的比例）
REGION = {
    "movie": (0.05, 0.75),
    "episode": (0.10, 0.80),
}

#: 窗口最高码率比中位数至少高出这么多，才认为码率曲线有起伏、值得信
INFORMATIVE_SPREAD = 0.08
#: 候选窗口的步长（秒）
WINDOW_STEP_S = 5.0
#: 起点在目标位置前后多大范围内找关键帧（秒）；找不到安静点时放宽到前后 25 秒
START_SEARCH_BACK_S = 15.0
START_SEARCH_FWD_S = 10.0
START_SEARCH_WIDE_S = 25.0
#: 目标位置前后多近的章节起点会被直接采用（秒）
CHAPTER_SNAP_S = 20.0
#: 一条字幕按最多占多久估算（只知道事件时间、不知道每句多长时的保守估计）
SPEECH_HOLD_S = 3.0

#: 关键帧字节位置就是取流地址上的位置、能给 App 预取范围的索引（``ContainerIndex.container``）
INDEXED_CONTAINERS = ("matroska", "mp4")

#: 预取：起点后多少秒的数据；文件头 / 索引 / 起点段各自的上限
PREFETCH_START_SECONDS = 4.0
HEAD_CAP_BYTES = 32 << 20
INDEX_CAP_BYTES = 64 << 20
START_CAP_BYTES = 64 << 20
#: 起点段读不出长度时的默认量
START_FALLBACK_BYTES = 8 << 20
#: 起点段按插值算出长度后多带的余量（Matroska 从 Cluster 起点读、插值有误差）
PREFETCH_MARGIN_BYTES = 1 << 20


@dataclass(frozen=True)
class ByteRange:
    """App 要预取的一段字节：[offset, offset + length)。purpose 仅供排查。"""

    offset: int
    length: int
    purpose: str  # head / index / start


@dataclass(frozen=True)
class SegmentPick:
    """挑出来的一段。时间都在原片时间轴上（秒）。"""

    start_s: float  # 有关键帧表时落在关键帧上，引擎从这里起播不需要先解前面的帧
    end_s: float
    method: str  # bitrate / chapter / position
    #: method=bitrate 时是所选窗口码率 ÷ 窗口码率中位数；其余为 0
    score: float
    prefetch: tuple[ByteRange, ...]


def pick_segment(
    index: ContainerIndex,
    *,
    kind: str,
    speech_events: Sequence[float] | None = None,
    duration_s: float | None = None,
) -> SegmentPick | None:
    """为一个文件挑片段。

    ``kind`` 为 "movie" 或 "episode"；``speech_events`` 是用来判断「有没有人在
    说话」的字幕事件时间（升序，调用方挑一条最能代表对白的字幕轨传进来，没有字幕
    传 None）；``duration_s`` 在容器没写总时长时兜底（台账里的探测时长）。
    片子太短（放不下最短片段）或没有关键帧时返回 None。
    """
    duration = index.duration_s or (duration_s or 0.0)
    if duration < MIN_S + 5:
        return None
    # 没有关键帧表（TS / AVI / DVD 这类读不出索引的片源）：按时间挑，起点交给 App 引擎
    # 定位到最近的关键帧——码率信号与「落在关键帧上」都没有，章节与固定位置照用
    times = [k.time_s for k in index.keyframes] if len(index.keyframes) >= 2 else []
    speech = sorted(speech_events) if speech_events else []

    lo_ratio, hi_ratio = REGION.get(kind, REGION["movie"])
    lo, hi = duration * lo_ratio, duration * hi_ratio
    if hi - lo < TARGET_S + 5:
        # 短片（十来分钟的动画单集等）：区间放不下一个完整窗口，放宽到整片
        lo, hi = 0.0, max(0.0, duration - MIN_S)
    latest_start = max(lo, hi - TARGET_S) if hi - lo >= TARGET_S else lo

    method, score, target = _choose_target(index, times, lo, latest_start)
    start = target
    if times:
        start = _snap_start(index, times, speech, target, lo, max(latest_start, lo))
    end = _choose_end(speech, start, duration)
    return SegmentPick(
        start_s=round(start, 3),
        end_s=round(end, 3),
        method=method,
        score=round(score, 3),
        prefetch=_prefetch_ranges(index, times, start),
    )


def reanchor(
    index: ContainerIndex,
    pick: SegmentPick,
    start_s: float,
    *,
    speech_events: Sequence[float] | None = None,
    duration_s: float | None = None,
) -> SegmentPick:
    """把片段起点挪到另一个关键帧上（封面检查发现起点是黑场时用），终点与预取随之重算。"""
    duration = index.duration_s or (duration_s or 0.0)
    times = [k.time_s for k in index.keyframes]
    speech = sorted(speech_events) if speech_events else []
    return SegmentPick(
        start_s=round(start_s, 3),
        end_s=round(_choose_end(speech, start_s, duration), 3),
        method=pick.method,
        score=pick.score,
        prefetch=_prefetch_ranges(index, times, start_s),
    )


def prefetch_for(index: ContainerIndex, start_s: float) -> tuple[ByteRange, ...]:
    """从任意起点起播要预取的三段（大图预告从续播点往前倒着放时用，起点不是挑出来的）。"""
    return _prefetch_ranges(index, [k.time_s for k in index.keyframes], start_s)


def _window_rate(index: ContainerIndex, times: list[float], start: float, length: float) -> float:
    """[start, start+length) 这一段的平均字节率：用两端最近的关键帧位置相减。"""
    i = bisect_left(times, start)
    j = bisect_left(times, start + length)
    if j >= len(times):
        j = len(times) - 1
    if i >= j:
        return 0.0
    k1, k2 = index.keyframes[i], index.keyframes[j]
    span = k2.time_s - k1.time_s
    if span <= 0 or k2.offset <= k1.offset:
        return 0.0
    return (k2.offset - k1.offset) / span


def _choose_target(
    index: ContainerIndex, times: list[float], lo: float, latest_start: float
) -> tuple[str, float, float]:
    """定一个目标起点：码率有起伏取最高窗口，否则退回章节 / 固定位置。"""
    windows: list[tuple[float, float]] = []
    s = lo
    while s <= latest_start + 1e-6:
        rate = _window_rate(index, times, s, TARGET_S)
        if rate > 0:
            windows.append((s, rate))
        s += WINDOW_STEP_S
    if windows:
        mid = median(r for _, r in windows)
        best_start, best_rate = max(windows, key=lambda w: w[1])
        if mid > 0 and (best_rate - mid) / mid >= INFORMATIVE_SPREAD:
            return "bitrate", best_rate / mid, best_start

    anchor = lo + (latest_start - lo) / 3
    in_region = [c for c, _ in index.chapters if lo <= c <= latest_start]
    if in_region:
        return "chapter", 0.0, min(in_region, key=lambda c: abs(c - anchor))
    return "position", 0.0, anchor


def _is_quiet(speech: list[float], t: float) -> bool:
    """t 时刻是否「没人在说话」：最近一条字幕事件的估计持续期已经结束。

    只知道事件时间、不知道每句多长，于是按「持续到下一条事件或最多 3 秒」估计。
    台词密（事件间隔都不到 3 秒）的地方一律不算安静——宁可错过短停顿，也不切半句。
    """
    if not speech:
        return True
    i = bisect_right(speech, t) - 1
    if i < 0:
        return True
    prev = speech[i]
    nxt = speech[i + 1] if i + 1 < len(speech) else float("inf")
    return t - prev >= min(SPEECH_HOLD_S, nxt - prev)


def _silence_before(speech: list[float], t: float) -> float:
    """t 之前距最近一条字幕事件多久（没有字幕视为无穷大）。"""
    i = bisect_right(speech, t) - 1
    return t - speech[i] if i >= 0 else float("inf")


def _snap_start(
    index: ContainerIndex,
    times: list[float],
    speech: list[float],
    target: float,
    lo: float,
    hi: float,
) -> float:
    """把目标起点落到一个合适的关键帧上。

    优先级：附近的章节起点（场景开头，上下文最完整）→ 前后都没有台词的关键帧
    → 离上一句台词最远的关键帧 → 离目标最近的关键帧。
    """
    window_lo = max(lo, target - START_SEARCH_BACK_S)
    window_hi = min(hi, target + START_SEARCH_FWD_S)
    candidates = [t for t in times[bisect_left(times, window_lo) : bisect_right(times, window_hi)]]
    if not candidates:
        # 区间里一个关键帧都没有（关键帧极稀）：取目标之前最近的关键帧
        i = max(0, bisect_right(times, target) - 1)
        return times[i]

    chapters = [
        c
        for c, _ in index.chapters
        if target - CHAPTER_SNAP_S <= c <= target + START_SEARCH_FWD_S and lo <= c <= hi
    ]
    if chapters:
        chapter = min(chapters, key=lambda c: abs(c - target))
        # 章节起点通常正好在关键帧上；取不晚于章节起点的最后一个关键帧
        i = bisect_right(times, chapter + 0.05) - 1
        if i >= 0 and times[i] >= window_lo - CHAPTER_SNAP_S:
            return times[i]

    quiet = [t for t in candidates if _is_quiet(speech, t)]
    if not quiet and speech:
        # 目标附近台词太密：放宽到前后 25 秒再找一次停顿（窗口大半仍落在选中的那一段里）
        wide_lo = max(lo, target - START_SEARCH_WIDE_S)
        wide_hi = min(hi, target + START_SEARCH_WIDE_S)
        wide = times[bisect_left(times, wide_lo) : bisect_right(times, wide_hi)]
        quiet = [t for t in wide if _is_quiet(speech, t)]
    if quiet:
        return min(quiet, key=lambda t: abs(t - target))
    if speech:
        return max(candidates, key=lambda t: (_silence_before(speech, t), -abs(t - target)))
    return min(candidates, key=lambda t: abs(t - target))


def _choose_end(speech: list[float], start: float, duration: float) -> float:
    """在 [起点+30, 起点+60] 里找离 45 秒最近的安静时刻作终点。"""
    earliest = start + MIN_S
    latest = min(start + MAX_S, duration - 1.0)
    goal = min(start + TARGET_S, latest)
    if latest <= earliest:
        return max(start + 1.0, latest)
    if not speech:
        return goal
    steps = int((latest - earliest) / 0.5) + 1
    candidates = [earliest + i * 0.5 for i in range(steps)]
    quiet = [t for t in candidates if _is_quiet(speech, t)]
    if quiet:
        return min(quiet, key=lambda t: abs(t - goal))
    return max(candidates, key=lambda t: (_silence_before(speech, t), -abs(t - goal)))


def _prefetch_ranges(
    index: ContainerIndex, times: list[float], start: float
) -> tuple[ByteRange, ...]:
    """App 要预取的三段：文件头、索引、起点后约 4 秒。

    只有 Matroska / MP4：光盘的关键帧字节位置是拼出来的（各剪辑首尾相接），只能估码率，
    不是 App 取流地址上的位置；没有关键帧表的片源不知道起点在哪个字节。
    """
    if index.container not in INDEXED_CONTAINERS or not times:
        return ()
    ranges: list[ByteRange] = []
    head = min(index.head_end, HEAD_CAP_BYTES, index.file_size)
    if head > 0:
        ranges.append(ByteRange(0, head, "head"))
    if index.index_range is not None:
        begin, end = index.index_range
        ranges.append(ByteRange(begin, min(end - begin, INDEX_CAP_BYTES), "index"))

    i = max(0, bisect_right(times, start + 1e-3) - 1)
    begin = index.keyframes[i].offset
    if index.container == "mp4":
        # MP4 音视频按块交错，起点处的音频块可能排在视频关键帧前面：往前多带一点
        rate = _window_rate(index, times, max(0.0, start - 5.0), 10.0)
        begin = max(0, begin - int(min(2 << 20, rate)))
    # 第 4 秒落在哪两个关键帧之间，就按这两个关键帧的字节位置线性插值出它的位置。
    # 不能直接取「第 4 秒之后的下一个关键帧」：长 GOP 的片子（10 秒一个关键帧）
    # 会多带十几秒的数据（实测能到 64 MB 上限）。
    goal = start + PREFETCH_START_SECONDS
    j = bisect_left(times, goal)
    if 0 < j < len(times):
        k0, k1 = index.keyframes[j - 1], index.keyframes[j]
        span = k1.time_s - k0.time_s
        fraction = (goal - k0.time_s) / span if span > 0 else 1.0
        end_offset = k0.offset + int((k1.offset - k0.offset) * min(1.0, max(0.0, fraction)))
        length = end_offset - begin + PREFETCH_MARGIN_BYTES
    else:
        length = START_FALLBACK_BYTES
    if length <= PREFETCH_MARGIN_BYTES:
        length = START_FALLBACK_BYTES
    length = min(length, START_CAP_BYTES, index.file_size - begin)
    if length > 0:
        ranges.append(ByteRange(begin, length, "start"))
    return tuple(ranges)
