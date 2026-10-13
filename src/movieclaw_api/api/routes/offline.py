"""App 离线下载接口（docs/design/offline-download.md §5.2、§7）。

全部挂在成员区、用 Bearer 设备令牌鉴权（后台下载会话能带请求头，用不着 12 小时有效的
播放签名）；下载类接口另校验「下载影片到设备」开关。观看记录补传只要求登录：权限后来被
关掉，已下的片照样能播，它们的观看记录也得能回来。命令行不可见。
"""

from __future__ import annotations

from pathlib import Path as PathLib
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Path, Query, Request
from fastapi.responses import Response
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.api.deps import require_login, require_video_download_capability
from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.schemas.offline import (
    OfflineExportRequest,
    OfflineExportView,
    OfflineManifestView,
    OfflineProfilesRequest,
    OfflineProfilesView,
    PlaybackViewingsRequest,
    PlaybackViewingsView,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.access import assert_item_visible, visible_library_ids
from movieclaw_api.services.offline import exports, viewings
from movieclaw_api.services.offline.manifest import build_manifest, build_profiles
from movieclaw_api.services.playback import watch as playback_watch
from movieclaw_db.engine import get_session
from movieclaw_db.models import LibraryFile
from movieclaw_playback import activity
from movieclaw_playback.streaming import (
    DisconnectAwareFileResponse,
    RemoteRelayResponse,
    StrmError,
    StrmLink,
    container_mime_type,
    is_strm,
    local_strm_container,
    parse_strm,
)

router = APIRouter(
    prefix="/offline",
    tags=["offline"],
    dependencies=[Depends(require_video_download_capability)],
)
viewings_router = APIRouter(prefix="/playback", tags=["playback"])

_HIDDEN = {"x-cli-hidden": True}


async def _visible_file(session: AsyncSession, principal: Principal, file_id: int) -> LibraryFile:
    file = await session.get(LibraryFile, file_id)
    if file is None or file.media_item_id is None:
        raise NotFoundException("文件不存在")
    if file.library_id not in await visible_library_ids(session, principal):
        raise NotFoundException("文件不存在")
    await assert_item_visible(session, principal, file.media_item_id)
    return file


def _member_id(principal: Principal) -> int:
    return principal.member_id if principal.member_id is not None else 0


def _client(request: Request, principal: Principal):
    member_id = _member_id(principal)
    return playback_watch.web_client_info(
        device_id=playback_watch.web_device_id(
            None,
            member_id=member_id,
            login_device_id=principal.device.id if principal.device is not None else None,
        ),
        user_agent=request.headers.get("user-agent"),
    )


def _range_start(request: Request) -> int:
    raw = (request.headers.get("range") or "").strip().lower()
    if not raw.startswith("bytes="):
        return 0
    start = raw[len("bytes=") :].split(",")[0].split("-")[0].strip()
    return int(start) if start.isdigit() else 0


def _register_download(
    request: Request,
    principal: Principal,
    file: LibraryFile,
    name: str,
    size: int,
    export_id: str | None = None,
):
    """登记到活动页「正在下载」（与 Jellyfin 客户端整文件下载同一类活动）。"""
    return activity.register_stream(
        device_id=_client(request, principal).device_id,
        kind=activity.STREAM_KIND_DOWNLOAD,
        member_id=_member_id(principal),
        unit=(file.media_item_id, file.season_number or 0, file.episode_number or 0),
        file_id=file.id,
        file_name=name,
        size_bytes=size,
        client=_client(request, principal),
        start_offset=_range_start(request),
        export_id=export_id,
    )


@router.get(
    "/manifest",
    response_model=ApiResponse[OfflineManifestView],
    summary="离线下载清单：一个播放单元打包所需的一切",
    operation_id="offline.manifest",
    openapi_extra=_HIDDEN,
)
async def get_offline_manifest(
    file_id: Annotated[int, Query()],
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
    user_agent: Annotated[str | None, Header(include_in_schema=False)] = None,
) -> ApiResponse[OfflineManifestView]:
    return ok(await build_manifest(session, principal, file_id, user_agent=user_agent))


@router.post(
    "/profiles",
    response_model=ApiResponse[OfflineProfilesView],
    summary="一批文件的可选下载档位与预计大小（选档表单批量估大小）",
    operation_id="offline.profiles",
    openapi_extra=_HIDDEN,
)
async def get_offline_profiles(
    payload: OfflineProfilesRequest,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[OfflineProfilesView]:
    return ok(await build_profiles(session, principal, payload.file_ids))


@router.get(
    "/files/{file_id}/content",
    summary="原画下载：原文件字节（Range 可续传）",
    operation_id="offline.file.content",
    openapi_extra=_HIDDEN,
)
@router.head("/files/{file_id}/content", include_in_schema=False)
async def download_original_file(
    request: Request,
    file_id: Annotated[int, Path()],
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> Response:
    file = await _visible_file(session, principal, file_id)
    # 下载能挂几十分钟：读完台账就把数据库连接还回去（原文件直出同一个教训）
    await session.close()
    if file.is_disc():
        raise NotFoundException("原盘暂不支持下载到设备")
    path = PathLib(file.file_path)
    container = file.container
    if is_strm(file.file_path):
        try:
            source = parse_strm(file.file_path)
        except StrmError as exc:
            raise NotFoundException(f"strm 用不了：{exc}") from exc
        if isinstance(source, StrmLink):
            # 一律由服务端转发，不 302：后台下载跟跳转时会把我们的设备令牌带给网盘
            meter = _register_download(request, principal, file, path.name, file.size_bytes or 0)
            return RemoteRelayResponse(
                source.url,
                range_header=request.headers.get("range"),
                upstream_headers=source.headers,
                byte_sink=meter.add,
                on_close=lambda: activity.unregister_stream(meter),
            )
        path = source
        container = local_strm_container(file.container, path)
    if not path.is_file():
        raise NotFoundException("文件已不在磁盘上")
    size = path.stat().st_size
    meter = _register_download(request, principal, file, path.name, size)
    return DisconnectAwareFileResponse(
        path,
        media_type=container_mime_type(container or path.suffix),
        byte_sink=meter.add,
        on_close=lambda: activity.unregister_stream(meter),
    )


def _export_view(manager: exports.ExportManager, state: exports.ExportState) -> OfflineExportView:
    return OfflineExportView(
        **exports.state_view_fields(manager, state),
        content_url=f"/api/v1/offline/exports/{state.export_id}/content",
    )


@router.post(
    "/exports",
    response_model=ApiResponse[OfflineExportView],
    summary="建或复用一个转码导出（1080p / 720p / 480p）",
    operation_id="offline.exports.create",
    openapi_extra=_HIDDEN,
)
async def create_offline_export(
    payload: OfflineExportRequest,
    request: Request,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[OfflineExportView]:
    file = await _visible_file(session, principal, payload.file_id)
    manager = exports.get_export_manager()
    try:
        state = await manager.ensure(
            file,
            payload.profile,
            payload.audio_track,
            duration_s=float(file.duration_seconds) if file.duration_seconds else None,
            claimant=_client(request, principal).device_id,
        )
    except exports.ExportUnavailable as exc:
        raise BadRequestException(str(exc)) from exc
    return ok(_export_view(manager, state))


async def _visible_export(
    session: AsyncSession, principal: Principal, export_id: str
) -> tuple[exports.ExportState, LibraryFile]:
    manager = exports.get_export_manager()
    state = manager.get(export_id)
    if state is None:
        raise NotFoundException("导出不存在或已回收")
    return state, await _visible_file(session, principal, state.file_id)


@router.get(
    "/exports/{export_id}",
    response_model=ApiResponse[OfflineExportView],
    summary="导出进度",
    operation_id="offline.exports.get",
    openapi_extra=_HIDDEN,
)
async def get_offline_export(
    export_id: str,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[OfflineExportView]:
    state, _file = await _visible_export(session, principal, export_id)
    return ok(_export_view(exports.get_export_manager(), state))


@router.get(
    "/exports/{export_id}/content",
    summary="导出文件：转完是静态文件（可续传），转码中边转边发",
    operation_id="offline.exports.content",
    openapi_extra=_HIDDEN,
)
@router.head("/exports/{export_id}/content", include_in_schema=False)
async def download_offline_export(
    request: Request,
    export_id: str,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> Response:
    state, file = await _visible_export(session, principal, export_id)
    await session.close()
    manager = exports.get_export_manager()
    manager.touch(state)
    if state.status == exports.STATUS_QUEUED:
        # 还没轮到：客户端按 Retry-After 定时重试（后台下载会话的 earliestBeginDate）
        position = manager.queue_position(export_id) or 0
        return Response(
            status_code=503,
            headers={"retry-after": str(min(600, 60 * (position + 1)))},
        )
    if state.status == exports.STATUS_FAILED:
        return Response(
            content=f"转码失败：{state.error or '未知原因'}".encode(),
            status_code=422,
            media_type="text/plain; charset=utf-8",
        )
    path = manager.output_path(state)
    if state.status == exports.STATUS_DONE and not path.is_file():
        raise NotFoundException("导出文件已回收")
    if request.method == "HEAD":
        # 只问头：不登记到活动页（没有字节要发，登记了也没人收口）
        if state.status == exports.STATUS_RUNNING:
            return exports.ExportTailResponse(manager, state)
        return DisconnectAwareFileResponse(
            path, media_type="video/mp4", headers={"etag": state.etag}
        )
    # 名字给源文件名（导出号是一串哈希，没意义）；活动页会把这一行换成转码信息
    size = state.final_bytes or state.expected_bytes
    meter = _register_download(
        request, principal, file, PathLib(file.file_path).name, size, export_id=export_id
    )
    if state.status == exports.STATUS_RUNNING:
        response = exports.ExportTailResponse(
            manager, state, on_close=lambda: activity.unregister_stream(meter)
        )
        _meter_tail(response, meter)
        return response
    manager.reader_enter(export_id)

    def _close() -> None:
        manager.reader_leave(export_id)
        activity.unregister_stream(meter)

    return DisconnectAwareFileResponse(
        path,
        media_type="video/mp4",
        headers={"etag": state.etag},
        byte_sink=meter.add,
        on_close=_close,
    )


def _meter_tail(response: exports.ExportTailResponse, meter) -> None:
    """边转边发的响应也计入活动页的下载速率。"""
    original = response._stream

    async def metered(send, disconnected):
        async def counting_send(message):
            if message.get("type") == "http.response.body":
                meter.add(len(message.get("body") or b""))
            await send(message)

        await original(counting_send, disconnected)

    response._stream = metered  # type: ignore[method-assign]


@router.delete(
    "/exports/{export_id}",
    response_model=ApiResponse[None],
    summary="下载完了：通知服务端可以回收导出",
    operation_id="offline.exports.release",
    openapi_extra=_HIDDEN,
)
async def release_offline_export(
    export_id: str,
    request: Request,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[None]:
    state = exports.get_export_manager().get(export_id)
    if state is not None:
        await _visible_file(session, principal, state.file_id)
        # 只摘掉这台设备：家里别的设备还要这份导出时留着
        exports.get_export_manager().release(export_id, _client(request, principal).device_id)
    return ok(None)


@viewings_router.post(
    "/viewings",
    response_model=ApiResponse[PlaybackViewingsView],
    summary="本机播放的观看记录（含离线补传），按编号幂等合并",
    operation_id="playback.viewings",
    openapi_extra=_HIDDEN,
)
async def report_playback_viewings(
    payload: PlaybackViewingsRequest,
    request: Request,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[PlaybackViewingsView]:
    results = await viewings.apply_viewings(
        session, principal, payload, client=_client(request, principal)
    )
    return ok(PlaybackViewingsView(results=results))
