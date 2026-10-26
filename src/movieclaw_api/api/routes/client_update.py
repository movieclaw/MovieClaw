"""Android 客户端自身的更新：查最新版、经服务器代取 APK（services/client_update.py）。"""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Query
from fastapi.responses import StreamingResponse

from movieclaw_api.schemas.app_update import ClientReleaseView
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services import client_update

router = APIRouter(prefix="/app/clients", tags=["app"])

Product = Literal["android", "androidtv"]


@router.get(
    "/{product}/latest",
    response_model=ApiResponse[ClientReleaseView],
    summary="客户端最新版本",
    operation_id="app.clients.latest",
    openapi_extra={"x-cli-hidden": True},
)
async def client_latest(
    product: Product,
    refresh: Annotated[bool, Query(description="跳过 30 分钟缓存重新查")] = False,
) -> ApiResponse[ClientReleaseView]:
    return ok(await client_update.latest(product, force=refresh))


@router.get(
    "/{product}/apk",
    summary="经服务器下载客户端最新安装包",
    operation_id="app.clients.apk",
    response_class=StreamingResponse,
    openapi_extra={"x-cli-hidden": True},
)
async def client_apk(product: Product) -> StreamingResponse:
    view, body = await client_update.open_apk(product)
    return StreamingResponse(
        body,
        media_type="application/vnd.android.package-archive",
        headers={
            "Content-Length": str(view.size),
            "Content-Disposition": f'attachment; filename="movieclaw-{product}-{view.version}.apk"',
            "X-Apk-Sha256": view.sha256,
        },
    )
