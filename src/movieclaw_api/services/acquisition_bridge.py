"""获取领域对媒体库接口的实现（docs/design/library-boundary.md §10）。

媒体库经 ``services/library/acquisition.py`` 的接口向这里要信息、发通知；
这里读订阅、下载器、手动下载的表与服务。``downloads`` 系统模块启动时绑定。
按设计稿 §10.3 分批迁入：入库桥（完成判定、身份线索、来源、画质、入库后）在后续批次搬过来，
搬过来之前这里经入库模块现有的函数取下载器信息。
"""

from __future__ import annotations

from collections.abc import Collection
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_db.models import LibraryFile, Subscription, utcnow


class Acquisition:
    async def describe_origins(
        self, session: AsyncSession, rows: list[LibraryFile]
    ) -> dict[int, dict[str, Any]]:
        from movieclaw_api.services.acquisition_origin import derive_origins

        return await derive_origins(session, rows)

    async def paths_in_use(self) -> set[str] | None:
        """下载器当前的落盘根名；下载器不可达时 None（如实报「无法确认」）。

        用途是识别「下载器直接做种库内路径」这种非常规部署：那种部署下库里的条目目录名就是下载器的落盘根名，
        搬走（哪怕是同盘 rename）都会让做种任务找不到文件。
        按正常方式入库的库（复制或硬链接）目录名是规范化过的 ``标题 (年份)``，
        与种子原名不同，不会命中。
        """
        from movieclaw_api.services.library import ingest

        briefs = await ingest._downloader_briefs()
        if briefs is None:
            return None
        return {b.content_name for b in briefs if getattr(b, "content_name", "")}

    async def item_moved(
        self, session: AsyncSession, media_item_id: int, target_library_id: int
    ) -> bool:
        """订阅一并改挂目标库：不然下一集下载完又按旧库投递，用户刚搬完就被打回原形。"""
        subscription = (
            await session.execute(
                select(Subscription).where(Subscription.media_item_id == media_item_id)
            )
        ).scalar_one_or_none()
        if subscription is None or subscription.library_id == target_library_id:
            return False
        subscription.library_id = target_library_id
        subscription.updated_at = utcnow()
        await session.commit()
        return True

    async def identity_changed(
        self,
        session: AsyncSession,
        *,
        gained: Collection[int],
        displaced: Collection[int] = (),
        moved_file_ids: Collection[int] = (),
    ) -> None:
        """库存对账的两个方向：新条目的单元在库成立、关工单；被腾空的旧条目工单退回继续找。

        退回时把改挂走的文件原先的来源种子一并记进负面记忆（见 ``reopen_unfulfilled_wanted``），
        来源按文件 id 从下载领域的来源记录里查。
        """
        from movieclaw_api.services.download_sources import stamps_for_files
        from movieclaw_api.services.subscription import (
            close_fulfilled_wanted,
            reopen_unfulfilled_wanted,
        )

        for item_id in gained:
            await close_fulfilled_wanted(session, item_id)
        if not displaced:
            return
        stamps = await stamps_for_files(session, list(moved_file_ids))
        lost_sources = {(site, torrent) for site, torrent in stamps.values() if torrent}
        for item_id in displaced:
            await reopen_unfulfilled_wanted(session, item_id, lost_sources=lost_sources)
