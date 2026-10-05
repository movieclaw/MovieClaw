"""用画面演职员表修正片尾（movieclaw_playback.credits）。

用合成的帧观测把本轮实片核对遇到的情况逐一固定下来：黑底演职员表（美剧 A）、
压在剧情上的演职员表（美剧 C）、片尾后的出品公司标志、演职员表中间的黑场
（美剧 D）、满屏名单最下一行落在下方居中（不是对白字幕）、角落水印
（访谈节目 A平台出品字样）、片尾后回到剧情（日本动画 A）、不是片尾的重复配乐
（韩剧 A）。
"""

from __future__ import annotations

import asyncio

from movieclaw_playback import credits as C

DURATION = 3000.0


def credits_frame(t: float, keyword: bool = True) -> C.Frame:
    """黑底演职员表：暗画面，中间几列人名，可选一行职务。"""
    lines = [("JOHN SMITH", 0.40, 0.30, 0.60, 0.34), ("JANE DOE", 0.40, 0.40, 0.60, 0.44)]
    lines.append(("Executive Producer" if keyword else "MARY ROE", 0.38, 0.50, 0.62, 0.54))
    return C.Frame(t, 6.0, lines)


def story_frame(t: float, subtitle: bool = False) -> C.Frame:
    lines = [("你明天还来吗", 0.40, 0.88, 0.60, 0.93)] if subtitle else []
    return C.Frame(t, 85.0, lines)


def logo_frame(t: float) -> C.Frame:
    return C.Frame(t, 4.0, [("TELEVISION 360", 0.40, 0.45, 0.60, 0.50)])


def black_frame(t: float) -> C.Frame:
    return C.Frame(t, 1.0, [])


def run(timeline, outro=None, duration=DURATION):
    """timeline(t) → Frame；返回修正结果和抽帧次数。"""
    calls: list[tuple[float, bool]] = []

    async def observe(t: float, accurate: bool) -> C.Frame:
        calls.append((t, accurate))
        return timeline(t)

    decision = asyncio.run(C.refine_outro(outro, duration, observe))
    return decision, calls


def test_credits_on_black_become_the_outro_without_audio() -> None:
    """美剧 A：片尾配乐每集不同，音频找不到；最后 78 秒是黑底演职员表。"""

    def timeline(t: float) -> C.Frame:
        if t < DURATION - 78:
            return story_frame(t)
        if t > DURATION - 8:
            return logo_frame(t)
        return credits_frame(t)

    decision, calls = run(timeline)
    assert decision.segment is not None
    start, end = decision.segment
    assert abs(start - (DURATION - 78)) <= C.BISECT_PRECISION_S
    assert end == DURATION
    assert len(calls) <= 15


def test_credits_over_story_are_not_skippable() -> None:
    """美剧 C：演职员表压在片尾彩蛋的剧情画面上，跳过就漏了剧情。"""

    def timeline(t: float) -> C.Frame:
        frame = credits_frame(t)
        return C.Frame(t, 90.0, frame.lines) if t > DURATION - 60 else story_frame(t)

    decision, _ = run(timeline)
    assert decision.segment is None


def test_black_interstitials_inside_credits_do_not_split_the_run() -> None:
    """美剧 D：演职员表中间有黑场，12 秒抽一帧会连着落进两帧黑场。"""

    def timeline(t: float) -> C.Frame:
        back = DURATION - t
        if back > 90:
            return story_frame(t)
        if 50 < back < 75:
            return black_frame(t)
        return credits_frame(t)

    decision, _ = run(timeline)
    assert decision.segment is not None
    assert abs(decision.segment[0] - (DURATION - 90)) <= C.BISECT_PRECISION_S


def name_page(t: float) -> C.Frame:
    """只有人名、没有职务的满屏名单页（美剧 A演员表）。"""
    lines = [(f"ACTOR {i}", 0.42, 0.10 + 0.08 * i, 0.58, 0.14 + 0.08 * i) for i in range(8)]
    return C.Frame(t, 3.0, lines)


def test_name_only_pages_count_as_credits() -> None:
    """12 秒抽一帧时，带职务关键词的帧可能只有一帧；满屏名单页同样算确定的演职员表。"""

    def timeline(t: float) -> C.Frame:
        back = DURATION - t
        if back > 80:
            return story_frame(t)
        if 40 < back < 52:
            return credits_frame(t)
        return name_page(t)

    decision, _ = run(timeline)
    assert decision.segment is not None
    assert abs(decision.segment[0] - (DURATION - 80)) <= C.BISECT_PRECISION_S


def test_dense_credit_page_is_not_mistaken_for_a_subtitle() -> None:
    """满屏名单的最下一行常落在画面下方居中，不能当成对白字幕。"""
    lines = [(f"NAME {i}", 0.42, 0.10 + 0.08 * i, 0.58, 0.14 + 0.08 * i) for i in range(10)]
    frame = C.Frame(0, 6.0, lines)
    assert not frame.subtitle
    assert frame.dark_credits
    assert story_frame(0, subtitle=True).subtitle


def test_corner_watermarks_are_ignored() -> None:
    """访谈节目 A每帧角落都有平台出品字样：不算演职员表。"""
    frame = C.Frame(0, 70.0, [("某平台出品 制片人", 0.82, 0.03, 0.97, 0.07)])
    assert not frame.credits


def test_audio_outro_without_credits_is_rejected_when_credits_come_later() -> None:
    """韩剧 A E02：每集都响的配乐被当成片尾，里面没有演职员表；真演职员表在最后。"""
    outro = (DURATION - 67, DURATION - 45)

    def timeline(t: float) -> C.Frame:
        return credits_frame(t) if t > DURATION - 30 else story_frame(t, subtitle=True)

    decision, _ = run(timeline, outro)
    assert decision.segment is None


def test_audio_outro_without_any_visual_evidence_is_kept() -> None:
    outro = (DURATION - 150, DURATION)
    decision, _ = run(lambda t: story_frame(t), outro)
    assert decision.segment == outro


def test_outro_followed_by_story_is_trimmed_to_the_credits() -> None:
    """日本动画 A E01：片尾曲放完回到剧情，音乐延续，音频终点越过演职员表 11 秒。"""
    credits_end = DURATION - 120
    outro = (DURATION - 180, credits_end + 11)

    def timeline(t: float) -> C.Frame:
        return credits_frame(t) if DURATION - 180 <= t <= credits_end else story_frame(t)

    decision, _ = run(timeline, outro)
    assert decision.segment is not None
    assert decision.segment[0] == outro[0]
    assert credits_end - C.BISECT_PRECISION_S <= decision.segment[1] <= credits_end + 1.5


def test_outro_running_to_the_end_is_not_trimmed_by_a_closing_card() -> None:
    """放到结尾的片尾最后几秒是平台标识：不截，客户端照样自动下一集。"""
    outro = (DURATION - 150, DURATION - 1)

    def timeline(t: float) -> C.Frame:
        return story_frame(t) if t > DURATION - 10 else credits_frame(t)

    decision, _ = run(timeline, outro)
    assert decision.segment == outro


def test_start_moves_only_when_dialogue_is_still_on_screen() -> None:
    """起点处还有对白字幕才往后挪；片尾曲开头几秒没字的动画不挪（日本动画 A片尾曲）。"""
    credits_start = DURATION - 140
    outro = (DURATION - 150, DURATION)

    def with_dialogue(t: float) -> C.Frame:
        return credits_frame(t) if t >= credits_start else story_frame(t, subtitle=True)

    decision, _ = run(with_dialogue, outro)
    assert decision.segment is not None
    assert abs(decision.segment[0] - credits_start) <= C.BISECT_PRECISION_S

    def silent_animation(t: float) -> C.Frame:
        return credits_frame(t) if t >= credits_start else story_frame(t)

    decision, _ = run(silent_animation, outro)
    assert decision.segment == outro


def test_no_credits_anywhere_gives_up_early() -> None:
    """片尾全是剧情：从结尾往前扫三帧就停，不把整个窗口都抽一遍。"""
    decision, calls = run(lambda t: story_frame(t))
    assert decision.segment is None
    assert len(calls) == 3
