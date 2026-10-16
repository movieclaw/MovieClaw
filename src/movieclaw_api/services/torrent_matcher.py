"""被动匹配（F2）：新入库种子 × 活跃缺口，水位驱动。

触发有两处（docs/design/subscription-p4.md 第 3 节）：
1. ``sync_site_torrents`` 尾部直调（同进程零延迟）；
2. 低频兜底任务（进程重启期间的漏网 + sync 异常中断后的补扫）。

水位语义：``app_setting`` 里存最后处理过的 ``site_torrent.id``。**首次运行把
水位初始化到当前最大 id**——历史缓存不参与匹配，这是"本地缓存只用来追新，
补旧永远真实搜索"铁律的实现落点：缓存对旧内容覆盖不完整，偶然命中给出的
是残缺候选集。
"""

from __future__ import annotations

import asyncio
import logging

from pydantic import Field
from sqlalchemy import func
from sqlmodel import select

from movieclaw_api.services.subscription import (
    MATCH_BATCH_SIZE,
    evaluate_and_dispatch,
    evaluate_release_forecasts,
    refresh_release_forecasts,
    try_replacement_candidates,
)
from movieclaw_api.settings.base import SettingSchema, register_setting
from movieclaw_api.settings.store import get_setting_store
from movieclaw_db.engine import get_database
from movieclaw_db.models import SiteTorrent
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_scheduler import register_task

logger = logging.getLogger("movieclaw_api.torrent_matcher")


@register_setting(namespace="subscription.match_watermark", title="订阅被动匹配水位")
class MatchWatermark(SettingSchema):
    """被动匹配的处理水位。走配置内核（校验/缓存/导出），不直写 app_setting。"""

    last_id: int | None = Field(
        default=None, description="最后处理过的 site_torrent.id；None 表示尚未初始化"
    )


# 单实例部署假设下，进程内锁足以避免 sync 尾调与兜底任务并发推进水位
_lock = asyncio.Lock()


async def process_new_torrents(*, full_forecast_refresh: bool = False) -> None:
    """扫描水位之后的新种子，喂给共享评估管道，批处理直到追平。

    背景任务语义：绝不向外抛异常（sync 尾调时不能影响同步主流程）。

    ``full_forecast_refresh``：同步尾调为 False——只重算本轮新种里出现了单集观测
    的在追剧（新种没带来观测，预测不可能变化）；每小时兜底为 True，全量重算，
    覆盖别名修改、种子补 ID、重新富化、观测滑出窗口这些不经过新种的变化。
    """
    try:
        async with _lock:
            before = await _read_watermark()
            await _process_locked()
            # 新种子的发布时间本身就是下一集预测的新观测。匹配水位推进后立即
            # 重算受影响的追新工单，不依赖另一套 observation 表或独立定时任务。
            after = await _read_watermark()
            async with get_database().session() as session:
                if full_forecast_refresh or before is None:
                    # 兜底任务，或水位刚初始化（首跑/记录损坏）不知道哪些是新种：全量重算
                    await refresh_release_forecasts(session)
                    # 预测机制的实验打分随兜底任务每小时跑一次，不进同步热路径
                    await evaluate_release_forecasts(session)
                elif after != before:
                    await refresh_release_forecasts(session, new_since_id=before)
    except Exception:  # noqa: BLE001 -- 背景匹配失败只记日志，等下一轮
        logger.exception("被动匹配执行失败，等待下一轮触发")


async def _read_watermark() -> int | None:
    """读取水位；记录损坏（脏 JSON / 非法值）时按首次运行处理（自愈）。

    SettingStore 对结构不合法的行会抛 ValueError（含 JSONDecodeError 与
    pydantic ValidationError），这里不能让它穿透——否则被动匹配会每个
    tick 报错直到手工修库。降级为 None 后，本轮会重新初始化水位并覆盖
    脏行，恢复旧实现的自愈语义。
    """
    try:
        return (await get_setting_store().get(MatchWatermark)).last_id
    except ValueError:
        logger.warning("被动匹配水位记录损坏，按首次运行处理")
        return None


async def _process_locked() -> None:
    db = get_database()
    store = get_setting_store()
    while True:
        watermark = await _read_watermark()
        async with db.session() as session:
            if watermark is None:
                # 首次运行：水位落到当前最大 id，历史缓存不参与匹配（见模块注释）
                result = await session.execute(select(func.max(SiteTorrent.id)))
                latest = int(result.scalar_one() or 0)
                await store.set(MatchWatermark(last_id=latest))
                logger.info("被动匹配水位初始化：从 site_torrent #%d 之后开始跟随", latest)
                return

            result = await session.execute(
                select(SiteTorrent)
                .where(SiteTorrent.id > watermark)  # type: ignore[arg-type]
                .order_by(SiteTorrent.id)  # type: ignore[arg-type]
                .limit(MATCH_BATCH_SIZE)
            )
            rows = list(result.scalars().all())
            if not rows:
                return

            # 没有任何缺口时评估管道自己会立即返回（它要加载匹配上下文，这里不再
            # 先加载一遍判空——那样每批都要把全部订阅的上下文多读一次）
            await evaluate_and_dispatch(session, rows, source="被动匹配")
            # 换源退避只约束主动跨站搜索；刚同步进索引的新种是新的事实，
            # 应立即抢跑评估，不能让用户等到 1h/3h/12h/24h 的下个时间点。
            await try_replacement_candidates(session, rows)
        await store.set(MatchWatermark(last_id=rows[-1].id or watermark))

        if len(rows) < MATCH_BATCH_SIZE:
            return  # 已追平


@register_task(
    "match_new_torrents",
    title="订阅被动匹配（兜底扫描）",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=3600,
    description=(
        "低频兜底：扫描种子索引中水位之后的新种子并匹配订阅缺口，并全量重算追新发布预测。"
        "主触发在站点同步任务尾部（零延迟），本任务只兜进程重启/同步异常的漏网。"
    ),
)
async def match_new_torrents_task() -> None:
    await process_new_torrents(full_forecast_refresh=True)
