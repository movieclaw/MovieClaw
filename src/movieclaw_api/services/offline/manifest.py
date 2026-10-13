"""离线下载清单（docs/design/offline-download.md §5.2）：一个播放单元打包所需的一切。

展示数据直接调详情、库、分集三个浏览接口的处理函数，拿到的就是 App 平时解码的同一份
模型——本机存档原样存下，离线时原样喂给同一个页面。播放数据（片段、章节、轨道清单与
默认轨）与开播放会话同源，只是不建会话。
"""

from __future__ import annotations

from urllib.parse import quote

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.schemas.offline import (
    OfflineManifestView,
    OfflineProfileView,
    OfflineSubtitleView,
)
from movieclaw_api.schemas.playback import ClientCapabilityIn, PlaybackSegmentView
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library import skip_segments
from movieclaw_api.services.library.access import assert_item_visible, visible_library_ids
from movieclaw_api.services.offline import exports
from movieclaw_api.services.playback import plan as playback_plan
from movieclaw_api.services.playback.signing import issue_stream_token
from movieclaw_db.models import LibraryFile
from movieclaw_playback import state as playback_state
from movieclaw_playback.decide import PlaybackPlan

#: App 的自研引擎：全解码、自己读原文件（与 App 开会话时申报的同一个意思）
_UNIVERSAL = ClientCapabilityIn(universal=True)


def _source_height(file: LibraryFile) -> int | None:
    resolution = (file.resolution or "").lower()
    for token, height in (
        ("2160", 2160),
        ("4k", 2160),
        ("1440", 1440),
        ("1080", 1080),
        ("720", 720),
        ("576", 576),
        ("480", 480),
    ):
        if token in resolution:
            return height
    return None


def _original_label(file: LibraryFile) -> str:
    parts = [p for p in (file.resolution, (file.video_codec or "").upper() or None) if p]
    return "原画" + (" · " + " ".join(parts) if parts else "")


async def build_manifest(
    session: AsyncSession, principal: Principal, file_id: int, *, user_agent: str | None
) -> OfflineManifestView:
    # 局部导入：路由模块反过来依赖服务层
    from movieclaw_api.api.routes import libraries as library_routes
    from movieclaw_api.api.routes.playback import _chapter_marks

    file = await session.get(LibraryFile, file_id)
    if file is None or file.media_item_id is None:
        raise NotFoundException("文件不存在")
    visible = await visible_library_ids(session, principal)
    if file.library_id not in visible:
        raise NotFoundException("文件不存在")
    await assert_item_visible(session, principal, file.media_item_id)
    member_id = principal.member_id if principal.member_id is not None else 0
    season_number = file.season_number or 0
    episode_number = file.episode_number or 0

    item = (
        await library_routes.get_library_item(
            file.library_id,
            file.media_item_id,
            principal=principal,
            session=session,
            user_agent=user_agent,
        )
    ).data
    library = (
        await library_routes.get_library(file.library_id, principal=principal, session=session)
    ).data
    season = None
    if item.kind == "tv":
        season = (
            await library_routes.list_item_episodes(
                file.library_id,
                file.media_item_id,
                season_number=season_number,
                principal=principal,
                session=session,
            )
        ).data

    unit = (file.media_item_id, season_number, episode_number)
    states = await playback_state.get_states(session, [file.media_item_id], member_id=member_id)
    state = states.get(unit)
    duration_s = float(file.duration_seconds) if file.duration_seconds else None

    view = OfflineManifestView(
        file_id=file.id,
        media_item_id=file.media_item_id,
        library_id=file.library_id,
        season_number=season_number,
        episode_number=episode_number,
        container=file.container,
        size_bytes=file.size_bytes or 0,
        duration_ms=int(duration_s * 1000) if duration_s else None,
        item=item,
        library=library,
        season=season,
        chapters=_chapter_marks(file),
        segments=[
            PlaybackSegmentView(**seg)
            for seg in await skip_segments.segments_for_file(session, file)
        ],
        resume_position_ms=state.position_ms if state is not None else None,
    )
    if file.is_disc():
        view.unavailable_reason = "原盘暂不支持下载到设备"
        return view

    decision = await playback_plan.decide_for_file(
        session,
        file.id,
        playback_plan.capability_from_request(_UNIVERSAL),
        can_self_enable=principal.is_admin,
        preferred_audio=state.audio_track if state is not None else None,
        preferred_subtitle=state.subtitle_track if state is not None else None,
        visible_library_ids=visible,
    )
    if isinstance(decision, PlaybackPlan):
        decided = playback_plan.to_view(decision)
        view.audio_tracks = decided.audio_tracks
        view.default_audio = decided.audio.track_ref if decided.audio else None
        token = await issue_stream_token(member_id=member_id, file_id=file.id)
        for sub in decided.subtitles:
            if sub.kind not in ("vtt", "ass"):
                continue  # 图形字幕（PGS）：原画档在文件里，转码档一期不带
            fmt = "ass" if sub.kind == "ass" else "srt"
            url = (
                f"/api/v1/playback/files/{file.id}/subtitles?track={quote(sub.track_ref, safe='')}"
            )
            if fmt == "srt":
                url += "&format=srt"
            view.subtitles.append(
                OfflineSubtitleView(
                    track_ref=sub.track_ref,
                    format=fmt,
                    language=sub.language,
                    title=sub.title,
                    is_default=sub.is_default,
                    is_forced=bool(sub.is_forced),
                    is_ai=sub.is_ai,
                    embedded=sub.track_ref.startswith("embedded:"),
                    url=f"{url}&token={token}",
                )
            )
            if sub.is_default and view.default_subtitle is None:
                view.default_subtitle = sub.track_ref
        if any(s.format == "ass" for s in view.subtitles):
            view.fonts_url = f"/api/v1/playback/files/{file.id}/fonts?token={token}"

    view.profiles.append(
        OfflineProfileView(
            profile="original",
            label=_original_label(file),
            height=_source_height(file),
            expected_bytes=file.size_bytes or 0,
        )
    )
    source_height = _source_height(file)
    for profile, height in exports.PROFILES.items():
        if source_height is not None and height >= source_height:
            continue  # 源本身就不高于这一档：转了只会更大更糊
        expected = exports.estimate_bytes(profile, duration_s)
        if file.size_bytes and expected >= file.size_bytes * 0.9:
            continue  # 源本身码率就低：转出来不比原文件小，没必要
        try:
            await exports.build_plan(file, profile, view.default_audio)
        except exports.ExportUnavailable:
            continue
        view.profiles.append(
            OfflineProfileView(
                profile=profile, label=profile, height=height, expected_bytes=expected
            )
        )
    return view
