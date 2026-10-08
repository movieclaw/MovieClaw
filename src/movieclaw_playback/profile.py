"""台账行 → 决策输入的适配（docs/design/web-player.md §3.2）。

单独成模块而不是并进 ``decide``：决策引擎必须保持零 IO、零框架依赖，才能被
表驱动单测在 ``pytest -m "not integration"`` 里完整覆盖。适配器要碰
``LibraryFile`` 与 strm 判定（后者所在的 ``streaming`` 会拉进 FastAPI），
放在这里就不会污染纯函数层的 import 链。

规格全部来自 ffprobe 落库的真值（``media_probe``），不从文件名猜——库存画质
的真相来自文件本体，这是媒体库的既定原则。
"""

from __future__ import annotations

from movieclaw_db.models import LibraryFile
from movieclaw_playback.decide import AudioTrack, MediaProfile, SubtitleTrack
from movieclaw_playback.streaming import is_strm
from movieclaw_playback.subtitles import (
    embedded_track,
    external_track,
    is_ai_generated,
)
from movieclaw_playback.track_policy import (
    AudioChoice,
    SubtitleChoice,
    TrackContext,
    default_tracks,
)


def media_profile_from_file(
    file: LibraryFile,
    *,
    keyframe_interval_s: float | None = None,
    disc_clips: int = 0,
    disc_playlist: str | None = None,
    context: TrackContext | None = None,
    preferred_audio: str | None = None,
) -> MediaProfile:
    """把一行台账装配成决策输入。

    ``keyframe_interval_s`` 由调用方从关键帧索引算出（§3.5）；未就绪时传 None，
    决策引擎会保守地不走 remux——档 1/2 的分片只能切在源片已有的 IDR 上，
    索引未知就赌不起。``disc_clips`` 是原盘主播放列表的段数（非原盘为 0），
    由调用方从播放源解析器取——本模块不碰磁盘；``disc_playlist`` 是它的文件名。

    ``context`` 是默认轨策略的上下文（库语言、原始语言，见 track_policy），``preferred_audio`` 是
    这次要放的音轨（用户点选 / 记忆）——默认字幕要看放的是哪种语言的音轨。不给上下文时按旧规则。
    """
    audio_choice, subtitle_choice = default_tracks(file, context or TrackContext(), preferred_audio)
    return MediaProfile(
        file_id=file.id or 0,
        container=file.container,
        video_codec=file.video_codec,
        resolution=file.resolution,
        hdr=file.hdr,
        dv_profile=file.dv_profile,
        dv_bl_compatible=file.dv_bl_compatible,
        color_space=file.color_space,
        bit_depth=file.bit_depth,
        duration_ms=(file.duration_seconds * 1000) if file.duration_seconds else None,
        audio_tracks=_audio_tracks(file, audio_choice),
        subtitle_tracks=_subtitle_tracks(file, subtitle_choice),
        keyframe_interval_s=keyframe_interval_s,
        is_strm=is_strm(file.file_path),
        disc_clips=disc_clips,
        disc_playlist=disc_playlist,
        dvd_folder=(file.container or "") == "dvd",
    )


def _audio_tracks(file: LibraryFile, choice: AudioChoice) -> tuple[AudioTrack, ...]:
    """``is_default`` 是容器旗标（直出放哪条）；``preferred`` 是默认轨策略挑中的那条
    （用户没表态时放哪条）。"""
    return tuple(
        AudioTrack(
            ref=embedded_track(index),
            codec=(raw.get("codec") or None),
            channels=raw.get("channels"),
            language=raw.get("language"),
            is_default=bool(raw.get("default")),
            preferred=index == choice.index,
        )
        for index, raw in enumerate(file.audio_streams or [])
        if isinstance(raw, dict)
    )


def _subtitle_tracks(file: LibraryFile, choice: SubtitleChoice) -> tuple[SubtitleTrack, ...]:
    """内封轨在前、外挂轨在后——与既有中性引用的编号口径保持一致。

    ``is_default`` 写的是**服务端裁决出的那一条**（track_policy 的默认字幕：库语言优先、再看原声），
    不是容器里的原始旗标，不开字幕时谁都不标。网页端、App 拿这个标记做首选，Jellyfin 端经
    track_policy.resolve_subtitle 走同一个策略——各端对同一部片给出同一条默认轨。
    """
    default_ref = choice.ref
    embedded = [
        SubtitleTrack(
            ref=embedded_track(index),
            codec=(raw.get("codec") or None),
            language=raw.get("language"),
            is_default=embedded_track(index) == default_ref,
            title=raw.get("title"),
            is_forced=bool(raw.get("forced")),
        )
        for index, raw in enumerate(file.subtitle_streams or [])
        if isinstance(raw, dict)
    ]
    external = [
        SubtitleTrack(
            ref=external_track(str(entry.get("filename"))),
            # 外挂字幕的台账字段是 format（srt/ass/…），语义等同内封的 codec
            codec=(entry.get("format") or None),
            language=entry.get("language"),
            is_external=True,
            is_default=external_track(str(entry.get("filename"))) == default_ref,
            # title 段是扫描时从文件名解析好的（视频 stem 之后的 token），
            # AI 字幕的世代标记就写在这里
            is_ai=is_ai_generated(entry.get("title")),
            title=entry.get("title"),
            is_forced=bool(entry.get("forced")),
        )
        for entry in (file.external_subtitles or [])
        if isinstance(entry, dict) and entry.get("filename")
    ]
    return tuple(embedded + external)
