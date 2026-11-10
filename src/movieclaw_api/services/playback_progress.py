"""卡片上的观看进度口径：时长取哪一个、百分比怎么算。

首页「接下来继续」、播放动态、观影统计、刷片、新到剧集、海报墙角标都印同一种
进度条，规则放在这一处，免得某一块悄悄改了口径、别处没跟上。
"""

from __future__ import annotations


def runtime_ms(
    file_duration_seconds: int | None,
    episode_runtime_minutes: int | None,
    item_runtime_minutes: int | None,
) -> int | None:
    """时长优先取真实文件，其次分集档案，最后退回条目常规片长。"""
    if file_duration_seconds and file_duration_seconds > 0:
        return file_duration_seconds * 1000
    runtime_minutes = episode_runtime_minutes or item_runtime_minutes
    return runtime_minutes * 60_000 if runtime_minutes and runtime_minutes > 0 else None


def progress_percent(position_ms: int, duration_ms: int | None) -> int | None:
    """生成卡片进度；保留 1%~99%——0 与 100 都不是"接着看"的状态。"""
    if position_ms <= 0 or not duration_ms:
        return None
    return max(1, min(99, round(position_ms * 100 / duration_ms)))


__all__ = ["progress_percent", "runtime_ms"]
