"""字幕生成领域管线：选源 → 同步质检 → 翻译 → 机检 → 落盘 → 台账刷新。

任务状态、去重、取消和恢复全部由持久化 Job 负责。本模块只保留同步预检与
可恢复的领域执行体，不维护第二套进程内状态。相同文件由 Job 资源锁单飞，
不同文件可并行执行；每个文件内部的模型调用另有自适应并发与限流退避。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re as _re
import time
from collections.abc import Awaitable, Callable
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import TypeVar

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import AppException, BadRequestException, NotFoundException
from movieclaw_api.i18n import t
from movieclaw_api.i18n.stored import reference, stored_fields
from movieclaw_api.schemas.base import utc_isoformat
from movieclaw_api.services import jobs, media_extract
from movieclaw_api.services.library.subtitles import discover_external_subtitles
from movieclaw_api.services.subtitle_gen import extract, pgs, source, sync, translate, validate
from movieclaw_db.engine import get_database
from movieclaw_db.models import FileState, LibraryFile, MediaItem, MediaMetadata, utcnow

logger = logging.getLogger("movieclaw_api.subtitle_gen")

#: 每千字符对白的估算 token 量（原文+译文+提示词开销的经验粗估，
#: 只用于发起前的确认展示，不参与任何限额判断）
_TOKENS_PER_KCHAR = 2600
#: 内封轨还没读出来时按片长粗估：常见影视剧每分钟约 12 条对白、每条约 40 字符。
#: 只给确认前一个量级参考，读出字幕后按实际对白翻译。
_EVENTS_PER_MINUTE = 12
_CHARS_PER_EVENT = 40


@dataclass
class SubtitleLlmUsage:
    """字幕任务的模型用量聚合器；并发回调只做无 await 的原子快照更新。"""

    request_count: int = 0
    failed_request_count: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0
    cache_read_tokens: int = 0
    total_duration_ms: int = 0
    max_duration_ms: int = 0
    thinking_response_count: int = 0
    by_purpose: dict[str, dict[str, int]] = field(default_factory=dict)
    finish_reasons: dict[str, int] = field(default_factory=dict)
    last_call: dict[str, object] = field(default_factory=dict)

    def record_success(
        self,
        call: translate.ChatCall,
        *,
        duration_ms: int,
        prompt_tokens: int,
        completion_tokens: int,
        total_tokens: int,
        cache_read_tokens: int,
        finish_reason: str | None,
        has_thinking: bool,
    ) -> None:
        self.request_count += 1
        self.prompt_tokens += prompt_tokens
        self.completion_tokens += completion_tokens
        self.total_tokens += total_tokens
        self.cache_read_tokens += cache_read_tokens
        self.total_duration_ms += duration_ms
        self.max_duration_ms = max(self.max_duration_ms, duration_ms)
        if has_thinking:
            self.thinking_response_count += 1
        reason = finish_reason or "unknown"
        self.finish_reasons[reason] = self.finish_reasons.get(reason, 0) + 1
        bucket = self.by_purpose.setdefault(
            call.purpose,
            {"requests": 0, "prompt_tokens": 0, "completion_tokens": 0, "duration_ms": 0},
        )
        bucket["requests"] += 1
        bucket["prompt_tokens"] += prompt_tokens
        bucket["completion_tokens"] += completion_tokens
        bucket["duration_ms"] += duration_ms
        self.last_call = {
            "purpose": call.purpose,
            "block_index": call.block_index,
            "attempt": call.attempt,
            "duration_ms": duration_ms,
            "finish_reason": reason,
        }

    def record_failure(
        self, call: translate.ChatCall, *, duration_ms: int, error_code: str
    ) -> None:
        self.request_count += 1
        self.failed_request_count += 1
        self.total_duration_ms += duration_ms
        self.max_duration_ms = max(self.max_duration_ms, duration_ms)
        bucket = self.by_purpose.setdefault(
            call.purpose,
            {"requests": 0, "prompt_tokens": 0, "completion_tokens": 0, "duration_ms": 0},
        )
        bucket["requests"] += 1
        bucket["duration_ms"] += duration_ms
        self.last_call = {
            "purpose": call.purpose,
            "block_index": call.block_index,
            "attempt": call.attempt,
            "duration_ms": duration_ms,
            "error_code": error_code,
        }

    def snapshot(self) -> dict[str, object]:
        """返回全新字典，避免 Job 轮询比较被后续原地更新污染。"""
        return {
            "request_count": self.request_count,
            "failed_request_count": self.failed_request_count,
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "total_tokens": self.total_tokens,
            "cache_read_tokens": self.cache_read_tokens,
            "total_duration_ms": self.total_duration_ms,
            "max_duration_ms": self.max_duration_ms,
            "thinking_response_count": self.thinking_response_count,
            "by_purpose": {key: dict(value) for key, value in self.by_purpose.items()},
            "finish_reasons": dict(self.finish_reasons),
            "last_call": dict(self.last_call),
        }


@dataclass
class GenState:
    """单次领域执行的内存快照；Job 处理器定期把它持久化为公共进度。"""

    # 阶段值由前端映射成稳定的五步进度，message 则描述阶段内的即时动作。
    phase: str = "preparing"
    message: str = stored_fields("library.subtitleJob.preparing")["message"]
    message_key: str | None = None
    message_params: dict = field(default_factory=dict)
    done_blocks: int = 0
    total_blocks: int = 0
    done_events: int = 0
    total_events: int = 0
    active_blocks: tuple[int, ...] = ()
    parallelism: int = 0
    oldest_active_seconds: int = 0
    last_completed_seconds_ago: int | None = None
    validation_retries: int = 0
    rate_limit_count: int = 0
    uses_ocr: bool = False
    target_language: str = "chs"
    secondary_language: str | None = None
    source_candidate_key: str | None = None
    # 读取阶段（extracting）：排队等全局读取闸门，或已读到片中的哪个时间点
    extract_queued: bool = False
    extract_position_seconds: float | None = None
    extract_duration_seconds: int | None = None
    llm_usage: SubtitleLlmUsage = field(default_factory=SubtitleLlmUsage)

    def set_message(self, key: str, **params) -> None:
        message = stored_fields(key, **params)
        self.message = message["message"]
        self.message_key = message["message_key"]
        self.message_params = message["message_params"]


@dataclass
class GenResult:
    """字幕领域执行结论；成功后被写入 Job.result。"""

    ok: bool
    message: str
    filename: str | None = None
    report: validate.QualityReport | None = None
    sync_score: float | None = None
    source_desc: str | None = None
    finished_at: object = None
    message_key: str | None = None
    message_params: dict = field(default_factory=dict)
    source_message: dict | None = None


async def _load_row(session: AsyncSession, file_id: int) -> LibraryFile:
    row = (
        await session.execute(select(LibraryFile).where(LibraryFile.id == file_id))
    ).scalar_one_or_none()
    if row is None or row.state != FileState.IN_PLACE:
        raise NotFoundException(message_key="errors.subtitles.fileMissing", params={"id": file_id})
    return row


async def _film_context(
    session: AsyncSession, row: LibraryFile
) -> tuple[translate.FilmContext, str | None]:
    item = await session.get(MediaItem, row.media_item_id) if row.media_item_id else None
    meta = None
    if row.media_item_id:
        meta = (
            await session.execute(
                select(MediaMetadata).where(MediaMetadata.media_item_id == row.media_item_id)
            )
        ).scalar_one_or_none()
    ctx = translate.FilmContext(
        title=item.title if item else Path(row.file_path).stem,
        year=item.year if item else None,
        genres=list(meta.genres or []) if meta else [],
        overview=meta.overview if meta else None,
    )
    return ctx, (meta.original_language if meta else None)


# 输出语言是产品能力边界，也是提示词、文件名和断点身份的一部分。语言 token
# 采用项目既有短码；外挂文件末段另写 ISO 639-2/B，兼容 Jellyfin/Plex/Kodi。
# 值是展示名的消息键（library.subtitleLanguages.*），渲染时按读者语言取
OUTPUT_LANGUAGES: dict[str, str] = {
    code: f"library.subtitleLanguages.{code}"
    for code in (
        "chs", "cht", "eng", "jpn", "kor", "fre", "ger", "spa", "ita", "por", "rus", "tha",
    )
}
_FILENAME_LANGUAGE = {"chs": "chi", "cht": "chi"}
_LANGUAGE_TOKEN = _re.compile(r"^[a-z0-9-]{2,16}$")


def ensure_language_token(target_language: str) -> str:
    token = target_language.strip().lower()
    if not _LANGUAGE_TOKEN.fullmatch(token):
        raise BadRequestException(
            message_key="errors.subtitles.languageTokenInvalid",
            params={"language": f"{target_language!r}"},
        )
    return token


def ensure_output_languages(
    target_language: str, secondary_language: str | None = None
) -> tuple[str, str | None]:
    """校验用户选择的单语/双语输出；双语两行不能选择同一种语言。"""
    target = ensure_language_token(target_language)
    secondary = ensure_language_token(secondary_language) if secondary_language else None
    if target not in OUTPUT_LANGUAGES:
        raise BadRequestException(
            message_key="errors.subtitles.languageUnsupported", params={"language": target}
        )
    if secondary is not None and secondary not in OUTPUT_LANGUAGES:
        raise BadRequestException(
            message_key="errors.subtitles.languageUnsupported", params={"language": secondary}
        )
    if secondary == target:
        raise BadRequestException(message_key="errors.subtitles.bilingualLanguagesSame")
    return target, secondary


def subtitle_output_key(target_language: str, secondary_language: str | None = None) -> str:
    target, secondary = ensure_output_languages(target_language, secondary_language)
    return target if secondary is None else f"{target}-{secondary}"


def subtitle_output_label(target_language: str, secondary_language: str | None = None) -> str:
    target, secondary = ensure_output_languages(target_language, secondary_language)
    if secondary is None:
        return t(OUTPUT_LANGUAGES[target])
    return t(
        "library.subtitleJob.bilingualLabel",
        primary=t(OUTPUT_LANGUAGES[target]),
        secondary=t(OUTPUT_LANGUAGES[secondary]),
    )


def _sidecar_path(
    row: LibraryFile, target_language: str, secondary_language: str | None = None
) -> Path:
    video = Path(row.file_path)
    target, secondary = ensure_output_languages(target_language, secondary_language)
    language = _FILENAME_LANGUAGE.get(target, target)
    title = f"ai-{target}" if target != language else "ai"
    if secondary is not None:
        title = f"ai-bilingual-{target}-{secondary}"
    return video.parent / f"{video.stem}.{title}.{language}.srt"


def _legacy_sidecar_path(row: LibraryFile, target_language: str) -> Path:
    """v2.1 及更早版本的 AI 字幕命名；只用于无重复迁移。"""
    video = Path(row.file_path)
    target = ensure_language_token(target_language)
    return video.parent / f"{video.stem}.{target}.ai.srt"


def _pgs_sidecar_path(row: LibraryFile, source_language: str) -> Path:
    """PGS OCR 通过完整度检查后的可复用外挂，语言码保持播放器可识别。"""
    video = Path(row.file_path)
    normalized = source.normalize_language(source_language) or "und"
    language = _FILENAME_LANGUAGE.get(normalized, normalized)
    return video.parent / f"{video.stem}.pgs-ocr.{language}.srt"


@dataclass
class Preview:
    """发起前的确认素材（§6：展示选源结果与成本估算）。

    预检只读数据库和现成产物，永远是毫秒级：内封轨还没读取过时不在请求里读
    （大文件在 NAS 上要几分钟，iOS 与网页 20 秒就超时），而是照常选中它、按
    片长粗估成本，并用 ``reference_notice`` 讲清楚「任务第一步会先读取」。
    """

    candidates: list[source.RankedCandidate]
    chosen: source.RankedCandidate | None
    event_count: int
    estimated_tokens: int
    already_generated: bool
    warnings: list[str]
    pgs_conversion: PgsConversionPlan | None
    blocker: PreviewBlocker | None
    output_filename: str | None = None
    selected_source_key: str | None = None
    #: 非空 = 参考字幕还没读取过：event_count 为 0，estimated_tokens 按片长粗估
    reference_notice: str | None = None
    reference_notice_message: dict | None = None
    warning_messages: list[dict] = field(default_factory=list)


@dataclass(frozen=True)
class PreviewBlocker:
    """预检未通过时面向产品层的结构化解释，而不是一条不可行动的错误。"""

    code: str
    title: str
    message: str
    suggestions: list[str]
    title_key: str | None = None
    message_key: str | None = None
    message_params: dict = field(default_factory=dict)
    suggestion_messages: list[dict] = field(default_factory=list)


@dataclass(frozen=True)
class PgsConversionPlan:
    """没有文本源时，预检选中的 PGS 轨道及当前设备能力。"""

    candidate: source.RankedCandidate
    capability: pgs.Capability
    language: pgs.OcrLanguageDecision
    language_options: tuple[tuple[str, str], ...] = ()


def candidate_key(candidate: source.RankedCandidate) -> str:
    """候选字幕的稳定中性引用；内封用序号，外挂用完整文件名。"""
    return f"{candidate.candidate.kind}:{candidate.candidate.key}"


def candidate_selectable(candidate: source.RankedCandidate) -> bool:
    """文本字幕可直接选择，PGS 可选择后进入 OCR；其他排除项不可选。"""
    return candidate.exclusion_code in {None, "pgs"}


async def _source_fingerprint(row: LibraryFile, selected_source_key: str) -> dict[str, int]:
    """记录预检实际读取的源文件身份，防止长时间排队后翻译另一份内容。"""
    kind, separator, key = selected_source_key.partition(":")
    if not separator or kind not in {"embedded", "external"}:
        raise BadRequestException(message_key="errors.subtitles.referenceInvalid")
    if kind == "external":
        known = {str(item.get("filename")) for item in row.external_subtitles or []}
        if key not in known:
            raise BadRequestException(message_key="errors.subtitles.referenceRemoved")
        path = Path(row.file_path).parent / key
    else:
        path = Path(row.file_path)
    try:
        stat = await asyncio.to_thread(path.stat)
    except OSError as exc:
        raise BadRequestException(message_key="errors.subtitles.referenceUnreadable") from exc
    return {"size_bytes": stat.st_size, "file_mtime_ns": stat.st_mtime_ns}


async def _verify_source_fingerprint(
    file_id: int,
    selected_source_key: str,
    expected: dict[str, object],
) -> None:
    """执行前复验源文件；不允许重试任务静默改用已变化的片源或字幕。"""
    db = get_database()
    async with db.session() as session:
        row = await _load_row(session, file_id)
    try:
        actual = await _source_fingerprint(row, selected_source_key)
    except AppException as exc:
        raise jobs.JobFailed(
            exc.message,
            message_key=exc.message_key,
            message_params=exc.params,
            code="SUBTITLE_SOURCE_UNAVAILABLE",
            actions=[
                {"type": "handoff_agent", "label": "交给 Agent", "label_key": "activity.jobs.agent"}
            ],
        ) from exc
    if actual != expected:
        raise jobs.JobFailed(
            **stored_fields("library.subtitleJob.sourceChanged"),
            code="SUBTITLE_SOURCE_CHANGED",
            actions=[
                {"type": "handoff_agent", "label": "交给 Agent", "label_key": "activity.jobs.agent"}
            ],
        )


def _select_reference(
    ranked: list[source.RankedCandidate], requested_key: str | None
) -> source.RankedCandidate | None:
    """绑定用户指定候选；未指定时优先英语，再回退既有质量排序。"""
    if requested_key is not None:
        selected = next((item for item in ranked if candidate_key(item) == requested_key), None)
        if selected is None:
            raise BadRequestException(message_key="errors.subtitles.referenceMissing")
        if not candidate_selectable(selected):
            raise BadRequestException(
                message_key="errors.subtitles.referenceExcluded",
                params={"reason": selected.excluded_message or selected.excluded},
            )
        return selected

    selectable = [item for item in ranked if candidate_selectable(item)]
    # 默认英语符合绝大多数用户的二次翻译习惯；有文本英语时不为了同语种
    # PGS 多走一次 OCR，只有没有英语文本时才选择英语 PGS。
    english_text = [
        item
        for item in selectable
        if item.candidate.language == "eng" and item.exclusion_code is None
    ]
    if english_text:
        return english_text[0]
    english = [item for item in selectable if item.candidate.language == "eng"]
    if english:
        return english[0]
    return selectable[0] if selectable else None


async def _pgs_plan(
    row: LibraryFile,
    ranked: list[source.RankedCandidate],
    *,
    original_language: str | None = None,
    requested_candidate_key: str | None = None,
    requested_ocr_language: str | None = None,
) -> PgsConversionPlan | None:
    """按既有顺序选 PGS；用户确认后只允许复验同一轨道和识别语言。"""
    first_unavailable: PgsConversionPlan | None = None
    for ranked_candidate in ranked:
        if ranked_candidate.exclusion_code != "pgs":
            continue
        candidate_key = f"{ranked_candidate.candidate.kind}:{ranked_candidate.candidate.key}"
        if requested_candidate_key and candidate_key != requested_candidate_key:
            continue

        language = pgs.infer_ocr_language(
            row,
            ranked_candidate.candidate,
            original_language,
        )
        if requested_ocr_language is not None:
            selected = pgs.normalize_ocr_language(requested_ocr_language)
            language = pgs.language_decision(
                code=selected,
                label=pgs.OCR_LANGUAGE_LABELS.get(selected) if selected else None,
                confirmation_required=selected is None,
                reason=(
                    stored_fields(
                        "library.subtitleOcr.confirmedLanguage",
                        language=reference("library.subtitleLanguages." + selected),
                    )
                    if selected
                    else stored_fields(
                        "library.subtitleOcr.invalidLanguage", language=requested_ocr_language
                    )
                ),
            )

        options: tuple[tuple[str, str], ...] = ()
        if language.code is not None:
            capability = await asyncio.to_thread(
                pgs.conversion_capability,
                row,
                ranked_candidate.candidate,
                language.code,
            )
            if language.confirmation_required and not capability.cached:
                options, representative = await asyncio.to_thread(pgs.available_ocr_languages)
                if language.code not in {code for code, _label in options}:
                    language = pgs.language_decision(
                        code=None,
                        label=None,
                        confirmation_required=True,
                        reason=(
                            stored_fields(
                                "library.subtitleOcr.packageUnavailable",
                                reason=language.reason_message or language.reason,
                            )
                        ),
                    )
                    if representative is not None:
                        capability = representative
        else:
            options, representative = await asyncio.to_thread(pgs.available_ocr_languages)
            capability = representative or await asyncio.to_thread(pgs.detect_capability, None)

        if capability.cached and language.confirmation_required:
            language = pgs.language_decision(
                code=language.code,
                label=language.label,
                confirmation_required=False,
                reason=stored_fields("library.subtitleOcr.cachedLanguage"),
            )
        plan = PgsConversionPlan(
            candidate=ranked_candidate,
            capability=capability,
            language=language,
            language_options=options,
        )
        if capability.available:
            return plan
        if first_unavailable is None:
            first_unavailable = plan
    return first_unavailable


def _blocker(
    code: str,
    title_key: str,
    message_key: str | None,
    suggestions: list,
    *,
    detail: dict | str | None = None,
    **params,
) -> PreviewBlocker:
    message = stored_fields(message_key, **params) if message_key else detail
    if isinstance(message, str):
        message = {"message": message}
    return PreviewBlocker(
        code=code,
        title=stored_fields(title_key)["message"],
        **message,
        title_key=title_key,
        suggestions=[item["message"] if isinstance(item, dict) else item for item in suggestions],
        suggestion_messages=[
            item if isinstance(item, dict) else {"message_key": None, "message": item}
            for item in suggestions
        ],
    )


def _output_message(target: str, secondary: str | None = None) -> dict:
    primary = reference("library.subtitleLanguages." + target)
    if secondary is None:
        return primary
    return reference(
        "library.subtitlePreflight.bilingual",
        primary=primary,
        secondary=reference("library.subtitleLanguages." + secondary),
    )


def _preview_blocker(
    ranked: list[source.RankedCandidate],
    pgs_plan: PgsConversionPlan | None = None,
    target_language: str = "chs",
    secondary_language: str | None = None,
    detail: dict | str | None = None,
) -> PreviewBlocker:
    output = _output_message(target_language, secondary_language)
    add_sidecar = stored_fields("library.subtitlePreflight.addSidecar")
    rescan = stored_fields("library.subtitlePreflight.rescan")
    if not ranked:
        return _blocker(
            "no_subtitle",
            "library.subtitlePreflight.noSubtitleTitle",
            "library.subtitlePreflight.noSubtitle",
            [add_sidecar, rescan],
        )
    if pgs_plan is not None:
        capability = pgs_plan.capability
        language = (
            reference("library.subtitleLanguages." + pgs_plan.language.code)
            if pgs_plan.language.code
            else reference("library.subtitlePreflight.waitingLanguage")
        )
        if capability.available:
            if pgs_plan.language.confirmation_required:
                return _blocker(
                    "pgs_conversion_required",
                    "library.subtitlePreflight.confirmLanguage",
                    "library.subtitlePreflight.imageNeedsLanguage",
                    [
                        stored_fields("library.subtitlePreflight.originalNotTarget", output=output),
                        stored_fields("library.subtitlePreflight.watchToCheck"),
                    ],
                    output=output,
                )
            return _blocker(
                "pgs_conversion_required",
                "library.subtitlePreflight.recognizeFirst",
                "library.subtitlePreflight.imageRecognize",
                [
                    stored_fields("library.subtitlePreflight.keepOriginals"),
                    stored_fields("library.subtitlePreflight.checkOcr"),
                ],
                language=language,
                output=output,
            )
        return _blocker(
            "pgs_conversion_unavailable",
            "library.subtitlePreflight.imageUnavailableTitle",
            "library.subtitlePreflight.imageUnavailable",
            list(capability.suggestion_refs or capability.suggestions),
        )
    if all(c.exclusion_code in {"graphic", "pgs"} for c in ranked):
        return _blocker(
            "graphics_only",
            "library.subtitlePreflight.imageUnavailableTitle",
            "library.subtitlePreflight.graphicsOnly",
            [add_sidecar, rescan],
            count=len(ranked),
        )
    if all(c.exclusion_code == "target_language" for c in ranked):
        return _blocker(
            "target_exists",
            "library.subtitlePreflight.targetTitle",
            "library.subtitlePreflight.targetExists",
            [stored_fields("library.subtitlePreflight.addOtherLanguage")],
            output=output,
        )
    if any(c.excluded is None for c in ranked):
        return _blocker(
            "unusable_text",
            "library.subtitlePreflight.unusableTitle"
            if detail
            else "library.subtitlePreflight.incompleteTitle",
            None if detail else "library.subtitlePreflight.unusable",
            [stored_fields("library.subtitlePreflight.chooseComplete"), rescan],
            detail=detail,
        )
    graphic_count = sum(c.exclusion_code == "graphic" for c in ranked)
    return _blocker(
        "no_usable_reference",
        "library.subtitlePreflight.noUsableTitle",
        "library.subtitlePreflight.noUsable",
        [add_sidecar, rescan],
        count=len(ranked),
        hasGraphic="yes" if graphic_count else "no",
        graphic=graphic_count,
    )


async def preview(
    session: AsyncSession,
    file_id: int,
    target_language: str,
    *,
    secondary_language: str | None = None,
    source_candidate_key: str | None = None,
    pgs_ocr_language: str | None = None,
) -> Preview:
    """选源 + 用现成产物做成本估算（不动 LLM，也不读视频）。

    HTTP 预检与发起生成共用它：两者都必须秒回。内封轨还没读取过时照常选中、
    按片长粗估，读取留给生成任务第一步（任务里有进度、可取消、重启可续）。
    """
    target_language, secondary_language = ensure_output_languages(
        target_language, secondary_language
    )
    row = await _load_row(session, file_id)
    _, original_language = await _film_context(session, row)
    # 双语允许把其中一种语言的现有字幕当参考；例如英语原字幕生成英中双语，
    # 不能因为第一行也是英语就把这条唯一参考排除。
    source_target = target_language if secondary_language is None else "__bilingual__"
    ranked = source.rank_candidates(
        row, original_language=original_language, target_language=source_target
    )
    selected = _select_reference(ranked, source_candidate_key)
    selected_candidates = [selected] if selected is not None else []
    warnings: list[str] = []
    warning_messages: list[dict] = []
    output_filename = _sidecar_path(row, target_language, secondary_language).name
    already_generated = bool(
        {
            output_filename,
            *(
                [_legacy_sidecar_path(row, target_language).name]
                if secondary_language is None
                else []
            ),
        }
        & {e.get("filename") for e in row.external_subtitles or []}
    )
    selected_key = candidate_key(selected) if selected is not None else None

    reference_notice: str | None = None
    notice_message = None
    try:
        chosen, events = await _pick_loadable(
            row, selected_candidates, warnings, wait=False, warning_messages=warning_messages
        )
    except extract.SourceExtractionPending:
        # 还没读过不等于「做不了」：照常选中它，blocker 留空；读取与完整度检查
        # 都在任务里做，不合格会在调用模型之前停下。
        chosen, events = selected, []
        notice_message = await _reading_message(row)
        reference_notice = notice_message["message"]

    pgs_conversion = (
        await _pgs_plan(
            row,
            selected_candidates,
            original_language=original_language,
            requested_candidate_key=(candidate_key(selected) if selected is not None else None),
            requested_ocr_language=pgs_ocr_language,
        )
        if chosen is None
        else None
    )
    est = 0
    if events:
        est = _estimate_tokens(sum(len(t) for _, _, t in events), secondary_language)
    elif reference_notice is not None and row.duration_seconds:
        chars = row.duration_seconds / 60 * _EVENTS_PER_MINUTE * _CHARS_PER_EVENT
        est = _estimate_tokens(chars, secondary_language)
    return Preview(
        candidates=ranked,
        chosen=chosen,
        event_count=len(events),
        estimated_tokens=est,
        already_generated=already_generated,
        warnings=warnings,
        warning_messages=warning_messages,
        reference_notice_message=notice_message,
        pgs_conversion=pgs_conversion,
        blocker=(
            _preview_blocker(
                ranked,
                pgs_conversion,
                target_language,
                secondary_language,
                detail=warning_messages[-1] if warning_messages else None,
            )
            if chosen is None
            else None
        ),
        output_filename=output_filename,
        selected_source_key=selected_key,
        reference_notice=reference_notice,
    )


def _estimate_tokens(chars: float, secondary_language: str | None) -> int:
    est = int(chars / 1000 * _TOKENS_PER_KCHAR)
    if secondary_language is not None:
        # 同一个请求同时产出两种语言，共享提示词和上下文，但输出量接近翻倍。
        est = int(est * 1.8)
    return est


def _format_size(size: int) -> str:
    """文件体积的人话写法：15.2 GB / 830 MB。"""
    if size >= 1024**3:
        return f"{size / 1024**3:.1f} GB"
    if size >= 1024**2:
        return f"{size / 1024**2:.0f} MB"
    return f"{max(1, size // 1024)} KB"


async def _reading_message(row: LibraryFile) -> dict:
    try:
        size = (await asyncio.to_thread(Path(row.file_path).stat)).st_size
    except OSError:
        size = 0
    return stored_fields(
        "library.subtitlePreflight.readNotice",
        hasSize="yes" if size else "no",
        size=_format_size(size) if size else "",
    )


async def _reading_notice(row: LibraryFile) -> str:
    return (await _reading_message(row))["message"]


async def _pick_loadable(
    row: LibraryFile,
    ranked: list[source.RankedCandidate],
    warnings: list[str],
    *,
    wait: bool = True,
    warning_messages: list[dict] | None = None,
) -> tuple[source.RankedCandidate | None, list[extract.SubEvent]]:
    """按排序逐个加载候选，返回第一个完整度合格的（§2：加载后评估）。

    ``wait=False``（预检）只用现成产物；内封轨还没读过时抛
    ``SourceExtractionPending``，且不在这里吞掉——它不是「这条候选不能用」，
    而是「这条候选还没读出来」，必须原样上抛给预检。
    """
    for cand in ranked:
        if cand.excluded:
            continue
        try:
            events = await extract.load_candidate_events(
                row, cand.candidate, wait=wait, schedule=False
            )
        except extract.SourceLoadError as exc:
            warnings.append(str(exc))
            if warning_messages is not None:
                warning_messages.append(exc.reference or {"message_key": None, "message": str(exc)})
            continue
        if cand.candidate.sdh:
            events = extract.strip_sdh_markers(events)
        assessment = source.assess_events(events, row.duration_seconds)
        cand.reasons.append(assessment.reason)
        cand.reason_messages.append(
            assessment.reason_message or {"message_key": None, "message": assessment.reason}
        )
        if assessment.ok:
            return cand, events
        warning = stored_fields(
            "library.subtitlePreflight.incompleteCandidate",
            candidate=_cand_message(cand.candidate),
            reason=assessment.reason_message or assessment.reason,
        )
        warnings.append(warning["message"])
        if warning_messages is not None:
            warning_messages.append(warning)
    return None, []


def _cand_message(c: source.SourceCandidate) -> dict:
    return stored_fields(
        "library.subtitleCalibration.reference",
        kind=c.kind,
        identity=c.key,
        known="yes" if c.language else "no",
        language=c.language or "",
        format=c.format,
    )


def _cand_desc(c: source.SourceCandidate) -> str:
    return _cand_message(c)["message"]


async def _prepare_generation(
    session: AsyncSession,
    file_id: int,
    target_language: str,
    *,
    secondary_language: str | None = None,
    source_candidate_key: str | None = None,
    convert_pgs: bool = False,
    pgs_ocr_language: str | None = None,
) -> tuple[Preview, GenState]:
    """发起前的秒级校验（不读视频）并生成首个进度快照，随后由 Job 原子入队。

    内封轨还没读取过也照样入队：读取是任务第一步，有进度、可取消；完整度不
    合格会在调用模型之前停下。此前这里要等 ffmpeg 通读整个文件，POST 在 iOS
    60 秒就超时，入库自动生成也得逐个文件读完才能排下一个。
    """
    target_language, secondary_language = ensure_output_languages(
        target_language, secondary_language
    )
    pv = await preview(
        session,
        file_id,
        target_language,
        secondary_language=secondary_language,
        source_candidate_key=source_candidate_key,
        pgs_ocr_language=pgs_ocr_language,
    )
    if pv.chosen is None:
        if source_candidate_key and pv.pgs_conversion is None:
            raise BadRequestException(message_key="errors.subtitles.pgsChanged")
        language_ready = bool(
            pv.pgs_conversion
            and (
                pv.pgs_conversion.capability.cached
                or (
                    pv.pgs_conversion.language.code
                    and not pv.pgs_conversion.language.confirmation_required
                )
            )
        )
        conversion_allowed = (
            convert_pgs
            and pv.pgs_conversion is not None
            and pv.pgs_conversion.capability.available
            and language_ready
        )
        if not conversion_allowed:
            if pv.blocker:
                raise BadRequestException(
                    pv.blocker.message,
                    message_key=pv.blocker.message_key,
                    params=pv.blocker.message_params,
                )
            raise BadRequestException(message_key="errors.subtitles.referenceUnavailable")
        initial = GenState(
            phase="ocr",
            **stored_fields("library.subtitleJob.queuedOcr"),
            uses_ocr=True,
            target_language=target_language,
            secondary_language=secondary_language,
            source_candidate_key=pv.selected_source_key,
        )
    else:
        initial = GenState(
            **stored_fields(
                "library.subtitleJob.waitRead"
                if pv.reference_notice
                else "library.subtitleJob.preparing"
            ),
            target_language=target_language,
            secondary_language=secondary_language,
            source_candidate_key=pv.selected_source_key,
        )

    # 入队前只组装一次 LLM 路由，不发送网络请求。这样缺少模型配置时由当前
    # POST 直接返回可读错误，不会让页面先看到“任务已开始”，随后又收到一条
    # 后台“未知错误”。排队后配置仍可能被删除，Job 处理器会转为 blocked。
    from movieclaw_api.services.llm_config import acquire_llm_router

    await acquire_llm_router(session)
    return pv, initial


async def enqueue_generation_job(
    session: AsyncSession,
    file_id: int,
    target_language: str,
    *,
    secondary_language: str | None = None,
    source_candidate_key: str | None = None,
    convert_pgs: bool = False,
    pgs_ocr_language: str | None = None,
    actor_kind: str | None = None,
    actor_name: str | None = None,
    actor_id: str | None = None,
    origin: str = "web",
) -> tuple[Preview, jobs.CreateJobResult]:
    """把字幕生成写成真正持久化任务；HTTP/CLI 只负责创建，不持有执行协程。"""
    target_language, secondary_language = ensure_output_languages(
        target_language, secondary_language
    )
    pv, initial = await _prepare_generation(
        session,
        file_id,
        target_language,
        secondary_language=secondary_language,
        source_candidate_key=source_candidate_key,
        convert_pgs=convert_pgs,
        pgs_ocr_language=pgs_ocr_language,
    )
    row = await _load_row(session, file_id)
    from movieclaw_api.services.llm_config import acquire_llm_router, default_model_ref

    router = await acquire_llm_router(session)
    # 字幕处理默认模型来自 AI 设定（未设置时按第一个实例兜底）
    provider, model_id = router.resolve(await default_model_ref(session, "subtitle"))
    provider_ref = provider.name
    selected_source_key = pv.selected_source_key
    if selected_source_key is None:
        raise BadRequestException(message_key="errors.subtitles.referenceUnavailable")
    source_fingerprint = await _source_fingerprint(row, selected_source_key)
    input_data = {
        "file_id": file_id,
        "target_language": target_language,
        "secondary_language": secondary_language,
        "source_candidate_key": selected_source_key,
        "source_fingerprint": source_fingerprint,
        "convert_pgs": convert_pgs,
        "pgs_ocr_language": pgs_ocr_language,
        # 固定到任务创建时实际选中的供应商/模型；不保存 API key。用户随后
        # 改默认模型不会让一个已开始的任务中途混用另一套翻译风格。
        "provider_ref": provider_ref,
        "model_ref": f"{provider_ref}/{model_id}",
        "prompt_revision": "subtitle.translate.v1",
    }
    resources = [
        jobs.ResourceRef("library_file", file_id),
        jobs.ResourceRef("library", row.library_id, "container"),
    ]
    if row.media_item_id is not None:
        resources.append(jobs.ResourceRef("media_item", row.media_item_id, "container"))
    progress = _job_progress(initial)
    created = await jobs.create_job(
        session,
        job_type="subtitle.generate",
        subject=Path(row.file_path).name,
        definition_version=1,
        handler_revision="subtitle.generate.v1",
        prompt_revision="subtitle.translate.v1",
        provider_ref=f"{provider_ref}/{model_id}",
        input_data=input_data,
        resources=resources,
        dedupe_key=(
            f"subtitle.generate:{file_id}:"
            f"{subtitle_output_key(target_language, secondary_language)}"
        ),
        conflict_policy="return_existing",
        max_attempts=2,
        actor_kind=actor_kind,
        actor_name=actor_name,
        actor_id=actor_id,
        origin=origin,
        progress=progress,
    )
    return pv, created


_PHASE_INDEX = {
    "preparing": 1,
    "extracting": 1,
    "ocr": 1,
    "syncing": 1,
    "glossary": 2,
    "translating": 3,
    "validating": 4,
    "compressing": 4,
    "writing": 5,
    "refreshing": 5,
}


def _job_progress(state: GenState) -> dict[str, object]:
    """把字幕领域实时状态映射到公共进度外壳，不伪造无法计算的百分比。"""
    percent = None
    if state.total_blocks > 0 and state.phase in {
        "translating",
        "validating",
        "compressing",
        "writing",
        "refreshing",
    }:
        percent = round(min(100.0, state.done_blocks / state.total_blocks * 100), 1)
    elif (
        state.phase == "extracting"
        and state.extract_position_seconds is not None
        and state.extract_duration_seconds
    ):
        # 读到哪个时间点 / 片长。片尾常没有字幕包，位置会停在九十几，读完前
        # 不报 100%，免得「满了却还在转」。
        ratio = state.extract_position_seconds / state.extract_duration_seconds
        percent = round(min(99.0, ratio * 100), 1)
    return {
        "mode": "determinate" if percent is not None else "indeterminate",
        "phase": state.phase,
        "message": state.message,
        "message_key": state.message_key,
        "message_params": state.message_params,
        "current": state.done_blocks if state.total_blocks else None,
        "total": state.total_blocks or None,
        "percent": percent,
        "phase_index": _PHASE_INDEX.get(state.phase),
        "phase_count": 5,
        "details": {
            "done_blocks": state.done_blocks,
            "total_blocks": state.total_blocks,
            "done_events": state.done_events,
            "total_events": state.total_events,
            "active_blocks": list(state.active_blocks),
            "parallelism": state.parallelism,
            "oldest_active_seconds": state.oldest_active_seconds,
            "last_completed_seconds_ago": state.last_completed_seconds_ago,
            "validation_retries": state.validation_retries,
            "rate_limit_count": state.rate_limit_count,
            "uses_ocr": state.uses_ocr,
            "target_language": state.target_language,
            "secondary_language": state.secondary_language,
            "source_candidate_key": state.source_candidate_key,
            "extract_queued": state.extract_queued,
            "extract_position_seconds": state.extract_position_seconds,
            "extract_duration_seconds": state.extract_duration_seconds,
        },
    }


def _result_payload(result: GenResult) -> dict[str, object]:
    finished_at = result.finished_at
    return {
        "ok": result.ok,
        "message": result.message,
        "message_key": result.message_key,
        "message_params": result.message_params,
        "filename": result.filename,
        "report": asdict(result.report) if result.report is not None else None,
        "sync_score": result.sync_score,
        "source_desc": result.source_desc,
        "source_desc_key": result.source_message.get("message_key")
        if result.source_message
        else None,
        "source_desc_params": result.source_message.get("message_params")
        if result.source_message
        else None,
        "finished_at": utc_isoformat(finished_at)
        if isinstance(finished_at, datetime)
        else finished_at,
    }


#: 这些阶段只在等外部进程或读盘，收到停止请求就立即取消（见 _run_generation_job）
_STOP_AT_ONCE_PHASES = frozenset({"preparing", "extracting", "ocr", "syncing"})
#: 模型服务暂时不可用时，隔多久自动重试一次（从断点继续，不重复花钱）
_MODEL_RETRY_DELAY_SECONDS = 30


def _model_setup_problem(message: str, key: str | None, params: dict | None) -> bool:
    """失败原因是不是「模型没配好/不可用」（该引导去设置页）。

    判的是中文原文（与改造前同一口径），不随读者语言变化：有消息键按键重新渲染中文，
    没有键的旧文本直接判。
    """
    text = stored_fields(key, **(params or {}))["message"] if key else message
    # i18n-ignore: decision keywords over the Chinese source text, never shown
    return "配置" in text or "模型" in text


def _brief(exc: Exception, limit: int = 200) -> str:
    """错误原文可能带整段响应体：给用户看的截到够判断原因的长度。"""
    text = str(exc).strip()
    return text if len(text) <= limit else text[:limit] + "…"


@jobs.register_job_handler("subtitle.generate")
async def _run_generation_job(
    context: jobs.JobContext, input_data: dict[str, object]
) -> dict[str, object]:
    """Job 原生处理器：直接执行领域管线并持久化进度，不维护影子任务状态。"""
    from movieclaw_llm import (
        LlmAuthError,
        LlmConnectError,
        LlmError,
        LlmRateLimitError,
        LlmServerError,
    )

    file_id = int(input_data["file_id"])
    target_language = str(input_data.get("target_language") or "chs")
    secondary_language = input_data.get("secondary_language")
    source_candidate_key = input_data.get("source_candidate_key")
    model_ref = input_data.get("model_ref")
    convert_pgs = input_data.get("convert_pgs") is True
    pgs_ocr_language = input_data.get("pgs_ocr_language")
    source_fingerprint = input_data.get("source_fingerprint")
    if source_candidate_key and isinstance(source_fingerprint, dict):
        await _verify_source_fingerprint(
            file_id,
            str(source_candidate_key),
            source_fingerprint,
        )
    state = GenState(
        phase="ocr" if convert_pgs else "preparing",
        **stored_fields(
            "library.subtitleJob.resume"
            if input_data.get("resume")
            else "library.subtitleJob.preparing"
        ),
        uses_ocr=convert_pgs,
        target_language=target_language,
        secondary_language=str(secondary_language) if secondary_language else None,
        source_candidate_key=str(source_candidate_key) if source_candidate_key else None,
    )
    cancelled = asyncio.Event()
    runner = asyncio.create_task(
        _run(
            file_id,
            target_language,
            state,
            convert_pgs=convert_pgs,
            pgs_ocr_language=str(pgs_ocr_language) if pgs_ocr_language else None,
            secondary_language=str(secondary_language) if secondary_language else None,
            source_candidate_key=(str(source_candidate_key) if source_candidate_key else None),
            model_ref=str(model_ref) if model_ref else None,
            job_id=getattr(context, "job_id", None),
            cancelled=cancelled.is_set,
        ),
        name=f"subtitle-pipeline-{file_id}",
    )
    last_snapshot: dict[str, object] | None = None
    last_usage: dict[str, object] | None = None
    try:
        while not runner.done():
            if await context.cancel_requested():
                cancelled.set()
                # 读取 / 识别 / 同步检查都在等外部进程，没有要保住的模型结果：
                # 直接取消执行协程，ffmpeg、seconv 随之整组结束，「停止」秒级
                # 生效。翻译阶段仍走协作式停止，让在途、已付费的块写进断点。
                if state.phase in _STOP_AT_ONCE_PHASES and not runner.cancelling():
                    runner.cancel()
            snapshot = _job_progress(state)
            usage = state.llm_usage.snapshot()
            if snapshot != last_snapshot or usage != last_usage:
                await context.update_progress(  # type: ignore[arg-type]
                    **snapshot,
                    usage=usage,
                )
                last_snapshot = snapshot
                last_usage = usage
            # asyncio.wait 只等不取消，也不把执行协程的异常或取消抛到这里
            await asyncio.wait({runner}, timeout=0.75)
        if runner.cancelled():
            raise jobs.JobCancelled
        result = await runner
    except translate.TranslationAborted as exc:
        if cancelled.is_set() or await context.cancel_requested():
            raise jobs.JobCancelled from exc
        # 「重试」沿用任务创建时固定的模型（见 input_data.model_ref 的注释）：
        # 模型本身就是失败原因时，重试只会原样再失败一次。把固定的模型写进
        # 错误信息，并给出改默认模型的入口——改完重新发起生成即可换模型续译。
        raise jobs.JobFailed(
            **stored_fields(
                "library.subtitleJob.aborted",
                reason=exc.reference or str(exc),
                model=model_ref or reference("library.subtitleJob.defaultModel"),
            ),
            code="SUBTITLE_TRANSLATION_ABORTED",
            actions=[
                {
                    "type": "open_settings",
                    "label": "调整 AI 模型",
                    "label_key": "library.subtitleJob.adjustModel",
                    "target": "llm",
                },
                {"type": "retry_job", "label": "重试", "label_key": "activity.jobs.retry"},
                {
                    "type": "handoff_agent",
                    "label": "交给 Agent",
                    "label_key": "activity.jobs.agent",
                },
            ],
        ) from exc
    except AppException as exc:
        if _model_setup_problem(exc.message, exc.message_key, exc.params):
            raise jobs.JobBlocked(
                exc.message,
                message_key=exc.message_key,
                message_params=exc.params,
                code="SUBTITLE_MODEL_UNAVAILABLE",
                actions=[
                    {
                        "type": "open_settings",
                        "label": "配置 AI 模型",
                        "label_key": "library.subtitleJob.configureModel",
                        "target": "llm",
                    },
                    {
                        "type": "retry_job",
                        "label": "配置后重试",
                        "label_key": "library.subtitleJob.retryConfigured",
                    },
                    {
                        "type": "handoff_agent",
                        "label": "交给 Agent",
                        "label_key": "activity.jobs.agent",
                    },
                ],
            ) from exc
        raise jobs.JobFailed(
            exc.message,
            message_key=exc.message_key,
            message_params=exc.params,
            code="SUBTITLE_GENERATION_FAILED",
            actions=[
                {"type": "handoff_agent", "label": "交给 Agent", "label_key": "activity.jobs.agent"}
            ],
        ) from exc
    except (LlmConnectError, LlmServerError, LlmRateLimitError) as exc:
        # 连不上、供应商 5xx：多半过一会儿自己恢复。说清楚是模型服务的问题、已完成
        # 的块都在断点里，交给调度器稍后自动重试——此前这里落进「未知错误」，
        # 用户只看到一句「任务遇到临时异常」，重试用尽后是「发生未知错误」。
        raise jobs.JobRetry(
            **stored_fields("library.subtitleJob.modelUnavailable", reason=_brief(exc)),
            delay_seconds=_MODEL_RETRY_DELAY_SECONDS,
            code="SUBTITLE_MODEL_TEMPORARILY_UNAVAILABLE",
            actions=[
                {"type": "retry_job", "label": "重试", "label_key": "activity.jobs.retry"},
                {
                    "type": "handoff_agent",
                    "label": "交给 Agent",
                    "label_key": "activity.jobs.agent",
                },
            ],
        ) from exc
    except LlmAuthError as exc:
        # API Key 失效重试多少次都一样：停在 blocked，引导去设置里修
        raise jobs.JobBlocked(
            **stored_fields("library.subtitleJob.modelAuthFailed", reason=_brief(exc)),
            code="SUBTITLE_MODEL_AUTH_FAILED",
            actions=[
                {
                    "type": "open_settings",
                    "label": "检查 AI 模型设置",
                    "label_key": "library.subtitleJob.checkModel",
                    "target": "llm",
                },
                {
                    "type": "retry_job",
                    "label": "修改后重试",
                    "label_key": "library.subtitleJob.retryModified",
                },
                {
                    "type": "handoff_agent",
                    "label": "交给 Agent",
                    "label_key": "activity.jobs.agent",
                },
            ],
        ) from exc
    except LlmError as exc:
        # 请求被拒（参数、上下文超长、内容审查）：原样说明原因，不做无意义的自动重试
        raise jobs.JobFailed(
            **stored_fields("library.subtitleJob.modelRejected", reason=_brief(exc)),
            code="SUBTITLE_MODEL_REQUEST_FAILED",
            actions=[
                {"type": "retry_job", "label": "重试", "label_key": "activity.jobs.retry"},
                {
                    "type": "handoff_agent",
                    "label": "交给 Agent",
                    "label_key": "activity.jobs.agent",
                },
            ],
        ) from exc
    finally:
        # 进度持久化失败等异常也必须回收领域协程；否则 dispatcher 已把 Job
        # 转入重试，旧翻译却仍在后台调用模型，造成重复费用和产物写入竞态。
        if not runner.done():
            runner.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await runner

    snapshot = _job_progress(state)
    usage = state.llm_usage.snapshot()
    if snapshot != last_snapshot or usage != last_usage:
        await context.update_progress(  # type: ignore[arg-type]
            **snapshot,
            usage=usage,
        )
    result.finished_at = utcnow()
    if not result.ok:
        if await context.cancel_requested():
            raise jobs.JobCancelled
        actions: list[dict[str, object]] = [
            {"type": "retry_job", "label": "重试", "label_key": "activity.jobs.retry"},
            {"type": "handoff_agent", "label": "交给 Agent", "label_key": "activity.jobs.agent"},
        ]
        if _model_setup_problem(result.message, result.message_key, result.message_params):
            raise jobs.JobBlocked(
                result.message,
                message_key=result.message_key,
                message_params=result.message_params,
                code="SUBTITLE_MODEL_UNAVAILABLE",
                actions=[
                    {
                        "type": "open_settings",
                        "label": "配置 AI 模型",
                        "label_key": "library.subtitleJob.configureModel",
                        "target": "llm",
                    },
                    {
                        "type": "retry_job",
                        "label": "配置后重试",
                        "label_key": "library.subtitleJob.retryConfigured",
                    },
                    {
                        "type": "handoff_agent",
                        "label": "交给 Agent",
                        "label_key": "activity.jobs.agent",
                    },
                ],
            )
        raise jobs.JobFailed(
            result.message,
            message_key=result.message_key,
            message_params=result.message_params,
            code="SUBTITLE_GENERATION_FAILED",
            actions=actions,
        )
    return _result_payload(result)


_T = TypeVar("_T")
_READ_PROGRESS_INTERVAL = 1.0


def _clock(seconds: float) -> str:
    hours, rest = divmod(int(seconds), 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


async def _reading(state: GenState, row: LibraryFile, work: Awaitable[_T]) -> _T:
    """等待整文件通读，同时把「排队中 / 已读到哪」同步进任务进度。

    大文件在 NAS 上要读几分钟：用户得看见它在动、读到了哪、为什么慢——同一
    时间只通读一个文件，排在别的文件后面时明说。取消任务时读取随之取消。
    """
    state.phase = "extracting"
    state.set_message("library.subtitleJob.reading")
    state.extract_duration_seconds = row.duration_seconds
    follower = asyncio.create_task(
        _follow_read_progress(state, row), name="subtitle-read-progress"
    )
    try:
        return await work
    finally:
        follower.cancel()
        state.extract_queued = False
        state.phase = "preparing"
        state.set_message("library.subtitleJob.checkingSource")


async def _follow_read_progress(state: GenState, row: LibraryFile) -> None:
    duration = row.duration_seconds
    while True:
        progress = await asyncio.to_thread(media_extract.read_progress, row)
        if progress is not None and progress.queued:
            state.extract_queued = True
            state.set_message("library.subtitleJob.queuedRead")
        elif progress is not None:
            state.extract_queued = False
            state.extract_position_seconds = progress.position_seconds
            if progress.position_seconds is not None and duration:
                state.set_message(
                    "library.subtitleJob.readPosition",
                    position=_clock(progress.position_seconds),
                    duration=_clock(duration),
                )
            else:
                state.set_message("library.subtitleJob.reading")
        await asyncio.sleep(_READ_PROGRESS_INTERVAL)


async def _run(
    file_id: int,
    target_language: str,
    state: GenState,
    *,
    convert_pgs: bool = False,
    pgs_ocr_language: str | None = None,
    secondary_language: str | None = None,
    source_candidate_key: str | None = None,
    model_ref: str | None = None,
    job_id: str | None = None,
    cancelled: Callable[[], bool],
) -> GenResult:
    target_language, secondary_language = ensure_output_languages(
        target_language, secondary_language
    )
    db = get_database()
    async with db.session() as session:
        row = await _load_row(session, file_id)
        ctx, original_language = await _film_context(session, row)
        chat = await _build_chat(
            session,
            model_ref=model_ref,
            job_id=job_id,
            usage=state.llm_usage,
        )

    source_target = target_language if secondary_language is None else "__bilingual__"
    ranked = source.rank_candidates(
        row, original_language=original_language, target_language=source_target
    )
    try:
        selected = _select_reference(ranked, source_candidate_key)
    except BadRequestException as exc:
        return GenResult(
            ok=False, message=exc.message, message_key=exc.message_key, message_params=exc.params
        )
    state.source_candidate_key = candidate_key(selected) if selected is not None else None
    selected_candidates = [selected] if selected is not None else []
    warnings: list[str] = []
    warning_messages: list[dict] = []
    state.phase = "preparing"
    state.set_message("library.subtitleJob.selecting")
    needs_reading = (
        selected is not None
        and not selected.excluded
        and await asyncio.to_thread(extract.needs_extraction, row, selected.candidate)
    )
    if needs_reading:
        chosen, events = await _reading(
            state,
            row,
            _pick_loadable(row, selected_candidates, warnings, warning_messages=warning_messages),
        )
    else:
        chosen, events = await _pick_loadable(
            row, selected_candidates, warnings, warning_messages=warning_messages
        )
    source_desc: str | None = None
    source_message = None
    if chosen is None and convert_pgs:
        plan = await _pgs_plan(
            row,
            selected_candidates,
            original_language=original_language,
            requested_candidate_key=(candidate_key(selected) if selected is not None else None),
            requested_ocr_language=pgs_ocr_language,
        )
        if plan is None:
            return GenResult(ok=False, **stored_fields("library.subtitleJob.pgsChanged"))
        if not plan.capability.available:
            return GenResult(
                ok=False,
                **stored_fields(
                    "library.subtitleJob.ocrUnavailable",
                    reason=plan.capability.message_ref or plan.capability.message,
                ),
            )
        if not plan.capability.cached and plan.language.code is None:
            return GenResult(ok=False, **stored_fields("library.subtitleJob.languageUnconfirmed"))
        pgs_candidate = plan.candidate.candidate
        try:
            if plan.capability.cached:
                ocr_path = pgs.cached_srt_path(row, pgs_candidate, plan.language.code)
            else:
                # .sup 走与播放器共用的整文件抽取：同一趟通读、同一份缓存，
                # 读取阶段同样有进度、可取消。
                sup_path = await _reading(state, row, pgs.extract_sup(row, pgs_candidate))
                state.phase = "ocr"
                state.set_message("library.subtitleJob.recognizing")
                ocr_path = await pgs.ocr_to_srt(
                    row, pgs_candidate, plan.capability, plan.language.code, sup_path
                )
            raw = await asyncio.to_thread(ocr_path.read_bytes)
            events = extract.parse_events(
                extract.decode_subtitle_bytes(raw, str(ocr_path)), str(ocr_path)
            )
        except (OSError, extract.SourceLoadError, pgs.PgsConversionError) as exc:
            return GenResult(
                ok=False,
                **stored_fields(
                    "library.subtitleJob.ocrIncomplete",
                    reason=getattr(exc, "reference", None) or str(exc),
                ),
            )
        if cancelled():
            raise translate.TranslationAborted(stored_fields("library.subtitleJob.ocrStopped"))
        assessment = source.assess_events(events, row.duration_seconds)
        if not assessment.ok:
            return GenResult(
                ok=False,
                **stored_fields(
                    "library.subtitleJob.ocrAssessment",
                    reason=assessment.reason_message or assessment.reason,
                ),
            )
        # OCR 不是只能服务当前这次 AI 翻译的临时步骤。完整度达标后立即规范化
        # 为 UTF-8 SRT 外挂；即使后续模型失败，这份耗时得到的文本以后仍可预览、
        # 校准或作为其他语言任务的参考。
        ocr_sidecar = _pgs_sidecar_path(row, plan.language.code or "und")
        try:
            await asyncio.to_thread(translate.write_srt, events, ocr_sidecar)
        except OSError as exc:
            return GenResult(
                ok=False,
                **stored_fields("library.subtitleJob.ocrWriteFailed", path=ocr_sidecar, detail=exc),
            )
        await _refresh_subtitle_inventory(db, file_id)
        chosen = plan.candidate
        chosen.reasons.append(
            # i18n-ignore: model prompt, task log detail or internal retry signal
            f"PGS 以 {plan.language.label or '已确认语言'}"
            # i18n-ignore: model prompt, task log detail or internal retry signal
            f"经 {plan.capability.engine or 'OCR'} 转为 SRT"
        )
        chosen.reasons.append(assessment.reason)
        source_message = stored_fields(
            "library.subtitleJob.ocrSource", source=_cand_message(chosen.candidate)
        )
        source_desc = source_message["message"]
    if chosen is None:
        detail = (
            {"message_list": warning_messages, "separator_key": "library.subtitleJob.separator"}
            if warnings
            else reference("library.subtitleJob.noText")
        )
        return GenResult(
            ok=False, **stored_fields("library.subtitleJob.unusableReference", reason=detail)
        )
    if source_desc is None:
        source_message = _cand_message(chosen.candidate)
        source_desc = source_message["message"]
    logger.info(
        "字幕生成选源：%s ← %s（%s）", row.file_path, source_desc, "；".join(chosen.reasons)
    )

    # L1 同步质检（§5.2）：错位参考在烧 LLM 钱之前拦下；无法检测按未知放行
    state.phase = "syncing"
    state.set_message("library.subtitleJob.syncing")
    state.total_events = len(events)
    sync_score = await sync.sample_sync_score(
        Path(row.file_path), events, row.duration_seconds, sync.audio_index(row.audio_streams)
    )
    if sync_score is not None and sync_score < sync.SYNC_THRESHOLD:
        return GenResult(
            ok=False,
            sync_score=sync_score,
            source_desc=source_desc,
            source_message=source_message,
            **stored_fields(
                "library.subtitleJob.unsynced",
                source=source_message,
                score=sync_score,
                threshold=sync.SYNC_THRESHOLD,
            ),
        )

    def _phase(phase: str, message: dict) -> None:
        state.phase = phase
        state.message = message["message"]
        state.message_key = message["message_key"]
        state.message_params = message["message_params"]
        state.active_blocks = ()
        state.oldest_active_seconds = 0

    def _progress(progress: translate.TranslationProgress) -> None:
        state.done_blocks = progress.done_blocks
        state.total_blocks = progress.total_blocks
        state.done_events = progress.done_events
        state.total_events = progress.total_events
        state.active_blocks = progress.active_blocks
        state.parallelism = progress.concurrency
        state.oldest_active_seconds = progress.oldest_active_seconds
        state.last_completed_seconds_ago = progress.last_completed_seconds_ago
        state.validation_retries = progress.validation_retries
        state.rate_limit_count = progress.rate_limit_count
        if state.phase == "translating" and progress.active_blocks:
            active_count = len(progress.active_blocks)
            if progress.done_blocks == 0:
                state.set_message("library.subtitleJob.firstBlocks", count=active_count)
            else:
                state.set_message(
                    "library.subtitleJob.activeBlocks",
                    done=progress.done_blocks,
                    total=progress.total_blocks,
                    active=active_count,
                )

    out_events, stats = await translate.translate_events(
        chat,
        events,
        ctx,
        target_language,
        file_id=file_id,
        secondary_language=secondary_language,
        progress=_progress,
        phase=_phase,
        cancelled=cancelled,
    )

    state.phase = "validating"
    state.set_message("library.subtitleJob.validating")
    state.active_blocks = ()
    final_events, report = validate.finalize_events(
        out_events,
        stats.glossary,
        target_language=target_language,
        secondary_language=secondary_language,
    )
    # 超读速二次压缩（§3.3"浓缩优先"的闭环）：只回炉超标子集（通常 <10%），
    # 压缩失败保留原译文——这是增益项，绝不因它废任务
    compressed = 0
    overruns = validate.overrun_indices(
        final_events,
        target_language=target_language,
        secondary_language=secondary_language,
    )
    # 双语的两行就是语种边界，压缩模型再次改写容易破坏严格两行结构；本期
    # 对双语只报告超读速，由首次翻译提示词负责浓缩。
    if overruns and secondary_language is None:
        state.phase = "compressing"
        state.set_message("library.subtitleJob.compressing", count=len(overruns))
        refined, compressed = await translate.compress_overruns(
            chat,
            final_events,
            overruns,
            ctx,
            target_language,
            secondary_language,
            glossary=stats.glossary,
        )
        if compressed:
            final_events, report = validate.finalize_events(
                refined,
                stats.glossary,
                target_language=target_language,
            )
    report.kept_original = stats.kept_original
    report.compressed = compressed

    state.phase = "writing"
    state.set_message("library.subtitleJob.writing")
    sidecar = _sidecar_path(row, target_language, secondary_language)
    try:
        await asyncio.to_thread(translate.write_srt, final_events, sidecar)
    except OSError as exc:
        return GenResult(
            ok=False,
            **stored_fields("library.subtitleJob.writeFailed", path=sidecar, detail=exc),
        )
    if secondary_language is None:
        legacy_sidecar = _legacy_sidecar_path(row, target_language)
        if legacy_sidecar != sidecar and legacy_sidecar.exists():
            try:
                await asyncio.to_thread(legacy_sidecar.unlink)
                logger.info("旧版 AI 字幕已迁移为规范文件名：%s → %s", legacy_sidecar, sidecar)
            except OSError as exc:
                # 新文件已经原子写成，旧文件清理失败不应让整次付费生成报失败；
                # 台账会同时展示两份，日志给出管理员可定位的明确原因。
                logger.warning("旧版 AI 字幕清理失败：%s（%s）", legacy_sidecar, exc)
    translate.Checkpoint(
        file_id,
        subtitle_output_key(target_language, secondary_language),
        translate.source_fingerprint(events, target_language, secondary_language),
    ).discard()

    # 台账即时刷新（不等 watchdog）：任务结束播放器立刻可选
    state.phase = "refreshing"
    state.set_message("library.subtitleJob.refreshing")
    await _refresh_subtitle_inventory(db, file_id)

    message = stored_fields(
        "library.subtitleJob.completed",
        filename=sidecar.name,
        source=source_message,
        count=report.event_count,
        failed=stats.failed_blocks,
        compressed=report.compressed,
        overrun=report.cps_overrun,
    )
    logger.info("字幕生成完成：%s", message["message"])
    return GenResult(
        ok=True,
        **message,
        filename=sidecar.name,
        report=report,
        sync_score=sync_score,
        source_desc=source_desc,
        source_message=source_message,
    )


async def _refresh_subtitle_inventory(db, file_id: int) -> None:  # noqa: ANN001
    """按磁盘现场刷新单文件字幕台账；PGS 中间产物与 AI 成品共用。"""
    async with db.session() as session:
        row = await _load_row(session, file_id)
        row.external_subtitles = await asyncio.to_thread(
            discover_external_subtitles, Path(row.file_path)
        )
        row.updated_at = utcnow()
        await session.commit()


async def _build_chat(
    session: AsyncSession,
    *,
    model_ref: str | None = None,
    job_id: str | None = None,
    usage: SubtitleLlmUsage | None = None,
) -> translate.ChatFn:
    """movieclaw_llm 路由 → 字幕专用结构化生成，并记录任务级用量。"""
    from movieclaw_api.services.llm_config import acquire_llm_router
    from movieclaw_llm import (
        ChatMessage,
        ChatRequest,
        LlmRateLimitError,
        LlmRoutingError,
        ModelSettings,
    )

    router = await acquire_llm_router(session)
    try:
        provider, resolved_model = router.resolve(model_ref or "")
    except LlmRoutingError as exc:
        raise BadRequestException(
            message_key="errors.subtitles.modelUnavailable", params={"error": exc}
        ) from exc
    # K2.5/K2.6 官方默认为深度思考；字幕逐条映射不需要长推理。只在官方
    # Kimi 方言上发送已确认支持的参数，不把私有字段泄漏给其他兼容端点。
    kimi_fast_json = provider.provider_type == "kimi" and resolved_model in {
        "kimi-k2.5",
        "kimi-k2.6",
    }

    async def chat(system: str, user: str, call: translate.ChatCall) -> str:
        # 不设 max_tokens：让模型有多少写多少，交给供应商按剩余上下文兜底
        # （与 agent 侧一致）。曾经按条数估算输出预算，结果是深度思考模型的
        # 思考先烧光额度、译文 JSON 半截被 finish=length 截断（issue #194）。
        # 上限并不省钱——被截断的响应照样全额计费却零可用产出，等于把「付一次
        # 拿到一个块」换成「付三次什么都没有」。真正的成本闸门是块重试上限和
        # 失败率熔断，它们按「块」计价，比按 token 猜一个数字可靠得多。
        settings = ModelSettings(
            response_format="json_object" if kimi_fast_json else None,
            extra_body=({"thinking": {"type": "disabled"}} if kimi_fast_json else None),
        )
        started = time.monotonic()
        try:
            response = await router.chat(
                ChatRequest(
                    model=model_ref or "",
                    messages=[
                        ChatMessage(role="system", content=system),
                        ChatMessage(role="user", content=user),
                    ],
                    settings=settings,
                )
            )
        except LlmRateLimitError as exc:
            duration_ms = max(1, int((time.monotonic() - started) * 1000))
            if usage is not None:
                usage.record_failure(call, duration_ms=duration_ms, error_code="rate_limit")
            logger.warning(
                "字幕模型调用限流 job=%s purpose=%s block=%s attempt=%d 耗时=%dms",
                job_id or "-",
                call.purpose,
                call.block_index or "-",
                call.attempt,
                duration_ms,
            )
            # 翻译层只认识统一限流信号，不依赖具体供应商或 OpenAI SDK；
            # 调度器据此降低并发、按 Retry-After 退避并重试当前块。
            raise translate.ChatRateLimited(exc.retry_after) from exc
        except LlmRoutingError as exc:
            duration_ms = max(1, int((time.monotonic() - started) * 1000))
            if usage is not None:
                usage.record_failure(call, duration_ms=duration_ms, error_code="routing")
            # Job 会固定创建时的供应商/模型；配置之后被停用或删除时不能静默
            # 换模型，否则同一任务重试的结果不可复现。转成业务异常后，持久化
            # 调度器会把任务置为 blocked，并给前端与 Agent 返回恢复配置的动作。
            raise BadRequestException(
                message_key="errors.subtitles.modelUnavailable", params={"error": exc}
            ) from exc
        except Exception as exc:
            duration_ms = max(1, int((time.monotonic() - started) * 1000))
            if usage is not None:
                usage.record_failure(
                    call,
                    duration_ms=duration_ms,
                    error_code=type(exc).__name__,
                )
            logger.warning(
                "字幕模型调用失败 job=%s purpose=%s block=%s attempt=%d 耗时=%dms：%s",
                job_id or "-",
                call.purpose,
                call.block_index or "-",
                call.attempt,
                duration_ms,
                exc,
            )
            raise
        duration_ms = max(1, int((time.monotonic() - started) * 1000))
        if usage is not None:
            usage.record_success(
                call,
                duration_ms=duration_ms,
                prompt_tokens=response.usage.prompt_tokens,
                completion_tokens=response.usage.completion_tokens,
                total_tokens=response.usage.total_tokens,
                cache_read_tokens=response.usage.cache_read_tokens,
                finish_reason=response.finish_reason,
                has_thinking=bool(response.thinking),
            )
        logger.info(
            "字幕模型调用完成 job=%s purpose=%s block=%s attempt=%d model=%s "
            "耗时=%dms tokens=%d/%d thinking=%s finish=%s",
            job_id or "-",
            call.purpose,
            call.block_index or "-",
            call.attempt,
            response.model or resolved_model,
            duration_ms,
            response.usage.prompt_tokens,
            response.usage.completion_tokens,
            bool(response.thinking),
            response.finish_reason,
        )
        if response.finish_reason == "length":
            # 专属信号：翻译层据此把块对半拆开重译。原样重发只会再次被截断——
            # 撞的是供应商天花板。深度思考模型是这里最常见的触发者。
            raise translate.ChatOutputTruncated(
                # i18n-ignore: model prompt, task log detail or internal retry signal
                "模型写到自身输出上限仍未写完译文"
                f"（本次思考+正文共 {response.usage.completion_tokens} tokens）"
            )
        if response.finish_reason == "tool_calls":
            # i18n-ignore: model prompt, task log detail or internal retry signal
            raise ValueError("字幕模型返回了意外的工具调用，正在重试结构化输出")
        return response.content or ""

    return chat


# ---------------------------------------------------------------------------
# 一键校准已有外挂字幕（§5.4：独立工具，不依赖 LLM、零调用成本）
# ---------------------------------------------------------------------------


@dataclass
class CalibrateResult:
    ok: bool
    message: str
    scale: float | None = None
    offset_ms: int | None = None
    score: float | None = None

    message_key: str | None = None
    message_params: dict = field(default_factory=dict)


#: 校准结论可信度下限：相关峰太低说明参考与字幕根本对不上（如错片字幕）
_CALIBRATE_MIN_SCORE = 0.15
#: 变化小于该量级视为"本就同步"，不动文件
_NOOP_OFFSET_MS = 200


#: 校准参考的抽样窗：沿时间轴均布 6 窗 × 2 分钟。稀疏参考不影响互相关
#: 峰位置（匹配发生在有信号处,错位处只加常数底噪）,却把 2 小时片的
#: 音频解码从整片降到 12 分钟——校准在 HTTP 请求内即可完成,不必转后台
_CALIBRATE_WINDOWS = 6
_CALIBRATE_WINDOW_S = 120


async def _audio_reference_intervals(
    row: LibraryFile, events: list[extract.SubEvent]
) -> list[tuple[int, int]] | None:
    """抽样语音区间（校准参考,映射回全片时间坐标）;无 ffmpeg/无音轨返回 None。"""
    runtime = row.duration_seconds or (max(e[1] for e in events) // 1000 if events else 0)
    if runtime <= 0:
        return None
    if runtime <= _CALIBRATE_WINDOWS * _CALIBRATE_WINDOW_S:
        starts = [0]
        window = float(runtime)
    else:
        # 均布起点,避开首尾 5%（片头 logo/片尾字幕常无对白）
        usable = runtime * 0.9
        step = usable / _CALIBRATE_WINDOWS
        starts = [int(runtime * 0.05 + i * step) for i in range(_CALIBRATE_WINDOWS)]
        window = float(_CALIBRATE_WINDOW_S)
    intervals: list[tuple[int, int]] = []
    audio = sync.audio_index(row.audio_streams)
    for start in starts:
        pcm = await sync.extract_pcm(Path(row.file_path), float(start), window, audio)
        if pcm is None:
            return intervals if intervals else None  # 首窗就失败=不可用
        speech = await asyncio.to_thread(sync.speech_intervals, pcm)
        intervals.extend((s + start * 1000, e + start * 1000) for s, e in speech)
    return intervals


async def _subtitle_reference_intervals(
    row: LibraryFile, exclude_filename: str
) -> tuple[list[tuple[int, int]] | None, dict | None]:
    """字幕对字幕兜底（L2'）：本文件另一条字幕的时间结构做参考。

    参考优先内封轨（配套概率最高）,其次其他外挂;返回 (区间表, 参考描述)。
    """
    ranked = source.rank_candidates(row, original_language=None, target_language="__none__")
    for cand in ranked:
        if cand.excluded and "forced" in cand.excluded:
            continue  # forced 轨时间结构残缺,不做参考;其余排除原因不影响对齐
        if cand.candidate.kind == "external" and cand.candidate.key == exclude_filename:
            continue
        try:
            events = await extract.load_candidate_events(row, cand.candidate)
        except extract.SourceLoadError:
            continue
        if len(events) >= 50:
            return [(s, e) for s, e, _ in events], _cand_message(cand.candidate)
    return None, None


async def calibrate_external_subtitle(
    session: AsyncSession, file_id: int, filename: str
) -> CalibrateResult:
    """校准一条外挂字幕并覆盖写回（UTF-8）;台账即时刷新。

    参考优先音轨（真相源）,无音频（strm/无 ffmpeg）退字幕对字幕;两者都
    不可用如实报错。校准量小于噪声阈值时不动文件（"本就同步"）。
    """
    if "/" in filename or "\\" in filename or filename.startswith("."):
        raise BadRequestException(
            message_key="errors.subtitles.filenameInvalid", params={"name": f"{filename!r}"}
        )
    row = await _load_row(session, file_id)
    entry = next(
        (e for e in row.external_subtitles or [] if e.get("filename") == filename),
        None,
    )
    if entry is None:
        # 台账兜底：旧行（NULL，未重扫）或刚放入的文件——控制台详情页展示
        # 的是磁盘现场清单，按现场重新发现一次，别让用户先扫库再校准
        discovered = await asyncio.to_thread(discover_external_subtitles, Path(row.file_path))
        entry = next((e for e in discovered if e.get("filename") == filename), None)
        if entry is None:
            raise NotFoundException(
                message_key="errors.subtitles.externalMissing", params={"name": filename}
            )
    cand = source.SourceCandidate(
        kind="external",
        key=filename,
        language=entry.get("language"),
        forced=bool(entry.get("forced")),
        sdh=bool(entry.get("sdh")),
        format=str(entry.get("format") or "").lower(),
    )
    events = await extract.load_candidate_events(row, cand)
    if len(events) < 20:
        return CalibrateResult(ok=False, **stored_fields("library.subtitleCalibration.tooFew"))

    reference = await _audio_reference_intervals(row, events)
    ref_desc = stored_fields("library.subtitleCalibration.audioReference")
    if not reference:
        reference, ref_desc = await _subtitle_reference_intervals(row, filename)
        if not reference:
            return CalibrateResult(
                ok=False,
                **stored_fields("library.subtitleCalibration.noReference"),
            )

    calibration = sync.estimate_calibration(reference, [(s, e) for s, e, _ in events])
    if calibration is None or calibration.score < _CALIBRATE_MIN_SCORE:
        return CalibrateResult(
            ok=False,
            **stored_fields("library.subtitleCalibration.lowConfidence", reference=ref_desc),
            score=calibration.score if calibration else None,
        )
    if calibration.scale == 1.0 and abs(calibration.offset_ms) <= _NOOP_OFFSET_MS:
        return CalibrateResult(
            ok=True,
            **stored_fields("library.subtitleCalibration.alreadySynced", reference=ref_desc),
            scale=1.0,
            offset_ms=calibration.offset_ms,
            score=calibration.score,
        )

    corrected = sync.apply_calibration(events, calibration)
    path = Path(row.file_path).parent / filename
    suffix = path.suffix.lstrip(".").lower()
    try:
        if suffix == "srt":
            await asyncio.to_thread(translate.write_srt, corrected, path)
        else:
            # 非 srt（ass/ssa/vtt）：pysubs2 原格式平移缩放后写回,样式保留
            await asyncio.to_thread(_shift_subtitle_file, path, calibration)
    except OSError as exc:
        return CalibrateResult(
            ok=False, **stored_fields("library.subtitleCalibration.writeFailed", detail=exc)
        )

    async with get_database().session() as refresh_session:
        fresh = await _load_row(refresh_session, file_id)
        fresh.external_subtitles = await asyncio.to_thread(
            discover_external_subtitles, Path(fresh.file_path)
        )
        fresh.updated_at = utcnow()
        await refresh_session.commit()

    logger.info(
        "外挂字幕校准完成：%s scale=%.6f offset=%dms score=%.2f 参考=%s",
        path,
        calibration.scale,
        calibration.offset_ms,
        calibration.score,
        ref_desc["message"],
    )
    return CalibrateResult(
        ok=True,
        **stored_fields(
            "library.subtitleCalibration.completed",
            reference=ref_desc,
            scale=calibration.scale,
            offset=calibration.offset_ms / 1000,
        ),
        scale=calibration.scale,
        offset_ms=calibration.offset_ms,
        score=calibration.score,
    )


def _shift_subtitle_file(path: Path, calibration: sync.Calibration) -> None:
    """（线程池）非 srt 字幕的原格式校准写回（保留 ass 样式）。"""
    import pysubs2

    raw = path.read_bytes()
    text = extract.decode_subtitle_bytes(raw, str(path))
    subs = pysubs2.SSAFile.from_string(text)
    for line in subs:
        line.start = max(0, int(line.start * calibration.scale) + calibration.offset_ms)
        line.end = max(line.start, int(line.end * calibration.scale) + calibration.offset_ms)
    fmt = {"ssa": "ssa", "ass": "ass", "vtt": "vtt"}.get(path.suffix.lstrip(".").lower(), "srt")
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_text(subs.to_string(fmt), encoding="utf-8")
    tmp.replace(path)
