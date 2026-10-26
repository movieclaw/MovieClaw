"""管理员批准的观看历史与状态交换，亦进入插件宿主操作目录。"""

from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.api.deps import require_admin
from movieclaw_api.schemas.playback_sync import (
    SyncCatalog,
    SyncImportIn,
    SyncImportResult,
    SyncStateIn,
    SyncStateResult,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services import playback_sync
from movieclaw_api.services.auth import Principal
from movieclaw_db.engine import get_session

router = APIRouter(prefix="/playback/sync", tags=["playback"])


@router.get(
    "/catalog",
    response_model=ApiResponse[SyncCatalog],
    operation_id="playback.sync.catalog",
    summary="分页读取指定成员的库内观看状态和观看记录",
)
async def catalog(
    member_id: Annotated[int, Query(ge=0)] = 0,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    principal: Principal = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    return ok(await playback_sync.catalog(session, principal, member_id, cursor, limit))


@router.post(
    "/import",
    response_model=ApiResponse[SyncImportResult],
    operation_id="playback.sync.import",
    summary="幂等导入指定成员的观看历史，不模拟播放",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def import_records(
    payload: SyncImportIn,
    principal: Principal = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    return ok(
        SyncImportResult(outcomes=await playback_sync.import_records(session, principal, payload))
    )


@router.post(
    "/state",
    response_model=ApiResponse[SyncStateResult],
    operation_id="playback.sync.state",
    summary="按单元写回指定成员的已看、续播和收藏，不发播放事件",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def apply_state(
    payload: SyncStateIn,
    principal: Principal = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    return ok(
        SyncStateResult(outcomes=await playback_sync.apply_state(session, principal, payload))
    )
