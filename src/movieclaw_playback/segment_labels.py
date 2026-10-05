"""用画面文字给片段定类型：广告、下集预告（docs/design/skip-intro.md §2.13）。

音频重复只能说明「这段每集都有」，所以开头那些段一直叫「其他」（界面显示「跳过此段」），
片尾后面的预告也混在片尾里。画面上的字能给出类型：

- **广告**：国内平台的冠名广告都打「广告」角标（法规要求），半透明灰底小字，在四个角之一
  （平台标识在右下，华语剧 D的冠名广告在右上）。四角放大识别，见 ``OcrEngine.read_corners``。
  只对中文内容做：海外平台不打角标；
- **下集预告**：片尾之后还有一段、且画面上出现「下集预告」这类字，就单独标成预告。

另外一件事也靠「广告」角标：首个开头段在 15～30 秒之间才开始时，前面那段超出了「开播贴零」
的范围（下发只把 15 秒内的空隙贴到 0），华语剧 A华语剧 D前 17～20 秒的冠名广告就漏在
那里。抽三帧都看到角标，就把首段起点延伸到 0。
"""

from __future__ import annotations

import re
from collections.abc import Awaitable, Callable
from typing import Any

from movieclaw_playback.credits import Frame

#: 「广告」角标：两个字，「广」常被识别成「厂」或被框边截掉只剩「告」
_AD_LABEL = re.compile(r"^[广廣厂]?[告吿]$")
#: 预告的标题字样（中 / 英 / 日文汉字；识别模型读不了韩文）
_PREVIEW = re.compile(
    r"下集预告|下集預告|下期预告|下期預告|下集看点|下集精彩|NEXT\s*EPISODE|次回予告",
    re.I,
)

#: 首段起点在这个区间里才考虑往前延伸（秒）：15 秒内的空隙下发时已经贴到 0
EXTEND_FROM_S = 15.0
EXTEND_UNTIL_S = 30.0

ObserveCorners = Callable[[float], Awaitable[Frame | None]]
Observe = Callable[[float, bool], Awaitable[Frame | None]]


def has_ad_label(frame: Frame | None) -> bool:
    return bool(frame and frame.corners and any(_AD_LABEL.match(t.strip()) for t in frame.corners))


def has_preview_title(frame: Frame | None) -> bool:
    return bool(frame and any(_PREVIEW.search(text) for text, *_ in frame.lines))


async def label_head_ads(segments: list[dict[str, Any]], observe: ObserveCorners) -> list[str]:
    """把开头的「其他」段里有广告角标的改标成广告；首段起点在 15～30 秒、前面全是广告的延伸到 0。

    原地修改 ``segments``（毫秒单位的片段字典），返回说明（写日志）。
    """
    notes: list[str] = []
    heads = sorted((s for s in segments if s.get("type") != "outro"), key=lambda s: s["start_ms"])
    for seg in heads:
        if seg.get("type") != "other":
            continue
        start, end = seg["start_ms"] / 1000, seg["end_ms"] / 1000
        for t in (start + 0.3 * (end - start), start + 0.7 * (end - start)):
            if has_ad_label(await observe(t)):
                seg["type"] = "ad"
                notes.append(f"{start:.0f}–{end:.0f} 秒有广告角标，标成广告")
                break
    if heads and EXTEND_FROM_S < heads[0]["start_ms"] / 1000 <= EXTEND_UNTIL_S:
        gap = heads[0]["start_ms"] / 1000
        hits = 0
        for t in (1.0, gap / 2, gap - 1.5):
            hits += has_ad_label(await observe(t))
        if hits >= 2:
            heads[0]["start_ms"] = 0
            notes.append(f"开头 0–{gap:.0f} 秒是冠名广告，首段延伸到 0")
    return notes


async def find_preview(
    outro_end: float, duration: float, observe: Observe
) -> tuple[float, float] | None:
    """片尾之后（不到结尾的片尾）有没有「下集预告」：有就返回 (起点, 文件结尾)。"""
    remaining = duration - outro_end
    if remaining <= 5.0:
        return None
    for t in (outro_end + 2.0, outro_end + min(20.0, remaining / 2)):
        frame = await observe(t, False)
        if has_preview_title(frame):
            return (max(outro_end, frame.t - 1.0), duration)  # type: ignore[union-attr]
    return None
