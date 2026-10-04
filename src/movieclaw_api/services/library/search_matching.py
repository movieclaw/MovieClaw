"""媒体库名称匹配内核：文字、拼音与首字母共用可解释的匹配档位。

检索文本完全由原始名称派生，不修改身份层；索引和首次构建的回退查询调用
同一套规则。混合输入逐字对齐，不枚举指数数量的「中文/全拼/首字母」组合。
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from functools import lru_cache

from opencc import OpenCC
from pypinyin import Style, pinyin

_converter = OpenCC("t2s")
_WORDS = re.compile(r"[^\W_]+", re.UNICODE)
_PARTS = re.compile(r"[a-z0-9]+|[^a-z0-9]+")


@lru_cache(maxsize=65536)
def normalized(text: str) -> str:
    """保留词边界的归一化文本；繁简只影响搜索，不改变展示原文。"""
    return _converter.convert(unicodedata.normalize("NFKC", text).casefold())


def compact(text: str) -> str:
    return "".join(ch for ch in normalized(text) if ch.isalnum())


@dataclass(frozen=True, slots=True)
class NameForms:
    """一个名称的派生形式及逐字读音；短生命周期缓存避免首次建索引时重复转换。"""

    text: str
    pinyin: str
    initials: str
    syllables: tuple[str, ...]
    words: tuple[str, ...]


@lru_cache(maxsize=65536)
def name_forms(raw: str) -> NameForms:
    text = compact(raw)
    syllables = tuple(
        part[0]
        for part in pinyin(
            text, style=Style.NORMAL, heteronym=False, errors=lambda value: list(value)
        )
    )
    words = tuple(_WORDS.findall(normalized(raw)))
    has_han = any("\u3400" <= ch <= "\u9fff" for ch in text)
    initials = "".join(part[:1] for part in syllables)
    if not has_han:
        initials = "".join(word[:1] for word in words) if len(words) > 1 else ""
    return NameForms(text, "".join(syllables), initials, syllables, words)


@dataclass(frozen=True, slots=True)
class NameMatch:
    """档位优先于长度等次要因素，避免简介或人物作品压过准确片名。"""

    tier: int
    kind: str
    start: int = 0
    end: int = 0


def _can_mix(query: str, text: str) -> bool:
    # 两个纯拉丁字母的混拼等价于全拼/首字母片段，无需逐字动态匹配。
    return (
        len(query) >= 2
        and (len(query) > 2 or not query.isascii())
        and re.search("[a-z]", query) is not None
        and any("\u3400" <= ch <= "\u9fff" for ch in text)
    )


def _mixed_match(query: str, forms: NameForms) -> tuple[int, int] | None:
    # 每个状态是已消费的输入长度，同一字只允许原文、全拼或首字母三种读法。
    # 输入可以落在末字全拼的前缀上；不能跳过标题中间的字。
    for start in range(len(forms.text)):
        states = {0}
        for end in range(start, len(forms.text)):
            options = {forms.text[end], forms.syllables[end], forms.syllables[end][:1]}
            next_states: set[int] = set()
            for consumed in states:
                remainder = query[consumed:]
                for option in options:
                    if remainder and option.startswith(remainder):
                        return start, end + 1
                    if query.startswith(option, consumed):
                        next_states.add(consumed + len(option))
            states = next_states
            if not states:
                break
    return None


def match_name(
    query: str, raw: str, derived: tuple[str, str, str] | None = None
) -> NameMatch | None:
    """索引内的名称直接复用派生字段；只有混输/词组需要读取逐字形式。"""
    needle = compact(query)
    if not needle:
        return None
    forms = None if derived is not None else name_forms(raw)
    text, full_pinyin, initials = derived or (forms.text, forms.pinyin, forms.initials)
    variants = [(text, "text", 0), (full_pinyin, "pinyin", 1)]
    if initials:
        variants.append((initials, "initials", 2))
    for value, kind, tier in variants:
        if needle == value:
            return NameMatch(tier, f"{kind}_exact", 0, len(text))
    for value, kind, tier in variants:
        if value.startswith(needle):
            return NameMatch(3 + tier, f"{kind}_prefix", 0, len(text))
    mixed = _mixed_match(needle, forms or name_forms(raw)) if _can_mix(needle, text) else None
    if mixed is not None:
        return NameMatch(5 if mixed[0] == 0 else 8, "mixed", *mixed)
    # 单字母只做准确/前缀查询；中文单字仍允许找片名中的实际文字。
    for value, kind, tier in variants:
        if (len(needle) >= 2 or not needle.isascii()) and needle in value:
            start = value.index(needle)
            return NameMatch(6 + tier, f"{kind}_contains", start, start + len(needle))
    words = _WORDS.findall(normalized(query))
    if len(words) > 1 and all(
        any(w.startswith(part) for w in (forms or name_forms(raw)).words) for part in words
    ):
        return NameMatch(9, "words", 0, len(text))
    return None


def _grams(value: str) -> set[str]:
    # 名称允许单字检索。所有词元编码成纯 ASCII，用户文字不会变成 FTS 操作符。
    return {"g" + part.encode().hex() for part in value} | {
        "g" + value[i : i + 2].encode().hex() for i in range(len(value) - 1)
    }


def name_tokens(names: list[str]) -> str:
    tokens: set[str] = set()
    for raw in names:
        forms = name_forms(raw)
        for value in (forms.text, forms.pinyin, forms.initials):
            tokens.update(_grams(value))
    return " ".join(sorted(tokens))


def query_tokens(query: str) -> str:
    """只召回候选，最终必须在同一名称上核验，防止跨别名拼出假命中。"""
    tokens: set[str] = set()
    for word in _WORDS.findall(normalized(query)):
        for part in _PARTS.findall(word):
            if len(part) == 1:
                tokens.add("g" + part.encode().hex())
            else:
                tokens.update("g" + part[i : i + 2].encode().hex() for i in range(len(part) - 1))
    return " AND ".join(sorted(tokens))
