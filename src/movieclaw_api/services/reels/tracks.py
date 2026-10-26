"""刷片的音轨 / 字幕挑选。纯函数，输入是台账里的 ``audio_streams`` / ``subtitle_streams``。

编号口径与播放器一致：内封轨按**同类型里的序号**计（台账数组下标，即
``embedded:<k>`` 里的 k；App 的自研引擎按这个序号选轨）。

- **音轨**：沿用文件的默认音轨；默认音轨是 TrueHD 时，换成同语言的轻量音轨
  （AC3 / E-AC3 / AAC 等）。TrueHD 要在手机上软解，起播更慢，刷片要的是一滑就出画面。
- **字幕**：只挑中文字幕（语言码或标题认得出是中文的），简体优先；强制字幕、
  评论音轨字幕排在后面。没有中文字幕就不开——外挂字幕一期不接（见设计文档）。
  「强制」只在不是默认轨时才扣分：不少片源把整条正片字幕同时标了默认和强制（如
  《我的大叔》的「简体中文-ASS」），真正只翻标牌 / 外语段落的强制字幕不会标默认。
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

#: 手机上要软解、起播明显变慢的音频编码
_HEAVY_AUDIO = {"truehd", "mlp"}

_ZH_LANGS = {
    "chi",
    "zho",
    "zh",
    "chs",
    "cht",
    "cmn",
    "yue",
    "zh-cn",
    "zh-hans",
    "zh-tw",
    "zh-hant",
    "zh-hk",
    "zh-sg",
}
# i18n-ignore: tokens matched against track titles
_ZH_TITLE_MARKS = ("中", "简", "繁", "國", "国", "chs", "cht", "chinese", "mandarin", "cantonese")
# i18n-ignore: tokens matched against track titles
_SIMPLIFIED_MARKS = ("简", "chs", "hans", "zh-cn")
# i18n-ignore: tokens matched against track titles
_COMMENTARY_MARKS = ("评论", "評論", "commentary", "解说", "導演", "导演")


def _text(stream: dict[str, Any], key: str) -> str:
    value = stream.get(key)
    return str(value).strip().lower() if value else ""


def choose_audio(streams: Sequence[dict[str, Any]] | None) -> int | None:
    """选音轨，返回同类型序号；没有音轨返回 None。"""
    if not streams:
        return None
    default = next((i for i, s in enumerate(streams) if s.get("default")), 0)
    if _text(streams[default], "codec") not in _HEAVY_AUDIO:
        return default
    language = _text(streams[default], "language")
    for i, stream in enumerate(streams):
        if _text(stream, "language") == language and _text(stream, "codec") not in _HEAVY_AUDIO:
            return i
    return default


def is_chinese_subtitle(stream: dict[str, Any]) -> bool:
    if _text(stream, "language") in _ZH_LANGS:
        return True
    title = _text(stream, "title")
    return any(mark in title for mark in _ZH_TITLE_MARKS)


def _subtitle_rank(stream: dict[str, Any]) -> int:
    title = _text(stream, "title")
    language = _text(stream, "language")
    rank = 0
    if any(mark in title for mark in _SIMPLIFIED_MARKS) or language in ("chs", "zh-cn", "zh-hans"):
        rank += 2
    if stream.get("default"):
        rank += 1
    if stream.get("forced") and not stream.get("default"):
        rank -= 5
    if any(mark in title for mark in _COMMENTARY_MARKS):
        rank -= 10
    return rank


def choose_subtitle(streams: Sequence[dict[str, Any]] | None) -> int | None:
    """选中文内封字幕，返回同类型序号；没有中文字幕返回 None。"""
    if not streams:
        return None
    candidates = [i for i, s in enumerate(streams) if is_chinese_subtitle(s)]
    if not candidates:
        return None
    # 同分取靠前的那条（片源通常把主字幕排在前面）
    return max(candidates, key=lambda i: (_subtitle_rank(streams[i]), -i))
