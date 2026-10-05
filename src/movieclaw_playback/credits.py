"""用画面上的演职员表修正片尾（docs/design/skip-intro.md §2.12）。

音频比对只能说「这段声音每集都有」，三类问题它解决不了：

1. **片尾没认出来**：欧美剧的片尾配乐常常每集不同（美剧 A美剧 B），音频
   找不到重复段，欧美剧只有 46% 的集认出了片尾；
2. **片尾越界**：片尾曲放完又接一段剧情，音乐却延续着（日本动画 A E01 片尾后 11 秒
   是角色剧情），音频边界越过了演职员表；
3. **认错了**：每集都响的一段配乐不是片尾（韩剧 A E02/E03，用户确认是剧情）。

画面上的演职员表是直接证据。这里只放判定逻辑：调用方给一个 ``observe(t, accurate)``，
按需在某个时间点抽一帧、做文字识别，返回 ``Frame``；本模块决定在哪些时间点抽、
怎么判。抽帧很贵（NAS 上 4K 一帧解码 + 识别约 2 秒），所以按情况只抽几帧：

- **有音频片尾**：片尾里抽 3～5 帧确认有演职员表；终点前一帧已回到剧情就二分找演职员表
  结束的位置截短；片尾里一帧演职员表都没有、演职员表却出现在片尾之外，就否决这段；
- **没有音频片尾**：从结尾往前每 12 秒抽一帧，只认**黑底演职员表**（暗画面 + 演职员文字，
  至少两帧有职务关键词），起点再二分到约 3 秒精度。压在画面上的演职员表不认——
  美剧 C片尾彩蛋、日剧片尾曲期间都是演职员表压在剧情上，跳过就漏了剧情。

起点不按演职员表往后挪：片尾曲开头常有几秒没字的动画或空镜（日本动画 A），往后挪就
少跳了片尾曲；除非起点那一帧有对白字幕，才说明那里还是剧情。
"""

from __future__ import annotations

import re
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

#: 演职员表的职务关键词（中 / 英 / 日文汉字）。只要求出现在非角落区域的文字里。
#: 识别模型是 PP-OCR 中文模型，字表里没有韩文、几乎没有假名，写了也认不出来
CREDIT_KEYWORDS = re.compile(
    r"导演|導演|编剧|編劇|制片|製片|监制|監製|主演|领衔|領銜|摄影|攝影|美术|美術|剪辑|剪輯|"
    r"作曲|作词|作詞|演唱|配乐|配樂|策划|策劃|统筹|統籌|鸣谢|鳴謝|摄制|攝製|出演|主题曲|主題曲|"
    r"片尾曲|字幕|翻译|翻譯|"
    r"Directed|Director|Producer|Produced|Written|Writer|Executive|Casting|Music|Editor|Edited|"
    r"Photography|Starring|Created|Production|Designer|Supervisor|Associate|Consultant|Coordinator|"
    r"Cinematograph|Composer|Copyright|All Rights|Story by|Teleplay|Visual Effects|Costume|Makeup|"
    r"Stunt|"
    r"監督|脚本|原作|主題歌|製作|演出|撮影|編集|音楽",
    re.I,
)

#: 「暗画面」的平均亮度上限（0～255）：黑底演职员表实测 5～15，正常剧情画面 40 以上
DARK_LUMA = 28.0
#: 没有音频片尾时往前扫的步长与最远距离（秒）
SCAN_STEP_S = 12.0
SCAN_MAX_S = 300.0
#: 二分找边界的精度（秒）
BISECT_PRECISION_S = 3.0
#: 演职员表跑到离结尾多近算「到结尾」（结尾常跟几秒厂标）
TAIL_SLACK_S = 25.0
#: 音频片尾离结尾多近算「放到结尾」（与 skip_segments.TO_END_S 一致）
TO_END_SLACK_S = 5.0


@dataclass
class Frame:
    """一帧的观测：时间（文件秒）、平均亮度、文字行（归一化坐标 x0, y0, x1, y1）。

    ``corners``：四角放大识别出的字（找「广告」角标用，按需才算，None 表示没算过）。
    """

    t: float
    luma: float
    lines: list[tuple[str, float, float, float, float]] = field(default_factory=list)
    corners: list[str] | None = None

    def content(self) -> list[tuple[str, float, float, float, float]]:
        """去掉四角小字后的文字行：台标、水印、平台标识（访谈节目 A每帧都有平台出品字样）。"""
        out = []
        for line in self.lines:
            _, x0, y0, x1, y1 = line
            corner_x = x1 < 0.22 or x0 > 0.78
            corner_y = y1 < 0.16 or y0 > 0.86
            if not (corner_x and corner_y):
                out.append(line)
        return out

    @property
    def keyword(self) -> bool:
        return any(CREDIT_KEYWORDS.search(text) for text, *_ in self.content())

    @property
    def strong(self) -> bool:
        """确定是演职员表：有职务关键词，或满屏名单（6 行以上）。

        美剧 A的演员名单页只有人名、没有职务，12 秒抽一帧时带关键词的帧可能只有一帧。
        """
        return self.keyword or len(self.content()) >= 6

    @property
    def credits(self) -> bool:
        """有演职员表：职务关键词，或三行以上的字（滚动的人名列表常常一屏都是名字）。"""
        return self.keyword or len(self.content()) >= 3

    @property
    def subtitle(self) -> bool:
        """对白字幕：整帧只有一两行字，且在画面下方居中、不太宽，说明这里是剧情。

        满屏的演职员表最下面一行也常落在下方居中（美剧 A），按行数排除。
        """
        lines = self.content()
        if not lines or len(lines) > 2:
            return False
        return any(
            y0 > 0.78 and abs((x0 + x1) / 2 - 0.5) < 0.18 and x1 - x0 < 0.7
            for _, x0, y0, x1, _ in lines
        )

    @property
    def dark(self) -> bool:
        return self.luma < DARK_LUMA

    @property
    def dark_credits(self) -> bool:
        return self.dark and self.credits and not self.subtitle

    @property
    def neutral(self) -> bool:
        """暗画面上没有演职员表：纯黑过场，或出品公司标志、片尾卡（黑底上一两行字）。"""
        return self.dark and not self.credits

    @property
    def story(self) -> bool:
        """亮画面且不是黑底演职员表：剧情，或压在剧情画面上的演职员表（美剧 C片尾彩蛋）。"""
        return not self.dark


Observe = Callable[[float, bool], Awaitable[Frame | None]]


@dataclass
class OutroDecision:
    """修正结果：``segment`` 为 None 表示没有片尾（否决或没找到）；``reason`` 写进日志。"""

    segment: tuple[float, float] | None
    reason: str


async def refine_outro(
    outro: tuple[float, float] | None, duration: float, observe: Observe
) -> OutroDecision:
    """按画面修正一集的片尾。``observe(t, accurate)``：accurate 为假时可以取 t 附近的关键帧（快），
    为真时要精确到 t（要从关键帧解码过去，慢，只在二分边界时用）。取不到帧返回 None。"""
    if outro is None:
        return await _find_credits_on_black(duration, observe)
    return await _check_audio_outro(outro, duration, observe)


async def _find_credits_on_black(duration: float, observe: Observe) -> OutroDecision:
    seen: list[Frame] = []
    story_streak = 0
    t = duration - 2.0
    floor = max(duration * 0.6, duration - SCAN_MAX_S)
    while t >= floor:
        # 第一帧要精确：「取请求点之后的关键帧」在文件末尾可能已经没有关键帧了
        frame = await observe(t, t == duration - 2.0)
        if frame is not None:
            seen.append(frame)
            if frame.story:
                story_streak += 1
            elif frame.dark_credits:
                story_streak = 0
            found = any(f.dark_credits for f in seen)
            # 见过演职员表后连续两帧回到剧情，或从结尾起连续三帧都不是黑底演职员表：不用再往前扫
            if (found and story_streak >= 2) or (not found and story_streak >= 3):
                break
        t -= SCAN_STEP_S
    frames = sorted(seen, key=lambda f: f.t)
    run = _credits_run(frames)
    if run is None:
        return OutroDecision(None, "没有音频片尾，也没看到黑底演职员表")
    first, last = frames[run[0]], frames[run[1]]
    earlier = [f for f in frames if f.t < first.t]
    start = first.t
    if earlier:
        start = await _bisect(
            earlier[-1].t, first.t, observe, lambda f: f.dark_credits, find_first=True
        )
    tail = [f for f in frames if f.t > last.t]
    # 演职员表之后只剩黑场、出品公司标志：一直放到结尾
    to_end = duration - last.t <= TAIL_SLACK_S or (tail and all(f.neutral for f in tail))
    end = duration if to_end else last.t + BISECT_PRECISION_S
    return OutroDecision((start, end), "黑底演职员表")


def _credits_run(frames: list[Frame]) -> tuple[int, int] | None:
    """最长的一段黑底演职员表，至少两帧确定是演职员表（``Frame.strong``）。

    中间允许夹最多两帧中性画面（黑场过场、出品公司标志）：美剧 D的演职员表中间有
    黑场，按 12 秒抽帧会连着落进两帧。遇到亮画面（剧情）就断开。
    """
    best: tuple[int, int] | None = None
    i = 0
    while i < len(frames):
        if not frames[i].dark_credits:
            i += 1
            continue
        j, last, gap = i, i, 0
        while j + 1 < len(frames):
            j += 1
            if frames[j].dark_credits:
                last, gap = j, 0
            elif frames[j].neutral and gap < 2:
                gap += 1
            else:
                break
        span = frames[i : last + 1]
        if sum(f.strong for f in span) >= 2 and (best is None or last - i > best[1] - best[0]):
            best = (i, last)
        i = last + 1
    return best


async def _check_audio_outro(
    outro: tuple[float, float], duration: float, observe: Observe
) -> OutroDecision:
    start, end = outro
    length = end - start
    to_end = duration - end <= TO_END_SLACK_S
    probes: list[Frame] = []
    # 不到结尾的片尾要查终点处是不是已回到剧情：贴着终点前 0.5 秒取精确帧
    # （日本动画 A E01 演职员表最后一张卡后 1.5 秒就是剧情）
    last = (end - 2.0, False) if to_end else (end - 0.5, True)
    for t, accurate in ((start + 2.0, False), (start + length / 2, False), last):
        frame = await observe(t, accurate)
        if frame is not None:
            probes.append(frame)
    if not any(f.credits for f in probes):
        for t in (start + length / 4, start + length * 3 / 4):
            frame = await observe(t, False)
            if frame is not None:
                probes.append(frame)
    probes.sort(key=lambda f: f.t)
    credit_frames = [f for f in probes if f.credits and not f.subtitle]
    if not credit_frames:
        outside: list[Frame] = []
        t = end + 8.0
        while t < duration - 1.0 and len(outside) < 4:
            frame = await observe(t, False)
            if frame is not None:
                outside.append(frame)
            t += 15.0
        if any(f.credits and not f.subtitle for f in outside):
            return OutroDecision(None, "片尾里没有演职员表、演职员表在片尾之后：否决")
        if not probes:
            return OutroDecision(outro, "取不到画面，保持")
        return OutroDecision(outro, "没有画面证据，保持")
    new_start, new_end, notes = start, end, []
    first_probe = probes[0]
    if not first_probe.credits and first_probe.subtitle:
        # 起点处还有对白字幕：剧情没完，起点挪到演职员表出现处
        new_start = await _bisect(
            first_probe.t,
            credit_frames[0].t,
            observe,
            lambda f: f.credits and not f.subtitle,
            find_first=True,
        )
        notes.append(f"起点 {start:.0f}→{new_start:.0f}（有对白字幕）")
    last_probe = probes[-1]
    returned_to_story = last_probe.story and not last_probe.credits
    if not to_end and last_probe.t > credit_frames[-1].t and returned_to_story:
        # 终点前已回到剧情（不是演职员表、也不是纯黑）：截到演职员表结束处。
        # 只对不到结尾的片尾做：放到结尾的片尾最后几秒常是平台标识、版权卡，
        # 截掉会让客户端从「自动下一集」退成「跳过片尾」按钮
        last_credit = await _bisect(
            credit_frames[-1].t,
            last_probe.t,
            observe,
            lambda f: f.credits and not f.subtitle,
            find_first=False,
        )
        new_end = min(end, last_credit + 1.0)
        notes.append(f"终点 {end:.0f}→{new_end:.0f}（演职员表后回到剧情）")
    if new_end - new_start < 10.0:
        return OutroDecision(None, "修正后不足 10 秒：否决")
    return OutroDecision((new_start, new_end), "；".join(notes) or "演职员表确认")


async def _bisect(
    lo: float, hi: float, observe: Observe, inside: Callable[[Frame], bool], *, find_first: bool
) -> float:
    """在 (lo, hi) 之间二分边界，精度 ``BISECT_PRECISION_S``。

    find_first：lo 不满足、hi 满足，返回第一个满足的时间（起点）；否则 lo 满足、hi 不满足，
    返回最后一个满足的时间（终点）。取不到帧时保守收敛到已知满足的一侧。
    """
    good = hi if find_first else lo
    bad = lo if find_first else hi
    while abs(good - bad) > BISECT_PRECISION_S:
        mid = (good + bad) / 2
        frame = await observe(mid, True)
        if frame is not None and inside(frame):
            good = mid
        else:
            bad = mid
    return good
