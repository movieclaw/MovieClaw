"""播放域事件：开始、停止、看完、进度、标记已看。全部是敏感事件（谁在什么时候看了什么）。"""

from __future__ import annotations

from movieclaw_sdk.events._base import ClientRef, Frozen, MediaRef, UnitRef, define


class Playback(Frozen):
    """一次播放上报时的状态。"""

    member_id: int
    """谁在看：成员 id，超管为 0。"""
    media: MediaRef
    unit: UnitRef | None
    """看的哪一集；电影为 ``None``。"""
    file_id: int | None = None
    """放的哪个文件（多版本时）；客户端没说为 ``None``。"""
    position_ms: int | None = None
    duration_ms: int | None = None
    played: bool = False
    play_count: int = 0
    client: ClientRef | None = None


class PlaybackStopped(Playback):
    completed: bool = False
    """这次停止时刚好看完（越过已看阈值），同时也会有一个 ``playback.completed``。"""


class PlaybackMarked(Frozen):
    """手动标记已看 / 取消已看（整部、整季标记会级联到下面每一集）。"""

    member_id: int
    media: MediaRef
    units: tuple[UnitRef, ...]
    """受影响的集；电影为空。"""
    client: ClientRef | None = None


PLAYBACK_STARTED = define(
    "playback.started",
    Playback,
    title="开始播放",
    group="播放",
    sensitive=True,
    version="2.0",
)
PLAYBACK_STOPPED = define(
    "playback.stopped", PlaybackStopped, title="停止播放", group="播放", sensitive=True
)
PLAYBACK_COMPLETED = define(
    "playback.completed",
    Playback,
    title="看完",
    group="播放",
    doc="看完（越过已看阈值）",
    sensitive=True,
)
PLAYBACK_PROGRESS = define(
    "playback.progress",
    Playback,
    title="播放进度",
    group="播放",
    doc="播放进度（每集最多 30 秒一条，高频）",
    sensitive=True,
    high_frequency=True,
)
PLAYBACK_MARKED_PLAYED = define(
    "playback.marked_played", PlaybackMarked, title="标记已看", group="播放", sensitive=True
)
PLAYBACK_MARKED_UNPLAYED = define(
    "playback.marked_unplayed", PlaybackMarked, title="取消已看", group="播放", sensitive=True
)
