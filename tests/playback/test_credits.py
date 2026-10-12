"""用画面演职员表修正片尾（movieclaw_playback.credits）。

用合成的帧观测把本轮实片核对遇到的情况逐一固定下来：黑底演职员表（美剧 A）、
压在剧情上的演职员表（美剧 C）、片尾后的出品公司标志、演职员表中间的黑场
（美剧 D）、满屏名单最下一行落在下方居中（不是对白字幕）、角落水印
（访谈节目 A平台出品字样）、片尾后回到剧情（日本动画 A）、不是片尾的重复配乐
（韩剧 A）。
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest

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


def ad_frame(t: float, luma: float = 85) -> C.Frame:
    # 实片广告角标位于画面左上，含黑边时 y 可超过 0.16。
    return C.Frame(t, luma, [("广告", 0.14, 0.15, 0.20, 0.21), *credits_frame(t).lines])


def test_explicit_ad_label_overrides_many_lines_and_credit_words():
    frame = ad_frame(100, 6)
    assert not frame.credits
    assert not frame.strong
    assert not frame.neutral
    assert not C.Frame(100, 6, credits_frame(100).lines, corners=["广告"]).credits
    # 正文讨论“广告”、名单中的广告部门，都不是角标。
    assert C.Frame(100, 6, [("广告", 0.4, 0.4, 0.6, 0.5), *credits_frame(100).lines]).credits
    assert C.Frame(
        100, 6, [("广告制作", 0.14, 0.15, 0.20, 0.21), *credits_frame(100).lines]
    ).credits


@pytest.mark.parametrize("audio", [False, True])
def test_explicit_ad_cannot_become_an_outro(audio):
    decision, _ = run(lambda t: ad_frame(t, 6), (2800, 3000) if audio else None)
    assert decision.segment is None


@pytest.mark.parametrize("audio", [False, True])
def test_ad_after_credits_cannot_trigger_next_episode(audio):
    def timeline(t):
        if t >= 2992:
            return ad_frame(t, 6)
        return credits_frame(t) if t >= 2800 else story_frame(t)

    decision, _ = run(timeline, (2800, 3000) if audio else None)
    assert decision.segment is not None
    assert 2989 <= decision.segment[1] <= 2992
    assert decision.to_end is False


def test_ad_in_middle_cannot_be_bridged_by_later_credit_like_text():
    def timeline(t):
        if 2900 <= t < 2910:
            return ad_frame(t)
        return credits_frame(t)

    decision, _ = run(timeline, (2800, 3000))
    assert decision.segment is not None
    assert 2897 <= decision.segment[1] <= 2900
    assert decision.to_end is False


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


@pytest.mark.parametrize("accurate_missing", [False, True])
def test_credits_after_audio_outro_cannot_validate_it(accurate_missing) -> None:
    """长 GOP 落到区间之后的名单，不能证明区间内的重复配乐是片尾。"""
    calls = []

    async def observe(t, accurate):
        calls.append((t, accurate))
        if t >= 2948 or not accurate:
            return credits_frame(max(t, 2950))
        return None if accurate_missing else story_frame(t)

    decision = asyncio.run(C.refine_outro((2920, 2940), DURATION, observe))
    assert decision.segment is None
    assert (2922, True) in calls


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


@pytest.mark.parametrize("audio", [False, True])
@pytest.mark.parametrize("tail_seconds", [1, 2, 8])
def test_dialogue_after_credits_is_protected_even_near_eof(audio, tail_seconds) -> None:
    """最后八秒重回有对白剧情，接近 EOF 不能覆盖已看到的反证。"""
    boundary = DURATION - tail_seconds

    def timeline(t):
        if t < DURATION - 80 or t >= boundary:
            return story_frame(t, subtitle=True)
        return credits_frame(t)

    decision, _ = run(timeline, (DURATION - 80, DURATION) if audio else None)
    assert decision.segment is not None
    assert boundary - C.BISECT_PRECISION_S <= decision.segment[1] <= boundary
    assert decision.to_end is False


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


@pytest.mark.xfail(strict=True, reason="晚到的滚动姓名仍会被当对白；回查方案在实片中有回归")
def test_late_keyframe_does_not_replace_the_outro_start_context() -> None:
    """深夜食堂：晚到的滚动姓名不是片尾起点仍有对白的证据。"""
    outro = (2800.0, 2999.0)

    async def observe(t, accurate):
        if t < 2805:
            if accurate:
                return black_frame(t)
            return C.Frame(
                2810.0,
                20,
                [("田中圭", 0.58, 0.35, 0.77, 0.43), ("村川絵梨", 0.58, 0.92, 0.77, 1.0)],
            )
        return credits_frame(t)

    decision = asyncio.run(C.refine_outro(outro, DURATION, observe))
    assert decision.segment == outro


def test_no_credits_anywhere_gives_up_early() -> None:
    """片尾全是剧情：从结尾往前扫三帧就停，不把整个窗口都抽一遍。"""
    decision, calls = run(lambda t: story_frame(t))
    assert decision.segment is None
    assert len(calls) == 3


def run_lead(timeline, lead=2800.0, start=2865.0):
    calls: list[tuple[float, bool]] = []

    async def observe(t: float, accurate: bool) -> C.Frame:
        calls.append((t, accurate))
        return timeline(t)

    return asyncio.run(C.extend_lead(lead, start, observe)), calls


def test_dark_lead_before_audio_outro_is_joined() -> None:
    """铁拳教育：配音名单前的黑底韩文演职员表（识别不出字）是暗画面，整截接上。"""
    new, calls = run_lead(black_frame)
    assert new == 2800.5
    assert len(calls) <= 7


def test_lead_stops_at_story_and_bisects_the_boundary() -> None:
    """前段开头还是剧情的最后几个镜头：只接暗画面那部分，边界二分到约 3 秒。"""
    credits_start = 2830.0
    new, _ = run_lead(lambda t: credits_frame(t) if t >= credits_start else story_frame(t))
    assert credits_start <= new <= credits_start + C.BISECT_PRECISION_S


def test_bright_lead_is_not_joined() -> None:
    """圆桌派节目尾的资料书页：音频首尾相接、跨集重复，但是亮画面的正片，不接。"""
    new, calls = run_lead(lambda t: story_frame(t))
    assert new == 2865.0
    assert len(calls) == 1


def test_dark_scene_with_dialogue_subtitles_is_not_joined() -> None:
    """近黑的画面带对白字幕：还是剧情。"""
    new, _ = run_lead(lambda t: C.Frame(t, 6.0, [("你明天还来吗", 0.40, 0.88, 0.60, 0.93)]))
    assert new == 2865.0


def test_full_page_credits_brighter_than_near_black_are_joined() -> None:
    """黑暗荣耀：满屏白字名单平均亮度 10～12，不算近黑，但认得出是黑底演职员表。"""
    new, _ = run_lead(lambda t: C.Frame(t, 11.0, credits_frame(t).lines))
    assert new == 2800.5


def test_night_scene_darker_than_story_threshold_is_not_joined() -> None:
    """金粉世家 E37 片尾前的夜戏亮度 18～20：比一般剧情暗，但不是黑底，不接。"""
    new, _ = run_lead(lambda t: C.Frame(t, 19.0, []))
    assert new == 2865.0


def test_lead_keeps_story_before_the_first_confirmed_black_frame() -> None:
    async def observe(t: float, accurate: bool) -> C.Frame:
        actual = t + 0.04
        return story_frame(actual) if actual < 2800.3 else black_frame(actual)

    assert asyncio.run(C.extend_lead(2800, 2865, observe)) == 2800.54


def test_lead_boundary_probe_inside_audio_outro_cannot_extend_it() -> None:
    new, _ = run_lead(black_frame, lead=2864.8)
    assert new == 2865


def test_keyframes_landing_inside_audio_outro_are_not_evidence() -> None:
    """只解关键帧拿到的是请求点之后的帧：落进音频片尾里的不能算前段是暗画面。"""
    calls: list[tuple[float, bool]] = []

    async def observe(t: float, accurate: bool) -> C.Frame:
        calls.append((t, accurate))
        actual = t if accurate else 2866.0
        return credits_frame(actual) if actual >= 2865.0 else story_frame(actual)

    assert asyncio.run(C.extend_lead(2800.0, 2865.0, observe)) == 2865.0


def test_late_keyframes_cannot_bridge_story_after_a_black_opening() -> None:
    """长 GOP：前段起点黑场，中间是剧情；后移到片尾的关键帧不能证明中间可跳。"""

    async def observe(t: float, accurate: bool) -> C.Frame:
        if not accurate:
            return credits_frame(2866.0)
        return black_frame(t) if t < 2802 else story_frame(t)

    assert asyncio.run(C.extend_lead(2800.0, 2865.0, observe)) == 2865.0


def test_failed_lead_probe_does_not_cross_the_unknown_interval() -> None:
    new, _ = run_lead(lambda t: None if t < 2845 else black_frame(t))
    assert 2845 <= new < 2848


def test_first_lead_probe_failure_keeps_audio_start() -> None:
    new, _ = run_lead(lambda t: None)
    assert new == 2865.0


def run_credit_lead(timeline):
    async def observe(t, accurate):
        return timeline(t)

    return asyncio.run(C.extend_credits(2865.0, observe))


def test_credits_before_audio_start_do_not_need_repeated_music() -> None:
    new = run_credit_lead(lambda t: credits_frame(t) if t >= 2800 else story_frame(t))
    assert 2800 <= new <= 2803


def test_credit_lead_requires_two_strong_pages() -> None:
    assert run_credit_lead(lambda t: credits_frame(t) if t > 2855 else black_frame(t)) == 2865
    assert run_credit_lead(lambda t: credits_frame(t, keyword=False)) == 2865


def test_credit_lead_does_not_bridge_black_story_or_a_missing_frame() -> None:
    for gap in (black_frame, story_frame, lambda t: None):
        new = run_credit_lead(lambda t, gap=gap: gap(t) if 2820 <= t <= 2835 else credits_frame(t))
        assert 2835 < new <= 2838


def test_credit_lead_rejects_dark_dialogue_bright_credits_and_logos() -> None:
    for timeline in (
        black_frame,
        logo_frame,
        lambda t: C.Frame(t, 5, story_frame(t, subtitle=True).lines),
        lambda t: C.Frame(t, 90, credits_frame(t).lines),
    ):
        assert run_credit_lead(timeline) == 2865


def test_credit_lead_late_keyframes_cannot_count_as_distinct_evidence() -> None:
    async def observe(t, accurate):
        return story_frame(t) if accurate else credits_frame(2866)

    assert asyncio.run(C.extend_credits(2865, observe)) == 2865


@pytest.mark.parametrize("gap", ["logo", "missing", "dialogue", "story", "ad"])
def test_credit_run_extension_does_not_cross_negative_or_missing_evidence(gap):
    async def observe(t, accurate):
        if t < 2750:
            return story_frame(t)
        if 2810 <= t < 2825:
            return {
                "logo": logo_frame(t),
                "missing": None,
                "dialogue": C.Frame(t, 4, story_frame(t, subtitle=True).lines),
                "story": story_frame(t),
                "ad": ad_frame(t, 4),
            }[gap]
        return credits_frame(t)

    earlier = asyncio.run(C.extend_credits_past_logos(2865, 2995, 3000, observe))
    if gap == "logo":
        assert 2750 <= earlier <= 2753
    else:
        assert earlier > 2825


def test_credit_run_extension_cannot_change_a_verified_tail_boundary():
    async def observe(t, accurate):
        if t < 2750 or t > 2990:
            return story_frame(t, subtitle=True)
        return credits_frame(t)

    assert asyncio.run(C.extend_credits_past_logos(2865, 2990, 3000, observe)) == 2865


def test_credit_run_extension_ignores_changes_within_search_precision():
    async def observe(t, accurate):
        return credits_frame(t) if t >= 2864 else story_frame(t)

    assert asyncio.run(C.extend_credits_past_logos(2865, 3000, 3000, observe)) == 2865


def test_credit_run_extension_does_not_scan_when_start_precedes_search_window():
    async def observe(t, accurate):
        pytest.fail("扫描窗口不可能提供更早起点")

    assert asyncio.run(C.extend_credits_past_logos(2700, 3000, 3000, observe)) == 2700


def test_intro_music_continuing_into_story_is_trimmed_after_title_cards():
    async def observe(t, accurate):
        assert accurate or t in (390.71 - 12.5, 390.71 - 6.5)  # 只有初筛取关键帧
        return credits_frame(t) if t < 386 else story_frame(t)

    end = asyncio.run(C.trim_intro_end(316.78, 390.71, observe))
    assert 383 <= end < 386


def test_intro_end_without_two_dark_credit_observations_is_kept():
    for timeline in (
        story_frame,
        black_frame,
        lambda t: credits_frame(t) if 383 < t < 386 else story_frame(t),
        lambda t: C.Frame(t, 90, credits_frame(t).lines),
        lambda t: None,
    ):

        async def observe(t, accurate, timeline=timeline):
            return timeline(t)

        assert asyncio.run(C.trim_intro_end(316.78, 390.71, observe)) == 390.71


# NAS 真实关键帧初筛观测（2026-10-12，生产 FFmpeg + OCR 校正亮度）：
# (文件, 片头起点, 原终点, [(实际秒, 亮度)])。
# 前 9 集是线上确实收紧过片头终点（或夹具里需要收紧）的集，后 6 集是随机抽样里亮画面收尾的片头。
_INTRO_GATE_TITLE_CARDS = [
    (16280, 453.377, 526.9, [(516.04, 10.9), (522.64, 9.3)]),
    (16308, 316.782, 390.714, [(380.0, 15.9), (386.0, 37.0)]),
    (16317, 227.494, 301.302, [(290.0, 15.8), (296.0, 112.6)]),
    (20314, 109.722, 177.8, [(165.48, 12.6), (174.0, 66.6)]),
    (20316, 163.345, 229.8, [(219.52, 12.6), (223.6, 11.7)]),
    (20317, 163.592, 231.8, [(223.24, 11.7), (231.08, 110.0)]),
    (20318, 74.799, 143.5, [(135.0, 13.6), (144.0, 127.7)]),
    (20319, 172.385, 240.5, [(230.0, 12.6), (234.08, 11.7)]),
    (24224, 0.0, 86.8, [(79.04, 38.7), (85.12, 18.5)]),
]
_INTRO_GATE_BRIGHT = [
    (17334, 0.0, 98.329, [(86.68, 202.8), (92.68, 206.2)]),
    (14748, 0.0, 92.075, [(80.0, 77.8), (90.0, 33.2)]),
    (13462, 0.0, 53.932, [(42.54, 84.8), (47.55, 145.6)]),
    (13728, 0.124, 96.1, [(87.72, 174.6), (91.72, 215.4)]),
    (14013, 0.124, 45.078, [(33.36, 111.6), (40.64, 218.6)]),
    (17643, 0.0, 99.319, [(88.52, 35.4), (94.52, 39.2)]),
]


def _keyframe_replay(case):
    _, _, end, observed = case
    landed = dict(zip((end - 12.5, end - 6.5), observed, strict=True))
    requests = []

    async def observe(t, accurate):
        requests.append(accurate)
        if accurate:
            return story_frame(t)
        actual, luma = landed[t]
        return C.Frame(actual, luma, [])

    return observe, requests


@pytest.mark.parametrize("case", _INTRO_GATE_TITLE_CARDS, ids=lambda c: f"intro-gate-{c[0]}")
def test_real_title_card_intros_pass_keyframe_screen(case):
    observe, _ = _keyframe_replay(case)
    assert asyncio.run(C._dark_before_intro_end(case[1], case[2], observe))


@pytest.mark.parametrize("case", _INTRO_GATE_BRIGHT, ids=lambda c: f"intro-gate-{c[0]}")
def test_real_bright_intro_ends_skip_accurate_frames(case):
    observe, requests = _keyframe_replay(case)
    assert asyncio.run(C.trim_intro_end(case[1], case[2], observe)) == case[2]
    assert requests == [False, False]


def test_keyframe_screen_defers_when_no_keyframe_lands_inside_intro():
    """长 GOP：关键帧都落到片头终点之后（或取帧失败），初筛看不出来，必须交给精确帧。"""
    for landed in (lambda t: story_frame(400.0), lambda t: None):

        async def observe(t, accurate, landed=landed):
            assert not accurate
            return landed(t)

        assert asyncio.run(C._dark_before_intro_end(316.78, 390.71, observe))


@pytest.mark.parametrize(
    "case",
    json.loads(
        (
            Path(__file__).parent / "fixtures/skip_segments/nas-intro-credit-boundaries.json"
        ).read_text()
    ),
    ids=lambda c: f"intro-{c['id']}",
)
def test_real_intro_title_cards_end_before_the_first_story_frame(case):
    async def observe(t, accurate):
        if not accurate:
            return None  # 夹具没录关键帧：初筛看不出来，照常走精确帧判定
        for f in sorted(case["frames"], key=lambda f: abs(f["req"] - t)):
            if f["accurate"] and abs(f["t"] - t) <= 0.3:
                return C.Frame(f["t"], f["luma"], f["lines"])
        return None

    end = asyncio.run(C.trim_intro_end(case["start"], case["end"], observe))
    last_card, first_story = case["transition"]
    assert last_card - C.BISECT_PRECISION_S <= end < first_story
    assert end < case["end"]


@pytest.mark.parametrize(
    "case",
    json.loads(
        (Path(__file__).parent / "fixtures/skip_segments/nas-credit-leads.json").read_text()
    ),
    ids=lambda c: f"{c['title']}-{c['id']}",
)
def test_real_ocr_credit_leads_keep_visual_safety_bounds(case):
    """真实抽帧/OCR 观测回放；保护下界来自每秒画面核对，不是旧算法黄金输出。"""

    async def observe(t, accurate):
        frames = sorted(
            case["frames"],
            key=lambda f: (abs(f["req"] - t), f["accurate"] != accurate, abs(f["t"] - t)),
        )
        for f in frames:
            if (accurate and f["accurate"] and abs(f["t"] - t) <= 0.3) or (
                not accurate and abs(f["req"] - t) <= 1.5
            ):
                return C.Frame(f["t"], f["luma"], f["lines"])
        return None

    start = asyncio.run(C.extend_credits(case["start"], observe))
    assert case["safe_start"] <= start <= case["start"] - case["min_gain"]
