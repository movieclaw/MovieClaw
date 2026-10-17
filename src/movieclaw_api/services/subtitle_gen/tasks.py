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
    message: str = "正在准备"
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


async def _load_row(session: AsyncSession, file_id: int) -> LibraryFile:
    row = (
        await session.execute(select(LibraryFile).where(LibraryFile.id == file_id))
    ).scalar_one_or_none()
    if row is None or row.state != FileState.IN_PLACE:
        raise NotFoundException(f"文件不存在或已丢失：id={file_id}")
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
OUTPUT_LANGUAGES: dict[str, str] = {
    "chs": "简体中文",
    "cht": "繁体中文",
    "eng": "英语",
    "jpn": "日语",
    "kor": "韩语",
    "fre": "法语",
    "ger": "德语",
    "spa": "西班牙语",
    "ita": "意大利语",
    "por": "葡萄牙语",
    "rus": "俄语",
    "tha": "泰语",
}
_FILENAME_LANGUAGE = {"chs": "chi", "cht": "chi"}
_LANGUAGE_TOKEN = _re.compile(r"^[a-z0-9-]{2,16}$")


def ensure_language_token(target_language: str) -> str:
    token = target_language.strip().lower()
    if not _LANGUAGE_TOKEN.fullmatch(token):
        raise BadRequestException(
            f"目标语言 token 不合法：{target_language!r}"
            "（只允许 2-16 位小写字母/数字/连字符，如 chs）"
        )
    return token


def ensure_output_languages(
    target_language: str, secondary_language: str | None = None
) -> tuple[str, str | None]:
    """校验用户选择的单语/双语输出；双语两行不能选择同一种语言。"""
    target = ensure_language_token(target_language)
    secondary = ensure_language_token(secondary_language) if secondary_language else None
    if target not in OUTPUT_LANGUAGES:
        raise BadRequestException(f"暂不支持生成 {target} 字幕")
    if secondary is not None and secondary not in OUTPUT_LANGUAGES:
        raise BadRequestException(f"暂不支持生成 {secondary} 字幕")
    if secondary == target:
        raise BadRequestException("双语字幕的第一行和第二行不能选择同一种语言")
    return target, secondary


def subtitle_output_key(target_language: str, secondary_language: str | None = None) -> str:
    target, secondary = ensure_output_languages(target_language, secondary_language)
    return target if secondary is None else f"{target}-{secondary}"


def subtitle_output_label(target_language: str, secondary_language: str | None = None) -> str:
    target, secondary = ensure_output_languages(target_language, secondary_language)
    if secondary is None:
        return OUTPUT_LANGUAGES[target]
    return f"{OUTPUT_LANGUAGES[target]} + {OUTPUT_LANGUAGES[secondary]}双语"


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


@dataclass(frozen=True)
class PreviewBlocker:
    """预检未通过时面向产品层的结构化解释，而不是一条不可行动的错误。"""

    code: str
    title: str
    message: str
    suggestions: list[str]


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
        raise BadRequestException("参考字幕标识不合法，请重新预检")
    if kind == "external":
        known = {str(item.get("filename")) for item in row.external_subtitles or []}
        if key not in known:
            raise BadRequestException("所选参考字幕已不存在，请重新扫描后再试")
        path = Path(row.file_path).parent / key
    else:
        path = Path(row.file_path)
    try:
        stat = await asyncio.to_thread(path.stat)
    except OSError as exc:
        raise BadRequestException("参考字幕暂时无法读取，请检查文件后重试") from exc
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
            code="SUBTITLE_SOURCE_UNAVAILABLE",
            actions=[{"type": "handoff_agent", "label": "交给 Agent"}],
        ) from exc
    if actual != expected:
        raise jobs.JobFailed(
            "参考字幕或影片在排队期间发生了变化，请重新预检后再生成",
            code="SUBTITLE_SOURCE_CHANGED",
            actions=[{"type": "handoff_agent", "label": "交给 Agent"}],
        )


def _select_reference(
    ranked: list[source.RankedCandidate], requested_key: str | None
) -> source.RankedCandidate | None:
    """绑定用户指定候选；未指定时优先英语，再回退既有质量排序。"""
    if requested_key is not None:
        selected = next((item for item in ranked if candidate_key(item) == requested_key), None)
        if selected is None:
            raise BadRequestException("所选参考字幕已不存在，请重新选择")
        if not candidate_selectable(selected):
            raise BadRequestException(f"所选参考字幕不能用于翻译：{selected.excluded}")
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
            language = pgs.OcrLanguageDecision(
                code=selected,
                label=pgs.OCR_LANGUAGE_LABELS.get(selected) if selected else None,
                confirmation_required=selected is None,
                reason=(
                    f"已确认使用 {pgs.OCR_LANGUAGE_LABELS[selected]} 识别 PGS"
                    if selected
                    else f"不支持的 OCR 语言：{requested_ocr_language}"
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
                    language = pgs.OcrLanguageDecision(
                        code=None,
                        label=None,
                        confirmation_required=True,
                        reason=(
                            f"{language.reason}；但当前设备没有对应语言包，"
                            "请从实际可用语言中重新选择"
                        ),
                    )
                    if representative is not None:
                        capability = representative
        else:
            options, representative = await asyncio.to_thread(pgs.available_ocr_languages)
            capability = representative or await asyncio.to_thread(pgs.detect_capability, None)

        if capability.cached and language.confirmation_required:
            language = pgs.OcrLanguageDecision(
                code=language.code,
                label=language.label,
                confirmation_required=False,
                reason="已有可复用的 OCR 缓存，无需再次选择识别语言",
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


def _preview_blocker(
    ranked: list[source.RankedCandidate],
    pgs_plan: PgsConversionPlan | None = None,
    target_language: str = "chs",
    secondary_language: str | None = None,
    detail: str | None = None,
) -> PreviewBlocker:
    """把选源失败归纳为用户能理解、能继续处理的原因。

    ``detail`` 是所选参考字幕加载失败的具体原因（读取超时、完整度不够等），
    有就直接告诉用户，不再只给一句笼统的「不完整」。
    """
    output_label = subtitle_output_label(target_language, secondary_language)
    add_sidecar = "添加与当前片源匹配的 SRT、ASS 或 VTT 外挂字幕"
    rescan = "重新扫描媒体库后再试"

    if not ranked:
        return PreviewBlocker(
            code="no_subtitle",
            title="这份片源没有参考字幕",
            message="当前功能只翻译现有文本字幕，不会从音轨听写对白。",
            suggestions=[add_sidecar, rescan],
        )

    if pgs_plan is not None:
        capability = pgs_plan.capability
        language = pgs_plan.language.label or "待确认语言"
        if capability.available:
            if pgs_plan.language.confirmation_required:
                return PreviewBlocker(
                    code="pgs_conversion_required",
                    title="请确认字幕语言",
                    message=(
                        "这份字幕是图片，需要先识别其中的文字。"
                        f"请选择画面中实际显示的语言，再开始生成{output_label}字幕。"
                    ),
                    suggestions=[
                        f"这里选择的是原字幕语言，不是最终生成的{output_label}字幕语言",
                        "不确定时可以先播放影片查看字幕内容",
                    ],
                )
            return PreviewBlocker(
                code="pgs_conversion_required",
                title="先识别图片字幕",
                message=(
                    f"检测到{language}图片字幕。MovieClaw 会先识别文字，"
                    f"确认内容完整后再生成{output_label}字幕。"
                ),
                suggestions=[
                    "原影片和字幕不会被修改",
                    "识别结果可能有少量错字，完成后建议抽查人名与特殊字体",
                ],
            )
        return PreviewBlocker(
            code="pgs_conversion_unavailable",
            title="暂时无法识别这份字幕",
            message=(
                "当前设备还不能自动识别这份图片字幕。你可以按下面的建议处理，或交给 Agent 检查。"
            ),
            suggestions=list(capability.suggestions),
        )

    if all(c.exclusion_code in {"graphic", "pgs"} for c in ranked):
        return PreviewBlocker(
            code="graphics_only",
            title="暂时无法识别这份字幕",
            message=(f"检测到 {len(ranked)} 条图片字幕，但当前设备无法自动识别其中的文字。"),
            suggestions=[add_sidecar, rescan],
        )

    if all(c.exclusion_code == "target_language" for c in ranked):
        return PreviewBlocker(
            code="target_exists",
            title="已有目标语言字幕",
            message=f"检测到的字幕已经是{output_label}，无需再次生成。",
            suggestions=["如需替换，请先添加其他语言的参考字幕"],
        )

    if any(c.excluded is None for c in ranked):
        return PreviewBlocker(
            code="unusable_text",
            title="参考字幕不能用于翻译" if detail else "参考字幕不完整",
            message=detail or "文本字幕无法解析，或对白数量、时间覆盖不足。",
            suggestions=[
                "换用与当前片源匹配、内容完整的文本字幕",
                rescan,
            ],
        )

    graphic_count = sum(c.exclusion_code == "graphic" for c in ranked)
    return PreviewBlocker(
        code="no_usable_reference",
        title="现有字幕无法用于翻译",
        message=(
            f"检测到 {len(ranked)} 条字幕"
            + (f"，其中 {graphic_count} 条是图形字幕" if graphic_count else "")
            + "；其余为强制片段或目标语言字幕。"
        ),
        suggestions=[add_sidecar, rescan],
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
    try:
        chosen, events = await _pick_loadable(row, selected_candidates, warnings, wait=False)
    except extract.SourceExtractionPending:
        # 还没读过不等于「做不了」：照常选中它，blocker 留空；读取与完整度检查
        # 都在任务里做，不合格会在调用模型之前停下。
        chosen, events = selected, []
        reference_notice = await _reading_notice(row)

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
        pgs_conversion=pgs_conversion,
        blocker=(
            _preview_blocker(
                ranked,
                pgs_conversion,
                target_language,
                secondary_language,
                detail=warnings[-1] if warnings else None,
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


async def _reading_notice(row: LibraryFile) -> str:
    """内封轨还没读取过时给用户的说明：会发生什么、为什么可能慢、花不花钱。"""
    try:
        size = (await asyncio.to_thread(Path(row.file_path).stat)).st_size
    except OSError:
        size = 0
    whole = f"整个视频文件（{_format_size(size)}）" if size else "整个视频文件"
    return (
        f"这条内封字幕还没读取过：开始后会先通读{whole}把字幕读出来，大文件可能要几分钟，"
        "这一步不调用 AI；读出后先检查完整度，不合格就停下，不产生模型费用。"
    )


async def _pick_loadable(
    row: LibraryFile,
    ranked: list[source.RankedCandidate],
    warnings: list[str],
    *,
    wait: bool = True,
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
            continue
        if cand.candidate.sdh:
            events = extract.strip_sdh_markers(events)
        assessment = source.assess_events(events, row.duration_seconds)
        cand.reasons.append(assessment.reason)
        if assessment.ok:
            return cand, events
        warnings.append(f"候选「{_cand_desc(cand.candidate)}」完整度不合格：{assessment.reason}")
    return None, []


def _cand_desc(c: source.SourceCandidate) -> str:
    kind = "内封轨" if c.kind == "embedded" else "外挂"
    return f"{kind} {c.key}（{c.language or '未知语言'}/{c.format}）"


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
            raise BadRequestException("用户确认的 PGS 轨道已变化，请重新预检后再试")
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
            message = pv.blocker.message if pv.blocker else "没有可用的参考字幕"
            raise BadRequestException(message)
        initial = GenState(
            phase="ocr",
            message="正在排队识别图片字幕",
            uses_ocr=True,
            target_language=target_language,
            secondary_language=secondary_language,
            source_candidate_key=pv.selected_source_key,
        )
    else:
        initial = GenState(
            message="等待开始，第一步先读取内封字幕" if pv.reference_notice else "正在准备",
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
        raise BadRequestException("没有可用的参考字幕，请重新预检")
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
        "filename": result.filename,
        "report": asdict(result.report) if result.report is not None else None,
        "sync_score": result.sync_score,
        "source_desc": result.source_desc,
        "finished_at": utc_isoformat(finished_at)
        if isinstance(finished_at, datetime)
        else finished_at,
    }


#: 这些阶段只在等外部进程或读盘，收到停止请求就立即取消（见 _run_generation_job）
_STOP_AT_ONCE_PHASES = frozenset({"preparing", "extracting", "ocr", "syncing"})
#: 模型服务暂时不可用时，隔多久自动重试一次（从断点继续，不重复花钱）
_MODEL_RETRY_DELAY_SECONDS = 30


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
        message="正在从已保存进度继续" if input_data.get("resume") else "正在准备",
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
            f"{exc}。当前任务固定使用模型 {model_ref or '默认模型'}；"
            "换模型请改默认模型后重新发起生成，点「重试」仍会用原模型",
            code="SUBTITLE_TRANSLATION_ABORTED",
            actions=[
                {"type": "open_settings", "label": "调整 AI 模型", "target": "llm"},
                {"type": "retry_job", "label": "重试"},
                {"type": "handoff_agent", "label": "交给 Agent"},
            ],
        ) from exc
    except AppException as exc:
        if "配置" in exc.message or "模型" in exc.message:
            raise jobs.JobBlocked(
                exc.message,
                code="SUBTITLE_MODEL_UNAVAILABLE",
                actions=[
                    {"type": "open_settings", "label": "配置 AI 模型", "target": "llm"},
                    {"type": "retry_job", "label": "配置后重试"},
                    {"type": "handoff_agent", "label": "交给 Agent"},
                ],
            ) from exc
        raise jobs.JobFailed(
            exc.message,
            code="SUBTITLE_GENERATION_FAILED",
            actions=[{"type": "handoff_agent", "label": "交给 Agent"}],
        ) from exc
    except (LlmConnectError, LlmServerError, LlmRateLimitError) as exc:
        # 连不上、供应商 5xx：多半过一会儿自己恢复。说清楚是模型服务的问题、已完成
        # 的块都在断点里，交给调度器稍后自动重试——此前这里落进「未知错误」，
        # 用户只看到一句「任务遇到临时异常」，重试用尽后是「发生未知错误」。
        raise jobs.JobRetry(
            f"模型服务暂时不可用：{_brief(exc)}。已完成的字幕块已保存，稍后自动重试会从断点继续",
            delay_seconds=_MODEL_RETRY_DELAY_SECONDS,
            code="SUBTITLE_MODEL_TEMPORARILY_UNAVAILABLE",
            actions=[
                {"type": "retry_job", "label": "重试"},
                {"type": "handoff_agent", "label": "交给 Agent"},
            ],
        ) from exc
    except LlmAuthError as exc:
        # API Key 失效重试多少次都一样：停在 blocked，引导去设置里修
        raise jobs.JobBlocked(
            f"模型服务认证失败：{_brief(exc)}",
            code="SUBTITLE_MODEL_AUTH_FAILED",
            actions=[
                {"type": "open_settings", "label": "检查 AI 模型设置", "target": "llm"},
                {"type": "retry_job", "label": "修改后重试"},
                {"type": "handoff_agent", "label": "交给 Agent"},
            ],
        ) from exc
    except LlmError as exc:
        # 请求被拒（参数、上下文超长、内容审查）：原样说明原因，不做无意义的自动重试
        raise jobs.JobFailed(
            f"模型服务拒绝了请求：{_brief(exc)}",
            code="SUBTITLE_MODEL_REQUEST_FAILED",
            actions=[
                {"type": "retry_job", "label": "重试"},
                {"type": "handoff_agent", "label": "交给 Agent"},
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
            {"type": "retry_job", "label": "重试"},
            {"type": "handoff_agent", "label": "交给 Agent"},
        ]
        if "配置" in result.message or "模型" in result.message:
            raise jobs.JobBlocked(
                result.message,
                code="SUBTITLE_MODEL_UNAVAILABLE",
                actions=[
                    {"type": "open_settings", "label": "配置 AI 模型", "target": "llm"},
                    {"type": "retry_job", "label": "配置后重试"},
                    {"type": "handoff_agent", "label": "交给 Agent"},
                ],
            )
        raise jobs.JobFailed(result.message, code="SUBTITLE_GENERATION_FAILED", actions=actions)
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
    state.message = "正在读取内封字幕"
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
        state.message = "正在检查参考字幕"


async def _follow_read_progress(state: GenState, row: LibraryFile) -> None:
    duration = row.duration_seconds
    while True:
        progress = await asyncio.to_thread(media_extract.read_progress, row)
        if progress is not None and progress.queued:
            state.extract_queued = True
            state.message = "排队等待读取：同一时间只通读一个视频文件，前面的读完就轮到这里"
        elif progress is not None:
            state.extract_queued = False
            state.extract_position_seconds = progress.position_seconds
            state.message = (
                f"正在读取内封字幕：已读到 {_clock(progress.position_seconds)} / "
                f"{_clock(duration)}"
                if progress.position_seconds is not None and duration
                else "正在读取内封字幕"
            )
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
        return GenResult(ok=False, message=exc.message)
    state.source_candidate_key = candidate_key(selected) if selected is not None else None
    selected_candidates = [selected] if selected is not None else []
    warnings: list[str] = []
    state.phase = "preparing"
    state.message = "正在选择参考字幕"
    needs_reading = (
        selected is not None
        and not selected.excluded
        and await asyncio.to_thread(extract.needs_extraction, row, selected.candidate)
    )
    if needs_reading:
        chosen, events = await _reading(
            state, row, _pick_loadable(row, selected_candidates, warnings)
        )
    else:
        chosen, events = await _pick_loadable(row, selected_candidates, warnings)
    source_desc: str | None = None
    if chosen is None and convert_pgs:
        plan = await _pgs_plan(
            row,
            selected_candidates,
            original_language=original_language,
            requested_candidate_key=(candidate_key(selected) if selected is not None else None),
            requested_ocr_language=pgs_ocr_language,
        )
        if plan is None:
            return GenResult(ok=False, message="文件中的 PGS 字幕已变化，请重新预检后再试")
        if not plan.capability.available:
            return GenResult(
                ok=False,
                message=f"当前设备无法识别这份图片字幕：{plan.capability.message}",
            )
        if not plan.capability.cached and plan.language.code is None:
            return GenResult(ok=False, message="原字幕语言尚未确认，请重新检查后再试")
        pgs_candidate = plan.candidate.candidate
        try:
            if plan.capability.cached:
                ocr_path = pgs.cached_srt_path(row, pgs_candidate, plan.language.code)
            else:
                # .sup 走与播放器共用的整文件抽取：同一趟通读、同一份缓存，
                # 读取阶段同样有进度、可取消。
                sup_path = await _reading(state, row, pgs.extract_sup(row, pgs_candidate))
                state.phase = "ocr"
                state.message = "正在识别图片字幕，可能需要一些时间"
                ocr_path = await pgs.ocr_to_srt(
                    row, pgs_candidate, plan.capability, plan.language.code, sup_path
                )
            raw = await asyncio.to_thread(ocr_path.read_bytes)
            events = extract.parse_events(
                extract.decode_subtitle_bytes(raw, str(ocr_path)), str(ocr_path)
            )
        except (OSError, extract.SourceLoadError, pgs.PgsConversionError) as exc:
            return GenResult(ok=False, message=f"图片字幕识别未完成：{exc}")
        if cancelled():
            raise translate.TranslationAborted("图片字幕识别完成，已按你的请求停止后续 AI 翻译")
        assessment = source.assess_events(events, row.duration_seconds)
        if not assessment.ok:
            return GenResult(
                ok=False,
                message=f"图片字幕已识别，但完整度检查未通过：{assessment.reason}",
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
                message=f"图片字幕已识别，但无法保存外挂字幕：{ocr_sidecar}（{exc}）",
            )
        await _refresh_subtitle_inventory(db, file_id)
        chosen = plan.candidate
        chosen.reasons.append(
            f"PGS 以 {plan.language.label or '已确认语言'}"
            f"经 {plan.capability.engine or 'OCR'} 转为 SRT"
        )
        chosen.reasons.append(assessment.reason)
        source_desc = f"{_cand_desc(chosen.candidate)}（OCR 转换）"
    if chosen is None:
        detail = "；".join(warnings) or "当前没有可选择的文本字幕"
        return GenResult(ok=False, message="所选参考字幕无法用于翻译：" + detail)
    if source_desc is None:
        source_desc = _cand_desc(chosen.candidate)
    logger.info(
        "字幕生成选源：%s ← %s（%s）", row.file_path, source_desc, "；".join(chosen.reasons)
    )

    # L1 同步质检（§5.2）：错位参考在烧 LLM 钱之前拦下；无法检测按未知放行
    state.phase = "syncing"
    state.message = "正在检查字幕与影片是否同步"
    state.total_events = len(events)
    sync_score = await sync.sample_sync_score(
        Path(row.file_path), events, row.duration_seconds, sync.audio_index(row.audio_streams)
    )
    if sync_score is not None and sync_score < sync.SYNC_THRESHOLD:
        return GenResult(
            ok=False,
            sync_score=sync_score,
            source_desc=source_desc,
            message=(
                f"参考字幕「{source_desc}」与影片疑似不同步"
                f"（语音命中率 {sync_score:.0%}，阈值 {sync.SYNC_THRESHOLD:.0%}）——"
                "请先用同步的字幕做参考，避免翻译成果整体错位"
            ),
        )

    def _phase(phase: str, message: str) -> None:
        state.phase = phase
        state.message = message
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
                state.message = f"首批 {active_count} 个字幕块正在等待模型返回"
            else:
                state.message = (
                    f"已完成 {progress.done_blocks}/{progress.total_blocks} 块，"
                    f"另有 {active_count} 块处理中"
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
    state.message = "正在检查字幕质量"
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
        state.message = f"正在压缩 {len(overruns)} 条超读速译文"
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
    state.message = "正在保存字幕文件"
    sidecar = _sidecar_path(row, target_language, secondary_language)
    try:
        await asyncio.to_thread(translate.write_srt, final_events, sidecar)
    except OSError as exc:
        return GenResult(
            ok=False,
            message=f"字幕文件写入失败（库目录是否只读？）：{sidecar}（{exc}）",
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
    state.message = "正在更新媒体库字幕列表"
    await _refresh_subtitle_inventory(db, file_id)

    message = f"已生成 {sidecar.name}（参考：{source_desc}，{report.event_count} 条对白"
    if stats.failed_blocks:
        message += f"，{stats.failed_blocks} 块翻译失败保留原文"
    if report.compressed:
        message += f"，压缩改写 {report.compressed} 条超读速译文"
    if report.cps_overrun:
        message += f"，仍有 {report.cps_overrun} 条超读速"
    message += "）"
    logger.info("字幕生成完成：%s", message)
    return GenResult(
        ok=True,
        message=message,
        filename=sidecar.name,
        report=report,
        sync_score=sync_score,
        source_desc=source_desc,
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
            f"任务使用的 AI 模型配置已不可用：{exc}。请恢复配置后重试任务"
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
                f"任务使用的 AI 模型配置已不可用：{exc}。请恢复配置后重试任务"
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
                "模型写到自身输出上限仍未写完译文"
                f"（本次思考+正文共 {response.usage.completion_tokens} tokens）"
            )
        if response.finish_reason == "tool_calls":
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
) -> tuple[list[tuple[int, int]] | None, str | None]:
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
            return [(s, e) for s, e, _ in events], _cand_desc(cand.candidate)
    return None, None


async def calibrate_external_subtitle(
    session: AsyncSession, file_id: int, filename: str
) -> CalibrateResult:
    """校准一条外挂字幕并覆盖写回（UTF-8）;台账即时刷新。

    参考优先音轨（真相源）,无音频（strm/无 ffmpeg）退字幕对字幕;两者都
    不可用如实报错。校准量小于噪声阈值时不动文件（"本就同步"）。
    """
    if "/" in filename or "\\" in filename or filename.startswith("."):
        raise BadRequestException(f"字幕文件名不合法：{filename!r}")
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
            raise NotFoundException(f"没有找到这条外挂字幕文件：{filename}")
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
        return CalibrateResult(ok=False, message="字幕事件太少，无法可靠校准")

    reference = await _audio_reference_intervals(row, events)
    ref_desc = "影片音轨"
    if not reference:
        reference, ref_desc = await _subtitle_reference_intervals(row, filename)
        if not reference:
            return CalibrateResult(
                ok=False,
                message="没有可用的校准参考：本机无 ffmpeg 或无音轨（strm 云端文件），"
                "且该文件没有其他字幕轨可做时间结构对齐",
            )

    calibration = sync.estimate_calibration(reference, [(s, e) for s, e, _ in events])
    if calibration is None or calibration.score < _CALIBRATE_MIN_SCORE:
        return CalibrateResult(
            ok=False,
            message=f"校准置信度不足（参考：{ref_desc}）——字幕可能与该影片不匹配",
            score=calibration.score if calibration else None,
        )
    if calibration.scale == 1.0 and abs(calibration.offset_ms) <= _NOOP_OFFSET_MS:
        return CalibrateResult(
            ok=True,
            message=f"字幕本就同步（参考：{ref_desc}），未做修改",
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
        return CalibrateResult(ok=False, message=f"校准结果写入失败（库目录是否只读？）：{exc}")

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
        ref_desc,
    )
    return CalibrateResult(
        ok=True,
        message=(
            f"校准完成（参考：{ref_desc}）：缩放 {calibration.scale:.4f}、"
            f"平移 {calibration.offset_ms / 1000:+.2f} 秒，已覆盖写回"
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
