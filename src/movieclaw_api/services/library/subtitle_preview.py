"""媒体库详情页的字幕预览加载。

预览沿用 AI 字幕生成已经验证过的“外挂解码 / 内封抽取 / pysubs2 解析”
链路，只负责把详情页传来的中性轨引用解析为当前台账文件中的真实字幕。
轨道必须先命中台账，客户端不能借 filename 或流序号读取任意文件。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.i18n.stored import reference
from movieclaw_api.services.subtitle_gen import extract
from movieclaw_api.services.subtitle_gen.source import _TEXT_CODECS, SourceCandidate
from movieclaw_db.models import LibraryFile
from movieclaw_playback.subtitles import parse_embedded_track, parse_external_track

logger = logging.getLogger("movieclaw_api.subtitle_preview")


class SubtitleTrackNotFound(NotFoundException):
    """轨引用没有命中当前文件的内封轨或外挂字幕台账。"""


class SubtitlePreviewError(BadRequestException):
    """字幕存在，但其格式、文件状态或解析结果不支持文本预览。"""


@dataclass(frozen=True)
class SubtitlePreview:
    """解析后的字幕预览；events 已按开始时间排序并移除格式样式标记。

    ``pending`` 为真时 events 为空：内封轨正在后台抽取，稍后重试即可。
    """

    format: str | None
    events: list[extract.SubEvent]
    pending: str | None = None


def _candidate_for_track(file: LibraryFile, track: str) -> SourceCandidate:
    """中性轨引用 → 已由台账验证的字幕加载候选。"""

    embedded_index = parse_embedded_track(track)
    if embedded_index is not None:
        streams = file.subtitle_streams or []
        if embedded_index >= len(streams):
            raise SubtitleTrackNotFound(message_key="errors.subtitles.previewEmbeddedMissing")
        raw = streams[embedded_index]
        codec = str(raw.get("codec") or "").lower()
        if codec not in _TEXT_CODECS:
            label = codec.upper() if codec else reference("errors.subtitles.previewUnknownFormat")
            raise SubtitlePreviewError(
                message_key="errors.subtitles.previewGraphic", params={"format": label}
            )
        return SourceCandidate(
            kind="embedded",
            key=str(embedded_index),
            language=raw.get("language"),
            forced=bool(raw.get("forced")),
            sdh=False,
            format=codec,
        )

    filename = parse_external_track(track)
    if filename is not None:
        entry = next(
            (raw for raw in (file.external_subtitles or []) if raw.get("filename") == filename),
            None,
        )
        if entry is None:
            raise SubtitleTrackNotFound(message_key="errors.subtitles.previewExternalMissing")
        fmt = str(entry.get("format") or Path(filename).suffix.lstrip(".")).lower() or None
        return SourceCandidate(
            kind="external",
            key=filename,
            language=entry.get("language"),
            forced=bool(entry.get("forced")),
            sdh=bool(entry.get("sdh")),
            format=fmt,
        )

    raise SubtitleTrackNotFound(message_key="errors.subtitles.previewInvalidTrack")


async def load_subtitle_preview(
    file: LibraryFile, track: str, *, wait: bool = False
) -> SubtitlePreview:
    """读取并解析一条字幕；磁盘读取与 ffmpeg 抽取都不阻塞事件循环。

    内封轨首次预览要通读整个容器（大文件分钟级）。默认 ``wait=False``：没有
    现成产物就转后台抽取并返回 pending，由前端轮询——把请求挂住等的下场是
    浏览器先超时，用户看到一条莫名其妙的网络错误（issue #432）。
    """

    candidate = _candidate_for_track(file, track)
    try:
        events = await extract.load_candidate_events(
            file, candidate, preserve_linebreaks=True, wait=wait
        )
    except extract.SourceExtractionPending as pending:
        return SubtitlePreview(format=candidate.format, events=[], pending=pending.message)
    except extract.SourceLoadError as exc:
        # SourceLoadError 会包含磁盘绝对路径，便于部署者排障，但该接口也对普通
        # 成员开放，不能把服务端目录结构透传到响应中。
        logger.warning("字幕预览加载失败：file_id=%s track=%s（%s）", file.id, track, exc)
        raise SubtitlePreviewError(message_key="errors.subtitles.previewUnreadable") from exc
    return SubtitlePreview(format=candidate.format, events=events)
