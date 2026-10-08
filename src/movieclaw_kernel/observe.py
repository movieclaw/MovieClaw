"""归属、发起方与内存指标（docs/design/plugin-kernel.md §4.7、§4.8）。

全部在内存里，零落盘：
- ``current_entry``：当前正在执行哪个条目的代码（apply、事件监听器、``ctx.task``）；
- ``current_origin``：当前操作由谁发起、因哪些事件引起（因果链）；
- ``EntryStats``：每个条目一份计数，诊断接口直接读。
"""

from __future__ import annotations

import contextvars
import logging
from dataclasses import dataclass, field

#: 因果链长度上限：插件之间经事件互相触发超过这个深度即拒绝分发
MAX_CAUSE_DEPTH = 8

current_entry: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "movieclaw_kernel_entry", default=None
)


@dataclass(frozen=True)
class Origin:
    """发起方与因果链。``kind``：``system`` / ``user`` / ``member`` / ``plugin``。"""

    kind: str = "system"
    id: str | None = None
    chain: tuple[str, ...] = ()
    """引起当前操作的事件名序列，最早的在前。"""

    def is_plugin(self, entry_id: str) -> bool:
        return self.kind == "plugin" and self.id == entry_id

    def caused_by(self, event_name: str, *, entry_id: str) -> Origin:
        """该条目处理 ``event_name`` 时，它的后续动作的发起方。"""
        return Origin(kind="plugin", id=entry_id, chain=(*self.chain, event_name))


SYSTEM = Origin()


@dataclass(frozen=True)
class DeliveryInfo:
    """可靠事件监听器的投递信息（经 ``ctx.delivery`` 读取）。

    ``origin`` 是**事件发生时**的发起方：插件据此忽略自己引起的事件。消费方以 ``event_id`` 去重
    （至少一次投递，重试与重放会重复送达）。
    """

    event_id: str
    name: str
    occurred_at: str
    origin: Origin
    attempt: int = 1


current_delivery: contextvars.ContextVar[DeliveryInfo | None] = contextvars.ContextVar(
    "movieclaw_kernel_delivery", default=None
)

current_origin: contextvars.ContextVar[Origin] = contextvars.ContextVar(
    "movieclaw_kernel_origin", default=SYSTEM
)


class EntryLogFilter(logging.Filter):
    """把当前条目 id 写进日志记录的 ``plugin`` 字段（没有时为空串）。"""

    def filter(self, record: logging.LogRecord) -> bool:
        if not hasattr(record, "plugin"):
            record.plugin = current_entry.get() or ""
        return True


@dataclass
class EntryStats:
    apply_ms: float | None = None
    dispose_ms: float | None = None
    events: int = 0
    failures: int = 0
    timeouts: int = 0
    dropped: int = 0
    handler_max_ms: float = 0.0
    handler_avg_ms: float = 0.0
    last_error: str | None = None
    unsettled: bool = False
    """释放超时、放弃等待：可能还有残留工作在跑。"""

    def record_handler(self, elapsed_ms: float) -> None:
        self.events += 1
        self.handler_max_ms = max(self.handler_max_ms, elapsed_ms)
        # 滑动平均：最近的样本权重 1/16，只为看量级
        if self.events == 1:
            self.handler_avg_ms = elapsed_ms
        else:
            self.handler_avg_ms += (elapsed_ms - self.handler_avg_ms) / 16

    def as_dict(self) -> dict[str, object]:
        return {
            "events": self.events,
            "failures": self.failures,
            "timeouts": self.timeouts,
            "dropped": self.dropped,
            "handler_max_ms": round(self.handler_max_ms, 2),
            "handler_avg_ms": round(self.handler_avg_ms, 2),
            "last_error": self.last_error,
        }


@dataclass
class Breaker:
    """监听器熔断（§4.7）：连续失败 5 次暂停，冷却 1 分钟起翻倍、最长 30 分钟。"""

    threshold: int = 5
    base_cooldown: float = 60.0
    max_cooldown: float = 1800.0
    consecutive_failures: int = 0
    trips: int = 0
    open_until: float | None = None
    half_open: bool = field(default=False)

    def allow(self, now: float) -> bool:
        if self.open_until is None:
            return True
        if now >= self.open_until:
            # 冷却结束：放行一次试探
            self.open_until = None
            self.half_open = True
            return True
        return False

    def success(self) -> None:
        self.consecutive_failures = 0
        self.half_open = False
        self.trips = 0

    def failure(self, now: float) -> bool:
        """记一次失败；返回本次是否触发了熔断。"""
        self.consecutive_failures += 1
        if self.half_open or self.consecutive_failures >= self.threshold:
            self.trips += 1
            cooldown = min(self.base_cooldown * (2 ** (self.trips - 1)), self.max_cooldown)
            self.open_until = now + cooldown
            self.consecutive_failures = 0
            self.half_open = False
            return True
        return False

    @property
    def state(self) -> str:
        if self.open_until is not None:
            return "open"
        return "half-open" if self.half_open else "closed"
