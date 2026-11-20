"""服务端生成的 VOD 播放列表（docs/design/web-player.md §12）。

与旧方案（ffmpeg 边转边写 EVENT 播放列表）的根本区别：播放列表在开会话时
**一次性完整生成**——每个分片的边界与时长来自全片关键帧索引（keyframes.py），
带 ENDLIST，类型 VOD。收益：

- 播放器（hls.js / Safari 原生 HLS / AVPlayer）拿到的是「时长已知的点播」，
  不再被当成直播贴边播（那是 iPhone 周期闪黑屏与刷新进度漂移的根源）；
- seek 任意位置都在列表内，跳转由播放器直接请求对应分片，服务端按需转码，
  前端不再需要「seek 出已转区间就重开会话」的整套逻辑；
- 时间轴变成**文件绝对时间**：分片 N 的内容就是文件的第 boundaries[N] 秒起，
  start_ms 换算、关键帧校正从此消失。

分片边界必须与 ffmpeg hls muxer 的实际切分**逐一吻合**，而且无论 ffmpeg 从片头一路转、
还是 seek 后从第 N 段重启，切出来都要一样——AVPlayer（Safari 原生 HLS、Infuse 等 Jellyfin
客户端）完全按列表的时间轴放，分片内容错位就是画面与字幕错位；hls.js 虽按分片真实时间戳
自我校正，远跳也会反复取错段。

- **转码档**：``-force_key_frames`` 在 k × SEGMENT_SECONDS 上强插关键帧，边界就是等差数列
  （``compute_uniform_plan``），从哪重启都一样。
- **直通档**：只能切在源片已有的关键帧上，**每个关键帧切一段**（``compute_keyframe_plan``，
  ffmpeg 侧 ``-hls_time`` 给到极小）。曾经按「k × hls_time 的绝对栅格」预测 ffmpeg 的切分，
  实测对不上（2026-10-01，4K MKV 关键帧最长 10 秒）：hls muxer 的切分条件是
  ``关键帧 pts − 本次起点 ≥ hls_time × 已切段数``——关键帧一稀就每个关键帧都切、与「跳到
  下一个整数倍」的预测分叉；seek 重启后「本次起点」又换成重启点，栅格整体平移。缓存里 425 段
  有 380 段与列表错位（最多 71 秒）。每个关键帧切一段，与起点无关，连续转与重启转天然一致；
  代价是关键帧密的片子分片更多（片库抽样每分钟中位 12 → 15 段）。

ffmpeg 侧用 ``-start_number N`` 保证 seek 重启后文件名编号接上。
"""

from __future__ import annotations

import bisect
import math
from dataclasses import dataclass


@dataclass(frozen=True)
class SegmentPlan:
    """一个文件的完整分片规划。boundaries 是每个分片的起点（秒），首元素恒 0；
    分片 i 的区间是 [boundaries[i], boundaries[i+1])，末段止于 duration_s。"""

    boundaries: tuple[float, ...]
    duration_s: float

    @property
    def count(self) -> int:
        return len(self.boundaries)

    def duration_of(self, index: int) -> float:
        end = self.boundaries[index + 1] if index + 1 < self.count else self.duration_s
        return max(0.0, end - self.boundaries[index])

    def segment_for(self, position_s: float) -> int:
        """position_s 落在哪个分片里。越界钳到首/末段。"""
        if position_s <= 0:
            return 0
        return min(self.count - 1, bisect.bisect_right(self.boundaries, position_s) - 1)

    def start_offset(self, position_s: float) -> float:
        """写进 ``EXT-X-START`` 的起播位置：夹进 ``segment_for`` 那一段的内部。

        播放器按 EXTINF（6 位小数）逐段累加来找「起播点在哪一段」，累加误差会让
        正好压在分片边界上的位置（``?t=600`` 这种整秒、恰好又是关键帧）被算进
        **前一段**；服务端却从后一段起转——播放器要的那段在转码头后面，要熬完
        3 秒宽限期再重启一轮才供得出来（本机实测续播首帧 3.7 秒）。离两端各留
        2 毫秒，远大于累加误差，画面上看不出差别。
        """
        head = self.segment_for(position_s)
        low = self.boundaries[head] + _START_MARGIN_S
        high = self.boundaries[head] + self.duration_of(head) - _START_MARGIN_S
        return min(max(position_s, low), max(low, high))

    def seek_pad(self, index: int) -> float:
        """直通档从第 ``index`` 段重启 ffmpeg 时，``-ss`` 要比分片起点往后多给的秒数。

        ffmpeg 的 ``-ss`` 恰好等于关键帧时间时会退到前一个关键帧，所以要往后多给一点；
        但不能越过下一个关键帧（每个关键帧都是一段，相邻关键帧可能只隔一两帧），
        否则会落到下一段、整轮编号错一位。取两者较小：0.5 秒或到下一段距离的一半。
        """
        return min(_SEEK_PAD_S, self.duration_of(index) / 2)


#: EXT-X-START 离分片两端的余量（秒），见 ``SegmentPlan.start_offset``
_START_MARGIN_S = 0.002
#: 直通档 seek 重启时 ``-ss`` 往分片起点后多给的上限（秒），见 ``SegmentPlan.seek_pad``
_SEEK_PAD_S = 0.5
#: 片头这么多秒内的关键帧不单独成段：要么是索引在开头补出来的 0 点之后那个真正的首帧
#: （ffmpeg 不会在首个视频包上切），要么是首帧本身。真实的第二个关键帧紧挨着片头的情况几乎没有
_HEAD_MERGE_S = 0.5


def compute_keyframe_plan(
    keyframes_s: tuple[float, ...] | list[float], duration_s: float
) -> SegmentPlan:
    """直通档的分片规划：每个关键帧切一段（理由见模块文档）。

    与 ffmpeg 一侧（``-hls_time`` 极小）逐包吻合：hls muxer 不在首个视频包上切，之后每个
    关键帧都满足「pts − 起点 ≥ hls_time × 段数」。首段从 0 起；片头 ``_HEAD_MERGE_S`` 内的
    关键帧并进首段（见常量注释）；不合并片尾的短段——ffmpeg 不会合并，列表也不能。
    """
    boundaries: list[float] = [0.0]
    for time_s in sorted(keyframes_s):
        if time_s >= duration_s:
            break
        if time_s < _HEAD_MERGE_S or time_s <= boundaries[-1]:
            continue
        boundaries.append(time_s)
    return SegmentPlan(boundaries=tuple(boundaries), duration_s=duration_s)


def compute_uniform_plan(duration_s: float, *, target_s: float) -> SegmentPlan:
    """等长分片规划——给转码档用：视频经过重编码，``-force_key_frames
    expr:gte(t,n_forced*target)`` 在绝对栅格上强插关键帧，边界就是等差数列，
    不需要读源片的关键帧索引。"""
    count = max(1, math.ceil(duration_s / target_s))
    boundaries = tuple(i * target_s for i in range(count))
    return SegmentPlan(boundaries=boundaries, duration_s=duration_s)


def build_media_playlist(
    plan: SegmentPlan,
    *,
    init_name: str | None,
    segment_name: str,
    query: str = "",
    start_s: float | None = None,
    from_index: int = 0,
) -> str:
    """媒体播放列表（VOD）。``segment_name`` 是含 %05d 的文件名模板；
    ``query`` 形如 ``?token=xxx``，逐条附在 URI 上（HLS 客户端不继承查询串）。
    ``init_name=None`` 即 MPEG-TS 分片：自含 PAT/PMT，没有 init 段，不写 EXT-X-MAP。

    ``start_s``：起播位置（续播点，文件绝对时间）。大于 0 时写
    ``EXT-X-START``，让播放器**第一个请求就取起播点所在的分片**。不写的话
    AVPlayer 会先按 0 秒去取第 0 段、就绪后才 seek 过去：服务端的转码此时正从
    续播点起转，第 0 段的请求会把它拉回片头重启一轮、seek 过来再重启一轮
    （NAS 实测远程转码续播首片因此多等 5 秒）。hls.js 与 Safari 同样认这个标签。

    ``from_index``：从第几个分片开始列（默认 0 = 全片）。大于 0 时列表截断——
    ``MEDIA-SEQUENCE`` 跟着改成它、不再写 ``EXT-X-START``（列表头就是起播段，
    无处可指）。给「认不认 ``EXT-X-START`` 无法验证」的播放器用（鸿蒙系统播放
    器 histreamer 即如此）：``?from=start`` 让它第一个请求就落在起播段，不赌
    标签解析。分片 URI 的编号仍是全片绝对编号，缓存与 seek 重启的编号账不受
    影响；截断只是少列，分片按需转码（``ensure_segment``）照常兜住后续请求。
    """
    from_index = max(0, min(from_index, plan.count - 1))
    max_duration = max((plan.duration_of(i) for i in range(plan.count)), default=1.0)
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        f"#EXT-X-TARGETDURATION:{math.ceil(max_duration)}",
        f"#EXT-X-MEDIA-SEQUENCE:{from_index}",
        "#EXT-X-PLAYLIST-TYPE:VOD",
        "#EXT-X-INDEPENDENT-SEGMENTS",
    ]
    if from_index == 0 and start_s is not None and start_s > 0:
        lines.append(f"#EXT-X-START:TIME-OFFSET={plan.start_offset(start_s):.3f},PRECISE=YES")
    if init_name is not None:
        lines.append(f'#EXT-X-MAP:URI="{init_name}{query}"')
    for i in range(from_index, plan.count):
        lines.append(f"#EXTINF:{plan.duration_of(i):.6f},")
        lines.append(f"{segment_name % i}{query}")
    lines.append("#EXT-X-ENDLIST")
    return "\n".join(lines) + "\n"


def build_master_playlist(
    *,
    media_uri: str,
    subtitles: list[tuple[str, str]] | None = None,
    codecs: str | None = None,
    query: str = "",
) -> str:
    """master 播放列表：一路视频 + 可选的 WEBVTT 字幕组与编码声明。

    字幕做成 HLS 字幕组的意义：Safari 原生 HLS / AVPlayer 把它当**系统级
    字幕轨**渲染——画中画小窗、原生全屏里都有字幕，这是网页 DOM 字幕层
    做不到的（PiP 图层只含视频帧）。``subtitles`` 为 (名字, 字幕列表 URI)。
    ``codecs`` 只有调用方能准确知道输出 sample entry 时才传入；旧路径不应
    为未知的源流伪造 CODECS，避免 Safari 依据错误声明选择错误的解码器。
    """
    lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
    subtitle_attr = ""
    if subtitles:
        for index, (name, uri) in enumerate(subtitles):
            default = "YES" if index == 0 else "NO"
            lines.append(
                '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",'
                f'NAME="{name}",DEFAULT={default},AUTOSELECT=YES,'
                f'URI="{uri}{query}"'
            )
        subtitle_attr = ',SUBTITLES="subs"'
    # BANDWIDTH 是必填属性；直通档给不出真值，报一个宽松上限即可——
    # 单变体列表没有档位切换，这个数字不参与任何决策。CODECS 对 Safari
    # 原生 HLS 尤其重要：它会在初始化 fMP4 前先按该声明筛选解码路径。
    codecs_attr = f',CODECS="{codecs}"' if codecs else ""
    lines.append(
        f"#EXT-X-STREAM-INF:BANDWIDTH=80000000{codecs_attr}{subtitle_attr}"
    )
    lines.append(f"{media_uri}{query}")
    return "\n".join(lines) + "\n"


def build_subtitle_playlist(
    *,
    vtt_uri: str,
    duration_s: float,
    query: str = "",
) -> str:
    """字幕媒体列表：整片一个 VTT 分片。

    HLS 允许字幕分片任意长；文本字幕整片不过几百 KB，切片只会多几次请求。
    """
    target = max(1, math.ceil(duration_s))
    return "\n".join(
        [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            f"#EXT-X-TARGETDURATION:{target}",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            f"#EXTINF:{duration_s:.6f},",
            f"{vtt_uri}{query}",
            "#EXT-X-ENDLIST",
        ]
    ) + "\n"
