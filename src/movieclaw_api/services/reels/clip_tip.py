"""「开启片段预切」建议（docs/design/tips.md「服务端代记的事件」）。

片段预切默认关。开关关着时有人刷片、电视放了大图预告，说明这台服务器用得上它。可这件事
是谁都可能做的（成员、电视），能开开关的只有管理员，所以由服务端替管理员记一次事件
``reels.played-without-clips``：网页媒体库页据此给管理员出提示卡；第一次记到时再给
管理员的手机推一条，点开到「设置 → 播放」。开关一打开（哪一端开的都算），提示作废。

开销：每个进程只在第一次放出片段时写一次库，之后都是同一个事实，直接返回。
"""

from __future__ import annotations

import logging

from movieclaw_api.services import tips
from movieclaw_api.services.push import events as push_events
from movieclaw_api.services.push.dispatcher import spawn
from movieclaw_db.engine import get_database

logger = logging.getLogger("movieclaw_api.reels")

EVENT_ID = "reels.played-without-clips"
TIP_ID = "playback.reel-clips"
#: 只有超管能改播放设置
ADMIN = 0

_noted = False


def note_played_without_clips() -> None:
    """刷片 / 大图预告放出了原片片段（业务链路上调用：只看一个内存标记）。"""
    global _noted
    if _noted:
        return
    _noted = True
    spawn(_record())


async def _record() -> None:
    from movieclaw_api.services.reels import clips

    try:
        if await clips.enabled():
            # 开着却还有老 App 放原片：管理员已经知道这个功能（含本功能上线前就开了的）
            await invalidate("action_performed")
            return
        async with get_database().session() as session:
            record = await tips.load_record(session, ADMIN, TIP_ID)
            if record is not None and record.invalidated_at is not None:
                return
            event = await tips.donate(session, ADMIN, EVENT_ID)
        if event.count == 1:
            push_events.reel_clips_suggested()
    except Exception:  # noqa: BLE001 -- 提示不是关键功能，不能影响刷片
        logger.exception("记录片段预切建议失败（已忽略）")


async def invalidate(reason: str) -> None:
    """开关打开了：提示作废，网页不再出卡片。"""
    try:
        async with get_database().session() as session:
            await tips.invalidate(session, ADMIN, TIP_ID, reason)
    except Exception:  # noqa: BLE001 -- 提示不是关键功能，不能让保存设置失败
        logger.exception("作废片段预切建议失败（已忽略）")


def reset_state() -> None:
    """测试用。"""
    global _noted
    _noted = False
