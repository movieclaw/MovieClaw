"""进程外运行器的消息协议（docs/design/plugin-phase3.md §4.2）。

传输无关：本机子进程走标准输入输出（每行一条 JSON），将来 ``mclaw plugin dev`` 远程开发用 WebSocket
承载同一套消息。载荷就是契约里的冻结模型按 JSON 模式导出，两端用同一个模型类校验。

- 宿主 → 插件：``init``、``call``（投递事件 / 调用钩子）、``next_result``（钩子里 ``next()``
  的结果）、``dispose``；
- 插件 → 宿主：``hello``、``on``、``ready`` / ``failed``、``next``（钩子里调用 ``next()``）、
  ``reply``。
"""

from __future__ import annotations

import json
from functools import cache
from typing import Any

from pydantic import TypeAdapter

from movieclaw_kernel import Event, Stability

#: 一条消息的上限：钩子载荷是一批候选，几百 KB 已经很大了
MAX_LINE = 16 * 1024 * 1024


def encode(message: dict[str, Any]) -> bytes:
    return json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


def decode(line: bytes) -> dict[str, Any]:
    message = json.loads(line)
    if not isinstance(message, dict) or not isinstance(message.get("type"), str):
        raise ValueError(f"不是合法的协议消息：{line[:200]!r}")
    return message


@cache
def known_events() -> dict[str, Event[Any, Any]]:
    """进程外插件能订阅的事件：开放给第三方（实验级以上）的钩子与领域事件，按名字索引。"""
    from movieclaw_api import domain_events, hooks

    found: dict[str, Event[Any, Any]] = {}
    for module in (hooks, domain_events):
        for value in vars(module).values():
            if isinstance(value, Event) and value.stability is not Stability.INTERNAL:
                found[value.name] = value
    return found


@cache
def _adapter(tp: Any) -> TypeAdapter[Any]:
    return TypeAdapter(tp)


def dump(tp: Any, value: Any) -> Any:
    if value is None:
        return None
    return _adapter(tp).dump_python(value, mode="json")


def load(tp: Any, data: Any) -> Any:
    if data is None:
        return None
    return _adapter(tp).validate_python(data)
