"""「设置 → MovieClaw Cloud」的接口（管理员，docs/design/cloud-push.md §7.1）。

实现都在 services/cloud/，这里只做参数进出。全部标 ``x-cli-hidden``：连接云要在官网
批准、要看配对码，命令行用不上。
"""

from __future__ import annotations

from fastapi import APIRouter

from movieclaw_api.schemas.cloud import (
    CloudDisconnectRequest,
    CloudPairingRequest,
    CloudSettingsRequest,
    CloudStatusView,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.cloud import get_cloud_service
from movieclaw_api.services.cloud.views import build_status

router = APIRouter(prefix="/cloud", tags=["cloud"])

_HIDDEN = {"x-cli-hidden": True}


@router.get(
    "",
    response_model=ApiResponse[CloudStatusView],
    summary="MovieClaw Cloud 的连接状态",
    operation_id="cloud.status",
    openapi_extra=_HIDDEN,
)
async def cloud_status() -> ApiResponse[CloudStatusView]:
    return ok(await build_status())


@router.post(
    "/pairing",
    response_model=ApiResponse[CloudStatusView],
    summary="开始连接：申请配对码，到 movieclaw.io 批准",
    operation_id="cloud.pairing.start",
    openapi_extra=_HIDDEN,
)
async def start_pairing(payload: CloudPairingRequest) -> ApiResponse[CloudStatusView]:
    await get_cloud_service().start_pairing(payload.instance_name)
    return ok(await build_status())


@router.delete(
    "/pairing",
    response_model=ApiResponse[CloudStatusView],
    summary="取消配对",
    operation_id="cloud.pairing.cancel",
    openapi_extra={**_HIDDEN, "x-cli-dangerous": "confirm"},
)
async def cancel_pairing() -> ApiResponse[CloudStatusView]:
    await get_cloud_service().cancel_pairing()
    return ok(await build_status())


@router.post(
    "/renew",
    response_model=ApiResponse[CloudStatusView],
    summary="立即和 MovieClaw Cloud 同步一次",
    operation_id="cloud.renew",
    openapi_extra=_HIDDEN,
)
async def renew_now() -> ApiResponse[CloudStatusView]:
    await get_cloud_service().renew_now()
    return ok(await build_status())


@router.post(
    "/disconnect",
    response_model=ApiResponse[CloudStatusView],
    summary="断开 MovieClaw Cloud（云端连不上时可强制只删本地凭证）",
    operation_id="cloud.disconnect",
    openapi_extra=_HIDDEN,
)
async def disconnect(payload: CloudDisconnectRequest) -> ApiResponse[CloudStatusView]:
    await get_cloud_service().disconnect(force=payload.force)
    return ok(await build_status(), message="已断开 MovieClaw Cloud")


@router.put(
    "/settings",
    response_model=ApiResponse[CloudStatusView],
    summary="上报统计信息的开关",
    operation_id="cloud.settings.set",
    openapi_extra=_HIDDEN,
)
async def update_settings(payload: CloudSettingsRequest) -> ApiResponse[CloudStatusView]:
    await get_cloud_service().set_report_stats(payload.report_stats)
    return ok(await build_status())


@router.post(
    "/notices/{notice_id}/dismiss",
    response_model=ApiResponse[CloudStatusView],
    summary="关掉一条 MovieClaw Cloud 的服务通知",
    operation_id="cloud.notices.dismiss",
    openapi_extra=_HIDDEN,
)
async def dismiss_notice(notice_id: str) -> ApiResponse[CloudStatusView]:
    await get_cloud_service().dismiss_notice(notice_id)
    return ok(await build_status())
