"""网盘规格预探（docs/design/plugin-strm-prefetch.md §5）。

网盘（strm）条目的格式、音轨、字幕要读网盘上的文件头才知道。主程序在第一次播放时现探（要多等一次
远程读取）；这个插件把它挪到播放之前：后台逐个补探，看到要播的、收藏的、打开详情的就让它们插队。

插件只管**先探谁、多快**——探测本身、失败退避、strm 改写后重探都在主程序（``library.strm.*`` 宿主
操作）。停用或卸载后回到「第一次播放时现探」，什么都不会坏。

- **整库补探**（``strm-prefetch:backfill``，优先级 −10）：每次取一个待探文件（新入库的在前），探完
  歇一个间隔；一轮最长 10 分钟就交还执行位，再排下一轮，直到没有待探的。启动、启用插件、扫描入账了
  新的网盘文件时排上（去重：同时只有一个）。
- **插队**（``strm-prefetch:item``，优先级 0，先于整库补探被领取）：开始播放 → 这一季接下来几集；
  收藏 → 整部（有上限）；打开详情 → 前几个。
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

from pydantic import BaseModel, Field

from movieclaw_sdk import Context, plugin
from movieclaw_sdk.events import (
    LIBRARY_FILES_ADDED,
    LIBRARY_ITEM_FAVORITED,
    LIBRARY_ITEM_VIEWED,
    PLAYBACK_STARTED,
    FilesAdded,
    ItemFavorite,
    ItemViewed,
    Playback,
)
from movieclaw_sdk.jobs import (
    JOB_HANDLERS,
    PLUGIN_JOBS,
    JobCancelled,
    JobRetry,
    RegisteredJobHandler,
    ResourceRef,
)
from movieclaw_sdk.ops import HOST_OPS, OpsError

logger = logging.getLogger("movieclaw_plugins.strm_prefetch")

PLUGIN_ID = "strm-prefetch"
BACKFILL = f"{PLUGIN_ID}:backfill"
ITEM = f"{PLUGIN_ID}:item"

#: 整库补探一轮最长占用执行位多久（秒）：到点交还，让别的任务也有机会
ROUND_SECONDS = 600.0
#: 插队探多少个：开始播放（接下来几集）、打开详情、收藏
NEXT_EPISODES = 2
ON_VIEW = 3
ON_FAVORITE = 30


class Config(BaseModel):
    interval_seconds: float = Field(
        default=3.0,
        ge=0.5,
        le=120.0,
        title="两次探测的间隔（秒）",
        description="每探完一个歇多久。网盘限流严的调大一些",
    )
    skip_containers: list[str] = Field(
        default_factory=lambda: ["ts", "m2ts", "iso"],
        title="不预探的格式",
        description="按直链后缀。这些格式在网盘上探得慢、容易失败，留给第一次播放时再探",
    )


class _Prefetch:
    def __init__(self, ctx: Context) -> None:
        self.ctx = ctx
        self.config: Config = ctx.config
        self.jobs = ctx.use(PLUGIN_JOBS).scoped(ctx)
        self.ops: Any = None

    async def call(self, operation: str, **arguments: Any) -> Any:
        if self.ops is None:
            self.ops = await self.ctx.use(HOST_OPS).client(self.ctx)
        return await self.ops.call(operation, arguments)

    async def pending(self, limit: int, **filters: Any) -> dict[str, Any]:
        """待探列表；一页里全是跳过的格式时接着往后翻，直到凑到或翻完。"""
        arguments = {k: v for k, v in filters.items() if v is not None}
        cursor = None
        while True:
            page = await self.call(
                "library.strm.list-pending",
                limit=limit,
                exclude_containers=list(self.config.skip_containers),
                **arguments,
                **({"cursor": cursor} if cursor else {}),
            )
            if page["items"] or not page["next_cursor"]:
                return page
            cursor = page["next_cursor"]

    async def probe(self, file_id: int) -> dict[str, Any]:
        return await self.call("library.strm.probe", file_id=file_id)

    # ------------------------------------------------------------------ 排任务
    async def backfill(self, *, after: str | None = None) -> None:
        """排一轮整库补探（已有就不重复排）。

        去重拿回来的是正在收尾的旧任务时（停用后还在取消中、或这一轮刚到点），等它结束再排——
        否则它一结束就没有下一轮了。``after="running"``：调用方就是那个正在收尾的任务。
        """
        winding_down = {"cancelling", after}
        for _ in range(60):
            # 不给 subject：任务中心直接显示任务名「网盘规格预探」
            ref = await self.jobs.create(BACKFILL, priority=-10, dedupe_key="backfill")
            if ref.created or ref.status not in winding_down:
                return
            await asyncio.sleep(1.0)

    async def backfill_if_pending(self) -> None:
        try:
            if (await self.pending(1))["total"]:
                await self.backfill()
        except Exception:  # noqa: BLE001 -- 启动时查不到就等下一次入账
            logger.exception("查询待探的网盘条目失败")

    async def jump(
        self,
        media_item_id: int,
        *,
        season: int | None = None,
        after_episode: int | None = None,
        limit: int,
        reason: str,
    ) -> None:
        """插队：这个条目（这一季、这一集之后）待探的先探。"""
        key = f"item:{media_item_id}:{season}:{after_episode}:{limit}"
        await self.jobs.create(
            ITEM,
            input={
                "media_item_id": media_item_id,
                "season": season,
                "after_episode": after_episode,
                "limit": limit,
                "reason": reason,
            },
            priority=0,
            dedupe_key=key,
            resources=[ResourceRef("media_item", media_item_id, "context")],
        )

    # ------------------------------------------------------------------ 事件
    async def on_files_added(self, event: FilesAdded) -> None:
        if any(f.strm for f in event.files):
            await self.backfill()

    async def on_playback(self, event: Playback) -> None:
        if event.unit is not None and event.unit.season > 0:
            await self.jump(
                event.media.id,
                season=event.unit.season,
                after_episode=event.unit.episode,
                limit=NEXT_EPISODES,
                reason="接下来要播的几集",
            )

    async def on_favorite(self, event: ItemFavorite) -> None:
        await self.jump(
            event.media.id, season=event.season, limit=ON_FAVORITE, reason="收藏的条目"
        )

    async def on_viewed(self, event: ItemViewed) -> None:
        await self.jump(
            event.media.id, season=event.season, limit=ON_VIEW, reason="打开详情的条目"
        )

    # ------------------------------------------------------------------ 任务
    async def run_backfill(self, context: Any, data: dict[str, Any]) -> dict[str, Any]:
        started = time.monotonic()
        first = await self.pending(1)
        total = first["total"]
        done = failed = 0
        last: int | None = None
        while time.monotonic() - started < ROUND_SECONDS:
            await context.raise_if_cancelled()
            page = first if done == 0 and failed == 0 else await self.pending(1)
            if not page["items"]:
                return {"probed": done, "failed": failed, "remaining": 0}
            file_id = page["items"][0]["file_id"]
            if file_id == last:
                # 同一个文件还在队首：主程序没记下结论（不该发生），别原地打转
                raise JobRetry("网盘条目的探测结论没记下来，稍后再试", delay_seconds=300)
            last = file_id
            result = await self._probe_quietly(file_id)
            if result in ("probed", "ready"):
                done += 1
            else:
                failed += 1
            await context.update_progress(
                mode="determinate",
                phase="probe",
                message=f"已探 {done} 个" + (f"，{failed} 个没探成（稍后重试）" if failed else ""),
                current=done + failed,
                total=max(total, done + failed),
            )
            await self._pause(context)
        # 到点交还执行位：结束这一轮，稍后排下一轮
        self.ctx.task(self._next_round(), name="next-round")
        return {"probed": done, "failed": failed, "remaining": "more"}

    async def run_item(self, context: Any, data: dict[str, Any]) -> dict[str, Any]:
        after = data.get("after_episode")
        limit = int(data.get("limit") or 1)
        page = await self.pending(
            200,
            media_item_id=data["media_item_id"],
            season=data.get("season"),
            order="episode",
        )
        targets = [
            item
            for item in page["items"]
            if after is None or (item["season"], item["episode"]) > (data.get("season"), after)
        ][:limit]
        done = 0
        for index, item in enumerate(targets):
            await context.raise_if_cancelled()
            if index:
                await self._pause(context)
            if await self._probe_quietly(item["file_id"]) in ("probed", "ready"):
                done += 1
            await context.update_progress(
                mode="determinate",
                phase="probe",
                message=f"已探 {index + 1} / {len(targets)}",
                current=index + 1,
                total=len(targets),
            )
        return {"probed": done, "targets": len(targets)}

    async def _probe_quietly(self, file_id: int) -> str:
        try:
            return (await self.probe(file_id))["status"]
        except OpsError as exc:
            if exc.status == 404:
                return "missing"  # 文件刚被删了
            raise

    async def _pause(self, context: Any) -> None:
        """两次探测之间歇一会儿；期间取消能及时生效。"""
        deadline = time.monotonic() + self.config.interval_seconds
        while (left := deadline - time.monotonic()) > 0:
            await asyncio.sleep(min(left, 1.0))
            if await context.cancel_requested():
                raise JobCancelled

    async def _next_round(self) -> None:
        """这一轮的任务收尾以后再排下一轮（还没收尾时去重会拿回它自己）。"""
        await asyncio.sleep(1.0)
        await self.backfill(after="running")


@plugin(
    PLUGIN_ID,
    title="网盘规格预探",
    config=Config,
    inject=(HOST_OPS, PLUGIN_JOBS),
    permissions=("library.strm.list-pending", "library.strm.probe"),
    disableable=True,
    reloadable=True,
)
async def strm_prefetch(ctx: Context) -> None:
    """提前在后台探好网盘条目的格式与音轨字幕，首播不用现等；要播的、收藏的、打开详情的优先。"""
    prefetch = _Prefetch(ctx)
    ctx.contribute(
        JOB_HANDLERS,
        BACKFILL,
        RegisteredJobHandler(prefetch.run_backfill, frozenset({1}), title="网盘规格预探"),
    )
    ctx.contribute(
        JOB_HANDLERS,
        ITEM,
        RegisteredJobHandler(prefetch.run_item, frozenset({1}), title="网盘规格预探（插队）"),
    )
    ctx.on(LIBRARY_FILES_ADDED, prefetch.on_files_added, id="files-added")
    ctx.on(PLAYBACK_STARTED, prefetch.on_playback, id="playback")
    ctx.on(LIBRARY_ITEM_FAVORITED, prefetch.on_favorite, id="favorite")
    ctx.on(LIBRARY_ITEM_VIEWED, prefetch.on_viewed, id="viewed")
    # 没探过的补探：有待探的就排一轮（升级后第一次启动即开始补已有的网盘条目）
    ctx.task(prefetch.backfill_if_pending(), name="initial-backfill")
