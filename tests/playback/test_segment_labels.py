"""用画面文字给片段定类型（movieclaw_playback.segment_labels）：广告角标、下集预告。"""

from __future__ import annotations

import asyncio

from movieclaw_playback import segment_labels as L
from movieclaw_playback.credits import Frame


def corners(t: float, texts: list[str]) -> Frame:
    return Frame(t, 80.0, [], texts)


def test_ad_label_variants() -> None:
    """「广」常被识别成「厂」或被框边截掉只剩「告」；角落里的其他字不算。"""
    for text in ("广告", "告", "厂告", "廣告"):
        assert L.has_ad_label(corners(0, [text]))
    assert not L.has_ad_label(corners(0, ["某平台首播"]))
    assert not L.has_ad_label(corners(0, ["广告主题曲"]))
    assert not L.has_ad_label(Frame(0, 80.0, []))  # 没算过四角


def run_labels(segments, frame_at):
    async def observe(t: float):
        return frame_at(t)

    return asyncio.run(L.label_head_ads(segments, observe))


def test_other_segment_with_ad_label_becomes_ad() -> None:
    segments = [
        {"type": "other", "start_ms": 4_600, "end_ms": 17_300},
        {"type": "intro", "start_ms": 354_700, "end_ms": 457_600},
        {"type": "outro", "start_ms": 2_893_000, "end_ms": 3_041_000},
    ]
    notes = run_labels(segments, lambda t: corners(t, ["广告"] if t < 20 else []))
    assert [s["type"] for s in segments] == ["ad", "intro", "outro"]
    assert notes


def test_unsnapped_sponsor_gap_extends_first_segment() -> None:
    """华语剧 A E05：首段 17.2 秒才开始，前面是冠名广告（超出下发贴零的 15 秒）。"""
    segments = [{"type": "intro", "start_ms": 17_200, "end_ms": 102_800}]
    run_labels(segments, lambda t: corners(t, ["告"] if t < 17 else []))
    assert segments[0]["start_ms"] == 0

    once = [{"type": "intro", "start_ms": 17_200, "end_ms": 102_800}]
    run_labels(once, lambda t: corners(t, ["广告"] if t < 2 else []))
    assert once[0]["start_ms"] == 17_200  # 三帧只有一帧有角标：不延伸


def test_preview_after_outro() -> None:
    def frame_at(t: float, accurate: bool) -> Frame:
        lines = [("下集预告", 0.4, 0.4, 0.6, 0.5)] if t >= 2_899 else []
        return Frame(t, 80.0, lines)

    async def observe(t: float, accurate: bool):
        return frame_at(t, accurate)

    assert asyncio.run(L.find_preview(2_898.0, 2_960.0, observe)) == (2_899.0, 2_960.0)
    assert asyncio.run(L.find_preview(2_958.0, 2_960.0, observe)) is None  # 片尾放到结尾

    async def nothing(t: float, accurate: bool):
        return Frame(t, 80.0, [])

    assert asyncio.run(L.find_preview(2_898.0, 2_960.0, nothing)) is None
