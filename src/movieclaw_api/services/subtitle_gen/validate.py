"""译文机检：Netflix 简中规范的可机检部分（subtitle-ai-translate.md §3.3/§3.5）。

折行/标点/数字是规则活，不劳模型；CPS 超标率与术语一致性只统计入报告
（时长是参考字幕定的，翻译只能靠压缩表达，超标率是"浓缩力"的量化）。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from movieclaw_api.services.subtitle_gen.extract import SubEvent

LINE_LIMIT = 16  # Netflix 简中：每行 ≤16 字
CPS_LIMIT = 9.0  # 成人简中内容 ≤9 字/秒
_EAST_ASIAN_LANGUAGES = {"chs", "cht", "chi", "jpn", "kor"}
_CHINESE_LANGUAGES = {"chs", "cht", "chi"}

# 折行断点偏好：标点/空格之后断，读起来才不别扭
_BREAK_CHARS = " ，。！？…、；：,!?"
_FULLWIDTH_DIGITS = str.maketrans("０１２３４５６７８９", "0123456789")


def line_limit(language: str) -> int:
    """返回单行建议容量；拉丁/西里尔文字按播放器通行的较宽行长处理。"""
    return 18 if language in _EAST_ASIAN_LANGUAGES else 42


def reading_speed_limit(language: str) -> float:
    """不同书写体系不能共用简中的 9 字/秒阈值。"""
    if language in {"chs", "cht", "chi", "jpn"}:
        return 9.0
    if language == "kor":
        return 12.0
    return 17.0


def clean_punctuation(text: str, language: str = "chs") -> str:
    """简中字幕标点铁律的机械清理（§3.3）：

    - 句尾句号/逗号删除（含半角），省略号/问叹号保留；
    - 句中全角逗号/句号 → 空格（Netflix：停顿用空格）；
    - 全角数字 → 半角；禁 !?/?? 组合收敛为单个。
    """
    text = text.translate(_FULLWIDTH_DIGITS)
    if language not in _CHINESE_LANGUAGES:
        # 英语、法语等语言的逗号和句号承载语法，不能套用简中规则删除。
        return text.strip()
    text = re.sub(r"[！!？?]{2,}", lambda m: m.group(0)[0], text)
    text = re.sub(r"[，。,]+(?=\s|$)", "", text)  # 行尾（含折行前）
    text = re.sub(r"[，。](?=.)", " ", text)
    return re.sub(r" {2,}", " ", text).strip()


def _visible_len(text: str) -> int:
    return len(text.replace(" ", "").replace("\n", ""))


def fold_line(text: str, limit: int = LINE_LIMIT) -> str:
    """超过行长的单行文本折成至多两行（断点找标点/空格，找不到取中点）。

    两行仍超长不截断（宁超不丢，§3.4 铁律），由 CPS/超长统计呈现问题。
    """
    text = text.strip()
    if len(text) <= limit or "\n" in text:
        return text
    # 在 [limit//2, limit] 里找最靠右的断点字符；没有就硬切中点附近
    cut = -1
    for i in range(min(limit, len(text) - 1), max(limit // 2 - 1, 0), -1):
        if text[i - 1] in _BREAK_CHARS:
            cut = i
            break
    if cut <= 0:
        cut = min(limit, (len(text) + 1) // 2)
    first, rest = text[:cut].rstrip(), text[cut:].lstrip()
    if not rest:
        return first
    return f"{first}\n{rest}"


@dataclass
class QualityReport:
    """机检结论（任务报告呈现，§3.5）。"""

    event_count: int = 0
    cps_overrun: int = 0  # 译文超读速的事件数（双语只看第一行译文）
    secondary_cps_overrun: int = 0  # 双语第二行超读速的事件数，不归译文质量
    overlong: int = 0  # 折行后仍超两行容量（>32 字）的事件数
    kept_original: int = 0  # 翻译失败保留原文的事件数
    compressed: int = 0  # 超读速二次压缩成功的事件数（"浓缩优先"闭环）
    glossary_usage: dict[str, int] = field(default_factory=dict)  # 译名 → 出现次数

    @property
    def cps_overrun_rate(self) -> float:
        return self.cps_overrun / self.event_count if self.event_count else 0.0


def _reading_overrun(
    text: str,
    duration_s: float,
    language: str,
    fixed_limit: float | None = None,
) -> bool:
    limit = fixed_limit or reading_speed_limit(language)
    return _visible_len(text) / duration_s > limit


def _target_text(text: str, secondary_language: str | None) -> str:
    """译文部分：双语第一行是目标语言，第二行（通常是原文语言）不归翻译考核。"""
    if secondary_language is None:
        return text
    return (text.splitlines() or [""])[0]


def overrun_indices(
    events: list[SubEvent],
    limit: float | None = None,
    *,
    target_language: str = "chs",
    secondary_language: str | None = None,
) -> list[int]:
    """超读速事件的下标表（二次压缩的输入）。"""
    out: list[int] = []
    for i, (start, end, text) in enumerate(events):
        duration_s = max((end - start) / 1000, 0.001)
        if _reading_overrun(
            _target_text(text, secondary_language),
            duration_s,
            target_language,
            fixed_limit=limit,
        ):
            out.append(i)
    return out


def finalize_events(
    events: list[SubEvent],
    glossary: dict[str, str] | None = None,
    *,
    target_language: str = "chs",
    secondary_language: str | None = None,
) -> tuple[list[SubEvent], QualityReport]:
    """标点清理 + 折行 + 统计，产出可落盘事件与机检报告。"""
    report = QualityReport(event_count=len(events))
    out: list[SubEvent] = []
    for start, end, text in events:
        if secondary_language is not None:
            # 双语的换行表达语种顺序，不能再交给单语折行器重排。两行分别做
            # 标点清理，具体长度由提示词约束，机检只报告不截断。
            languages = (target_language, secondary_language)
            cleaned_lines = [
                clean_punctuation(line, language)
                for line, language in zip(text.splitlines(), languages, strict=False)
            ]
            cleaned = "\n".join(cleaned_lines)
        else:
            cleaned = fold_line(
                clean_punctuation(text, target_language),
                line_limit(target_language),
            )
        duration_s = max((end - start) / 1000, 0.001)
        if _reading_overrun(_target_text(cleaned, secondary_language), duration_s, target_language):
            report.cps_overrun += 1
        if secondary_language is not None:
            second_line = cleaned.splitlines()[1:2]
            if second_line and _reading_overrun(second_line[0], duration_s, secondary_language):
                report.secondary_cps_overrun += 1
        if secondary_language is None:
            overlong = _visible_len(cleaned) > line_limit(target_language) * 2
        else:
            overlong = any(
                _visible_len(line) > line_limit(language)
                for line, language in zip(
                    cleaned.splitlines(),
                    (target_language, secondary_language),
                    strict=False,
                )
            )
        if overlong:
            report.overlong += 1
        out.append((start, end, cleaned))
    for dst in (glossary or {}).values():
        if not dst:
            continue
        report.glossary_usage[dst] = sum(t.count(dst) for _, _, t in out)
    return out, report


_CJK = re.compile(r"[一-鿿]")


def looks_translated(text: str, target_language: str) -> bool:
    """漏翻检测（§3.5 机检）：目标是中文时，译文行必须含 CJK 字符。

    纯数字/纯标点/专有名词行放过（无 ASCII 字母才要求 CJK）。
    """
    if not target_language.startswith("ch") and target_language != "chi":
        return True  # 非中文目标 v1 不做语言判定
    if _CJK.search(text):
        return True
    return not re.search(r"[A-Za-z]{4,}", text)  # 长英文串且无中文 = 疑似漏翻
