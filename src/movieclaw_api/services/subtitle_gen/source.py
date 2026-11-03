"""参考字幕选源：规则打分，不用 AI（subtitle-ai-translate.md §2）。

决定参考质量的因素全部是结构化事实——排除项（forced/目标语言/图形轨）、
语言优先级（原语言 > 英语 > 其他）、完整度（加载后评估）、形态平分决胜
（内封优先，v2.1 评审修正：内封多为发行方官方字幕）。打分明细随任务
日志输出，用户要能看懂"为什么选了这条"。
"""

from __future__ import annotations

from dataclasses import dataclass, field

from movieclaw_api.i18n.stored import reference, stored_fields
from movieclaw_api.services.library.subtitles import LANGUAGE_TOKENS
from movieclaw_api.services.subtitle_gen import pgs
from movieclaw_db.models import LibraryFile

# 内封文本字幕 codec（可抽取为 srt 做翻译源）；图形轨（PGS/VobSub）排除
_TEXT_CODECS = {"srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "text"}


def normalize_language(raw: str | None) -> str | None:
    """任意语言写法 → ISO 639-2/B 三字码（复用 A 层 token 表）；认不出原样返回。"""
    if not raw:
        return None
    return LANGUAGE_TOKENS.get(raw.lower(), raw.lower())


@dataclass(frozen=True)
class SourceCandidate:
    """一个可做翻译参考的字幕轨（内封或外挂）。"""

    kind: str  # "embedded" | "external" | "audio"（音轨识别，docs/design/subtitle-asr.md）
    key: str  # embedded: 字幕轨数组下标的字符串；external: 台账文件名；audio: 音轨序号
    language: str | None  # ISO 639-2/B
    forced: bool
    sdh: bool
    format: str | None  # 外挂扩展名 / 内封 codec（小写）
    provenance: str = "original"  # original / pgs_ocr / asr / ai / ai_bilingual
    #: 只有音轨候选有：SenseVoice 的台词语言（zh / yue / en / ja / ko），None = 未知
    spoken_language: str | None = None


@dataclass
class RankedCandidate:
    candidate: SourceCandidate
    excluded: str | None = None  # 非空 = 被排除的中文原因
    exclusion_code: str | None = None  # 稳定原因码，供预检生成可执行的用户提示
    reasons: list[str] = field(default_factory=list)  # 打分明细（任务日志）
    rank_key: tuple = ()  # 越大越优
    excluded_message: dict | None = None
    reason_messages: list[dict] = field(default_factory=list)
    #: 只供用户主动选择、不参与默认选择（识别过的音轨：选它是为了重新识别）
    on_request: bool = False

    def exclude(self, key: str, **params) -> None:
        self.excluded_message = stored_fields(key, **params)
        self.excluded = self.excluded_message["message"]

    def explain(self, key: str, **params) -> None:
        message = stored_fields(key, **params)
        self.reason_messages.append(message)
        self.reasons.append(message["message"])


def _language_rank(lang: str | None, original: str | None) -> int:
    """原语言=2（第一手台词），英语=1（通用中间语言），其余=0。"""
    if lang is None:
        return 0
    if original is not None and lang == original:
        return 2
    return 1 if lang == "eng" else 0


def _external_provenance(entry: dict) -> str:
    """从规范 title/文件名识别字幕世代，避免把 AI 成品继续当默认翻译源。"""
    marker = f"{entry.get('title') or ''}.{entry.get('filename') or ''}".lower()
    if "ai-bilingual-" in marker:
        return "ai_bilingual"
    if ".ai-" in marker or marker.startswith("ai-") or ".ai." in marker:
        return "ai"
    if "pgs-ocr" in marker:
        return "pgs_ocr"
    if marker.startswith("asr.") or ".asr." in marker:
        return "asr"
    return "original"


def rank_candidates(
    file: LibraryFile,
    *,
    original_language: str | None,
    target_language: str,
) -> list[RankedCandidate]:
    """元数据级排序（完整度/同步度在加载后另行评估，tasks 按序逐个尝试）。

    排序键（越大越优）：语言优先级 → 非 sdh（听障标记要清理，同分让路）
    → 来源世代（发行原文 > OCR 文本 > 语音识别 > AI 单语 > AI 双语）→ 内封优先。

    音轨识别候选不在这里：自动生成与一键校准都调用本函数，放进来会让它们对所有
    没有字幕的文件跑识别。手动流程按需追加 ``audio_candidate``。
    """
    original = normalize_language(original_language)
    target = normalize_language(target_language)
    ranked: list[RankedCandidate] = []

    for k, raw in enumerate(file.subtitle_streams or []):
        codec = str(raw.get("codec") or "").lower()
        cand = SourceCandidate(
            kind="embedded",
            key=str(k),
            language=normalize_language(raw.get("language")),
            forced=bool(raw.get("forced")),
            sdh=False,
            format=codec,
            provenance="original",
        )
        ranked.append(_rank_one(cand, original, target, is_text=codec in _TEXT_CODECS))

    for entry in file.external_subtitles or []:
        filename = entry.get("filename")
        if not filename:
            continue
        cand = SourceCandidate(
            kind="external",
            key=str(filename),
            language=normalize_language(entry.get("language")),
            forced=bool(entry.get("forced")),
            sdh=bool(entry.get("sdh")),
            format=str(entry.get("format") or "").lower(),
            provenance=_external_provenance(entry),
        )
        # 外挂台账只收文本格式（SUBTITLE_EXTS 保证），恒可用
        ranked.append(_rank_one(cand, original, target, is_text=True))

    # 稳定排序：rank_key 降序，同分保持进入顺序（内封在前=决胜时内封优先）
    order = {c.candidate.key + c.candidate.kind: i for i, c in enumerate(ranked)}
    ranked.sort(
        key=lambda c: (
            [-x for x in c.rank_key],
            order[c.candidate.key + c.candidate.kind],
        )
    )
    return ranked


def _rank_one(
    cand: SourceCandidate, original: str | None, target: str | None, *, is_text: bool
) -> RankedCandidate:
    r = RankedCandidate(candidate=cand)
    if cand.forced:
        r.exclusion_code = "forced"
        r.exclude("library.subtitleSource.forced")
        return r
    if target is not None and cand.language == target:
        r.exclusion_code = "target_language"
        r.exclude("library.subtitleSource.target")
        return r

    lang_rank = _language_rank(cand.language, original)
    lang_label = cand.language or reference("library.subtitleSource.unknownLanguage")
    if lang_rank == 2:
        r.explain("library.subtitleSource.originalLanguage", language=lang_label)
    elif lang_rank == 1:
        r.explain("library.subtitleSource.english", language=lang_label)
    else:
        r.explain("library.subtitleSource.otherLanguage", language=lang_label)
    if cand.sdh:
        r.explain("library.subtitleSource.sdh")
    embedded = cand.kind == "embedded"
    provenance_rank = {
        "original": 4,
        "pgs_ocr": 3,
        "asr": 2,
        "ai": 1,
        "ai_bilingual": 0,
    }.get(cand.provenance, 1)
    if embedded:
        r.explain("library.subtitleSource.embedded")
        provenance_rank = 5
    elif cand.provenance == "pgs_ocr":
        r.explain("library.subtitleSource.ocr")
    elif cand.provenance == "asr":
        r.explain("library.subtitleSource.asrSidecar")
    elif cand.provenance == "ai":
        r.explain("library.subtitleSource.ai")
    elif cand.provenance == "ai_bilingual":
        r.explain("library.subtitleSource.bilingual")
    else:
        r.explain("library.subtitleSource.external")
    r.rank_key = (
        lang_rank,
        0 if cand.sdh else 1,
        provenance_rank,
        1 if embedded else 0,
    )
    if not is_text:
        r.exclusion_code = "pgs" if pgs.is_pgs_codec(cand.format) else "graphic"
        if r.exclusion_code == "pgs":
            r.exclude("library.subtitleSource.pgs")
        else:
            r.exclude("library.subtitleSource.graphic", format=cand.format)
    return r


def audio_candidate(
    file: LibraryFile, *, original_language: str | None, recognized: bool = False
) -> RankedCandidate | None:
    """最后一级候选：从音轨识别台词（docs/design/subtitle-asr.md §3）。没有音轨时返回 None。

    只在手动流程里、文本字幕与 PGS 都选不到时（或请求显式指定 ``audio:<k>``）追加；
    ``recognized`` = 这个文件识别过（已有识别外挂），列出来供用户选它重新识别。
    不能识别（语言不支持、网盘文件、缺组件）时照样返回，带排除原因，预检据此说明。
    """
    # 延迟导入：asr → extract → source 是一条导入链
    from movieclaw_api.services import media_extract
    from movieclaw_api.services.subtitle_gen import asr

    plan = asr.plan_audio(
        file.file_path,
        file.audio_streams,
        original_language,
        remote=media_extract.is_remote(file.file_path),
    )
    if plan is None:
        return None
    cand = SourceCandidate(
        kind="audio",
        key=str(plan.index),
        language=plan.language_token,
        forced=False,
        sdh=False,
        format=plan.codec,
        provenance="asr",
        spoken_language=plan.language,
    )
    r = RankedCandidate(candidate=cand, rank_key=(-1,))
    r.explain(
        "library.subtitleSource.audioTrack",
        index=plan.index + 1,
        hasLanguage="yes" if plan.language else "no",
        language=reference("library.asrLanguages." + plan.language) if plan.language else "",
        hasLayout="yes" if plan.layout else "no",
        layout=plan.layout or "",
    )
    r.explain("library.subtitleSource.asrAgain" if recognized else "library.subtitleSource.asr")
    if plan.center_channel:
        r.explain("library.subtitleSource.audioCenter")
    if plan.language is None and plan.refusal is None:
        r.explain("library.subtitleSource.audioAutoLanguage")
    if plan.refusal is not None:
        r.exclusion_code = plan.refusal
        if plan.refusal == "asr_language":
            r.exclude("library.subtitleSource.asrLanguage", language=plan.raw_language or "")
        elif plan.refusal == "asr_remote":
            r.exclude("library.subtitleSource.asrRemote")
        else:
            r.exclude("library.subtitleSource.asrUnavailable")
    return r


@dataclass(frozen=True)
class Assessment:
    """候选加载后的完整度评估（§2.3：条数 + 覆盖时长比）。"""

    event_count: int
    coverage: float  # 首末事件跨度 / 影片时长；无时长数据 = 1.0（不惩罚）
    ok: bool
    reason: str
    reason_message: dict | None = None


# 完整度阈值：条数低于此值多半是残缺轨/纯标题轨；覆盖率低于此值疑似片段
_MIN_EVENTS = 50
_MIN_COVERAGE = 0.5


def assess_events(
    events: list[tuple[int, int, str]],
    runtime_seconds: int | None,
    *,
    provenance: str = "original",
) -> Assessment:
    """events 为 (start_ms, end_ms, text) 序列（加载层产物）。

    ASR 在整段音频识别成功后才原子写出外挂；对白条数与首末跨度不能代表识别是否
    完成（短片、长静音都可能很稀疏）。只检查非空，字幕轨与 OCR 仍按完整度筛选。
    """
    count = len(events)
    if count == 0:
        return _assessment(0, 0.0, False, "library.subtitleSource.empty")
    if runtime_seconds and runtime_seconds > 0:
        span_ms = max(e[1] for e in events) - min(e[0] for e in events)
        coverage = min(1.0, span_ms / (runtime_seconds * 1000))
    else:
        coverage = 1.0
    if provenance != "asr" and count < _MIN_EVENTS:
        return _assessment(count, coverage, False, "library.subtitleSource.tooFew", count=count)
    if provenance != "asr" and coverage < _MIN_COVERAGE:
        return _assessment(
            count, coverage, False, "library.subtitleSource.lowCoverage", coverage=coverage
        )
    return _assessment(
        count, coverage, True, "library.subtitleSource.complete", count=count, coverage=coverage
    )


def _assessment(event_count: int, fraction: float, ok: bool, key: str, **params) -> Assessment:
    message = stored_fields(key, **params)
    return Assessment(event_count, fraction, ok, message["message"], message)
