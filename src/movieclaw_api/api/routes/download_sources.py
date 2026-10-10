"""媒体库文件的下载来源（docs/design/library-boundary.md §5）。

种子关联归下载领域：

- ``library.items.relations``：条目背后的订阅与下载器任务；路径与操作 id 沿用原来挂在媒体库下的，
  插件与命令行照常可用；
- ``dl.file-sources.list``：按文件 id 查来源种子，文件已经删掉也能查（删片后的清理靠它）。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.api.deps import require_admin
from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.schemas.download_sources import (
    FileTorrentView,
    ItemRelationsView,
    TorrentRelationView,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.download_sources import item_relations, torrents_for_files
from movieclaw_db.engine import get_session
from movieclaw_db.models import LibraryFile, MediaItem

router = APIRouter()


@router.get(
    "/downloaders/file-sources",
    response_model=ApiResponse[list[FileTorrentView]],
    summary="这些媒体库文件来自哪些下载器任务（文件已删除也能查，删片后清理用）",
    operation_id="dl.file-sources.list",
    tags=["downloaders"],
    dependencies=[Depends(require_admin)],
)
async def list_file_sources(
    file_ids: Annotated[
        str, Query(description="媒体库文件 id，逗号分隔（如删除事件里的 files[].id）")
    ],
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[FileTorrentView]]:
    """只读。``other_file_ids`` 非空表示这个种子还供着媒体库里别的文件（季包别的集、合集里别的条目、
    别的库、没识别的文件），删种会连带毁掉它们；``owned_by_movieclaw`` / ``hit_and_run`` 是删种前
    最该看的两个字段。"""
    try:
        ids = [int(x) for x in file_ids.split(",") if x.strip()]
    except ValueError as exc:
        raise BadRequestException("file_ids 须是逗号分隔的整数") from exc
    torrents = await torrents_for_files(session, ids)
    return ok([FileTorrentView(**t.__dict__) for t in torrents])


@router.get(
    "/libraries/{library_id}/items/{media_item_id}/relations",
    response_model=ApiResponse[ItemRelationsView],
    summary="条目背后的订阅与下载器任务（删片前看看会牵动什么）",
    operation_id="library.items.relations",
    tags=["libraries"],
    dependencies=[Depends(require_admin)],
)
async def get_item_relations(
    library_id: int,
    media_item_id: int,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ItemRelationsView]:
    """从订阅下载记录、手动下载意图和文件来源三处汇总，同一个下载器任务只出现一次。

    只读。``owned_by_movieclaw`` 与 ``hit_and_run`` 是删种前最该看的两个字段：不是 MovieClaw
    投递的种子、或 H&R 未达标的种子，删了可能违反站点规则。
    """
    item = await session.get(MediaItem, media_item_id)
    has_files = await session.scalar(
        select(LibraryFile.id)
        .where(LibraryFile.library_id == library_id, LibraryFile.media_item_id == media_item_id)
        .limit(1)
    )
    if item is None or has_files is None:
        raise NotFoundException("条目不存在，或在该媒体库中没有库存文件")
    relations = await item_relations(session, media_item_id)
    return ok(
        ItemRelationsView(
            media_item_id=media_item_id,
            subscription_id=relations.subscription_id,
            subscription_status=relations.subscription_status,
            torrents=[
                TorrentRelationView(
                    info_hash=t.info_hash,
                    downloader_id=t.downloader_id,
                    downloader_name=t.downloader_name,
                    title=t.title,
                    source=t.source,
                    site_id=t.site_id,
                    torrent_id=t.torrent_id,
                    owned_by_movieclaw=t.owned_by_movieclaw,
                    hit_and_run=t.hit_and_run,
                    status=t.status,
                    units=[list(u) for u in t.units],
                    file_ids=list(t.file_ids),
                    other_file_ids=list(t.other_file_ids),
                )
                for t in relations.torrents
            ],
        )
    )
