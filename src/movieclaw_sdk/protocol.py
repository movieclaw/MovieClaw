"""进程外插件的契约编解码与一次性输出（docs/design/plugin-ipc-http.md）。

插件与宿主之间的通信是 HTTP over Unix 套接字（``movieclaw_sdk.rpc`` / ``http``），这里只剩：

- 开放事件的查找（``known_events``）与载荷编解码（``dump`` / ``load``，
  契约里的冻结模型按 JSON 模式导出，两端用同一个模型类校验）；
- ``runner --describe`` / ``--validate`` 这类一次性子命令在 stdout 输出的一行 JSON（``encode``）。
"""

from __future__ import annotations

import json
from functools import cache
from typing import Any

from pydantic import TypeAdapter

from movieclaw_kernel import Event, Stability


def encode(message: dict[str, Any]) -> bytes:
    return json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


@cache
def known_events() -> dict[str, Event[Any, Any]]:
    """进程外插件能订阅的事件：开放给第三方（实验级以上）的钩子与系统事件，按名字索引。"""
    from movieclaw_api import hooks
    from movieclaw_sdk.events import core_events

    found: dict[str, Event[Any, Any]] = {}
    for module in (hooks,):
        for value in vars(module).values():
            if isinstance(value, Event) and value.stability is not Stability.INTERNAL:
                found[value.name] = value
    for event in core_events():
        found[event.name] = event
    # 在运行的插件登记的事件（domain-events.md §7）：别的插件也能订
    from movieclaw_api.services import plugin_events

    found.update(plugin_events.catalog())
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
