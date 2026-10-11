"""网盘（strm）条目的规格探测接口（docs/design/plugin-strm-prefetch.md §3）。

预探插件、CLI 与 MCP 共用：列出还没探过规格的网盘条目，探一个文件。探测本身与失败退避在主程序
（services/playback/strm_probe.py），插件只决定先探谁、多快。
"""

from __future__ import annotations

from datetime import datetime
from pathlib import PurePosixPath
from typing import Literal
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, Query
from pydantic import Field
from sqlalchemy import func, or_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_db.engine import get_session
from movieclaw_db.models import FileState, LibraryFile, StrmProbeState
from movieclaw_db.models.base import utcnow

router = APIRouter(prefix="/library-strm", tags=["library"])

#: 一页最多扫多少行来凑够 ``limit``（排除容器的行要读 .strm 才知道直链后缀）
_SCAN_BUDGET = 500


class StrmPendingFile(BaseModel):
    file_id: int
    library_id: int
    media_item_id: int | None
    season: int
    episode: int
    container: str | None = Field(description="直链看得出的容器（后缀）；看不出为空")
    created_at: datetime = Field(description="入账时间")


class StrmPendingView(BaseModel):
    items: list[StrmPendingFile]
    total: int = Field(description="符合条件的待探文件数（不计排除的容器）")
    next_cursor: str | None = Field(description="下一页的游标；没有了为空")


class StrmProbeView(BaseModel):
    file_id: int
    status: Literal["probed", "ready", "failed", "backoff", "not_strm"] = Field(
        description="probed：这次探出了规格；ready：本来就有；failed：没探成；"
        "backoff：还在失败退避期没探；not_strm：不是网盘条目"
    )
    error: str | None = Field(default=None, description="没探成的原因")
    next_retry_at: datetime | None = Field(default=None, description="失败退避到什么时候")
    container: str | None = None
    video_codec: str | None = None
    resolution: str | None = None


def _container_of(file_path: str) -> str | None:
    """直链的容器：双后缀文件名（foo.mkv.strm）直接看出来，否则读 .strm 看直链路径的后缀。"""
    from movieclaw_api.services.playback.strm_probe import URL_CONTAINERS
    from movieclaw_playback.streaming import resolve_strm_url

    known = URL_CONTAINERS | {"iso"}
    inner = PurePosixPath(PurePosixPath(file_path).stem).suffix.lower().lstrip(".")
    if inner in known:
        return inner
    url = resolve_strm_url(file_path)
    if url is None:
        return None
    suffix = PurePosixPath(urlsplit(url).path).suffix.lower().lstrip(".")
    return suffix if suffix in known else None


@router.get(
    "/pending",
    response_model=ApiResponse[StrmPendingView],
    summary="还没探过规格的网盘条目（不含失败退避期内的）",
    operation_id="library.strm.list-pending",
)
async def list_pending(
    library_id: int | None = Query(default=None, description="只看这个库"),
    media_item_id: int | None = Query(default=None, description="只看这个条目"),
    season: int | None = Query(default=None, description="只看这一季（配合条目）"),
    exclude_containers: list[str] = Query(
        default_factory=list, description="跳过这些容器（按直链后缀，如 ts、iso）"
    ),
    order: Literal["recent", "episode"] = Query(
        default="recent", description="recent：新入库的在前；episode：按季集顺序"
    ),
    limit: int = Query(default=20, ge=1, le=200),
    cursor: str | None = Query(default=None, description="上一页返回的 next_cursor"),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[StrmPendingView]:
    now = utcnow()
    conditions = [
        func.lower(LibraryFile.file_path).like("%.strm"),
        LibraryFile.video_codec.is_(None),
        LibraryFile.state == FileState.IN_PLACE,
        or_(StrmProbeState.next_retry_at.is_(None), StrmProbeState.next_retry_at <= now),
    ]
    if library_id is not None:
        conditions.append(LibraryFile.library_id == library_id)
    if media_item_id is not None:
        conditions.append(LibraryFile.media_item_id == media_item_id)
    if season is not None:
        conditions.append(LibraryFile.season_number == season)
    base = select(LibraryFile).outerjoin(StrmProbeState, StrmProbeState.file_id == LibraryFile.id)
    count = select(func.count()).select_from(
        LibraryFile.__table__.outerjoin(
            StrmProbeState.__table__, StrmProbeState.file_id == LibraryFile.id
        )
    )
    total = (await session.execute(count.where(*conditions))).scalar_one()
    if order == "episode":
        ordering = (LibraryFile.season_number, LibraryFile.episode_number, LibraryFile.id)
    else:
        ordering = (LibraryFile.created_at.desc(), LibraryFile.id.desc())
    offset = int(cursor) if cursor and cursor.isdigit() else 0
    excluded = {c.lower().lstrip(".") for c in exclude_containers}
    rows = (
        (
            await session.execute(
                base.where(*conditions).order_by(*ordering).offset(offset).limit(_SCAN_BUDGET)
            )
        )
        .scalars()
        .all()
    )
    items: list[StrmPendingFile] = []
    consumed = 0
    for row in rows:
        if len(items) >= limit:
            break
        consumed += 1
        container = _container_of(row.file_path)
        if container in excluded:
            continue
        assert row.id is not None
        items.append(
            StrmPendingFile(
                file_id=row.id,
                library_id=row.library_id,
                media_item_id=row.media_item_id,
                season=row.season_number,
                episode=row.episode_number,
                container=container,
                created_at=row.created_at,
            )
        )
    more = consumed < len(rows) or len(rows) == _SCAN_BUDGET
    return ok(
        StrmPendingView(
            items=items,
            total=total,
            next_cursor=str(offset + consumed) if more else None,
        )
    )


@router.post(
    "/files/{file_id}/probe",
    response_model=ApiResponse[StrmProbeView],
    summary="探一个网盘条目的规格（默认遵守失败退避）",
    operation_id="library.strm.probe",
)
async def probe(
    file_id: int,
    respect_backoff: bool = Query(default=True, description="还在失败退避期就不探"),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[StrmProbeView]:
    from movieclaw_api.services.playback.strm_probe import probe_file

    result = await probe_file(file_id, respect_backoff=respect_backoff)
    if result.status == "missing":
        raise NotFoundException(f"没有文件 #{file_id}")
    row = await session.get(LibraryFile, file_id)
    if row is not None:
        await session.refresh(row)
    return ok(
        StrmProbeView(
            file_id=file_id,
            status=result.status,  # type: ignore[arg-type]
            error=result.error,
            next_retry_at=result.next_retry_at,
            container=row.container if row is not None else None,
            video_codec=row.video_codec if row is not None else None,
            resolution=row.resolution if row is not None else None,
        )
    )
