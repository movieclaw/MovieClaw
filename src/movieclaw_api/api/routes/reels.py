"""刷片：沉浸式上下滑动看片段（docs/design/reels.md）。

- ``GET /reels``：一页片段。第一页不带 ``seed``，服务端生成后随响应返回，翻页时
  原样带回；``modes`` 声明 App 会放的方式（一期只有 ``seek``）。
- 筛选：``GET /reels`` 带媒体库筛选的同一组参数（``g`` 类型 / ``c`` 地区 / ``d`` 年代 /
  ``rating_gte`` 评分 / ``rt`` 片长 / ``w`` 观看状态，维内 OR、维间 AND）外加 ``kind``
  （电影 / 剧集 / 其他，``video`` 只认观看状态）；``GET /reels/facets`` 同参，给筛选菜单的
  候选值与计数。
- ``GET /reels/preview/{media_item_id}``：Apple TV 大图预告——首页从续播点往前倒 30 秒
  （``source=resume``），详情页放挑好的那一段（``source=highlight``），放不了返回 null。
- ``POST /reels/events``：App 攒一批刷片事件报上来，只落 ``reel_event`` 表，
  不写观看记录。
- 片段预切（docs/design/reels.md §8）：``GET /reels/clips/{file_id}/{start_ms}.mp4``
  按 Range 出切好的小文件（令牌同原片取流，不登记播放活动）；``GET /reels/clips/stats``
  与 ``DELETE /reels/clips`` 给设置页「关掉时要不要删」用（管理员）。
"""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Path, Query
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.api.deps import require_admin, require_login
from movieclaw_api.api.routes.libraries import _filter_params
from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.schemas.reels import (
    ReelClipStatsView,
    ReelEventBatch,
    ReelEventResult,
    ReelFacetsView,
    ReelFeedView,
    ReelItemView,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.items import LibraryFilter
from movieclaw_api.services.playback.signing import verify_stream_token
from movieclaw_api.services.reels import clips
from movieclaw_api.services.reels.facets import build_reel_facets
from movieclaw_api.services.reels.feed import build_feed, record_events
from movieclaw_api.services.reels.preview import build_preview
from movieclaw_db.engine import get_session
from movieclaw_playback.streaming import DisconnectAwareFileResponse

router = APIRouter(prefix="/reels", tags=["reels"])
#: 取流字节面（公开区，挂载时不注入登录鉴权）：系统播放器按 Range 取片段，带不了登录凭据，
#: 只认查询参数里的签名令牌——同 ``playback.stream_router`` 的原文件直出
clip_stream_router = APIRouter(prefix="/reels", tags=["reels"])

#: 「电影 / 剧集 / 其他」这一维：媒体库筛选没有它（一个库本来就只有一种），刷片是混着抽的。
#: 不传 = 电影 + 剧集；「其他」（video）不混进默认，要主动选，选了之后只剩观看状态可筛
#: （只有其他库时不传也回落到它，见 ``pool_libraries``）
KindParam = Annotated[
    Literal["movie", "tv", "video"] | None,
    Query(description="只刷电影 / 剧集 / 其他；不传是电影 + 剧集"),
]


@router.get(
    "",
    response_model=ApiResponse[ReelFeedView],
    summary="刷片：取一页片段",
    operation_id="reels.feed",
    openapi_extra={"x-cli-hidden": True},
)
async def get_reel_feed(
    seed: Annotated[int | None, Query(ge=0, description="随机种子；第一页不传")] = None,
    offset: Annotated[int, Query(ge=0, description="从抽样顺序的第几部开始")] = 0,
    limit: Annotated[int, Query(ge=1, le=20, description="这一页最多几条")] = 10,
    modes: Annotated[
        str,
        Query(description="App 会放的方式，逗号分隔：seek 原片起播 / clip 预切片段"),
    ] = "seek",
    kind: KindParam = None,
    filters: Annotated[LibraryFilter, Depends(_filter_params)] = None,  # type: ignore[assignment]
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ReelFeedView]:
    page = await build_feed(
        session,
        principal,
        seed=seed,
        offset=offset,
        limit=limit,
        modes={m.strip() for m in modes.split(",") if m.strip()},
        filters=filters,
        kind=kind,
    )
    return ok(
        ReelFeedView(
            seed=page.seed,
            next_offset=page.next_offset,
            has_more=page.has_more,
            items=page.items,  # type: ignore[arg-type]
            clips=page.clips,  # type: ignore[arg-type]
        )
    )


@router.get(
    "/facets",
    response_model=ApiResponse[ReelFacetsView],
    summary="刷片：筛选菜单的候选值与计数（每一维排除自身条件后算）",
    operation_id="reels.facets",
    openapi_extra={"x-cli-hidden": True},
)
async def get_reel_facets(
    kind: KindParam = None,
    filters: Annotated[LibraryFilter, Depends(_filter_params)] = None,  # type: ignore[assignment]
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ReelFacetsView]:
    """与 ``GET /reels`` 同参：菜单上写几部，点下去刷的就是这几部。"""
    return ok(await build_reel_facets(session, principal, filters, kind))


@router.get(
    "/preview/{media_item_id}",
    response_model=ApiResponse[ReelItemView | None],
    summary="大图预告：一部片停留后原地播放的那一段",
    operation_id="reels.preview",
    openapi_extra={"x-cli-hidden": True},
)
async def get_reel_preview(
    media_item_id: Annotated[int, Path(description="条目 id")],
    source: Annotated[
        Literal["resume", "highlight"],
        Query(
            description="resume：续播点往前 30 秒放到续播点（没有续播点退回 highlight）；"
            "highlight：挑好的片段"
        ),
    ] = "highlight",
    season: Annotated[int, Query(ge=0, description="resume 的季号（电影 0）")] = 0,
    episode: Annotated[int, Query(ge=0, description="resume 的集号（电影 0）")] = 0,
    modes: Annotated[
        str,
        Query(
            description="App 会放的方式，逗号分隔。带 clip 且开了片段预切时只给切好的片段"
            "（没切好返回 null 并排队去切），source 一律按 highlight"
        ),
    ] = "seek",
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ReelItemView | None]:
    item = await build_preview(
        session,
        principal,
        media_item_id,
        source=source,
        season=season,
        episode=episode,
        modes={m.strip() for m in modes.split(",") if m.strip()},
    )
    return ok(item)  # type: ignore[arg-type]


@router.get(
    "/clips/stats",
    response_model=ApiResponse[ReelClipStatsView],
    summary="片段预切：已切片段的数量与占用空间",
    operation_id="reels.clips.stats",
    dependencies=[Depends(require_admin)],
    openapi_extra={"x-cli-hidden": True},
)
async def get_clip_stats() -> ApiResponse[ReelClipStatsView]:
    return ok(ReelClipStatsView(**clips.stats()))


@router.delete(
    "/clips",
    response_model=ApiResponse[ReelClipStatsView],
    summary="片段预切：删除全部已切片段",
    operation_id="reels.clips.clear",
    dependencies=[Depends(require_admin)],
    openapi_extra={"x-cli-hidden": True, "x-cli-dangerous": "destructive"},
)
async def delete_clips() -> ApiResponse[ReelClipStatsView]:
    """先停队列再整目录删除；返回删掉前的统计。开关开着时下次用到片段会重新排队。"""
    return ok(ReelClipStatsView(**await clips.delete_all()))


@clip_stream_router.get(
    "/clips/{file_id}/{start_ms}.mp4",
    summary="片段预切：按 Range 取切好的片段",
    operation_id="reels.clips.stream",
    openapi_extra={"x-cli-hidden": True},
)
async def stream_clip(
    file_id: Annotated[int, Path()],
    start_ms: Annotated[int, Path()],
    token: Annotated[str, Query()],
):
    """令牌与原片取流同一种（按文件签发）。不登记播放活动：预告、刷片不算「有人在看」，
    否则在首页浏览反而会让后台预切停下来让路。"""
    if await verify_stream_token(token, file_id=file_id) is None:
        raise NotFoundException("播放地址无效或已过期")
    info = clips.clip_for_file(file_id, start_ms)
    if info is None:
        raise NotFoundException("片段不存在或已过期")
    return DisconnectAwareFileResponse(info.path, media_type="video/mp4")


@router.post(
    "/events",
    response_model=ApiResponse[ReelEventResult],
    summary="刷片：上报事件",
    operation_id="reels.events",
    openapi_extra={"x-cli-hidden": True},
)
async def post_reel_events(
    payload: ReelEventBatch,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ReelEventResult]:
    member_id = principal.member_id if principal.member_id is not None else 0
    accepted = await record_events(session, member_id, [e.model_dump() for e in payload.events])
    return ok(ReelEventResult(accepted=accepted))
