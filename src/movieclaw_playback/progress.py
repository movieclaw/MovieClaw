"""进度判定规则——通行的 scrobble 语义（设计文档第 7 节，v1.1 按源码修正版）。

默认沿用 Jellyfin 的三分支（阈值 5% / 90% / 300 秒），完成条件可由服务端配置：
- 进度 < 5% → 位置清零、已看状态**不变**（视为未开始）；
- 超过完成百分比，或到达有效片尾起点 → 位置清零、标记已看；
- 中间区间：时长 < 300 秒的短片直接算看完；否则记录续播位置；
- 无时长数据 → 直接标记已看（无从判定，宁可标完）。

play_count 与 last_played_at 在**开始播放**时更新（SessionManager.cs:845），
不在结束时——这也是"只发 Progress 不发 Stopped 的客户端（强杀 App）
不会漏计"的原因。
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from movieclaw_db.models.base import utcnow

MIN_RESUME_PCT = 5.0
MAX_RESUME_PCT = 90.0
MIN_RESUME_DURATION_MS = 300 * 1000


@dataclass(frozen=True)
class ProgressOutcome:
    """一次进度上报应落库的结果。"""

    position_ms: int
    played: bool


def resolve_progress(
    position_ms: int | None,
    runtime_ms: int | None,
    *,
    currently_played: bool,
    completion_percent: float = MAX_RESUME_PCT,
    completion_position_ms: int | None = None,
    preserve_unknown_runtime: bool = False,
) -> ProgressOutcome:
    """按阈值三分支把"播到哪了"折算成落库状态。

    Progress 与 Stopped 都走本函数——达到完成条件后强杀 App（只发过 Progress）
    的场景同样要被标已看。

    ``position_ms=None`` = 客户端**没报**位置（区别于报了 0）。对齐
    UserDataManager.cs:445 的 ``reportedPositionTicks ?? runtimeTicks``：
    不报位置视同播到结尾（标已看）；报 0 = 拖回开头（清续播点，已看不变）。
    """
    if preserve_unknown_runtime and not runtime_ms:
        # 显式片源已经丢失、且没有该版本片长：不能把未知时长当作已播完。
        return ProgressOutcome(position_ms=max(position_ms or 0, 0), played=currently_played)
    if position_ms is None:
        position_ms = runtime_ms or 0
        if position_ms <= 0:
            # 无位置也无时长：无从判定，宁可标完（UserDataManager.cs:492-496）
            return ProgressOutcome(position_ms=0, played=True)
    if position_ms <= 0:
        return ProgressOutcome(position_ms=0, played=currently_played)
    if not runtime_ms or runtime_ms <= 0:
        return ProgressOutcome(position_ms=0, played=True)

    pct = position_ms / runtime_ms * 100
    if pct < MIN_RESUME_PCT:
        return ProgressOutcome(position_ms=0, played=currently_played)
    valid_completion = (
        completion_position_ms is not None and 0 < completion_position_ms < runtime_ms
    )
    completed = (
        position_ms >= completion_position_ms
        if valid_completion
        else pct > completion_percent
    )
    # 库内片长只有整秒精度（原盘还会四舍五入）；100% 也须保留这一秒容差，
    # 否则 600.6 秒的文件被记为 601 秒后，实际播完仍永远到不了阈值。
    at_end = position_ms >= runtime_ms - 1000
    if completed or at_end:
        return ProgressOutcome(position_ms=0, played=True)
    if (
        runtime_ms < MIN_RESUME_DURATION_MS
        and completion_percent == MAX_RESUME_PCT
        and not valid_completion
    ):
        # 默认策略保留既有短片语义；自定义百分比/片尾不能被短片规则绕过。
        return ProgressOutcome(position_ms=0, played=True)
    return ProgressOutcome(position_ms=position_ms, played=currently_played)


def resolve_mark_played(
    *, play_count: int, date_played: datetime | None, last_played_at: datetime | None
) -> tuple[int, datetime]:
    """显式"标记已看"的计数语义（BaseItem.MarkPlayed）：

    传了 date_played 才 +1；否则只保证至少为 1（幂等标已看不刷次数）。
    返回 (新 play_count, 新 last_played_at)。
    """
    if date_played is not None:
        return play_count + 1, date_played
    return max(play_count, 1), last_played_at or utcnow()
