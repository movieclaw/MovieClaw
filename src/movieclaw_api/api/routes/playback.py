"""播放记录与网页播放器的 Web 业务接口。"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import logging
import os
import re
import time
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path as PathLib
from typing import Annotated, Literal, TypeVar
from urllib.parse import quote

from fastapi import APIRouter, BackgroundTasks, Depends, Header, Path, Query, Request, Response
from fastapi.responses import FileResponse, RedirectResponse, StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.api.deps import require_admin, require_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import (
    BadRequestException,
    ConflictException,
    NotFoundException,
    ServiceUnavailableException,
)
from movieclaw_api.schemas.base import utc_isoformat
from movieclaw_api.schemas.library import LibraryGalleryGroupView, SeasonEpisodesView
from movieclaw_api.schemas.playback import (
    ClientCapabilityIn,
    FavoritesView,
    HwBackendStatusView,
    HwProbeView,
    MatroskaCuesView,
    MediaActivityView,
    PlaybackArtifactUploadView,
    PlaybackAttemptView,
    PlaybackChapterMarkView,
    PlaybackClientLogPayload,
    PlaybackDecideRequest,
    PlaybackDecisionView,
    PlaybackDiagnosticsView,
    PlaybackDiscFileView,
    PlaybackDiscListingView,
    PlaybackFontsView,
    PlaybackHistoryClearView,
    PlaybackHistoryView,
    PlaybackItemView,
    PlaybackMarksRequest,
    PlaybackMarksView,
    PlaybackMetricPayload,
    PlaybackPolicyPayload,
    PlaybackPolicyView,
    PlaybackProgressRequest,
    PlaybackQoeStatsView,
    PlaybackSegmentView,
    PlaybackSessionRequest,
    PlaybackSessionView,
    PlaybackSourceView,
    PlaybackStateView,
    PlaybackStatsView,
    PlaybackWatchStatsView,
    TrickplayView,
    UpNextView,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services import login_devices, media_scrape
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library import chapters as chapters_mod
from movieclaw_api.services.library import skip_segments
from movieclaw_api.services.library.access import (
    assert_item_visible,
    assert_library_visible,
    visible_library_ids,
)
from movieclaw_api.services.library.items import build_season_episodes, episode_view
from movieclaw_api.services.media_probe import probe_keyframe_before
from movieclaw_api.services.playback import marks as playback_marks
from movieclaw_api.services.playback import metrics, qoe, track_memory, trickplay, video_cues
from movieclaw_api.services.playback import plan as playback_plan
from movieclaw_api.services.playback import warmup as playback_warmup
from movieclaw_api.services.playback import watch as playback_watch
from movieclaw_api.services.playback.adaptive import adapt_to_downlink
from movieclaw_api.services.playback.disc_source import disc_source_for_file
from movieclaw_api.services.playback.embedded_subs import (
    extract_embedded_fonts,
    extract_embedded_subtitle_async,
    extract_embedded_subtitle_window_async,
    font_cache_dir,
    safe_font_name,
    window_format,
)
from movieclaw_api.services.playback.ffmpeg_args import (
    HW_BACKENDS,
    INIT_NAME,
    SEGMENT_SECONDS,
    effective_hw_backend,
    is_mpegts,
    segment_pattern,
)
from movieclaw_api.services.playback.hwprobe import (
    available_backends,
    available_local_backends,
    probe_backends_async,
)
from movieclaw_api.services.playback.limits import (
    MAX_REMUX_CONCURRENCY,
    auto_quota_bytes,
    auto_transcode_concurrency,
)
from movieclaw_api.services.playback.remote_worker import (
    effective_remote_transcode_config,
    get_remote_worker_registry,
    remote_worker_available,
)
from movieclaw_api.services.playback.session import (
    DiskQuotaError,
    PartialSegment,
    SessionLimitError,
    SessionStartError,
    TranscodeSession,
    get_session_manager,
)
from movieclaw_api.services.playback.signing import (
    STREAM_TOKEN_TTL_S,
    StreamGrant,
    issue_stream_token,
    verify_stream_token,
)
from movieclaw_api.services.playback.track_context import files_with_contexts
from movieclaw_api.services.playback_activity import (
    end_playback,
    live_session_label,
    media_activity_overview,
    revoke_device,
)
from movieclaw_api.services.playback_favorites import (
    FavoriteSort,
    favorite_gallery,
    favorite_items,
)
from movieclaw_api.services.playback_stats import playback_history, playback_stats
from movieclaw_api.services.playback_up_next import up_next_items
from movieclaw_api.services.tmdb_images import tmdb_image_url
from movieclaw_api.settings import PlaybackPolicySetting
from movieclaw_api.settings.store import get_setting_store
from movieclaw_db.engine import get_database, get_session
from movieclaw_db.models import LibraryFile, MediaItem, PlaybackMetric, PlaybackState
from movieclaw_db.models.base import utcnow
from movieclaw_db.repositories.media_repo import MediaItemRepository
from movieclaw_playback import activity
from movieclaw_playback import state as playback_state
from movieclaw_playback.decide import PlaybackTier as Tier
from movieclaw_playback.hls_vod import (
    build_master_playlist,
    build_media_playlist,
    build_subtitle_playlist,
    compute_keyframe_plan,
    compute_uniform_plan,
)
from movieclaw_playback.keyframes import read_keyframe_index, schedule_background_index
from movieclaw_playback.streaming import (
    ClientDisconnected,
    DisconnectAwareFileResponse,
    await_unless_disconnected,
    container_mime_type,
    direct_play_byte_patches,
    is_strm,
    register_device_stream,
    resolve_strm_url,
    unregister_device_stream,
)
from movieclaw_playback.subtitles import (
    SubtitleServeError,
    parse_embedded_track,
    resolve_external_subtitle,
    serve_subtitle,
)

logger = logging.getLogger("movieclaw_api.playback")

router = APIRouter(prefix="/playback", tags=["playback"])
#: 取流字节面（播放列表 / 分片 / 直出 / 字幕 / 字体 / trickplay）：``<video src>``、
#: hls.js 与 iOS 原生 HLS 都带不了自定义 header，这些端点只认查询参数里的签名
#: token，不挂登录依赖（挂在公开区）。无 token / token 不符一律 404。影片分享的
#: 访客（docs/design/media-share.md）没有会话 Cookie，靠的正是这条通道。
stream_router = APIRouter(prefix="/playback", tags=["playback"])


class _SubtitleClientDisconnected(Exception):
    """客户端已放弃字幕请求，且底层抽取任务已经完成取消。"""


_DIAGNOSTIC_SECRET_RE = re.compile(
    r"((?:[?&]|\b)(?:token|access_token|signature|sig)=)[^&\s]+", re.IGNORECASE
)


def _chapter_marks(file: LibraryFile) -> list[PlaybackChapterMarkView]:
    """进度条上的章节刻度（docs/design/player-feel.md §2.C1）。

    **只下发真章节**：``effective_chapters`` 在没有内嵌章节时会按时长合成
    等距章节，那是给详情页凑场景图用的；等距刻度画到进度条上没有任何信息量，
    只会让轨道变成一排竖条。章节未探测（旧台账行）同样返回空表。
    """
    if file.chapters is None:
        return []
    return [
        PlaybackChapterMarkView(start_ms=chapter.start_ms, title=chapter.title)
        for chapter in chapters_mod.effective_chapters(file.chapters, file.duration_seconds)
        if not chapter.synthetic
    ]


def _diagnostic_error(error: str | None) -> str | None:
    """截断并脱敏错误文本，避免把签名 URL 带进播放器诊断。"""
    if not error:
        return None
    sanitized = _DIAGNOSTIC_SECRET_RE.sub(r"\1<redacted>", error)
    return sanitized[-1000:]


def _diagnostic_processing_mode(session: TranscodeSession) -> str:
    """把内部档位归一成面向用户的执行模式。"""
    if session.remote:
        return "remote-hardware"
    if session.plan.video.action == "transcode":
        return "local-hardware" if session.hw_backend else "local-software"
    if session.plan.audio.action == "transcode":
        return "audio-transcode"
    return "remux"


def _diagnostic_encoder(session: TranscodeSession) -> str | None:
    if session.plan.video.action != "transcode":
        return None
    if session.hw_backend:
        backend = HW_BACKENDS.get(session.hw_backend)
        if backend is not None:
            return backend.encoder
    return "libx264"


def _diagnostic_playback_cursor(session: TranscodeSession) -> int:
    """取最近一次播放器活动对应的分片号，作为缺口展示的时间游标。

    播放器会并行请求分片，完成顺序也可能与请求顺序不同，所以优先使用最近
    一次请求（它代表播放器当前的供片意图），不能让晚到的旧分片响应把游标
    往回覆盖。没有请求记录时才回退到最近供给分片，再没有播放器事件则使用
    当前转码头。
    """
    if session.last_requested_segment is not None:
        return session.last_requested_segment
    if session.last_served_segment is not None:
        return session.last_served_segment
    return session.head_segment


def _build_playback_diagnostics(
    session: TranscodeSession,
) -> PlaybackDiagnosticsView:
    """组装单次快照；只读取内存台账和本地缓存，不返回任何访问凭据。"""
    manager = get_session_manager()
    registry = get_remote_worker_registry()
    worker = None
    if session.remote_worker_id:
        worker = next(
            (
                item
                for item in registry.snapshot()
                if item.get("worker_id") == session.remote_worker_id
            ),
            None,
        )
    job = registry.job_state(session.remote_job_id or "") if session.remote_job_id else None
    highest_produced = (
        manager._highest_produced(session) if session.segment_plan is not None else None
    )
    uploads = [
        PlaybackArtifactUploadView(
            name=event.name,
            status=event.status,
            received_bytes=event.received_bytes,
            content_length=event.content_length,
            transfer_encoding=event.transfer_encoding,
            occurred_at_ms=event.occurred_at_ms,
        )
        for event in list(reversed(session.remote_uploads))[:12]
    ]
    try:
        cache_bytes = session.size_bytes()
    except OSError:
        # 诊断轮询可能正好与结束会话并发；目录已开始清理时仍返回快照，
        # 不能因为统计临时目录大小把播放器旁路请求变成 500。
        cache_bytes = 0
    job_type = job.get("type") if job else None
    job_out_time_ms = job.get("out_time_ms") if job else None
    if not isinstance(job_out_time_ms, int):
        job_out_time_ms = None
    job_speed = job.get("speed") if job else None
    if not isinstance(job_speed, str):
        job_speed = None
    job_phase = job.get("phase") if job else None
    if not isinstance(job_phase, str):
        job_phase = None
    job_exit_code = job.get("exit_code") if job else None
    if not isinstance(job_exit_code, int) or isinstance(job_exit_code, bool):
        job_exit_code = None
    job_error = _diagnostic_error(
        job.get("error") if job and isinstance(job.get("error"), str) else None
    )
    job_stderr_tail = _diagnostic_error(
        job.get("stderr_tail") if job and isinstance(job.get("stderr_tail"), str) else None
    )
    session_error = _diagnostic_error(session.error)
    if session_error is None:
        session_error = job_error
    failed_segments = sorted(session.remote_failed_segments)
    playback_cursor = _diagnostic_playback_cursor(session)
    active_failed_segments = [segment for segment in failed_segments if segment >= playback_cursor][
        :32
    ]
    historical_failed_segments = [
        segment for segment in failed_segments if segment < playback_cursor
    ][:32]

    return PlaybackDiagnosticsView(
        session_state=session.state,
        session_error=session_error,
        processing_mode=_diagnostic_processing_mode(session),
        execution_location="remote_worker" if session.remote else "nas",
        backend=session.hw_backend,
        encoder=_diagnostic_encoder(session),
        worker_id=session.remote_worker_id,
        worker_version=worker.get("worker_version") if worker else None,
        worker_platform=worker.get("platform") if worker else None,
        worker_arch=worker.get("arch") if worker else None,
        ffmpeg_version=worker.get("ffmpeg_version") if worker else None,
        worker_online=(
            bool(worker.get("online"))
            if worker is not None
            else (None if session.remote_restarting else False)
        ),
        worker_last_seen_seconds=(
            float(worker["last_seen_seconds"])
            if worker is not None and worker.get("last_seen_seconds") is not None
            else None
        ),
        job_id=session.remote_job_id,
        attempt_id=session.remote_job_id,
        job_state=job_type if isinstance(job_type, str) else None,
        job_out_time_ms=job_out_time_ms,
        job_speed=job_speed,
        job_phase=job_phase,
        job_exit_code=job_exit_code,
        job_error=job_error,
        job_stderr_tail=job_stderr_tail,
        head_segment=session.head_segment if session.segment_plan is not None else None,
        highest_produced_segment=highest_produced,
        lead_seconds=manager.lead_seconds(session),
        pause_reasons=sorted(session.pause_reasons),
        cache_hit=session.cache_hit,
        cached_segments=session.cached_segments,
        requested_segment=session.last_requested_segment,
        served_segment=session.last_served_segment,
        segment_wait_ms=session.last_segment_wait_ms,
        segment_status=session.last_segment_status,
        pending_segments=sorted(session.pending_segments)[:32],
        failed_segments=active_failed_segments,
        historical_failed_segments=historical_failed_segments,
        recent_uploads=uploads,
        cache_bytes=cache_bytes,
        total_segments=session.segment_plan.count if session.segment_plan is not None else None,
        timeline=sorted(session.timeline, key=lambda entry: entry["t"]),
    )


@router.get(
    "/up-next",
    response_model=ApiResponse[UpNextView],
    summary="接下来继续",
    operation_id="playback.up-next",
    openapi_extra={"x-cli-hidden": True},
)
async def list_up_next(
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    this_device: Annotated[
        bool,
        Query(description="只看本设备播过的（iOS「接着看」条用，不混入 Infuse 等）"),
    ] = False,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[UpNextView]:
    """当前账号在可见媒体库中"接下来该接着看"的作品。

    每张卡都指向一个还没看完的单元；看完的作品不出现在这里。``this_device``
    按登录设备收窄；没有登录设备的凭证（旧网页会话）认不出"本设备"，返回空。
    """
    if this_device and principal.device is None:
        return ok(UpNextView(items=[]))
    visible_ids = await visible_library_ids(session, principal)
    member_id = principal.member_id if principal.member_id is not None else 0
    items = await up_next_items(
        session,
        member_id=member_id,
        visible_library_ids=visible_ids,
        limit=limit,
        device_id=(
            login_devices.playback_device_id(principal.device.id)
            if this_device and principal.device is not None
            else None
        ),
    )
    return ok(UpNextView(items=items))


_FAVORITE_SORT_DESC = (
    "排序：favorited_at=最近收藏在前（默认）/ title=按标题 / added_at=最近入账 / "
    "release_date=按上映时间 / rating=按评分 / runtime=按片长 / size=按体积 / "
    "last_played=最近观看——与单库海报墙同一套档位"
)
_ORDER_DESC = "方向：asc / desc；不给 = 该档的自然方向（收藏时间新→旧、标题 A→Z…）"


@router.get(
    "/favorites",
    response_model=ApiResponse[FavoritesView],
    summary="我的收藏",
    operation_id="playback.favorites",
    openapi_extra={"x-cli-hidden": True},
)
async def list_favorites(
    limit: Annotated[int, Query(ge=1, le=200)] = 20,
    offset: Annotated[int, Query(ge=0, description="跳过的作品数（全部收藏页滚动加载用）")] = 0,
    unwatched_first: Annotated[
        bool, Query(description="把还没看完的整体提前（首页横滚行用；全量页不传）")
    ] = False,
    sort: Annotated[FavoriteSort, Query(description=_FAVORITE_SORT_DESC)] = "favorited_at",
    order: Annotated[Literal["asc", "desc"] | None, Query(description=_ORDER_DESC)] = None,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[FavoritesView]:
    """列出当前账号在可见媒体库中收藏的作品（网页与 Jellyfin 客户端点的心同一份），
    默认最近收藏在前。首页横滚行取前 20 且把没看完的提前；「全部收藏」海报墙按
    offset 滚动加载，排序档与单库海报墙对齐（``sort`` / ``order``）。"""
    visible_ids = await visible_library_ids(session, principal)
    member_id = principal.member_id if principal.member_id is not None else 0
    items, total = await favorite_items(
        session,
        member_id=member_id,
        visible_library_ids=visible_ids,
        limit=limit,
        offset=offset,
        unwatched_first=unwatched_first,
        sort=sort,
        order=order,
    )
    return ok(FavoritesView(items=items, total=total))


@router.get(
    "/favorites/gallery",
    response_model=ApiResponse[list[LibraryGalleryGroupView]],
    summary="我的收藏 · 图廊：收藏作品的海报 / 剧照 / 章节场景图按作品分组铺平",
    operation_id="playback.favorites.gallery",
    openapi_extra={"x-cli-hidden": True},
)
async def list_favorites_gallery(
    limit: Annotated[int, Query(ge=1, le=100, description="本页作品数（按作品分页，不按图）")] = 24,
    offset: Annotated[int, Query(ge=0, description="跳过的作品数（滚动加载翻页用）")] = 0,
    sort: Annotated[FavoriteSort, Query(description=_FAVORITE_SORT_DESC)] = "favorited_at",
    order: Annotated[Literal["asc", "desc"] | None, Query(description=_ORDER_DESC)] = None,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[LibraryGalleryGroupView]]:
    """「全部收藏」页的图床浏览模式：与 ``/playback/favorites`` 同一份名单与顺序
    （``sort`` / ``order`` 传同一个值），一组就是一部作品的全部图。收藏跨库，
    每组带自己的详情落点库。没有任何图的作品也占一组，一页的组数恒等于作品数。"""
    visible_ids = await visible_library_ids(session, principal)
    member_id = principal.member_id if principal.member_id is not None else 0
    return ok(
        await favorite_gallery(
            session,
            member_id=member_id,
            visible_library_ids=visible_ids,
            limit=limit,
            offset=offset,
            sort=sort,
            order=order,
        )
    )


@router.get(
    "/activity",
    response_model=ApiResponse[MediaActivityView],
    summary="看此刻家里谁在看什么、用哪台设备、速度多快",
    operation_id="playback.activity",
    dependencies=[Depends(require_admin)],
)
async def get_media_activity(
    scope: Annotated[
        Literal["visible", "all"],
        Query(description="visible=按我的浏览范围折叠范围外记录；all=跨库全量"),
    ] = "visible",
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[MediaActivityView]:
    """列出所有正在播放和正在下载的实时会话。

    每条包含成员、设备与客户端、正在看的片名和集号、播放进度与实时传输速率。
    「电视卡了 / 网怎么这么慢」时第一个该看的地方：一眼知道是不是有人在同时
    看片或拉文件。只显示此刻正在发生的事，看历史用 playback.history。

    ``scope=visible``（默认）把落在当前超管不可浏览的库里的记录折叠成计数，
    不出片名；``scope=all`` 是管控视角的全量口径——``admin_visible`` 是超管
    给自己设的浏览过滤而非安全边界，管理员有权看到所有人的全部播放活动。
    """
    return ok(
        await media_activity_overview(
            session,
            browsable_library_ids=await visible_library_ids(session, principal),
            fold_hidden=scope == "visible",
        )
    )


@router.post(
    "/activity/sessions/{device_id}/end",
    response_model=ApiResponse[None],
    summary="掐断某台设备正在进行的播放（不影响登录）",
    operation_id="playback.activity.end",
    dependencies=[Depends(require_admin)],
    # confirm 而非 destructive：只掐断本次播放，凭据与观看进度都不动，
    # 设备下次亲手点播放即可继续
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def end_device_playback(
    device_id: Annotated[str, Path(min_length=1, max_length=256)],
) -> ApiResponse[None]:
    """让指定设备立刻停止播放，一分钟内不能续播。

    用在「孩子该睡觉了」「某台设备把带宽吃光了」这类场景。设备的登录状态、
    看到第几分钟、收藏都不动，人重新点一下播放就能接着看；要让设备彻底登出
    请用 playback.device.revoke。

    实时会话立即消失并进入一分钟的拒绝窗口，直出取流与转码会话一并停止。
    网页播放器收到信号后退出；Jellyfin 客户端会看到播放中断，重新点播放即可继续。
    """
    label = live_session_label(device_id)
    if label is None:
        raise NotFoundException("这台设备当前没有在播放")
    await end_playback(device_id)
    return ok(None, message=f"已结束「{label}」的播放")


@router.get(
    "/history",
    response_model=ApiResponse[PlaybackHistoryView],
    summary="翻看每一场播放的流水：谁、什么时候、看了什么、看了多久",
    operation_id="playback.history",
    dependencies=[Depends(require_admin)],
)
async def list_playback_history(
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    before: Annotated[
        int | None, Query(ge=1, description="游标：上一页最后一行的 id，取更早的记录")
    ] = None,
    days: Annotated[int | None, Query(ge=1, le=365)] = None,
    member_id: Annotated[int | None, Query(ge=0)] = None,
    scope: Annotated[Literal["visible", "all"], Query()] = "visible",
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackHistoryView]:
    """按时间倒序列出播放记录，一场播放一行。

    每行带成员、设备、片名集号、看到的百分比、是否看完与实际观看时长，
    用来回答「上周谁看过这部」「这台电视最近都在放什么」。

    翻页用 ``before`` 接上一页最后一行的 id（响应里的 ``next_cursor``），
    而不是页码：这样翻页期间新产生的记录不会把同一行挤到两页里各出现一次。
    可见范围口径（``scope``）与 playback.activity 相同。"""
    return ok(
        await playback_history(
            session,
            limit=limit,
            before=before,
            days=days,
            member_id=member_id,
            browsable_library_ids=await visible_library_ids(session, principal),
            fold_hidden=scope == "visible",
        )
    )


@router.get(
    "/stats/watch",
    response_model=ApiResponse[PlaybackWatchStatsView],
    summary="一段时间的观看总览：看了多久、多少场、看完率、活跃了几个人",
    operation_id="playback.stats.watch",
    dependencies=[Depends(require_admin)],
)
async def get_watch_stats(
    days: Annotated[int, Query(ge=1, le=365)] = 30,
    tz_offset: Annotated[
        int, Query(ge=-840, le=840, description="浏览器时区相对 UTC 的分钟数（东八区 480）")
    ] = 0,
    member_id: Annotated[int | None, Query(ge=0)] = None,
    scope: Annotated[Literal["visible", "all"], Query()] = "visible",
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackWatchStatsView]:
    """统计最近 N 天的观看情况，并和上一个同长度周期成对给出，看得出是变多还是变少。

    除了汇总数（观看时长、播放场次、看完率、活跃成员）还给出按天的序列、
    星期×小时的分布（家里通常什么时候有人看，可以据此安排扫描、刮削这类重活），
    以及按成员 / 客户端 / 播放档位 / 作品的分解。``member_id`` 把整份统计收窄到
    一个成员。``tz_offset`` 是本地时区相对 UTC 的分钟数（东八区 480），不给就按
    UTC 分天——服务端不猜调用方在哪个时区。

    作品榜走可见范围折叠，其余是不出片名的聚合数。"""
    return ok(
        await playback_stats(
            session,
            days=days,
            tz_offset_minutes=tz_offset,
            member_id=member_id,
            browsable_library_ids=await visible_library_ids(session, principal),
            fold_hidden=scope == "visible",
        )
    )


@router.delete(
    "/history",
    response_model=ApiResponse[PlaybackHistoryClearView],
    summary="清除自己的观看记录（按条目 / 按库 / 全部）",
    operation_id="playback.history.clear",
    openapi_extra={"x-cli-hidden": True, "x-cli-dangerous": "destructive"},
)
async def clear_playback_history(
    scope: Annotated[Literal["item", "library", "all"], Query(description="清除范围")],
    media_item_id: Annotated[int | None, Query(description="scope=item 时的条目 id")] = None,
    library_id: Annotated[int | None, Query(description="scope=library 时的库 id")] = None,
    since: Annotated[
        datetime | None,
        Query(description="时间窗口起点（ISO 8601）：只清这个时刻之后播放过的记录"),
    ] = None,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackHistoryClearView]:
    """只删**当前登录主体自己**的记录（续播点、已看标记、播放次数与播放质量
    指标），超管删的是超管自己的；跨成员删除不提供（docs/design/library-access.md 2.6）。

    按条目/按库清除要求目标在主体的可浏览范围内——范围外无从得知条目，也不该能删。
    ``since`` 可叠在任一范围上：首页「清空今天 / 最近一周的观看记录」由前端按
    浏览器时区算出起点传来，服务端不猜用户在哪个时区。
    """
    from movieclaw_api.services import playback_history

    member_id = principal.member_id if principal.member_id is not None else 0
    if since is not None and since.tzinfo is not None:
        # 数据库里一律存 UTC 朴素时间（movieclaw_db.models.base.utcnow），
        # 带时区的入参先归一，否则 SQLite 比较的是字符串会得出错误结果
        since = since.astimezone(UTC).replace(tzinfo=None)
    if scope == "item":
        if media_item_id is None:
            raise BadRequestException("按条目清除需要 media_item_id")
        await assert_item_visible(session, principal, media_item_id)
        result = await playback_history.clear(
            session, member_id, media_item_id=media_item_id, since=since
        )
        message = "已清除这部作品的观看记录"
    elif scope == "library":
        if library_id is None:
            raise BadRequestException("按库清除需要 library_id")
        await assert_library_visible(session, principal, library_id)
        result = await playback_history.clear(
            session, member_id, library_id=library_id, since=since
        )
        message = "已清除你在这个库里的观看记录"
    elif since is not None:
        result = await playback_history.clear(session, member_id, since=since)
        message = "已清除你这段时间的观看记录"
    else:
        result = await playback_history.clear(session, member_id)
        message = "已清除你的全部观看记录"
    logger.info(
        "观看记录已清除：主体=%s 范围=%s 起点=%s 状态 %d 条 / 指标 %d 条",
        principal,
        scope,
        utc_isoformat(since) if since is not None else "不限",
        result.deleted_states,
        result.deleted_metrics,
    )
    return ok(result, message=message)


@router.delete(
    "/devices/{device_id}",
    response_model=ApiResponse[None],
    summary="注销一台播放设备，让它下次必须重新登录",
    operation_id="playback.device.revoke",
    dependencies=[Depends(require_admin)],
    # confirm 而非 destructive：注销会中断该设备正在进行的播放/下载并要求重新
    # 登录，但不销毁任何数据——观看进度、收藏按成员保存，与设备无关。
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def revoke_playback_device(
    device_id: Annotated[str, Path(min_length=1, max_length=256)],
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[None]:
    """立刻吊销这台设备的登录凭据，它正在进行的播放与下载一并中断。

    下次使用要重新输入账号密码（电视上会比较麻烦，所以需要确认）。用在设备
    丢了、借出去的账号要收回，或者不认识的设备出现在活动列表里的时候。

    观看进度和收藏是按人保存的，不会因为注销设备而丢失。只想停掉这一次播放
    用 playback.activity.end。
    """
    label = await revoke_device(session, device_id)
    if label is None:
        raise NotFoundException("设备不存在或已注销")
    return ok(None, message=f"已注销「{label}」，该设备需重新登录")


@router.post(
    "/decide",
    response_model=ApiResponse[PlaybackDecisionView],
    summary="播放决策",
    operation_id="playback.decide",
    openapi_extra={"x-cli-hidden": True},
)
async def decide_playback_route(
    payload: PlaybackDecideRequest,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
    user_agent: Annotated[str | None, Header(include_in_schema=False)] = None,
) -> ApiResponse[PlaybackDecisionView]:
    """算出「这部片在你的浏览器上该怎么放」（docs/design/web-player.md §3）。

    请求带上客户端的解码能力快照，服务端结合入库时 ffprobe 落下的规格真值，
    在五档降级阶梯里取能成立的最小档——尽可能不转码。

    返回三态：``plan`` 可以播；``consent`` 需要用户同意开启软件转码；
    ``rejected`` 放不了，附中文原因与下一步建议。
    """
    _remember_capability(payload, principal, user_agent)
    # 决策接口与开会话接口必须共享同一组参数转发和可见性规则；否则客户端
    # 在切换音轨/字幕/清晰度时会看到与实际起播不同的计划。观看记忆（上次的
    # 音轨 / 字幕）也按开会话的口径套上：App 的自动选引擎拿这里的结果决定开
    # 哪种会话，探测说「直出」、真开会话却因记住的 PGS 字幕整片压制，就会白白
    # 拉起又掐掉一路转码（2026-09-27 NAS 实测）。
    wants_memory = payload.audio_track is None or payload.subtitle_track is None
    if payload.media_item_id is not None and wants_memory:
        member_id = principal.member_id if principal.member_id is not None else 0
        unit = (payload.media_item_id, payload.season_number, payload.episode_number)
        states = await playback_state.get_states(
            session, [payload.media_item_id], member_id=member_id
        )
        payload = _with_watch_memory(payload, states.get(unit))
        payload, _ = await _with_series_memory(session, payload, states, unit)
    decision = await _decide(payload, principal, session)

    if decision is None:
        raise NotFoundException("没有找到可播放的文件")
    return ok(playback_plan.to_view(decision))


_RequestT = TypeVar("_RequestT", bound=PlaybackDecideRequest)


async def _with_series_memory(
    session: AsyncSession,
    request: _RequestT,
    states: dict[tuple[int, int, int], PlaybackState],
    unit: tuple[int, int, int],
) -> tuple[_RequestT, tuple[str | None, str | None]]:
    """本集没有记忆时，沿用同一部剧最近一集的音轨 / 字幕（按语言换算，见 ``track_memory``）。

    返回（补上记忆的请求，实际补上的（音轨, 字幕））——后者随观看状态带回，
    客户端据此提示「已沿用上次的选择」。
    """
    if request.audio_track is not None and request.subtitle_track is not None:
        return request, (None, None)
    target = None
    if request.file_id is not None:
        target = await session.get(LibraryFile, request.file_id)
    audio, subtitle = await track_memory.series_track_memory(session, states, unit, target)
    audio = audio if request.audio_track is None else None
    subtitle = subtitle if request.subtitle_track is None else None
    update = {k: v for k, v in (("audio_track", audio), ("subtitle_track", subtitle)) if v}
    return (request.model_copy(update=update) if update else request), (audio, subtitle)


def _with_watch_memory(request: _RequestT, watch_row: PlaybackState | None) -> _RequestT:
    """没指定音轨 / 字幕时沿用上次的选择（decide 与开会话同一口径）。

    轨在这次选中的文件里不存在时 decide 会自动回退默认轨（换版本文件轨序会变，
    这是既有覆盖）。字幕记忆里只有 PGS 会改变视频策略（继续烧录），文本轨 / "off"
    在 decide 里是 no-op。
    """
    if watch_row is None:
        return request
    update: dict[str, str] = {}
    if request.audio_track is None and watch_row.audio_track:
        update["audio_track"] = watch_row.audio_track
    if request.subtitle_track is None and watch_row.subtitle_track:
        update["subtitle_track"] = watch_row.subtitle_track
    return request.model_copy(update=update) if update else request


# ---------------------------------------------------------------------------
# 网页播放器：会话与取流（docs/design/web-player.md §4）
#
# 取流端点一律**不挂登录依赖**，改用查询参数里的短时效签名 token：
# <video src>、hls.js 拉分片、原生 HLS 都带不了自定义 header，整条取流链路
# 在浏览器内部，JS 插不进手（§4.7）。
# ---------------------------------------------------------------------------

# 只放行会话目录里由 ffmpeg 产出的两类文件名。**这是路径穿越的唯一防线**：
# 会话 id 来自签名 token 可信，但文件名来自 URL，必须白名单而不是过滤。
_SEGMENT_NAME = re.compile(r"^(init\.mp4|seg\d{5}\.(?:m4s|ts))$")
# 雪碧图文件名由服务端生成，但仍经过 URL——白名单一视同仁。
_TRICKPLAY_SHEET_NAME = re.compile(r"^sprite_\d{3}\.jpg$")


#: 播放列表里 `#EXT-X-MAP` 那行的初始化段地址，形如 `URI="init.mp4"`。
_PLAYLIST_MAP_URI = re.compile(r'(#EXT-X-MAP:.*?URI=")([^"]+)(")')


def playlist_with_tokens(playlist: str, token: str) -> str:
    """给播放列表里的每个分片地址补上取流 token。

    ffmpeg 写出来的地址是裸相对路径（`init.mp4` / `seg00000.m4s`），而浏览器
    按**播放列表自身的 URL** 解析相对地址时**会把 query 丢掉**——播放列表带着
    `?token=` 请求成功，它引用的分片却一个凭据都没有，全部倒在鉴权上。整条取流
    链路在浏览器内部，JS 插不进手补 header（§4.7），所以只能由服务端在发出前把
    token 写进每个地址。

    只改地址行：`#` 开头的是标签，除了 `EXT-X-MAP` 里的 URI 之外都不带地址。
    """
    if not token:
        return playlist
    query = f"?token={token}"
    lines = []
    for line in playlist.splitlines(keepends=True):
        stripped = line.strip()
        if not stripped:
            lines.append(line)
        elif stripped.startswith("#"):
            lines.append(_PLAYLIST_MAP_URI.sub(rf"\g<1>\g<2>{query}\g<3>", line))
        else:
            lines.append(line.replace(stripped, stripped + query, 1))
    return "".join(lines)


def _share_stream_kwargs(principal: Principal) -> dict[str, int]:
    """分享访客的取流 token 附加项：带分享 id（字节面据此回查分享是否仍有效），
    有效期不超过分享到期剩余（docs/design/media-share.md §4.3）。成员为空。"""
    if principal.share is None:
        return {}
    remaining = int((principal.share.expires_at - utcnow()).total_seconds())
    return {
        "share_id": principal.share.share_id,
        "ttl_seconds": max(1, min(STREAM_TOKEN_TTL_S, remaining)),
    }


#: 原生 App 在播放会话里报的 client：自研引擎直出原文件，用不上详情页的关键帧采样预热
NATIVE_APP_CLIENTS = ("ios", "tvos")


def _remember_capability(
    payload: PlaybackDecideRequest, principal: Principal, user_agent: str | None
) -> None:
    """把客户端上报的解码能力记给详情页预热：它据此判断值不值得读盘采样。"""
    playback_warmup.remember_capability(
        playback_warmup.identity_of(principal),
        user_agent,
        playback_plan.capability_from_request(payload.capability),
    )


def _remember_session_capability(
    payload: PlaybackSessionRequest, principal: Principal, user_agent: str | None
) -> None:
    """开会话也记下客户端的解码能力，供详情页起播预热（warmup.py）判断值不值得读盘采样。

    原来只在 /decide 里记，而网页早已改成直接开会话（续播点并进开会话，web-player.md §6.10），
    两个客户端都不再调 /decide——预热对网页一直没生效。原生 App（iPhone、Apple TV 同一个自研引擎）
    直出原文件、用不上关键帧采样，不记（免得它偶尔走系统播放器时申报的能力把同一账号的记录搅乱）。
    """
    if payload.client in NATIVE_APP_CLIENTS:
        return
    _remember_capability(payload, principal, user_agent)


async def _decide(
    payload: PlaybackDecideRequest,
    principal: Principal,
    session: AsyncSession,
):
    """decide 与开会话共用的取数与判定。

    **可见性在这里收口两次**：库范围（``visible_library_ids``）之外，还要过
    ``assert_item_visible``——它带着成员的内容分级约束。少了这一道，儿童档案
    只是看不到超分级的片，直链一个 ``media_item_id`` 过来照样起播；收窄只做在
    列表上，等于挡住了浏览、没挡住播放。

    ``_decide`` 是 decide、开会话与两处降级重试共用的唯一入口，所以这一道
    只需要写在这里。
    """
    visible = await visible_library_ids(session, principal)
    guard_item_id = payload.media_item_id
    if guard_item_id is None and payload.file_id is not None:
        file_row = await session.get(LibraryFile, payload.file_id)
        guard_item_id = file_row.media_item_id if file_row is not None else None
    if guard_item_id is not None:
        await assert_item_visible(session, principal, guard_item_id)
    capability = playback_plan.capability_from_request(payload.capability)
    failed = frozenset(Tier(t) for t in payload.failed_tiers if t in Tier._value2member_map_)
    if payload.file_id is not None:
        return await playback_plan.decide_for_file(
            session,
            payload.file_id,
            capability,
            can_self_enable=principal.is_admin,
            failed_tiers=failed,
            preferred_audio=payload.audio_track,
            preferred_subtitle=payload.subtitle_track,
            max_height=payload.max_height,
            visible_library_ids=visible,
        )
    if payload.media_item_id is not None:
        # 默认轨策略的上下文（库语言、原始语言）随取文件的同一条 SQL 取出，不多查一次
        files, contexts = await files_with_contexts(
            session,
            playback_plan.library_files_statement(
                payload.media_item_id,
                payload.season_number,
                payload.episode_number,
                visible_library_ids=visible,
            ),
        )
        return await playback_plan.decide_for_files(
            files,
            capability,
            can_self_enable=principal.is_admin,
            failed_tiers=failed,
            preferred_audio=payload.audio_track,
            preferred_subtitle=payload.subtitle_track,
            max_height=payload.max_height,
            contexts=contexts,
        )
    raise BadRequestException("需要提供 file_id 或 media_item_id")


@router.post(
    "/sessions",
    response_model=ApiResponse[PlaybackSessionView],
    summary="开始播放",
    operation_id="playback.session.start",
    openapi_extra={"x-cli-hidden": True},
)
async def start_playback_session(
    payload: PlaybackSessionRequest,
    response: Response,
    background_tasks: BackgroundTasks,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
    user_agent: Annotated[str | None, Header(include_in_schema=False)] = None,
) -> ApiResponse[PlaybackSessionView]:
    """判定档位并（需要时）起转码会话，返回可直接播放的地址。

    档 0 不起会话，直接给原文件的签名直出地址；档 1–4 起 ffmpeg 会话，
    playlist 一出现就返回——分片按需生成，客户端边拉边转。

    观看状态在这里一并解析（§6.10）：``start_ms`` 缺省时用续播点（看完的
    从头播）、``audio_track`` 缺省时用上次听的那条轨，整份状态随响应带回。
    起播链路因此不用先问一次 ``/resume``——省一个串行往返，分享出去的链接
    也天然「各看各的进度」。

    播放体验打点（docs/design/playback-qoe.md §2、§5.2）：请求带播放编号时，每个出口都在响应
    之后于后台记一条「已开始」（档位、决策原因、转码计划、服务端各段耗时），取流令牌写进编号；
    响应头 ``Server-Timing`` 回传服务端各段耗时，App 据此把起播分段拆成网络往返与服务端处理。
    """
    started_at = time.perf_counter()
    member_id = principal.member_id if principal.member_id is not None else 0
    attempt_id = payload.attempt_id or None
    _remember_session_capability(payload, principal, user_agent)

    def attempt_started(
        file_id: int | None, tier: int, view: PlaybackDecisionView, **timings: int
    ) -> None:
        """回传服务端耗时，并（有播放编号时）排一个后台任务记「已开始」。"""
        timings = {"total": int((time.perf_counter() - started_at) * 1000), **timings}
        response.headers["Server-Timing"] = ", ".join(
            f"{name};dur={value}" for name, value in timings.items()
        )
        if attempt_id is None:
            return
        background_tasks.add_task(
            _begin_attempt_in_background,
            attempt_id=attempt_id,
            member_id=member_id,
            file_id=file_id,
            tier=tier,
            client=payload.client or "",
            server=_attempt_server_facts(view, timings),
        )

    # 分享访客的 token 多带分享 id、有效期不超过分享到期（media-share.md §4.3）
    share_kwargs = _share_stream_kwargs(principal)
    # 取流 token 带上浏览器设备标识：取流字节据此记到活动页上这台浏览器的
    # 会话名下（与进度上报同一个标识）
    device_id = playback_watch.web_device_id(
        payload.device_id,
        member_id=member_id,
        login_device_id=principal.device.id if principal.device is not None else None,
    )
    if activity.device_ended(device_id):
        # 管理员刚在活动页结束了这台浏览器的播放：拒绝窗口内不再开会话，
        # 否则播放器把会话 404 当成超时回收、原地重开，结束就等于没结束
        raise ConflictException("管理员已结束本次播放，一分钟后可重新开始")
    watch_row = None
    watch_view: PlaybackStateView | None = None
    if payload.media_item_id is not None:
        unit = (payload.media_item_id, payload.season_number, payload.episode_number)
        states = await playback_state.get_states(
            session, [payload.media_item_id], member_id=member_id
        )
        watch_row = states.get(unit)
        payload = _with_watch_memory(payload, watch_row)
        payload, inherited = await _with_series_memory(session, payload, states, unit)
        watch_view = PlaybackStateView(
            position_ms=watch_row.position_ms if watch_row else 0,
            played=watch_row.played if watch_row else False,
            play_count=watch_row.play_count if watch_row else 0,
            duration_ms=await playback_state.unit_runtime_ms(session, unit),
            audio_track=(watch_row.audio_track if watch_row else None) or inherited[0],
            subtitle_track=(watch_row.subtitle_track if watch_row else None) or inherited[1],
        )
    resolved_start_ms = payload.start_ms
    if resolved_start_ms is None:
        # 看完的重播从头开始——续播到最后三十秒等于点开就是片尾
        resolved_start_ms = 0 if (watch_row is None or watch_row.played) else watch_row.position_ms

    decision = await _decide(payload, principal, session)
    decide_ms = int((time.perf_counter() - started_at) * 1000)
    if decision is None:
        raise NotFoundException("没有找到可播放的文件")
    view = playback_plan.to_view(decision)
    if view.outcome != "plan":
        attempt_started(view.file_id, -1, view, decide=decide_ms)
        return ok(PlaybackSessionView(decision=view, watch=watch_view))

    file = await session.get(LibraryFile, view.file_id)
    if file is None:
        raise NotFoundException("文件已不在台账中")

    manager = get_session_manager()
    if view.tier != int(Tier.DIRECT_PLAY):
        # 第一次决策可能看到同文件旧会话仍占着远程 Worker 的槽位，暂时落到
        # 软件转码。先释放旧会话，再重新决策一次，才能把刚空出来的远程能力
        # 纳入最终结果；没有旧会话时不重复做这次决策。
        replaced = await manager.stop_for_file(file.id, member_id)
        if replaced:
            decision = await _decide(payload, principal, session)
            if decision is None:
                raise NotFoundException("没有找到可播放的文件")
            view = playback_plan.to_view(decision)
            if view.outcome != "plan":
                attempt_started(view.file_id, -1, view, decide=decide_ms)
                return ok(PlaybackSessionView(decision=view, watch=watch_view))
            file = await session.get(LibraryFile, view.file_id)
            if file is None:
                raise NotFoundException("文件已不在台账中")

    # 诊断面板的「源 → 处理」层次要有左半边：台账真值原样带回（§6.5）
    source_view = PlaybackSourceView(
        container=file.container,
        resolution=file.resolution,
        video_codec=file.video_codec,
        hdr=file.hdr,
        bit_rate=file.bit_rate,
        frame_rate=file.frame_rate,
        size_bytes=file.size_bytes,
    )
    chapter_marks = _chapter_marks(file)
    # 片头片尾（docs/design/skip-intro.md）：两次主键查询；这一季还没识别过就在后台
    # 排一份优先作业（延迟开跑、去重），这一集多半赶不上，下一集就有了
    segment_views = [
        PlaybackSegmentView(**seg) for seg in await skip_segments.segments_for_file(session, file)
    ]
    if not segment_views:
        skip_segments.schedule_playback_bump(file)

    # 详情页可能正在为同一条目预热；正式播放已经接管 IO，取消那条后台任务，
    # 别让它和首片转码抢同一块盘。
    playback_warmup.cancel(file.media_item_id)

    # 进度条缩略图：后台起，不挡首帧；延迟 90 秒 + 读入限速，起播关键窗口
    # 不与首片转码抢 IO（「首次起播卡缓冲、重进就好」的头号元凶，§6.10）。
    trickplay.schedule(file, delay_s=90)

    subtitle_urls = [
        f"/api/v1/playback/files/{file.id}/subtitles"
        f"?track={quote(s.track_ref, safe='')}"
        f"&token={await issue_stream_token(member_id=member_id, file_id=file.id, **share_kwargs)}"
        for s in view.subtitles
    ]

    if view.tier == int(Tier.DIRECT_PLAY):
        token = await issue_stream_token(
            member_id=member_id,
            file_id=file.id,
            device_id=device_id,
            attempt_id=attempt_id,
            **share_kwargs,
        )
        # 分段计时（§6.10）：用户报「起播慢」时，这一行直接指认卡在哪一段。
        # 决策段偏慢多半是关键帧采样在现场读盘——详情页预热没盖住的路径。
        logger.info(
            "播放会话就绪：档 0 直出 · 决策 %d 毫秒（file_id=%s attempt=%s）",
            decide_ms,
            file.id,
            attempt_id or "-",
        )
        # MKV 精简索引（§9.12）：缓存里有就随会话下发，引擎起播时不必再下原索引；没有就等起播
        # 窗口过去在后台生成，给续播和下一次用。顺带把下一集也排上，追剧时点开下一集就用得上
        matroska_cues = None
        if view.disc is None and video_cues.is_matroska(file.file_path):
            cues = await asyncio.to_thread(video_cues.cached, file.id, file.file_path)
            if cues is not None:
                matroska_cues = MatroskaCuesView(
                    offset=cues.cues_offset,
                    data=base64.b64encode(cues.data).decode("ascii"),
                    original_bytes=cues.original_bytes,
                )
            video_cues.schedule(file)
        attempt_started(file.id, int(Tier.DIRECT_PLAY), view, decide=decide_ms)
        return ok(
            PlaybackSessionView(
                decision=view,
                matroska_cues=matroska_cues,
                # 目录直推（disc-direct-play.md）：地址是目录清单，引擎按清单逐个文件取字节
                stream_url=(
                    f"/api/v1/playback/files/{file.id}/disc?token={token}"
                    if view.disc == "folder"
                    else f"/api/v1/playback/files/{file.id}/stream?token={token}"
                ),
                # 直出没有会话时间轴，续播位置由前端 seek 到 watch.position_ms
                start_ms=resolved_start_ms,
                subtitle_urls=subtitle_urls,
                watch=watch_view,
                source=source_view,
                chapters=chapter_marks,
                segments=segment_views,
            )
        )

    # 原盘（disc-playback.md §3.4）：ffmpeg 吃不了目录——单剪辑也走 concat
    # 清单（时间轴 = 播放列表时间，与台账时长、章节同口径），关键帧索引来自
    # CLPI 的 EP_map。远程 Worker 读的是 NAS 下发的 ffconcat 清单（各段剪辑一个
    # HTTP 地址，remote-transcode.md §5.2），只派给申报了能读原盘的 Worker
    disc = disc_source_for_file(file) if file.is_disc() else None
    if file.is_disc() and disc is None:
        raise NotFoundException("原盘主播放列表不可读，无法播放；请检查 BDMV/PLAYLIST 是否完整")

    async def _keyframe_index():
        """全片关键帧索引，只有直通档的 VOD 规划要它。冷缓存时 mp4 要过
        ffprobe（上秒级）——这是把它并入 gather 的主要理由：分享链接直达
        播放页时详情页预热没跑过，串行 await 会把这一秒全记在起播上。"""
        if not file.duration_seconds or not view.video or view.video.action != "copy":
            return None
        if disc is not None:
            return await asyncio.to_thread(disc.keyframe_index)
        # 只走读索引的快路径（Matroska Cues、MP4 moov）。要 ffprobe 通读整片才拿得到的（TS 等），
        # 这次直接走会话相对模式，索引由后台补全给下一次（schedule_background_index）——原来在这里
        # 当场通读，NFS 上的大文件 120 秒超时作废，每次播放都白等
        return await asyncio.to_thread(read_keyframe_index, file.file_path, allow_ffprobe=False)

    # 三件准备工作互相独立，并行做：策略读取（设置存储自带短会话，与请求
    # 会话无关）、硬件后端探测、关键帧索引。旧会话已在上面的最终决策前串行
    # 释放，不能重新放回这里，否则远程 Worker 的槽位又会产生竞态。
    prep_started_at = time.perf_counter()
    policy, backends, keyframe_index = await asyncio.gather(
        get_setting_store().get(PlaybackPolicySetting),
        asyncio.to_thread(available_backends),
        _keyframe_index(),
    )
    # ``backends`` 可能包含外置 Worker 的 videotoolbox；本地命令只能从真实的
    # NAS 探测快照中选编码器。只有在执行端确认仍在线时，才把 videotoolbox
    # 作为远程命令发给 Worker。
    local_backends = await asyncio.to_thread(available_local_backends) if backends else ()
    remote_video_available = remote_worker_available("videotoolbox", disc=disc is not None)
    prep_ms = int((time.perf_counter() - prep_started_at) * 1000)
    if disc is None and view.video is not None and view.video.action == "copy":
        # 视频直通的会话：MP4 快路径只抽检了部分关键帧的，起播之后在后台全量核对；快路径拿不到
        # 索引的（TS 等），后台补全给下一次播放（keyframes.py 的 schedule_background_index）
        schedule_background_index(file.file_path)
    # 只有真的转视频才谈得上硬件加速：直通档（-c:v copy）不经编码器，报个
    # 后端名只会让诊断面板骗人。烧录时 VAAPI/QSV 会退软件编码（overlay 是
    # 软件滤镜，这两家编码器吃不了软件帧），同样要报实际值。后端选择必须
    # 结合当前计划的滤镜兼容性，不能把合并能力列表的第一项当成可执行后端。
    execution_backend, use_remote = playback_plan.select_execution_backend(
        decision,
        available=backends,
        local_backends=local_backends,
        remote_video_available=remote_video_available,
    )
    if view.tier == int(Tier.HARDWARE_TRANSCODE) and execution_backend is None:
        # 决策阶段看到的硬件能力可能在准备阶段断线，或本地后端与当前滤镜链
        # 不兼容。不能把硬件档的计划悄悄交给 libx264；把硬件档标记为失败后
        # 重新走统一降档逻辑：软件开关关闭时返回 consent，开启时才允许软转。
        logger.info(
            "硬件转码在准备阶段落空（远程 Worker 刚断开或本地后端与滤镜链不兼容），"
            "改走统一降档：file_id=%s 本地后端=%s 远程可用=%s",
            file.id,
            ",".join(local_backends) or "无",
            remote_video_available,
        )
        retry_failed_tiers = sorted({*payload.failed_tiers, int(Tier.HARDWARE_TRANSCODE)})
        fallback_payload = payload.model_copy(update={"failed_tiers": retry_failed_tiers})
        decision = await _decide(fallback_payload, principal, session)
        if decision is None:
            raise NotFoundException("没有找到可播放的文件")
        view = playback_plan.to_view(decision)
        if view.outcome != "plan":
            attempt_started(view.file_id, -1, view, decide=decide_ms)
            return ok(PlaybackSessionView(decision=view, watch=watch_view))
        file = await session.get(LibraryFile, view.file_id)
        if file is None:
            raise NotFoundException("文件已不在台账中")
        source_view = PlaybackSourceView(
            container=file.container,
            resolution=file.resolution,
            video_codec=file.video_codec,
            hdr=file.hdr,
            bit_rate=file.bit_rate,
            frame_rate=file.frame_rate,
            size_bytes=file.size_bytes,
        )
        playback_warmup.cancel(file.media_item_id)
        trickplay.schedule(file, delay_s=90)
        subtitle_urls = [
            f"/api/v1/playback/files/{file.id}/subtitles"
            f"?track={quote(s.track_ref, safe='')}"
            "&token="
            f"{await issue_stream_token(member_id=member_id, file_id=file.id, **share_kwargs)}"
            for s in view.subtitles
        ]
        execution_backend = None
        use_remote = False
    # 按实测线路带宽收紧转码码率（docs/design/player-pipeline-optimization.md §C）。
    # 用户手动选了画质上限时不动——他的选择优先于自动。
    if payload.max_height is None:
        adapted = adapt_to_downlink(decision, payload.downlink_bps)
        if adapted is not decision:
            decision = adapted
            view = playback_plan.to_view(decision)
            logger.info(
                "按线路带宽收紧转码：downlink=%s bps → 高度 %s 码率上限 %s bps（file_id=%s）",
                payload.downlink_bps,
                view.video.height if view.video else None,
                view.video.bitrate_cap_bps if view.video else None,
                file.id,
            )
    hw_used = (
        effective_hw_backend(decision, execution_backend)
        if execution_backend and view.video and view.video.action == "transcode"
        else None
    )
    # 仅把「硬件转码」任务交给远程硬件 Worker；直通/音频单转继续走 NAS，
    # 软件转码也保留本地回路。
    #
    # 这里取到的是**覆盖项**，通常为空：源/产物地址默认用接单 Worker 自己
    # 连上来的地址（remote_worker.py 的 observed_base_url），不需要配置。
    # 注意不能改用**播放请求**的 Host 头推导——那是浏览器够得着的地址，
    # 和 Worker 够得着的地址不是一回事。
    remote_base_url = effective_remote_transcode_config().base_url
    # VOD 预生成规划（§12）：直通档每个关键帧一段（hls_vod 模块文档）；转码档
    # force_key_frames 在绝对栅格上强插关键帧，用等长规划。规划失败（时长
    # 未知 / 关键帧索引读不出）退回旧的会话相对模式，一切照旧。
    segment_plan = None
    if file.duration_seconds:
        duration_s = float(file.duration_seconds)
        if view.video and view.video.action == "transcode":
            segment_plan = compute_uniform_plan(duration_s, target_s=SEGMENT_SECONDS)
        elif keyframe_index is not None:
            segment_plan = compute_keyframe_plan(keyframe_index.times_s, duration_s)
    start_ms = resolved_start_ms
    if segment_plan is None and start_ms > 0 and view.video and view.video.action == "copy":
        # 旧模式的关键帧校正（VOD 下不需要：start() 自己对齐到分片边界）
        keyframe_s = await asyncio.to_thread(probe_keyframe_before, file.file_path, start_ms / 1000)
        if keyframe_s is not None:
            start_ms = int(keyframe_s * 1000)
    spawn_started_at = time.perf_counter()
    try:
        transcode = await manager.start(
            decision,
            source_path=file.file_path,
            member_id=member_id,
            start_ms=start_ms,
            segment_plan=segment_plan,
            hw_backend=execution_backend,
            # 资源上限不再是配置项，按机器规格自动推导（limits.py）
            max_transcode=auto_transcode_concurrency(hardware=bool(execution_backend)),
            max_remux=MAX_REMUX_CONCURRENCY,
            quota_bytes=auto_quota_bytes(manager.cache_root),
            use_remote=use_remote,
            remote_base_url=remote_base_url if use_remote else "",
            # 远程 Worker 的菜单栏拿它显示「正在转什么」；本地会话用不上，
            # 但统一带上省得两条路径分叉
            display_name=PathLib(file.file_path).name,
            device_id=device_id,
            cache=policy.transcode_cache_enabled,
            source_concat=disc.concat_list() if disc is not None else None,
            attempt_id=attempt_id,
        )
    except (SessionLimitError, DiskQuotaError) as exc:
        # 这两类的文案本来就是写给用户的，前端原样展示；NAS 日志也要留一份，
        # 用户反馈「点了播放没反应」时才对得上
        logger.warning("播放会话被拒：file_id=%s 档 %s：%s", file.id, view.tier, exc)
        raise ServiceUnavailableException(str(exc)) from exc
    except SessionStartError as exc:
        logger.warning(
            "播放会话启动失败：file_id=%s 档 %s 执行=%s：%s",
            file.id,
            view.tier,
            "远程 Worker" if use_remote else (hw_used or "本地软件/直通"),
            exc,
        )
        raise ServiceUnavailableException(f"播放启动失败：{exc}") from exc
    spawn_ms = int((time.perf_counter() - spawn_started_at) * 1000)

    token = await issue_stream_token(
        member_id=member_id,
        file_id=file.id,
        session_id=transcode.id,
        device_id=device_id,
        attempt_id=attempt_id,
        **share_kwargs,
    )
    total_ms = int((time.perf_counter() - started_at) * 1000)
    # 分段计时（§6.10）：决策段偏慢 = 关键帧采样在现场读盘（详情页预热没盖住
    # 的路径）；准备段偏慢 = 杀旧会话的 SIGTERM 等待（换字幕烧录/换音轨重开
    # 时最常见，配合 stop_for_file 的日志看）或关键帧索引现场读盘；ffmpeg 段
    # 偏慢 = 进程起不来或首列表难产（转码/IO 竞争，看 trickplay 与存储负载）。
    # 用户报「起播慢」时这一行直接指认方向。
    logger.info(
        "播放会话就绪：档 %s · 决策 %d 毫秒 · 准备 %d 毫秒 · ffmpeg %d 毫秒 · 共 %d 毫秒"
        "（file_id=%s hw=%s session=%s 缓存=%s attempt=%s）",
        view.tier,
        decide_ms,
        prep_ms,
        spawn_ms,
        total_ms,
        file.id,
        hw_used or "无",
        transcode.id,
        f"命中 {transcode.cached_segments} 段" if transcode.cache_hit else "未命中",
        attempt_id or "-",
    )
    attempt_started(
        file.id,
        view.tier if view.tier is not None else -1,
        view,
        decide=decide_ms,
        prep=prep_ms,
        spawn=spawn_ms,
    )
    response_start_ms = resolved_start_ms if segment_plan is not None else start_ms
    if (
        segment_plan is not None
        and transcode.progressive
        and resolved_start_ms
        and _capability_consumes_partial_segments(payload.capability)
    ):
        # 边产出边送时起播点吸附到所在分片的起点，与播放列表的 EXT-X-START 一致（§5）：
        # App 挂引擎时会显式 seek 到这个位置，不吸附的话它要等转到续播点那一片
        response_start_ms = int(
            segment_plan.boundaries[segment_plan.segment_for(resolved_start_ms / 1000)] * 1000
        )
    return ok(
        PlaybackSessionView(
            decision=view,
            session_id=transcode.id,
            stream_url=(f"/api/v1/playback/sessions/{transcode.id}/index.m3u8?token={token}"),
            # master 列表带 WEBVTT 字幕组：iOS 原生 HLS 用它，字幕成为系统级
            # 字幕轨——画中画小窗、原生全屏里都由系统渲染（§12）
            master_url=(
                f"/api/v1/playback/sessions/{transcode.id}/master.m3u8?token={token}"
                if segment_plan is not None
                else None
            ),
            # VOD：时间轴是文件绝对时间，start_ms 只是建议起播位置（解析后
            # 的原值，不必对齐边界——播放器 seek 到毫秒都行；边产出边送时见上）
            start_ms=response_start_ms,
            timeline="file" if segment_plan is not None else "session",
            subtitle_urls=subtitle_urls,
            hw_backend=hw_used,
            watch=watch_view,
            source=source_view,
            chapters=chapter_marks,
            segments=segment_views,
        )
    )


@router.post(
    "/sessions/{session_id}/ping",
    response_model=ApiResponse[dict],
    summary="播放心跳",
    operation_id="playback.session.ping",
    openapi_extra={"x-cli-hidden": True},
)
async def ping_playback_session(
    session_id: Annotated[str, Path()],
    principal: Principal = Depends(require_login),
) -> ApiResponse[dict]:
    """续命。用户关页面不会发任何信号，超时回收是唯一可靠兜底。"""
    member_id = principal.member_id if principal.member_id is not None else 0
    if not get_session_manager().ping(session_id, member_id=member_id):
        raise NotFoundException("会话不存在或已结束")
    return ok({"alive": True})


@router.delete(
    "/sessions/{session_id}",
    response_model=ApiResponse[dict],
    summary="结束播放",
    operation_id="playback.session.stop",
    # confirm 而非 destructive：只掐断本次播放并清掉临时分片，
    # 观看进度、媒体文件都不受影响。
    openapi_extra={"x-cli-hidden": True, "x-cli-dangerous": "confirm"},
)
async def stop_playback_session(
    session_id: Annotated[str, Path()],
    principal: Principal = Depends(require_login),
) -> ApiResponse[dict]:
    manager = get_session_manager()
    member_id = principal.member_id if principal.member_id is not None else 0
    if manager.get(session_id, member_id=member_id) is None:
        raise NotFoundException("会话不存在或已结束")
    await manager.stop(session_id)
    return ok({"stopped": True})


@stream_router.get(
    "/sessions/{session_id}/index.m3u8",
    summary="播放列表",
    operation_id="playback.session.playlist",
    openapi_extra={"x-cli-hidden": True},
)
async def get_session_playlist(
    request: Request,
    session_id: Annotated[str, Path()],
    token: Annotated[str, Query()],
) -> Response:
    """HLS 播放列表。

    VOD 模式（§12）：按分片规划一次性生成完整列表（VOD + ENDLIST），播放器
    把它当真正的点播——总时长已知、seek 任意位置、绝不贴直播边缘。
    旧模式：转发 ffmpeg 边写的 EVENT 列表。
    """
    grant = await verify_stream_token(token, session_id=session_id)
    if grant is None:
        raise NotFoundException("播放地址无效或已过期")
    session = get_session_manager().get(session_id, member_id=grant.member_id)
    if session is None:
        raise NotFoundException("会话不存在或已结束")
    session.touch()  # 拉 playlist 也算活着
    if session.segment_plan is not None:
        start_s = session.playlist_start_ms / 1000
        if session.progressive and _consumes_partial_segments(request):
            # 边产出边送时起播点吸附到所在分片的起点（最多往回 4 秒）：第一个 0.5 秒片段一到
            # 就是起播那一帧；落在分片中间的话要等转到续播点那一片，越靠后省得越少
            # （docs/design/transcode-latency.md §5，iOS 引擎 P39 同一取舍）
            plan = session.segment_plan
            start_s = plan.boundaries[plan.segment_for(start_s)]
        playlist = build_media_playlist(
            session.segment_plan,
            init_name=None if is_mpegts(session.plan) else INIT_NAME,
            segment_name=segment_pattern(session.plan),
            query=f"?token={token}",
            start_s=start_s,
        )
        return Response(
            content=playlist,
            media_type="application/vnd.apple.mpegurl",
            headers={"Cache-Control": "no-store"},
        )
    if not session.playlist_path.exists():
        raise NotFoundException("会话不存在或已结束")
    playlist = await asyncio.to_thread(session.playlist_path.read_text, encoding="utf-8")
    return Response(
        content=playlist_with_tokens(playlist, token),
        media_type="application/vnd.apple.mpegurl",
        headers={"Cache-Control": "no-store"},
    )


#: HLS 字幕组 NAME 的语言显示名。装进系统播放器的字幕菜单里给人看的，
#: 覆盖常见语言即可，冷门语言直接显示原始码也能认。
_SUBTITLE_LANG_NAMES = {
    "chi": "中文",
    "zho": "中文",
    "zh": "中文",
    "eng": "英文",
    "en": "英文",
    "jpn": "日文",
    "ja": "日文",
    "kor": "韩文",
    "ko": "韩文",
}

#: 能进 HLS 字幕组的轨：文本轨（vtt 含 srt 转换；ass 服务端降级转 VTT）。
#: PGS 是图形字幕转不了。**与前端 planSubtitleTracks 的 options 过滤规则
#: 必须一致**——前端按 options 的下标定位系统字幕轨。
_MASTER_SUBTITLE_KINDS = {"vtt", "ass"}

# 只有转码目标是本服务明确固定过的编码时，才把 RFC 6381 标识写入 master。
# copy 音轨只保存 codec family，没有保存 AAC profile 等完整信息，不能据此
# 猜测 mp4a.40.2；Safari 收到错误 CODECS 比没有声明更容易走错解码路径。
_HLS_AUDIO_CODEC_IDS = {
    "aac": "mp4a.40.2",
    "ac3": "ac-3",
    "eac3": "ec-3",
}


def _master_subtitle_tracks(session) -> list:
    return [s for s in session.plan.subtitles if s.kind in _MASTER_SUBTITLE_KINDS]


def _master_playlist_codecs(session: TranscodeSession) -> str | None:
    """返回本会话可以确定的 HLS CODECS，未知时返回 None。

    服务端转码视频统一是 H.264 High@4.1，RFC 6381 标识为 avc1.640029。
    音频只有在本次明确转码时才知道 profile：AAC 参数由 ffmpeg 装配器锁为
    AAC-LC，E-AC-3/AC-3 的目标编码也没有 profile 歧义。源音轨 copy 路径
    没有保存足够的 profile 信息，因此整条声明保守省略。
    """
    plan = session.plan
    if plan.video.action != "transcode" or (plan.video.codec or "").lower() != "h264":
        return None
    codecs = ["avc1.640029"]
    if plan.audio.track_ref is None:
        return ",".join(codecs)
    if plan.audio.action != "transcode":
        return None
    audio_codec = _HLS_AUDIO_CODEC_IDS.get((plan.audio.codec or "").lower())
    if audio_codec is None:
        return None
    codecs.append(audio_codec)
    return ",".join(codecs)


@stream_router.get(
    "/sessions/{session_id}/master.m3u8",
    summary="master 播放列表（含字幕组）",
    operation_id="playback.session.master",
    openapi_extra={"x-cli-hidden": True},
)
async def get_session_master_playlist(
    session_id: Annotated[str, Path()],
    token: Annotated[str, Query()],
) -> Response:
    """master 列表：一路视频 + WEBVTT 字幕组（仅 VOD 会话）。

    iOS 原生 HLS（AVPlayer）吃它，字幕由系统在任何表面（内联/全屏/画中画）
    渲染——这是网页 DOM 字幕层做不到的（PiP 图层只含视频帧）。
    """
    grant = await verify_stream_token(token, session_id=session_id)
    if grant is None:
        raise NotFoundException("播放地址无效或已过期")
    session = get_session_manager().get(session_id, member_id=grant.member_id)
    if session is None or session.segment_plan is None:
        raise NotFoundException("会话不存在或已结束")
    session.touch()
    subtitles: list[tuple[str, str]] = []
    seen: dict[str, int] = {}
    for i, track in enumerate(_master_subtitle_tracks(session)):
        name = _SUBTITLE_LANG_NAMES.get((track.language or "").lower(), track.language or "字幕")
        seen[name] = seen.get(name, 0) + 1
        if seen[name] > 1:
            name = f"{name} {seen[name]}"
        subtitles.append((name, f"sub{i}.m3u8"))
    return Response(
        content=build_master_playlist(
            media_uri="index.m3u8",
            subtitles=subtitles,
            codecs=_master_playlist_codecs(session),
            query=f"?token={token}",
        ),
        media_type="application/vnd.apple.mpegurl",
        headers={"Cache-Control": "no-store"},
    )


@stream_router.get(
    "/sessions/{session_id}/sub{index}.m3u8",
    summary="字幕媒体列表",
    operation_id="playback.session.subtitle-playlist",
    openapi_extra={"x-cli-hidden": True},
)
async def get_session_subtitle_playlist(
    session_id: Annotated[str, Path()],
    index: Annotated[int, Path(ge=0, le=99)],
    token: Annotated[str, Query()],
) -> Response:
    """字幕组里一条轨的媒体列表：整片一个 VTT 分片。"""
    grant = await verify_stream_token(token, session_id=session_id)
    if grant is None:
        raise NotFoundException("播放地址无效或已过期")
    session = get_session_manager().get(session_id, member_id=grant.member_id)
    if session is None or session.segment_plan is None:
        raise NotFoundException("会话不存在或已结束")
    tracks = _master_subtitle_tracks(session)
    if index >= len(tracks):
        raise NotFoundException("字幕轨不存在")
    session.touch()
    file_token = await issue_stream_token(
        member_id=session.member_id, file_id=session.file_id, share_id=grant.share_id
    )
    vtt_uri = (
        f"/api/v1/playback/files/{session.file_id}/subtitles"
        f"?track={quote(tracks[index].track_ref, safe='')}"
        f"&format=vtt&token={file_token}"
    )
    return Response(
        content=build_subtitle_playlist(
            vtt_uri=vtt_uri, duration_s=session.segment_plan.duration_s
        ),
        media_type="application/vnd.apple.mpegurl",
        headers={"Cache-Control": "no-store"},
    )


@router.get(
    "/sessions/{session_id}/diagnostics",
    response_model=ApiResponse[PlaybackDiagnosticsView],
    summary="播放会话诊断",
    operation_id="playback.session.diagnostics",
    openapi_extra={"x-cli-hidden": True},
)
async def get_session_diagnostics(
    session_id: Annotated[str, Path()],
    token: Annotated[str, Query()],
) -> ApiResponse[PlaybackDiagnosticsView]:
    """返回当前播放会话的脱敏执行与供片状态。"""
    grant = await verify_stream_token(token, session_id=session_id)
    if grant is None:
        raise NotFoundException("播放地址无效或已过期")
    manager = get_session_manager()
    session = manager.get(session_id, member_id=grant.member_id)
    if session is None:
        raise NotFoundException("会话不存在或已结束")
    session.touch()
    return ok(_build_playback_diagnostics(session))


def _capability_consumes_partial_segments(capability: ClientCapabilityIn) -> bool:
    """按开会话时申报的能力判断播放器是不是 AVFoundation（系统 HLS、不走 MSE）。

    开会话的请求是 App 自己的 URLSession 发的，看不出 AVPlayer 的 UA；能力里「原生 HLS、没有 MSE」
    的只有 iOS App 放服务端流与没有 MSE 的 Safari——都能边收边解（见下面的 UA 判定）。"""
    return capability.native_hls and capability.mse == "none"


def _consumes_partial_segments(request: Request) -> bool:
    """客户端能不能边收边解一个还没转完的分片（docs/design/transcode-latency.md §5）。

    AVFoundation（iOS App 放服务端流、Safari 原生 HLS）收到一个完整的片段就能解码出画，
    UA 都带 ``AppleCoreMedia``。hls.js 要整段收完才喂给解码器，提前流式下发对它没有好处，
    反而会让按传输期算的带宽读数偏低（网页的「线路不够」判定吃这个读数）——照旧等整段。
    """
    return "AppleCoreMedia" in request.headers.get("user-agent", "")


#: 边产出边送的分片多久没长就放弃下发：Worker 那边卡住（或这一轮被悄悄换掉）时别把连接挂到天荒地老。
#: 一个 0.5 秒片段在最慢的软解链路上也只要零点几秒，10 秒不长必是出事了。
_PARTIAL_IDLE_S = 10.0


class _PartialSegmentResponse(StreamingResponse):
    """跟着一个边产出边送的分片往下送（docs/design/transcode-latency.md §5）。

    分块传输（不带 Content-Length）：文件长一截送一截，收齐即正常收尾。分片作废（seek 重启、
    Worker 那边断了）或长时间不长时**不发结束块**直接返回——客户端看到的是一个没收完的响应，
    会丢掉它重新请求；要是正常收尾，它会把半个分片当成完整的拿去解码。uvicorn 为此会记一条
    「ASGI callable returned without completing response.」，这正是我们要的结果。
    不进浏览器缓存（no-store）：中途作废的半截内容绝不能被当成这个地址的长期结果。
    """

    def __init__(
        self,
        partial: PartialSegment,
        *,
        final_path: PathLib,
        byte_sink: Callable[[int], None] | None = None,
    ) -> None:
        # 借 StreamingResponse 的头部装配（不写 Content-Length）；发送循环在 __call__ 里自己管
        super().__init__(
            content=iter(()), media_type="video/mp4", headers={"Cache-Control": "no-store"}
        )
        self._partial = partial
        self._final_path = final_path
        self._byte_sink = byte_sink

    async def __call__(self, scope, receive, send) -> None:
        partial = self._partial
        try:
            handle = open(partial.path, "rb")  # noqa: SIM115 —— 跨多次 await 持有，finally 关
        except FileNotFoundError:
            # 恰好在拿到它和打开之间收齐改名了：读正式分片，内容一样
            handle = open(self._final_path, "rb")  # noqa: SIM115
        gone = asyncio.Event()

        async def watch() -> None:
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    gone.set()
                    return
                await asyncio.sleep(0)

        watcher = asyncio.ensure_future(watch())
        try:
            await send({"type": "http.response.start", "status": 200, "headers": self.raw_headers})
            sent = 0
            while not gone.is_set():
                changed = partial.changed
                committed = partial.size
                if partial.failed:
                    logger.info(
                        "边产出边送的分片已作废（转码重启），中断下发：seg=%05d", partial.index
                    )
                    return
                if committed > sent:
                    handle.seek(sent)
                    data = handle.read(committed - sent)
                    sent += len(data)
                    if self._byte_sink is not None:
                        self._byte_sink(len(data))
                    await send({"type": "http.response.body", "body": data, "more_body": True})
                    continue
                if partial.done:
                    await send({"type": "http.response.body", "body": b"", "more_body": False})
                    return
                waits = {asyncio.ensure_future(changed.wait()), asyncio.ensure_future(gone.wait())}
                done, pending = await asyncio.wait(
                    waits, timeout=_PARTIAL_IDLE_S, return_when=asyncio.FIRST_COMPLETED
                )
                for task in pending:
                    task.cancel()
                if not done:
                    logger.warning(
                        "边产出边送的分片 %.0f 秒没有增长，中断下发：seg=%05d",
                        _PARTIAL_IDLE_S,
                        partial.index,
                    )
                    return
        finally:
            watcher.cancel()
            handle.close()


@stream_router.get(
    "/sessions/{session_id}/{name}",
    summary="播放分片",
    operation_id="playback.session.segment",
    openapi_extra={"x-cli-hidden": True},
)
async def get_session_segment(
    request: Request,
    session_id: Annotated[str, Path()],
    name: Annotated[str, Path()],
    token: Annotated[str, Query()],
) -> FileResponse:
    """取一个 fMP4 分片或初始化段。

    VOD 模式下这里就是 seek 的入口：播放器按预生成列表请求任意分片，
    ``ensure_segment`` 负责「等 ffmpeg 转过来」或「杀掉重启直奔目标」。
    """
    if not _SEGMENT_NAME.match(name):
        raise NotFoundException("分片不存在")
    grant = await verify_stream_token(token, session_id=session_id)
    if grant is None:
        raise NotFoundException("播放地址无效或已过期")
    manager = get_session_manager()
    session = manager.get(session_id, member_id=grant.member_id)
    if session is None:
        raise NotFoundException("会话不存在或已结束")
    if grant.device_id and activity.device_ended(grant.device_id):
        raise NotFoundException("播放已被管理员结束")
    session.touch()
    meter = await _session_activity_meter(session, grant, request)
    target = session.directory / name
    if session.segment_plan is not None and name.startswith("seg"):
        allow_partial = session.progressive and _consumes_partial_segments(request)
        try:
            # 等转码期间盯着客户端：它掐掉请求就撤销挂号，别让没人要的旧请求左右重启判定
            ready = await await_unless_disconnected(
                request.receive,
                manager.ensure_segment(session, int(name[3:8]), allow_partial=allow_partial),
            )
        except ClientDisconnected:
            # 客户端已经走了，回什么都送不到；按「没有这一片」收尾
            raise NotFoundException("客户端已断开") from None
        if ready is None:
            raise NotFoundException("分片尚未就绪")
        if isinstance(ready, PartialSegment):
            return _PartialSegmentResponse(
                ready, final_path=target, byte_sink=meter.add if meter is not None else None
            )
        target = ready
    elif name == INIT_NAME:
        # init.mp4 必须等到**写完**，不只是「文件存在」（2026-08-25 真机事故，
        # iPhone 烧录必现「解码失败」）：ffmpeg 起转就创建 init.mp4，但 avio
        # 缓冲让它长期 0 字节——实测软转会话创建后 ~5 秒才落盘，比首个分片
        # 还晚。只等存在就会把 0 字节的 init 以 immutable 缓存喂给 AVPlayer，
        # 整个会话被毒缓存钉死。判完整：非空且两次采样大小不变（moov 一次
        # 写入，落盘即稳定）。已经有分片产出过（缓存命中的冷目录、跑过一轮
        # 的会话）或是远程产物（先写临时文件再原子改名）时，非空就是完整的，
        # 不必再为第二次采样白等 50 毫秒——这是 HLS 起播的必经一跳。
        settled = bool(session.completed_segments) or session.remote
        deadline = time.monotonic() + 15.0
        last_size = -1
        while time.monotonic() < deadline:
            if session.state in ("stopped", "failed"):
                break
            if target.exists():
                size = target.stat().st_size
                if size > 0 and (settled or size == last_size):
                    break
                last_size = size
            await asyncio.sleep(0.05)
        if not target.exists() or target.stat().st_size == 0:
            raise NotFoundException("分片尚未就绪")
    elif not target.exists():
        raise NotFoundException("分片尚未就绪")
    # 分片与 init 段在一个会话的生命期内不可变，URL 又含会话 id 与签名 token
    # （换会话必换 URL）——放给浏览器缓存，用户往回拖（back buffer 只留 30
    # 秒，回看必然重新走 HTTP）就变成本地命中，不再打服务端。
    headers = {"Cache-Control": "private, max-age=3600, immutable"}
    media_type = "video/mp2t" if name.endswith(".ts") else "video/mp4"
    if meter is None:
        return FileResponse(target, media_type=media_type, headers=headers)
    # 逐块计量发出的字节（活动页的速率来源）；计量器随会话存活，这里不回收
    return DisconnectAwareFileResponse(
        target, media_type=media_type, headers=headers, byte_sink=meter.add
    )


async def _session_activity_meter(
    session: TranscodeSession, grant: StreamGrant, request: Request
) -> activity.StreamMeter | None:
    """会话级的活动页字节计量器：首次取分片时按 token 里的浏览器设备标识建立。

    旧 token（没有设备标识）不计量——那是升级前签出的地址，播完自然失效。
    """
    if session.activity_meter is not None:
        return session.activity_meter
    if not grant.device_id:
        return None
    file = await _grant_file(grant.file_id)
    if file is None:
        return None
    session.activity_meter = activity.register_stream(
        device_id=grant.device_id,
        kind=activity.STREAM_KIND_PLAY,
        member_id=grant.member_id,
        unit=(file.media_item_id, file.season_number, file.episode_number),
        file_id=file.id,
        file_name=PathLib(file.file_path).name,
        size_bytes=file.size_bytes or 0,
        client=playback_watch.web_client_info(
            device_id=grant.device_id, user_agent=request.headers.get("user-agent")
        ),
    )
    return session.activity_meter


async def _grant_file(file_id: int) -> LibraryFile | None:
    """取流凭据指向的台账行（已识别到条目的才有播放单元可记）。"""
    async with get_database().session() as session:
        file = await session.get(LibraryFile, file_id)
    if file is None or file.media_item_id is None:
        return None
    return file


@stream_router.get(
    "/files/{file_id}/stream",
    summary="原文件直出",
    operation_id="playback.file.stream",
    openapi_extra={"x-cli-hidden": True},
)
async def stream_library_file(
    request: Request,
    file_id: Annotated[int, Path()],
    token: Annotated[str, Query()],
    session: AsyncSession = Depends(get_session),
):
    """档 0 Direct Play：原文件按 Range 直出，零转码零开销。

    strm 网盘条目在这里跳转到云端直链——服务器零流量（硬边界 2）。
    """
    grant = await verify_stream_token(token, file_id=file_id)
    if grant is None:
        raise NotFoundException("播放地址无效或已过期")
    if grant.device_id and activity.device_ended(grant.device_id):
        # 拒绝窗口内不再供流：直出播放器每次缓冲续拉都是新的 Range 连接，
        # 只掐当前连接挡不住它
        raise NotFoundException("播放已被管理员结束")
    file = await session.get(LibraryFile, file_id)
    if file is None:
        raise NotFoundException("文件不存在")
    # 读完台账立刻把数据库连接还回连接池。FastAPI 的 yield 依赖要等响应**发完**才收尾，
    # 而直出播放器按 Range 长连接续拉，一条流能挂几十分钟：不在这里提前释放，每条流都一直
    # 占着一个连接，十几条并发流（一个本机换封装的播放器同时开主读取、尾部预读、字幕预读几路）
    # 就能耗尽连接池（5 + 溢出 10），整个服务的接口一起卡 30 秒超时（2026-09-27 NAS 实测）。
    # 往下只用已读出的列，不再访问数据库。
    await session.close()
    if is_strm(file.file_path):
        remote = resolve_strm_url(file.file_path)
        if remote is None:
            raise NotFoundException("网盘直链无效")
        return RedirectResponse(remote, status_code=302)
    path = PathLib(file.file_path)
    media_type = container_mime_type(file.container)
    if file.is_disc() and (file.container or "") != "iso":
        # 原盘目录只有单剪辑主片才有「原文件」可直出（disc-playback.md §3.3）。多剪辑由
        # 能读目录的播放器走目录直推（下面的 /disc 接口），其余客户端在决策层已被导向
        # remux，不会走到这里。ISO 不进这个分支：原样出原字节，盘内结构由播放器自己读
        # （disc-direct-play.md §2.3）
        disc = disc_source_for_file(file)
        clip = disc.single_clip if disc is not None else None
        if clip is None:
            raise NotFoundException("原盘主片由多段剪辑组成（或是 DVD 目录），不能按单文件直出")
        path = clip.path
        media_type = container_mime_type("m2ts")
    if not path.exists():
        raise NotFoundException("文件已不在磁盘上")
    # hev1 标签的 HEVC MP4 在 Safari 上直出必败，流里把标签改成 hvc1（#430）
    byte_patches = await direct_play_byte_patches(path, file.container, file.video_codec)
    return _metered_file_response(request, grant, file, path, media_type, byte_patches=byte_patches)


def _metered_file_response(
    request: Request,
    grant,
    file: LibraryFile,
    path: PathLib,
    media_type: str,
    *,
    byte_patches=None,
    size_bytes: int | None = None,
) -> Response:
    """按 Range 出一个磁盘文件，并登记到设备流与活动页（原文件直出与原盘目录直推共用）。"""
    # 播放体验打点的取流计时（playback-qoe.md §5.3）：令牌里带播放编号才计
    probe = qoe.serve_probe(grant.attempt_id)
    if not grant.device_id or file.media_item_id is None:
        # 升级前签出的旧地址没有设备标识，不计量；未识别文件没有播放单元可记
        return DisconnectAwareFileResponse(
            path, media_type=media_type, byte_patches=byte_patches, probe=probe
        )
    # 与 Jellyfin 取流同一套登记：按浏览器设备登记这条流，让停止上报能主动
    # 停止读盘（播放器不会因为退出就立刻关闭已建立的 Range 连接）；顺带登记
    # 到活动注册表，活动页据此展示这台浏览器的实时传输速率
    device_id = grant.device_id
    session_stopped = register_device_stream(device_id)
    meter = activity.register_stream(
        device_id=device_id,
        kind=activity.STREAM_KIND_PLAY,
        member_id=grant.member_id,
        unit=(file.media_item_id, file.season_number, file.episode_number),
        file_id=file.id,
        file_name=path.name,
        size_bytes=size_bytes if size_bytes is not None else (file.size_bytes or 0),
        client=playback_watch.web_client_info(
            device_id=device_id, user_agent=request.headers.get("user-agent")
        ),
    )

    def _close() -> None:
        unregister_device_stream(device_id, session_stopped)
        activity.unregister_stream(meter)

    return DisconnectAwareFileResponse(
        path,
        media_type=media_type,
        session_stopped=session_stopped,
        byte_sink=meter.add,
        on_close=_close,
        byte_patches=byte_patches,
        probe=probe,
    )


#: 目录直推只放行光盘结构里播放要用的文件（disc-direct-play.md §2.3）。**这是路径穿越的防线**：
#: 请求里的相对路径必须整段命中白名单、且是列目录时真实存在的文件，绝不拿它去拼磁盘路径
_DISC_FILE_PATTERNS = (
    re.compile(r"BDMV/(?:index|MovieObject)\.bdmv", re.IGNORECASE),
    re.compile(r"BDMV/PLAYLIST/\d{5}\.mpls", re.IGNORECASE),
    re.compile(r"BDMV/CLIPINF/\d{5}\.clpi", re.IGNORECASE),
    re.compile(r"BDMV/STREAM/\d{5}\.m2ts", re.IGNORECASE),
    # DVD 目录：菜单与各标题集的信息文件、节目流（BUP 是 IFO 的备份，IFO 坏了引擎可以读它）
    re.compile(r"VIDEO_TS/(?:VIDEO_TS|VTS_\d{2}_\d)\.(?:IFO|BUP|VOB)", re.IGNORECASE),
)
#: 能目录直推的台账容器：蓝光原盘目录与 DVD 目录
_DISC_FOLDER_CONTAINERS = frozenset({"bluray", "dvd"})
#: 目录清单短缓存：引擎读剪辑是一连串 Range 请求，每次都在网络挂载上重列几层目录不值得
_DISC_TREE_TTL_S = 30.0
_disc_tree_cache: dict[str, tuple[float, dict[str, tuple[str, PathLib, int]]]] = {}


def _child_dir(parent: PathLib, name: str) -> PathLib | None:
    """按名字（大小写不敏感）找子目录：制作工具有的写 ``BDMV/STREAM``，有的写 ``bdmv/stream``。"""
    try:
        with os.scandir(parent) as entries:
            for entry in entries:
                if entry.name.upper() == name and entry.is_dir():
                    return PathLib(entry.path)
    except OSError:
        return None
    return None


def _disc_tree(disc_dir: PathLib) -> dict[str, tuple[str, PathLib, int]]:
    """原盘目录里可直推的文件：大写的相对路径 → (盘上实际的相对路径, 绝对路径, 字节数)。

    蓝光只看 ``BDMV`` 与它下面的 PLAYLIST / CLIPINF / STREAM 三层，DVD 只看 ``VIDEO_TS`` 一层，
    不递归别处；读不到的层当作空。
    """
    key = str(disc_dir)
    cached = _disc_tree_cache.get(key)
    now = time.monotonic()
    if cached is not None and now - cached[0] < _DISC_TREE_TTL_S:
        return cached[1]
    found: dict[str, tuple[str, PathLib, int]] = {}
    layers: list[tuple[PathLib, str]] = []
    bdmv = _child_dir(disc_dir, "BDMV")
    if bdmv is not None:
        layers.append((bdmv, bdmv.name))
        for name in ("PLAYLIST", "CLIPINF", "STREAM"):
            child = _child_dir(bdmv, name)
            if child is not None:
                layers.append((child, f"{bdmv.name}/{child.name}"))
    video_ts = _child_dir(disc_dir, "VIDEO_TS")
    if video_ts is not None:
        layers.append((video_ts, video_ts.name))
    for directory, rel_dir in layers:
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    rel = f"{rel_dir}/{entry.name}"
                    if not any(p.fullmatch(rel) for p in _DISC_FILE_PATTERNS):
                        continue
                    try:
                        if entry.is_file():
                            size = entry.stat().st_size
                            found[rel.upper()] = (rel, PathLib(entry.path), size)
                    except OSError:
                        continue
        except OSError:
            continue
    _disc_tree_cache[key] = (now, found)
    return found


async def _disc_file_owner(file_id: int, token: str, session: AsyncSession):
    """目录直推两个接口共用的校验：token、拒绝窗口、台账行（只认原盘目录）。"""
    grant = await verify_stream_token(token, file_id=file_id)
    if grant is None:
        raise NotFoundException("播放地址无效或已过期")
    if grant.device_id and activity.device_ended(grant.device_id):
        raise NotFoundException("播放已被管理员结束")
    file = await session.get(LibraryFile, file_id)
    if file is None:
        raise NotFoundException("文件不存在")
    # 与原文件直出同理：读完台账立刻还连接，往下只用已读出的列
    await session.close()
    if (file.container or "") not in _DISC_FOLDER_CONTAINERS:
        raise NotFoundException("不是原盘目录（蓝光 BDMV / DVD VIDEO_TS），没有可直推的目录清单")
    return grant, file


@stream_router.get(
    "/files/{file_id}/disc",
    response_model=ApiResponse[PlaybackDiscListingView],
    summary="原盘目录清单（目录直推）",
    operation_id="playback.file.disc.list",
    openapi_extra={"x-cli-hidden": True},
)
async def list_disc_files(
    file_id: Annotated[int, Path(ge=1)],
    token: Annotated[str, Query(min_length=1)],
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackDiscListingView]:
    """列出原盘目录里播放要用的文件（disc-direct-play.md §2.3）。

    App 的自研引擎拿它在本机解析 MPLS、选主片、把多个剪辑拼成一条流、折叠时间轴；
    服务端不起任何进程，只按文件供字节——多剪辑原盘因此不再让 NAS 起 ffmpeg 换封装。
    """
    _grant, file = await _disc_file_owner(file_id, token, session)
    disc_dir = PathLib(file.file_path)
    tree = await asyncio.to_thread(_disc_tree, disc_dir)
    if not tree:
        raise NotFoundException("原盘目录不可读，请检查 BDMV / VIDEO_TS 是否完整")
    disc = await asyncio.to_thread(disc_source_for_file, file)
    files = [
        PlaybackDiscFileView(
            path=rel,
            size=size,
            url=f"/api/v1/playback/files/{file_id}/disc/{quote(rel, safe='/')}?token={token}",
        )
        for rel, _path, size in sorted(tree.values())
    ]
    return ok(PlaybackDiscListingView(files=files, playlist=disc.playlist_name if disc else None))


@stream_router.get(
    "/files/{file_id}/disc/{relative_path:path}",
    summary="原盘目录里的单个文件（目录直推，按 Range）",
    operation_id="playback.file.disc.file",
    openapi_extra={"x-cli-hidden": True},
)
async def stream_disc_file(
    file_id: Annotated[int, Path(ge=1)],
    relative_path: str,
    request: Request,
    token: Annotated[str, Query(min_length=1)],
    session: AsyncSession = Depends(get_session),
):
    """按 Range 出原盘目录里的一个文件：路径必须命中白名单、且是目录清单里真实存在的文件。"""
    grant, file = await _disc_file_owner(file_id, token, session)
    if not any(p.fullmatch(relative_path) for p in _DISC_FILE_PATTERNS):
        raise NotFoundException("原盘目录里没有这个文件")
    tree = await asyncio.to_thread(_disc_tree, PathLib(file.file_path))
    entry = tree.get(relative_path.upper())
    if entry is None:
        raise NotFoundException("原盘目录里没有这个文件")
    _rel, path, size = entry
    media_type = (
        container_mime_type("m2ts")
        if path.suffix.lower() == ".m2ts"
        else "application/octet-stream"
    )
    return _metered_file_response(request, grant, file, path, media_type, size_bytes=size)


async def _extract_subtitle_until_disconnect(request: Request, file: LibraryFile, index: int):
    """等待字幕抽取，并在浏览器放弃请求时取消底层 ffmpeg。

    内封 PGS/ASS 首次抽取需要通读整个容器，不能把它放进不可取消的线程池。
    ``Request.is_disconnected`` 只负责发现客户端已经放弃，实际进程回收由
    ``extract_embedded_subtitle_async`` 的进程组清理逻辑完成。
    """
    task = asyncio.create_task(extract_embedded_subtitle_async(file, index))
    try:
        while not task.done():
            await asyncio.wait((task,), timeout=0.25)
            if task.done():
                break
            if await request.is_disconnected():
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
                raise _SubtitleClientDisconnected
        return await task
    except asyncio.CancelledError:
        if not task.done():
            task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        raise


@stream_router.get(
    "/files/{file_id}/subtitles",
    summary="旁挂字幕",
    operation_id="playback.file.subtitle",
    openapi_extra={"x-cli-hidden": True},
)
async def get_playback_subtitle(
    request: Request,
    file_id: Annotated[int, Path()],
    track: Annotated[str, Query(description="中性轨引用：external:<文件名> / embedded:<序号>")],
    token: Annotated[str, Query()],
    format: Annotated[str | None, Query()] = None,
    start_ms: Annotated[
        int | None,
        Query(ge=0, description="片段窗口起点（文件时间，毫秒）：与 end_ms 同给时只抽这一段"),
    ] = None,
    end_ms: Annotated[int | None, Query(ge=0, description="片段窗口终点（文件时间，毫秒）")] = None,
    session: AsyncSession = Depends(get_session),
) -> Response:
    """字幕**永远旁挂**，绝不烧录（硬边界 1）——烧录会把任何档位拖进全转码。

    外挂轨直接读文件；内封轨按需 ffmpeg 抽出来（首次要通读整个容器，之后走
    缓存）。PT 片源的字幕绝大多数是内封的，只服务外挂等于对大部分片子没字幕。

    给了 ``start_ms`` / ``end_ms``（刷片的片段）时，能原样拷贝的文字轨只抽这段窗口：
    片段只放四五十秒，等不起整轨通读。时间戳仍是文件时间；整轨已抽过就直接给整轨。
    """
    grant = await verify_stream_token(token, file_id=file_id)
    if grant is None:
        raise NotFoundException("字幕地址无效或已过期")
    file = await session.get(LibraryFile, file_id)
    if file is None:
        raise NotFoundException("文件不存在")
    ref = resolve_external_subtitle(file, track)
    if ref is None:
        index = parse_embedded_track(track)
        windowed = start_ms is not None and end_ms is not None and end_ms > start_ms
        if index is not None and windowed and window_format(file, index) is not None:
            # 窗口抽取几秒内完成，客户端放弃了也照常抽完落盘（下次直接命中），不必盯着断开
            ref = await extract_embedded_subtitle_window_async(
                file, index, start_ms or 0, end_ms or 0
            )
        elif index is not None:
            try:
                ref = await _extract_subtitle_until_disconnect(request, file, index)
            except _SubtitleClientDisconnected:
                # 浏览器切换清晰度、关闭字幕或销毁播放器时可能主动取消请求。
                # 此时连接本身通常已经关闭，204 只用于让 ASGI 边界安静结束，
                # 不能把真实的 asyncio.CancelledError 一并吞掉。
                return Response(status_code=204)
    if ref is None:
        raise NotFoundException("字幕轨不存在或暂不支持在网页端渲染")
    if ref.format == "sup":
        # PGS 位图轨：二进制、可达几十 MB，不进文本管线（那条路要按编码解码
        # 成 UTF-8）。FileResponse 流式发出，前端 libbitsub 边收边解。
        return FileResponse(
            ref.path,
            media_type="application/octet-stream",
            headers={"Cache-Control": "private, max-age=3600"},
        )
    try:
        body, media_type = serve_subtitle(ref, format)
    except SubtitleServeError as exc:
        raise NotFoundException(str(exc)) from exc
    return Response(content=body, media_type=media_type)


# ---------------------------------------------------------------------------
# 网页播放器：观看状态（续播点、已看、轨记忆）
#
# 与 Jellyfin 的 /Sessions/Playing 系列同落库路径，「浏览器看一半换 App
# 接着看」因此天然成立。身份来自 Web 登录会话，可见性按成员的库范围校验。
# ---------------------------------------------------------------------------


async def _visible_unit(
    session: AsyncSession,
    principal: Principal,
    media_item_id: int,
    season_number: int,
    episode_number: int,
) -> playback_state.Unit:
    """校验该播放单元对当前成员可见，返回领域层的单元三元组。

    可见性以「有在位文件落在可见库里」为准——与决策接口同一判据，避免
    出现「能报进度却点不开」的错位。
    """
    visible = await visible_library_ids(session, principal)
    files = await playback_plan.library_files_for_unit(
        session,
        media_item_id,
        season_number,
        episode_number,
        visible_library_ids=visible,
    )
    if not files:
        raise NotFoundException("没有找到可播放的文件")
    return (media_item_id, season_number, episode_number)


@router.post(
    "/progress",
    response_model=ApiResponse[PlaybackStateView],
    summary="上报观看进度",
    operation_id="playback.progress",
    openapi_extra={"x-cli-hidden": True},
)
async def report_playback_progress(
    payload: PlaybackProgressRequest,
    request: Request,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackStateView]:
    """开始 / 心跳 / 停止三种事件同一入口，与 Jellyfin 的 /Sessions/Playing*
    走同一个服务：落 ``playback_state``、发 webhook、刷新活动页的实时会话。

    已看判定的分母（片长）一律服务端算，不听客户端报——否则同一部片在
    网页端和 Jellyfin 客户端会给出不同的「已看」结论。
    """
    unit = await _visible_unit(
        session,
        principal,
        payload.media_item_id,
        payload.season_number,
        payload.episode_number,
    )
    member_id = principal.member_id if principal.member_id is not None else 0
    client = playback_watch.web_client_info(
        device_id=playback_watch.web_device_id(
            payload.device_id,
            member_id=member_id,
            login_device_id=principal.device.id if principal.device is not None else None,
        ),
        user_agent=request.headers.get("user-agent"),
    )
    if payload.event == "start":
        row = await playback_watch.record_start(
            session,
            unit,
            member_id=member_id,
            client=client,
            audio_track=payload.audio_track,
            subtitle_track=payload.subtitle_track,
            file_id=payload.file_id,
        )
    else:
        row = await playback_watch.record_progress(
            session,
            unit,
            member_id=member_id,
            client=client,
            position_ms=payload.position_ms,
            stopped=payload.event == "stop",
            paused=payload.paused,
            audio_track=payload.audio_track,
            subtitle_track=payload.subtitle_track,
            file_id=payload.file_id,
        )
    # 管理员已结束本次播放：进度照常落库（位置不能丢），但响应里带上信号让
    # 播放器退出。「开始」是用户亲手的动作，上面的落库已经解除了拒绝窗口；
    # 停止上报本身不算「还在播」，也不带信号。
    ended_by_admin = payload.event != "stop" and activity.device_ended(client.device_id)
    return ok(
        PlaybackStateView(
            position_ms=row.position_ms,
            played=row.played,
            play_count=row.play_count,
            duration_ms=await playback_state.unit_runtime_ms(session, unit),
            audio_track=row.audio_track,
            subtitle_track=row.subtitle_track,
            ended_by_admin=ended_by_admin,
        )
    )


@router.get(
    "/resume",
    response_model=ApiResponse[PlaybackStateView],
    summary="续播点与记忆轨",
    operation_id="playback.resume",
    openapi_extra={"x-cli-hidden": True},
)
async def get_playback_resume(
    media_item_id: Annotated[int, Query()],
    season_number: Annotated[int, Query()] = 0,
    episode_number: Annotated[int, Query()] = 0,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackStateView]:
    """起播前问一次「上次看到哪、用的哪条音轨/字幕」。

    从未播过不是错误——返回全零状态，播放器从头开始放。
    """
    unit = await _visible_unit(session, principal, media_item_id, season_number, episode_number)
    member_id = principal.member_id if principal.member_id is not None else 0
    states = await playback_state.get_states(session, [media_item_id], member_id=member_id)
    row = states.get(unit)
    return ok(
        PlaybackStateView(
            position_ms=row.position_ms if row else 0,
            played=row.played if row else False,
            play_count=row.play_count if row else 0,
            duration_ms=await playback_state.unit_runtime_ms(session, unit),
            audio_track=row.audio_track if row else None,
            subtitle_track=row.subtitle_track if row else None,
        )
    )


# ---------------------------------------------------------------------------
# 网页播放器：播放页条目信息（§6.10 路由只带 media_item_id）
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# 网页端：已看 / 收藏标记
# ---------------------------------------------------------------------------


def _marks_view(state: playback_marks.MarkState) -> PlaybackMarksView:
    return PlaybackMarksView(
        played=state.played,
        is_favorite=state.is_favorite,
        unplayed_count=state.unplayed_count,
    )


async def _mark_target(
    session: AsyncSession,
    principal: Principal,
    media_item_id: int,
    season_number: int | None,
    episode_number: int | None,
) -> playback_marks.MarkTarget:
    """请求里的目标 → 标记服务的目标；条目对当前成员不可见按 404。

    可见性按条目（而不是播放单元）判：标记整剧 / 整季没有具体单元可查，
    而「能看到这部片的详情页」正是能给它点心的前提。
    """
    if season_number is None and episode_number is not None:
        raise BadRequestException("给了集号就必须同时给季号")
    await assert_item_visible(session, principal, media_item_id)
    return playback_marks.MarkTarget(media_item_id, season_number, episode_number)


@router.get(
    "/marks",
    response_model=ApiResponse[PlaybackMarksView],
    summary="已看 / 收藏状态",
    operation_id="playback.marks.get",
    openapi_extra={"x-cli-hidden": True},
)
async def get_playback_marks(
    media_item_id: Annotated[int, Query()],
    season_number: Annotated[int | None, Query(ge=0)] = None,
    episode_number: Annotated[int | None, Query(ge=0)] = None,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackMarksView]:
    """详情页的心与对勾的初始状态。不带季集 = 整个条目（电影 / 整剧），只带
    季 = 整季，都带 = 单集——与 Jellyfin 客户端点的是同一份数据。"""
    target = await _mark_target(session, principal, media_item_id, season_number, episode_number)
    member_id = principal.member_id if principal.member_id is not None else 0
    return ok(_marks_view(await playback_marks.get_state(session, target, member_id=member_id)))


@router.post(
    "/marks",
    response_model=ApiResponse[PlaybackMarksView],
    summary="标记已看 / 收藏",
    operation_id="playback.marks.set",
    openapi_extra={"x-cli-hidden": True},
)
async def set_playback_marks(
    payload: PlaybackMarksRequest,
    request: Request,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackMarksView]:
    """与 Jellyfin 的 UserPlayedItems / UserFavoriteItems 走同一个服务：落
    ``playback_state``、发 webhook。整剧 / 整季的「已看」级联到全部集，收藏
    落在整剧 / 整季自己的哨兵单元上——在 Infuse 里看到的与这里点的完全一致。"""
    if payload.played is None and payload.favorite is None:
        raise BadRequestException("played 与 favorite 至少要给一个")
    target = await _mark_target(
        session, principal, payload.media_item_id, payload.season_number, payload.episode_number
    )
    member_id = principal.member_id if principal.member_id is not None else 0
    client = playback_watch.web_client_info(
        device_id=playback_watch.web_device_id(
            payload.device_id,
            member_id=member_id,
            login_device_id=principal.device.id if principal.device is not None else None,
        ),
        user_agent=request.headers.get("user-agent"),
    )
    if payload.played is not None:
        hit = await playback_marks.set_played(
            session, target, member_id=member_id, client=client, played=payload.played
        )
        if not hit:
            raise NotFoundException("没有找到可标记的季或集")
    if payload.favorite is not None:
        await playback_marks.set_favorite(
            session, target, member_id=member_id, client=client, favorite=payload.favorite
        )
    return ok(_marks_view(await playback_marks.get_state(session, target, member_id=member_id)))


async def _visible_item(
    session: AsyncSession, principal: Principal, media_item_id: int
) -> tuple[MediaItem, int]:
    """条目 + 它对当前成员可见的库 id。

    播放路由只带 ``media_item_id``（比库自增 id 稳定，§6.10），库归属在这里
    按可见性解析：取该条目**有台账行落在可见库里**的最小库 id。不可见与不存
    在同样 404——与决策接口同一判据。
    """
    item = await session.get(MediaItem, media_item_id)
    if item is None:
        raise NotFoundException("媒体条目不存在（可能已被删除）")
    visible = await visible_library_ids(session, principal)
    library_ids = sorted(
        {
            lid
            for lid in (
                await session.execute(
                    select(LibraryFile.library_id).where(
                        LibraryFile.media_item_id == media_item_id,
                        LibraryFile.library_id.is_not(None),  # type: ignore[union-attr]
                    )
                )
            )
            .scalars()
            .all()
            if lid is not None and (visible is None or lid in visible)
        }
    )
    if not library_ids:
        raise NotFoundException("没有找到可播放的文件")
    return item, library_ids[0]


@router.get(
    "/items/{media_item_id}",
    response_model=ApiResponse[PlaybackItemView],
    summary="播放页条目信息（标题/海报/库归属）",
    operation_id="playback.item.info",
    openapi_extra={"x-cli-hidden": True},
)
async def get_playback_item(
    media_item_id: Annotated[int, Path()],
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackItemView]:
    """播放器要的条目信息，刻意只给几样：标题给顶栏、海报给起播占位、
    library_id 给「退出播放跳回条目页」。不复用条目详情大接口——那份要装配
    NFO/演职员/逐文件规格，播放页用不上还拖慢并行加载。"""
    item, library_id = await _visible_item(session, principal, media_item_id)
    # 海报两层：本地刮削资产（带 mtime 版本戳绕缓存）> TMDB 图床。条目目录
    # 美术图那层不查——它需要装配整个详情 bundle，这里只是起播前的占位画面
    meta_row = await MediaItemRepository(session).get_metadata(media_item_id)
    if meta_row is not None and meta_row.poster_file:
        version = media_scrape.asset_version(meta_row.poster_file)
        poster_url = f"/images/assets/{meta_row.poster_file}?v={version}"
    elif item.poster_path:
        poster_url = tmdb_image_url(item.poster_path, "poster")
    else:
        poster_url = None
    return ok(
        PlaybackItemView(
            media_item_id=item.id,
            library_id=library_id,
            kind=item.kind,
            title=item.title,
            year=item.year,
            poster_url=poster_url,
        )
    )


@router.get(
    "/items/{media_item_id}/episodes",
    response_model=ApiResponse[SeasonEpisodesView],
    summary="播放页一季的分集清单（切集/上一集下一集数据源）",
    operation_id="playback.item.episodes",
    openapi_extra={"x-cli-hidden": True},
)
async def get_playback_item_episodes(
    media_item_id: Annotated[int, Path()],
    season_number: Annotated[int, Query(ge=0, description="季号（0=特别篇）")],
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[SeasonEpisodesView]:
    """与库详情页的分集接口同一装配器（并集"元数据的集 ∪ 库里实有的集"），
    只是按 media_item_id 定位、库归属服务端解析——播放页不再依赖库 id。"""
    item, library_id = await _visible_item(session, principal, media_item_id)
    rows = list(
        (
            await session.execute(
                select(LibraryFile)
                .where(
                    LibraryFile.library_id == library_id,
                    LibraryFile.media_item_id == media_item_id,
                )
                .order_by(LibraryFile.season_number, LibraryFile.episode_number, LibraryFile.id)
            )
        )
        .scalars()
        .all()
    )
    episodes = await build_season_episodes(
        session,
        item,
        rows,
        season_number,
        member_id=principal.member_id if principal.member_id is not None else 0,
    )
    return ok(
        SeasonEpisodesView(
            season_number=season_number,
            episodes=[episode_view(e) for e in episodes],
        )
    )


# ---------------------------------------------------------------------------
# 网页播放器：策略配置（软件转码同意链路 §3.6）。独立设置页已撤（2026-08-25），
# 数字上限改为自动推导（limits.py），端点保留给同意弹窗与 API/CLI 排障用。
# ---------------------------------------------------------------------------


async def _policy_view() -> PlaybackPolicyView:
    stored = await get_setting_store().get(PlaybackPolicySetting)
    backends = await asyncio.to_thread(available_backends)
    return PlaybackPolicyView(
        **stored.model_dump(),
        hardware_available=bool(backends),
        hw_backends=list(backends),
    )


@router.get(
    "/policy",
    response_model=ApiResponse[PlaybackPolicyView],
    summary="读取播放策略",
    operation_id="playback.policy.show",
    dependencies=[Depends(require_admin)],
    openapi_extra={"x-cli-hidden": True},
)
async def get_playback_policy() -> ApiResponse[PlaybackPolicyView]:
    """策略当前取值（API/CLI 排障用）。硬件加速一项是实测结果而非配置项。"""
    return ok(await _policy_view())


@router.put(
    "/policy",
    response_model=ApiResponse[PlaybackPolicyView],
    summary="保存播放策略",
    operation_id="playback.policy.set",
    dependencies=[Depends(require_admin)],
    openapi_extra={"x-cli-hidden": True},
)
async def save_playback_policy(
    payload: PlaybackPolicyPayload,
) -> ApiResponse[PlaybackPolicyView]:
    """按字段增量保存：``None`` 的项保持原值。

    同意弹窗（§3.6）只翻 ``software_transcode_enabled`` 一个开关，不该被迫
    先读全量再回写——那样会把另一个标签页刚保存的值悄悄覆盖回去。
    """
    store = get_setting_store()
    stored = await store.get(PlaybackPolicySetting)
    changes = payload.model_dump(exclude_none=True)
    if changes:
        # 重新构造而不是 model_copy(update=...)：后者跳过校验，字段约束就
        # 形同虚设（写进去的非法值要到消费时才炸）。
        await store.set(PlaybackPolicySetting(**{**stored.model_dump(), **changes}))
    return ok(await _policy_view())


@stream_router.get(
    "/files/{file_id}/fonts",
    response_model=ApiResponse[PlaybackFontsView],
    summary="内嵌字体清单",
    operation_id="playback.file.fonts",
    openapi_extra={"x-cli-hidden": True},
)
async def list_playback_fonts(
    file_id: Annotated[int, Path()],
    token: Annotated[str, Query()],
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackFontsView]:
    """ASS 字幕依赖的内嵌字体。

    番剧的 ASS 把字体作为附件放在 MKV 里，不喂给 JASSUB 就会回退成默认字体，
    排版、字号、描边全走样——这是「ASS 能播」和「ASS 播得对」的差距。

    **懒加载**：抽取要通读整个容器，放在开会话里会拖慢首帧。前端只在真的要
    渲染 ASS 轨时才来拿，抽完进缓存，之后同一部片直接命中。
    """
    grant = await verify_stream_token(token, file_id=file_id)
    if grant is None:
        raise NotFoundException("字体地址无效或已过期")
    file = await session.get(LibraryFile, file_id)
    if file is None:
        raise NotFoundException("文件不存在")
    names = await asyncio.to_thread(extract_embedded_fonts, file)
    return ok(
        PlaybackFontsView(
            fonts=[
                f"/api/v1/playback/files/{file_id}/fonts/{quote(name, safe='')}?token={token}"
                for name in names
            ]
        )
    )


@stream_router.get(
    "/files/{file_id}/fonts/{name}",
    summary="内嵌字体文件",
    operation_id="playback.file.font",
    openapi_extra={"x-cli-hidden": True},
)
async def get_playback_font(
    file_id: Annotated[int, Path()],
    name: Annotated[str, Path()],
    token: Annotated[str, Query()],
) -> FileResponse:
    """取一个已抽出的字体文件。

    文件名来自附件、也就是媒体文件本体——**不可信输入**。落盘时已经过白名单
    消毒（``safe_font_name``），这里再消毒一次并只在该文件的字体目录里找：
    路径穿越的防线不能只有一道。
    """
    grant = await verify_stream_token(token, file_id=file_id)
    if grant is None:
        raise NotFoundException("字体地址无效或已过期")
    safe = safe_font_name(name)
    if safe is None or safe != name:
        raise NotFoundException("字体不存在")
    target = font_cache_dir(file_id) / safe
    if not target.is_file():
        raise NotFoundException("字体不存在")
    return FileResponse(target, media_type="font/sfnt")


@router.get(
    "/hardware",
    response_model=ApiResponse[HwProbeView],
    summary="硬件加速自检",
    operation_id="playback.hardware.probe",
    dependencies=[Depends(require_admin)],
    openapi_extra={"x-cli-hidden": True},
)
async def probe_playback_hardware(
    refresh: Annotated[bool, Query(description="重新检测而不是读缓存")] = False,
) -> ApiResponse[HwProbeView]:
    """逐个后端真跑一秒钟的编码，把失败原因翻成可操作的中文。

    自建软件里硬件加速最大的成本不是写代码，是用户配不对：设备没挂、容器
    用户不在 render 组、驱动版本不够。这些出问题的现象**全都是「转码失败」
    黑盒**——用户既不知道原因也不知道该改什么。这个接口就是为了把黑盒打开。

    `refresh=true` 供设置页的「重新检测」按钮：用户按提示挂上设备后要能立刻
    看到结果，不必重启容器。
    """
    statuses = await probe_backends_async(force=refresh)
    return ok(
        HwProbeView(
            backends=[HwBackendStatusView(**vars(s)) for s in statuses],
            hardware_available=any(s.available for s in statuses),
        )
    )


@stream_router.get(
    "/files/{file_id}/trickplay",
    response_model=ApiResponse[TrickplayView],
    summary="进度条缩略图索引",
    operation_id="playback.file.trickplay",
    openapi_extra={"x-cli-hidden": True},
)
async def get_trickplay_index(
    file_id: Annotated[int, Path()],
    token: Annotated[str, Query()],
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[TrickplayView]:
    """拖进度条时的画面预览索引。

    还没生成好就返回 `ready=false`——前端表现为「暂无预览」，不影响播放。
    生成要通读整个容器，是在开会话时后台起的。
    """
    grant = await verify_stream_token(token, file_id=file_id)
    if grant is None:
        raise NotFoundException("预览地址无效或已过期")
    index = trickplay.load_index(file_id)
    if index is None:
        file = await session.get(LibraryFile, file_id)
        if file is not None:
            trickplay.schedule(file)  # 没赶上开会话那次（或那次失败了），补一发
        return ok(TrickplayView(ready=False))
    return ok(
        TrickplayView(
            ready=True,
            interval_ms=index.interval_ms,
            tile_width=index.tile_width,
            tile_height=index.tile_height,
            columns=index.columns,
            rows=index.rows,
            count=index.count,
            sheets=[
                f"/api/v1/playback/files/{file_id}/trickplay/{quote(name, safe='')}?token={token}"
                for name in index.sheets
            ],
        )
    )


@stream_router.get(
    "/files/{file_id}/trickplay/{name}",
    summary="进度条缩略图雪碧图",
    operation_id="playback.file.trickplay.sheet",
    openapi_extra={"x-cli-hidden": True},
)
async def get_trickplay_sheet(
    file_id: Annotated[int, Path()],
    name: Annotated[str, Path()],
    token: Annotated[str, Query()],
) -> FileResponse:
    """取一张雪碧图。文件名走白名单——它虽然由服务端生成，但经过了 URL。"""
    grant = await verify_stream_token(token, file_id=file_id)
    if grant is None:
        raise NotFoundException("预览地址无效或已过期")
    if not _TRICKPLAY_SHEET_NAME.match(name):
        raise NotFoundException("预览图不存在")
    target = trickplay.trickplay_dir(file_id) / name
    if not target.is_file():
        raise NotFoundException("预览图不存在")
    return FileResponse(target, media_type="image/jpeg")


@router.post(
    "/client-log",
    response_model=ApiResponse[dict],
    summary="播放器客户端日志",
    operation_id="playback.client-log",
    openapi_extra={"x-cli-hidden": True},
)
async def report_playback_client_log(
    payload: PlaybackClientLogPayload,
    principal: Principal = Depends(require_login),
) -> ApiResponse[dict]:
    """浏览器侧播放现场落服务端日志（只记日志不落库）。

    iPhone 上没有可看的控制台，播放器在哪条路径上、MediaError 报了什么，
    只有让客户端主动报上来才能在服务端日志里与转码时间线对照排障。

    ``startup`` 事件是起播分段计时（App 首帧上屏时报一次）：不是异常，按 INFO
    记成一行「起播分段」，用户说「点了播放半天才出画」时直接看慢在哪一段。
    """
    import json as _json

    if payload.event == "startup":
        logger.info("起播分段：%s", _startup_summary(payload.detail))
        return ok({"logged": True})
    # 纯信息性的调参记录（网页按码率调整回看缓冲）不是异常：起播时一连好几条，
    # 记 WARNING 会让看日志的人以为出了问题
    log = logger.info if payload.event in _INFO_CLIENT_EVENTS else logger.warning
    log(
        "播放器客户端日志：%s %s",
        payload.event,
        _json.dumps(payload.detail, ensure_ascii=False, default=str)[:2000],
    )
    return ok({"logged": True})


#: 按 INFO 记的客户端事件（信息性，不代表出了问题）
_INFO_CLIENT_EVENTS = frozenset({"hls-back-buffer"})

#: 起播分段里的描述字段；其余键都是「计时点名 → 距点播放的毫秒数」
_STARTUP_META_KEYS = frozenset(
    {"engine", "tier", "original", "start_ms", "media_item_id", "file_id", "attempt_id"}
)


def _startup_summary(detail: dict) -> str:
    """起播分段 → 一行可读文本：

    ``mpv 档 0 原文件 · 出现 30 → 决策 120 → … → 首帧 540 毫秒``
    ``（条目 7180 · 文件 24776 · 起点 524 秒）``
    """
    marks = sorted(
        (
            (name, value)
            for name, value in detail.items()
            if name not in _STARTUP_META_KEYS and isinstance(value, int | float)
        ),
        key=lambda pair: pair[1],
    )
    path = "原文件" if detail.get("original") else "服务端流"
    start_ms = detail.get("start_ms")
    start_s = round(start_ms / 1000) if isinstance(start_ms, int | float) else 0
    return (
        f"{detail.get('engine') or '未知引擎'} 档 {detail.get('tier')} {path} · "
        + " → ".join(f"{name} {int(value)}" for name, value in marks)
        + f" 毫秒（条目 {detail.get('media_item_id')} · 文件 {detail.get('file_id')}"
        + f" · 起点 {start_s} 秒"
        + (f" · attempt={detail['attempt_id']}" if detail.get("attempt_id") else "")
        + "）"
    )


async def _begin_attempt_in_background(
    *,
    attempt_id: str,
    member_id: int,
    file_id: int | None,
    tier: int,
    client: str,
    server: dict,
) -> None:
    """会话接口响应之后，在后台记这次播放「已开始」（playback-qoe.md §2）。

    自开数据库会话、吞掉一切异常：打点失败绝不能影响播放，只记一行警告。"""
    try:
        async with get_database().session() as db:
            file = await db.get(LibraryFile, file_id) if file_id else None
            await qoe.begin_attempt(
                db,
                attempt_id=attempt_id,
                member_id=member_id,
                file=file,
                tier=tier,
                client=client,
                server=server,
            )
    except Exception:  # noqa: BLE001 — 打点是旁路，任何失败都不能冒到播放上
        logger.warning(
            "播放记录「已开始」写入失败（attempt=%s），不影响播放", attempt_id, exc_info=True
        )


def _attempt_server_facts(view: PlaybackDecisionView, timings: dict[str, int]) -> dict:
    """服务端视角的事实：档位、决策结果与原因、转码计划、各段耗时（进播放记录的 detail.server）。"""
    facts: dict = {
        "at": utc_isoformat(utcnow()),
        "outcome": view.outcome,
        "tier": view.tier,
        "degraded_from": view.degraded_from,
        "reason": view.reason,
        "disc": view.disc,
        "timings_ms": timings,
    }
    if view.video is not None:
        facts["video"] = {
            "action": view.video.action,
            "codec": view.video.codec,
            "height": view.video.height,
            "tone_map": view.video.tone_map,
            "burn_subtitle": view.video.burn_subtitle,
        }
    if view.audio is not None:
        facts["audio"] = {
            "action": view.audio.action,
            "codec": view.audio.codec,
            "channels": view.audio.channels,
            "downmix": view.audio.downmix,
        }
    return facts


#: 「未收尾」清扫与按时间清理最多每 10 分钟做一次（都在上报之后顺手做，不另起定时任务）
_QOE_HOUSEKEEPING_INTERVAL_S = 600.0
_qoe_housekeeping_at = 0.0


async def _qoe_housekeeping(session: AsyncSession) -> None:
    global _qoe_housekeeping_at
    now = time.monotonic()
    if now - _qoe_housekeeping_at < _QOE_HOUSEKEEPING_INTERVAL_S:
        return
    _qoe_housekeeping_at = now
    unreported = await qoe.sweep_unreported(session)
    purged = await qoe.purge_expired(session, days=get_settings().playback_metric_retention_days)
    dropped = qoe.sweep_serve_stats()
    if unreported or purged or dropped:
        logger.info(
            "播放记录清扫：%d 条超时未收尾、清理 %d 条过期记录、丢弃 %d 份闲置的取流统计",
            unreported,
            purged,
            dropped,
        )


@router.post(
    "/metrics",
    response_model=ApiResponse[dict],
    summary="上报播放质量",
    operation_id="playback.metric.report",
    openapi_extra={"x-cli-hidden": True},
)
async def report_playback_metric(
    payload: PlaybackMetricPayload,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[dict]:
    """一次播放结束时上报。

    带 ``attempt_id`` 的是 docs/design/playback-qoe.md 口径：合并进会话接口建好的那一行，服务端在
    这里统一判定跳转分位、非自愿中断、可避免的规格损失与北极星，并写一行「播放记录」摘要日志。
    不带编号的是网页播放器的旧口径整行快照。

    **只落本地**（硬边界 3）：写进自己的数据库，绝不外发。
    """
    member_id = principal.member_id if principal.member_id is not None else 0
    if payload.attempt_id:
        fields = payload.model_dump(exclude={"ttff_ms"})
        report = qoe.FinishReport(**{k: v for k, v in fields.items() if v is not None or k in {
            "first_frame_ms", "playing_ms", "degraded_from", "dropped_frames", "total_frames",
            "library_file_id", "media_item_id", "season_number", "episode_number",
        }})
        # 旧字段 ttff_ms 仍填上首帧，老的 /playback/stats 汇总照样能看
        row = await qoe.finish_attempt(session, member_id=member_id, report=report)
        if row.ttff_ms is None and payload.first_frame_ms is not None:
            row.ttff_ms = payload.first_frame_ms
            await session.commit()
        await _qoe_housekeeping(session)
        return ok({"recorded": True, "undisturbed": row.undisturbed})

    # 用户端的真实体验落进服务端日志：ttff 是 requestVideoFrameCallback 量出
    # 的「点播放 → 真出画」，与「播放会话就绪」的服务端分段计时对照，差值就
    # 是网络 + 播放器初始化 + 首片下载解码——排查「日志都快但用户说慢」靠它
    logger.info(
        "播放质量上报：档 %s%s · 引擎 %s · 首帧 %s · 卡顿 %d 次/%d 毫秒 · "
        "拖动 %d 次 · 观看 %d 秒（file_id=%s）",
        payload.tier,
        f"（从档 {payload.degraded_from} 降档）" if payload.degraded_from is not None else "",
        payload.engine or "未知",
        f"{payload.ttff_ms} 毫秒" if payload.ttff_ms is not None else "未出画",
        payload.rebuffer_count,
        payload.rebuffer_ms,
        payload.seek_count,
        payload.watched_ms // 1000,
        payload.library_file_id,
    )
    legacy = payload.model_dump(
        include={
            "library_file_id", "tier", "degraded_from", "engine", "hw_backend", "ttff_ms",
            "rebuffer_ms", "rebuffer_count", "seek_count", "dropped_frames", "total_frames",
            "watched_ms",
        }
    )
    await metrics.record(session, PlaybackMetric(member_id=member_id, client="web", **legacy))
    await _qoe_housekeeping(session)
    return ok({"recorded": True})


@router.get(
    "/stats/qoe",
    response_model=ApiResponse[PlaybackQoeStatsView],
    summary="播放体验统计：无打扰播放率、起播与跳转分位、中断、规格损失、最差的播放",
    operation_id="playback.stats.qoe",
    dependencies=[Depends(require_admin)],
)
async def get_playback_qoe_stats(
    days: Annotated[int, Query(ge=1, le=365, description="统计最近多少天")] = 7,
    group_by: Annotated[
        Literal["source_class", "network_class", "route", "app_version", "client", "interface"]
        | None,
        Query(description="分组维度；不给只看总体"),
    ] = None,
    include_lab: Annotated[bool, Query(description="是否包含实验室的播放（默认排除）")] = False,
    worst: Annotated[int, Query(ge=0, le=100, description="列出最差的多少次播放")] = 20,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackQoeStatsView]:
    """最近 N 天的播放体验（docs/design/playback-qoe.md §5.5）。

    北极星是**无打扰播放率**：一次播放从点下到离开，起播 ≤ 2 秒、每次跳转 ≤ 1.5 秒、没有非自愿
    中断（卡顿 ≥ 0.5 秒、冻帧 ≥ 1 秒、报错、闪退）、没有可避免的规格损失、没有猜错音轨字幕续播
    位置，才算一次无打扰。另给快（首帧、缓冲内 / 外跳转的 p50 / p90 / p99）、稳（每小时中断、
    失败率、出画前退出率、异常退出率）、对（可避免损失率、猜错率）、打扰原因的帕累托，
    以及最差的若干次播放（拿编号去查详情）。

    样本少于 30 次的分组不算分位数，改列明细。只统计本文口径（口径 2）的记录。"""
    await qoe.sweep_unreported(session)
    return ok(
        PlaybackQoeStatsView(
            **await qoe.qoe_stats(
                session, days=days, group_by=group_by, include_lab=include_lab, worst=worst
            )
        )
    )


@router.get(
    "/attempts/{attempt_id}",
    response_model=ApiResponse[PlaybackAttemptView],
    summary="一次播放的完整记录与时间线",
    operation_id="playback.attempt.get",
    dependencies=[Depends(require_admin)],
)
async def get_playback_attempt(
    attempt_id: Annotated[str, Path(max_length=64)],
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackAttemptView]:
    """按播放编号查一次播放：起播分段、每次跳转、中断、规格快照与判定、猜错、环境与资源、
    服务端视角（会话、取流统计）、事件时间线，失败时还有引擎日志尾巴（playback-qoe.md §5.5）。"""
    row = await qoe.get_attempt(session, attempt_id)
    if row is None:
        raise NotFoundException("没有这次播放的记录")
    data = row.model_dump(exclude={"id", "updated_at", "ttff_ms", "hw_backend", "dropped_frames",
                                   "total_frames", "seek_count", "metric_version"})
    data["attempt_id"] = row.attempt_id or attempt_id
    data["created_at"] = utc_isoformat(row.created_at)
    data["ended_at"] = utc_isoformat(row.ended_at) if row.ended_at else None
    return ok(PlaybackAttemptView(**data))


@router.get(
    "/stats",
    response_model=ApiResponse[PlaybackStatsView],
    summary="播放质量汇总",
    operation_id="playback.stats",
    dependencies=[Depends(require_admin)],
    openapi_extra={"x-cli-hidden": True},
)
async def get_playback_stats(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackStatsView]:
    """最近若干次播放的质量汇总。

    `direct_ratio` 是北极星指标：档 0 + 档 1 的占比，一个数同时代表画质、
    速度和服务器负担，也是「这个软件对我的库适配得好不好」的直观答案。
    """
    stats = await metrics.summarize(session)
    return ok(PlaybackStatsView(**vars(stats)))
