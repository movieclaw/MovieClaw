"""扩充属性的存量重算——"升级程序即全量生效"机制的落地。

提取逻辑改动时只需把 ``movieclaw_enrich.ENRICH_VERSION`` +1；应用启动阶段调用
本模块，把库里 ``enrich_version`` 落后（或从未扩充）的种子行按当前提取器重算。

``enrich`` 自 v3 起含同步 NER 模型推理（CPU 密集，弱机型单条可达几十毫秒），
存量几万行的重算可能长达分钟级甚至更久，因此有两条硬约束：

1. **不阻塞启动**：入口脚本对后端就绪有超时（默认 300 秒，应用内更新的快速
   重启窗口只有 60 秒），在 lifespan 里同步等完重算会在「大库 + 版本升级」时
   把启动拖过超时、被判启动失败而反复重启。故由 ``start_enrich_backfill``
   排成后台任务：应用先就绪，重算在后台进行。
2. **不阻塞事件循环**：每批的模型推理放入工作线程执行，循环保持响应
   （健康检查、页面请求不受影响，不会触发容器看门狗）。

分批提交：每批一个短会话 + commit，避免超大库时单事务过长；任一批失败只记
可读中文日志，不阻断（下次启动会重试，行为幂等）。后台重算期间种子同步可能
并发刷新同一行——attrs 只由 title/subtitle/category 纯函数推导，两边算出的
内容一致，覆盖无害。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging

from sqlalchemy import or_
from sqlmodel import select

# 重算 attrs 会改变 NER 片名，检索文本要跟着重算（见 services/torrent_match_text.py）
import movieclaw_api.services.torrent_match_text  # noqa: F401
from movieclaw_db.engine import get_database
from movieclaw_db.models.site_torrent import SiteTorrent
from movieclaw_enrich import ENRICH_VERSION, enrich

logger = logging.getLogger("movieclaw_api.enrich_backfill")

_BATCH_SIZE = 500

_backfill_task: asyncio.Task | None = None


def _enrich_batch(
    inputs: list[tuple[str, str | None, str | None, list[str] | None]],
) -> list[dict]:
    """整批扩充计算（含 NER 推理），供工作线程调用。"""
    return [
        enrich(title, subtitle, category, labels).model_dump(mode="json", exclude_defaults=True)
        for title, subtitle, category, labels in inputs
    ]


async def reenrich_stale_torrents() -> int:
    """把扩充版本过期（或从未扩充）的种子行重算一遍，返回处理行数。"""
    total = 0
    db = get_database()
    while True:
        try:
            async with db.session() as session:
                rows = (
                    (
                        await session.execute(
                            select(SiteTorrent)
                            .where(
                                or_(
                                    SiteTorrent.enrich_version.is_(None),  # type: ignore[union-attr]
                                    SiteTorrent.enrich_version != ENRICH_VERSION,
                                )
                            )
                            .limit(_BATCH_SIZE)
                        )
                    )
                    .scalars()
                    .all()
                )
                if not rows:
                    break
                # 行字段在主线程读齐，工作线程只做纯函数推理——ORM 对象不跨线程。
                # 站点标记不是从标题推出来的，旧 attrs 里有就带回去，不然重算会把它抹掉
                inputs = [
                    (row.title, row.subtitle, row.category, (row.attrs or {}).get("site_labels"))
                    for row in rows
                ]
                attrs_list = await asyncio.to_thread(_enrich_batch, inputs)
                for row, attrs in zip(rows, attrs_list, strict=True):
                    row.attrs = attrs
                    row.enrich_version = ENRICH_VERSION
                await session.commit()
                total += len(rows)
        except Exception:  # noqa: BLE001 -- 重算失败不阻断，下次启动幂等重试
            logger.warning("扩充属性重算中断（已完成 %d 条），下次启动将继续", total, exc_info=True)
            break
    if total:
        logger.info("已按提取器 v%d 重算 %d 条种子的扩充属性", ENRICH_VERSION, total)
    return total


def start_enrich_backfill() -> None:
    """把存量重算排成后台任务（lifespan 启动阶段调用，不等待完成）。"""
    global _backfill_task
    _backfill_task = asyncio.get_running_loop().create_task(_run_backfill())


async def _run_backfill() -> None:
    try:
        await reenrich_stale_torrents()
    except asyncio.CancelledError:
        raise
    except Exception:  # noqa: BLE001 -- reenrich 内部已自吞异常，这里是最后兜底
        logger.warning("扩充属性后台重算异常退出（下次启动将重试）", exc_info=True)


async def close_enrich_backfill() -> None:
    """停机时取消未完成的重算（已提交的批次保留，下次启动续算）。"""
    global _backfill_task
    if _backfill_task is not None:
        _backfill_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await _backfill_task
        _backfill_task = None
