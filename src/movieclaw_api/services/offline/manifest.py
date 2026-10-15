"""离线下载清单（docs/design/offline-download.md §5.2）：一个播放单元打包所需的一切。

展示数据直接调详情、库、分集三个浏览接口的处理函数，拿到的就是 App 平时解码的同一份
模型——本机存档原样存下，离线时原样喂给同一个页面。播放数据（片段、章节、轨道清单与
默认轨）与开播放会话同源，只是不建会话。
"""

from __future__ import annotations

from urllib.parse import quote

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.schemas.offline import (
    OfflineFileProfilesView,
    OfflineManifestView,
    OfflineProfilesView,
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

#: App 的自研引擎：全解码、自己读原文件（与 App 开会话时申报的同一个意思）。清单只拿决策里的
#: 音轨与字幕列表，杜比视界记录的核对照样交给引擎，别让它把决策顶到换封装
_UNIVERSAL = ClientCapabilityIn(universal=True, dolby_vision_record_audit=True)


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

    available: set[str] = set()
    for profile in _worth_exporting(file):
        try:
            await exports.build_plan(file, profile, view.default_audio)
        except exports.ExportUnavailable:
            continue
        available.add(profile)
    view.profiles = _profile_views(file, available)
    return view


def _worth_exporting(file: LibraryFile) -> list[str]:
    """可选的转码档：比源低的都列。不按体积替用户过滤——源码率低时转出来可能不比原画小，
    各档都带预计大小，让用户自己选（悄悄少几档比多几个选项更让人困惑）。"""
    source_height = _source_height(file)
    return [
        profile
        for profile, height in exports.PROFILES.items()
        # 源本身就不高于这一档：转了只会更大更糊
        if source_height is None or height < source_height
    ]


def _profile_views(file: LibraryFile, available: set[str]) -> list[OfflineProfileView]:
    duration_s = float(file.duration_seconds) if file.duration_seconds else None
    views = [
        OfflineProfileView(
            profile="original",
            label=_original_label(file),
            height=_source_height(file),
            expected_bytes=file.size_bytes or 0,
        )
    ]
    for profile in _worth_exporting(file):
        if profile in available:
            views.append(
                OfflineProfileView(
                    profile=profile,
                    label=profile,
                    height=exports.PROFILES[profile],
                    expected_bytes=exports.estimate_bytes(profile, duration_s),
                )
            )
    return views


async def build_profiles(
    session: AsyncSession, principal: Principal, file_ids: list[int]
) -> OfflineProfilesView:
    """选档表单批量估大小：一批文件的可选档位与预计大小（档位规则与清单同一套）。

    一部剧 40 多集时逐集取清单（每份带整部剧详情与整季分集，服务端串行 0.3 秒一份）要十几秒；
    这里只读文件行，轨道上下文、播放策略、本机编码后端整批取一次。"""
    visible = await visible_library_ids(session, principal)
    rows = await session.execute(select(LibraryFile).where(LibraryFile.id.in_(file_ids)))
    files = {f.id: f for f in rows.scalars()}
    seen_items: dict[int, bool] = {}
    allowed: list[LibraryFile] = []
    for file_id in dict.fromkeys(file_ids):
        file = files.get(file_id)
        if file is None or file.media_item_id is None or file.library_id not in visible:
            continue
        if file.media_item_id not in seen_items:
            try:
                await assert_item_visible(session, principal, file.media_item_id)
                seen_items[file.media_item_id] = True
            except NotFoundException:
                seen_items[file.media_item_id] = False
        if seen_items[file.media_item_id]:
            allowed.append(file)
    available = await exports.available_profiles([f for f in allowed if _worth_exporting(f)])
    result: list[OfflineFileProfilesView] = []
    for file in allowed:
        entry = OfflineFileProfilesView(
            file_id=file.id,
            media_item_id=file.media_item_id,
            season_number=file.season_number or 0,
            episode_number=file.episode_number or 0,
            container=file.container,
        )
        if file.is_disc():
            entry.profiles = []
            entry.unavailable_reason = "原盘暂不支持下载到设备"
        else:
            entry.profiles = _profile_views(file, available.get(file.id or 0, set()))
        result.append(entry)
    return OfflineProfilesView(files=result)
