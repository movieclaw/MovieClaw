"""智能订阅的记忆：看得懂的语言与按作品事实分范围的画质习惯（纯函数）。

设计见 docs/design/smart-subscription-memory.md。智能订阅只有一套规则，默认值来自
类型设置（SmartProfile），再按订阅那一刻就知道的作品事实叠加记忆：

- 原始语言 → 字幕：看不懂的语言，资源的字幕或音轨里要有一种看得懂的语言；
- 电影/剧集、地区、播出平台 → 画质（分辨率、片源）；
- 系列 → 沿用同系列上一部单独改过的画质。

同一项被多层设置时按固定顺序取：这部单独设的 > 系列上一部 > 平台 > 地区 > 电影或剧集
> 默认。每条习惯只存改过的那一项，所以大多数时候不会冲突。所有展示文案在这里生成，
各客户端只负责显示，保证 Web、iOS、Android 说的是同一句话。
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from movieclaw_matcher.smart import SmartPolicy, SmartPreferences

Resolution = Literal["1080p", "2160p"]
Source = Literal["web-dl", "blu-ray", "remux"]
Scope = Literal["kind", "region", "network"]

# 中文默认看得懂，不能移除：订阅的主语言就是中文
DEFAULT_UNDERSTOOD = "zh"

LANGUAGE_LABELS: dict[str, str] = {
    "zh": "中文",
    "yue": "粤语",
    "en": "英语",
    "ja": "日语",
    "ko": "韩语",
    "fr": "法语",
    "de": "德语",
    "es": "西班牙语",
    "it": "意大利语",
    "ru": "俄语",
    "pt": "葡萄牙语",
    "hi": "印地语",
    "th": "泰语",
    "sv": "瑞典语",
    "da": "丹麦语",
    "no": "挪威语",
    "nl": "荷兰语",
    "pl": "波兰语",
    "tr": "土耳其语",
}

# 设置页「添加语言」可选的语言，顺序即展示顺序
COMMON_LANGUAGES: tuple[str, ...] = ("en", "yue", "ja", "ko", "fr", "de", "es", "th")

_COUNTRY_NAMES: dict[str, str] = {
    "CN": "中国大陆",
    "HK": "香港",
    "TW": "台湾",
    "SG": "新加坡",
    "JP": "日本",
    "KR": "韩国",
    "US": "美国",
    "GB": "英国",
    "FR": "法国",
    "DE": "德国",
    "IT": "意大利",
    "ES": "西班牙",
    "CA": "加拿大",
    "AU": "澳大利亚",
    "NZ": "新西兰",
    "IE": "爱尔兰",
    "IN": "印度",
    "TH": "泰国",
    "RU": "俄罗斯",
}

_RESOLUTION_LABELS = {"2160p": "4K", "1080p": "1080p"}
_SOURCE_LABELS = {"web-dl": "WEB-DL", "blu-ray": "蓝光", "remux": "Remux"}


def language_key(tmdb_code: str | None) -> str | None:
    """TMDB original_language → 记忆用的语言键。TMDB 把粤语记作 cn。未知返回 None。"""
    if not tmdb_code:
        return None
    code = tmdb_code.strip().casefold()
    if code in {"", "xx", "zxx", "und"}:
        return None
    return "yue" if code == "cn" else code


def language_label(key: str) -> str:
    return LANGUAGE_LABELS.get(key, key)


def subtitle_codes(key: str) -> tuple[str, ...]:
    """语言键 → 资源字幕声明里对应的 BCP 47 前缀。"""
    return (key,)


def audio_codes(key: str) -> tuple[str, ...]:
    """语言键 → 资源音轨声明里对应的码。国语配音在解析器里记作 cmn。"""
    return ("cmn", "zh") if key == "zh" else (key,)


def country_label(code: str) -> str:
    return _COUNTRY_NAMES.get(code, code)


def quality_label(resolution: str, source: str) -> str:
    return f"{_RESOLUTION_LABELS.get(resolution, resolution)} {_SOURCE_LABELS.get(source, source)}"


class LanguageAnswer(BaseModel):
    model_config = ConfigDict(extra="forbid")

    key: str = Field(min_length=1, max_length=16)
    understood: bool
    source_title: str | None = None
    at: datetime | None = None


class QualityHabit(BaseModel):
    model_config = ConfigDict(extra="forbid")

    scope: Scope
    value: str = Field(min_length=1, max_length=120)
    kind: Literal["movie", "tv"]
    resolution: Resolution | None = None
    source: Source | None = None
    source_title: str | None = None
    at: datetime | None = None

    @property
    def key(self) -> str:
        return habit_key(self.scope, self.value, self.kind)

    @property
    def label(self) -> str:
        return scope_label(self.scope, self.value, self.kind)


def habit_key(scope: str, value: str, kind: str) -> str:
    return f"{scope}:{kind}:{value}"


def scope_label(scope: str, value: str, kind: str) -> str:
    noun = "剧" if kind == "tv" else "电影"
    if scope == "kind":
        return "所有剧集" if kind == "tv" else "所有电影"
    if scope == "region":
        return f"{country_label(value)}的{noun}"
    return f"{value} 的{noun}"


class SmartMemory(BaseModel):
    model_config = ConfigDict(extra="forbid")

    revision: int = 0
    languages: list[LanguageAnswer] = Field(default_factory=list)
    habits: list[QualityHabit] = Field(default_factory=list)

    def understood(self) -> tuple[str, ...]:
        extra = sorted(
            {a.key for a in self.languages if a.understood and a.key != DEFAULT_UNDERSTOOD}
        )
        return (DEFAULT_UNDERSTOOD, *extra)

    def answered(self, key: str) -> bool:
        return key == DEFAULT_UNDERSTOOD or any(a.key == key for a in self.languages)

    def with_language(
        self, key: str, understood: bool, *, source_title: str | None, at: datetime
    ) -> SmartMemory:
        rest = [a for a in self.languages if a.key != key]
        answer = LanguageAnswer(key=key, understood=understood, source_title=source_title, at=at)
        return self.model_copy(update={"languages": [*rest, answer]})

    def with_habit(self, habit: QualityHabit) -> SmartMemory:
        rest = [h for h in self.habits if h.key != habit.key]
        return self.model_copy(update={"habits": [*rest, habit]})

    def without_habit(self, key: str) -> SmartMemory:
        return self.model_copy(update={"habits": [h for h in self.habits if h.key != key]})


class SmartFacts(BaseModel):
    """订阅那一刻就知道的作品事实。"""

    model_config = ConfigDict(extra="forbid")

    kind: Literal["movie", "tv"]
    title: str
    language: str | None = None
    region: str | None = None
    network: str | None = None
    series_key: str | None = None


class QualityOverride(BaseModel):
    """这部单独设的画质（只这部），或从同系列上一部沿用来的画质。"""

    model_config = ConfigDict(extra="forbid")

    resolution: Resolution | None = None
    source: Source | None = None
    origin: Literal["only", "series"] = "only"
    series_title: str | None = None


class ScopeOption(BaseModel):
    value: str
    label: str


class LanguageQuestion(BaseModel):
    language: str
    prompt: str
    subtitles_label: str
    understood_label: str


class Resolved(BaseModel):
    """解析结果：可直接冻结成策略的取值，加上给客户端显示的整句文案。"""

    resolution: Resolution
    source: Source
    watchable_languages: tuple[str, ...] = ()
    quality_label: str
    quality_note: str | None = None
    quality_shadow: str | None = None
    subtitle_language: str | None = None
    subtitle_line: str | None = None
    question: LanguageQuestion | None = None
    scope_options: list[ScopeOption] = Field(default_factory=list)

    def policy(self, prefs: SmartPreferences, *, kind: str, profile_revision: int) -> SmartPolicy:
        return SmartPolicy(
            **{**prefs.model_dump(), "resolution": self.resolution, "source": self.source},
            kind=kind,
            profile_revision=profile_revision,
            watchable_languages=self.watchable_languages,
        )


def acceptable_text(understood: tuple[str, ...]) -> str:
    return "或".join(language_label(k) for k in understood)


def facts_scopes(facts: SmartFacts) -> list[tuple[Scope, str]]:
    """作品命中的习惯范围，从具体到宽泛：平台、地区、电影或剧集。"""
    scopes: list[tuple[Scope, str]] = []
    if facts.kind == "tv" and facts.network:
        scopes.append(("network", facts.network))
    if facts.region:
        scopes.append(("region", facts.region))
    scopes.append(("kind", facts.kind))
    return scopes


def resolve(
    prefs: SmartPreferences,
    facts: SmartFacts,
    memory: SmartMemory,
    *,
    override: QualityOverride | None = None,
    series: QualityOverride | None = None,
) -> Resolved:
    habits = {h.key: h for h in memory.habits}
    layers: list[tuple[str, QualityOverride | QualityHabit]] = []
    if override and (override.resolution or override.source):
        note = (
            f"按《{override.series_title}》的设置"
            if override.origin == "series" and override.series_title
            else "这部单独设置"
        )
        layers.append((note, override))
    if series and (series.resolution or series.source):
        layers.append((f"按《{series.series_title}》的设置", series))
    for scope, value in facts_scopes(facts):
        habit = habits.get(habit_key(scope, value, facts.kind))
        if habit and (habit.resolution or habit.source):
            layers.append((f"按「{habit.label}」的习惯", habit))

    picked: dict[str, str] = {}
    origin: dict[str, str] = {}
    shadow: str | None = None
    for note, layer in layers:
        for field in ("resolution", "source"):
            value = getattr(layer, field)
            if value is None:
                continue
            if field not in picked:
                picked[field], origin[field] = value, note
            elif value != picked[field] and shadow is None and isinstance(layer, QualityHabit):
                shadow = f"「{layer.label}」是 {_value_label(field, value)}"
    resolution = picked.get("resolution", prefs.resolution)
    source = picked.get("source", prefs.source)
    notes = list(dict.fromkeys(origin[f] for f in ("resolution", "source") if f in origin))

    language = facts.language
    understood = memory.understood()
    watchable: tuple[str, ...] = ()
    line = question = None
    if language is not None:
        label = language_label(language)
        if language in understood:
            if language != DEFAULT_UNDERSTOOD:
                line = f"{label} · 不需要字幕"
        else:
            watchable = understood
            acceptable = acceptable_text(understood)
            line = f"{label} · 只下带{acceptable}字幕的"
            if not memory.answered(language):
                question = LanguageQuestion(
                    language=language,
                    prompt=f"这是{label}片，要{acceptable}字幕吗？",
                    subtitles_label=f"要，只下带{acceptable}字幕的",
                    understood_label=f"不用，我看得懂{label}",
                )

    options = [ScopeOption(value="only", label="只这部")]
    options += [
        ScopeOption(
            value=habit_key(scope, value, facts.kind), label=scope_label(scope, value, facts.kind)
        )
        for scope, value in reversed(facts_scopes(facts))
    ]
    return Resolved(
        resolution=resolution,
        source=source,
        watchable_languages=watchable,
        quality_label=f"优先 {quality_label(resolution, source)}",
        quality_note=" · ".join(notes) or None,
        quality_shadow=shadow,
        subtitle_language=language,
        subtitle_line=line,
        question=question,
        scope_options=options,
    )


def _value_label(field: str, value: str) -> str:
    return (_RESOLUTION_LABELS if field == "resolution" else _SOURCE_LABELS).get(value, value)


def parse_scope(value: str, facts: SmartFacts) -> tuple[Scope, str] | None:
    """客户端回传的范围选项 → (scope, value)；只接受这部作品真的命中的范围。"""
    for scope, fact in facts_scopes(facts):
        if value == habit_key(scope, fact, facts.kind):
            return scope, fact
    return None
