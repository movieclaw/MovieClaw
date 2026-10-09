"""插件安全模式（docs/design/plugin-phase3.md §5）。

本地 / 第三方插件在主进程里运行，写坏了能把整个应用拖垮（死循环卡住事件循环、``os._exit``、
C 扩展段错误、吃光内存）。镜像入口脚本会在 overlay 启动后 60 秒内连续退出 2 次时判它是坏版本并回落——
如果真凶是插件，那就冤枉了应用版本。所以这里的阈值比入口脚本低一级：

1. 生命周期开始时在数据目录写一条「启动中」记录（时间、本次加载的插件）；
   稳定运行 60 秒或正常停机后清掉；
2. 启动时上一条记录还在（1 小时内）且那次加载过插件 → 本次跳过全部本地 / 第三方插件，
   进入安全模式；
3. 跳过插件后稳定了 → 问题在插件，保持安全模式直到用户退出（当场挂回被跳过的插件）；
   还是起不来 → 不是插件的问题，入口脚本的第 2 次失败照常回落坏版本。

手动入口：环境变量 ``MOVIECLAW_SAFE_MODE=1``（只能改环境变量退出），
或数据目录里放一个 ``SAFE_MODE`` 文件。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import secrets
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

logger = logging.getLogger("movieclaw_api.plugins.safe_mode")

STATE_FILE = "plugins-boot.json"
FLAG_FILE = "SAFE_MODE"
ENV = "MOVIECLAW_SAFE_MODE"
#: 稳定运行多久算「这次启动没问题」：与入口脚本的启动宽限期一致
STABLE_SECONDS = 60.0
#: 多久以前的「启动中」记录不再算数（与入口脚本的失败计数时间窗一致）
STALE_SECONDS = 3600.0
NOTICE_KEY = "plugins:safe-mode"


@dataclass
class SafeMode:
    active: bool = False
    reason: str = ""
    since: float | None = None
    skipped: list[str] = field(default_factory=list)
    forced: str | None = None
    """``env`` / ``file``：手动强制；``None``：自动进入或没有进入。"""

    def view(self) -> dict[str, Any]:
        return asdict(self)


#: 本次启动的结论（lifespan 在内核启动前定下，诊断接口与通知插件读它）
_current = SafeMode()


def current() -> SafeMode:
    return _current


def _data_dir(settings: object) -> Path:
    return Path(getattr(settings, "data_dir", "./data"))


def _read(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        logger.warning("插件启动记录 %s 读不出来，按没有记录处理", path)
        return {}
    return data if isinstance(data, dict) else {}


def _write(path: Path, data: dict[str, Any]) -> None:
    """尽力而为：写不进去只告警，绝不影响启动（安全模式是保护，不能自己变成故障）。"""
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, path)
    except OSError as exc:
        logger.warning("插件启动记录 %s 写不进去（%s），安全模式这次可能不生效", path, exc)
        with contextlib.suppress(OSError):
            tmp.unlink()


def decide(settings: object, plugin_ids: list[str], *, now: float | None = None) -> SafeMode:
    """启动时调用：定下本次是否进安全模式，并写下「启动中」记录。

    ``plugin_ids`` 是本次本该加载的本地 / 第三方插件。返回的结论同时存为 ``current()``。
    """
    global _current
    now = time.time() if now is None else now
    path = _data_dir(settings) / STATE_FILE
    state = _read(path)
    forced: str | None = None
    if os.environ.get(ENV, "").strip().lower() in ("1", "true", "yes", "on"):
        forced = "env"
    elif (_data_dir(settings) / FLAG_FILE).exists():
        forced = "file"

    safe = state.get("safe") if isinstance(state.get("safe"), dict) else None
    pending = state.get("pending") if isinstance(state.get("pending"), dict) else None
    if forced is not None:
        reason = (
            f"环境变量 {ENV} 要求以安全模式启动"
            if forced == "env"
            else f"数据目录里有 {FLAG_FILE} 文件，要求以安全模式启动"
        )
        result = SafeMode(True, reason, now, list(plugin_ids), forced)
    elif safe is not None:
        # 上次进了安全模式、用户还没退出：保持
        result = SafeMode(
            True, str(safe.get("reason") or ""), safe.get("since"), list(plugin_ids), None
        )
    elif (
        pending is not None
        and pending.get("plugins")
        and plugin_ids
        and now - float(pending.get("started_at") or 0) < STALE_SECONDS
    ):
        loaded = "、".join(pending["plugins"])
        reason = f"上次启动没能稳定运行（当时加载了插件：{loaded}），本次先不加载本地 / 第三方插件"
        result = SafeMode(True, reason, now, list(plugin_ids), None)
        state["safe"] = {"reason": reason, "since": now}
        logger.error("进入插件安全模式：%s", reason)
    else:
        result = SafeMode()
    if result.active and result.forced is not None:
        logger.warning("插件安全模式（手动）：%s", result.reason)
    state["pending"] = {"started_at": now, "plugins": [] if result.active else list(plugin_ids)}
    _write(path, state)
    _current = result
    return result


def mark_settled(settings: object) -> None:
    """稳定运行够久或正常停机：清掉「启动中」记录（安全模式本身保持，等用户退出）。"""
    path = _data_dir(settings) / STATE_FILE
    state = _read(path)
    if state.get("pending") is None:
        return
    state["pending"] = None
    _write(path, state)


def exit_safe_mode(settings: object, plugin_ids: list[str], *, now: float | None = None) -> None:
    """用户退出安全模式：清掉标记，重新开始「启动中」计时（挂回的插件再把应用拖垮，下次还会进来）。"""
    global _current
    if _current.forced == "env":
        raise PermissionError(f"安全模式是环境变量 {ENV} 强制的，去掉它并重启才能退出")
    if _current.forced == "file":
        (_data_dir(settings) / FLAG_FILE).unlink(missing_ok=True)
    path = _data_dir(settings) / STATE_FILE
    state = _read(path)
    state["safe"] = None
    state["pending"] = {
        "started_at": time.time() if now is None else now,
        "plugins": list(plugin_ids),
    }
    _write(path, state)
    _current = SafeMode()


_settle_task: asyncio.Task[None] | None = None


def schedule_settle(settings: object, delay: float = STABLE_SECONDS) -> None:
    """``delay`` 秒后清「启动中」记录；重复调用以最后一次为准。"""
    global _settle_task
    cancel_settle()

    async def settle() -> None:
        await asyncio.sleep(delay)
        mark_settled(settings)

    _settle_task = asyncio.get_running_loop().create_task(settle(), name="plugins-safe-mode-settle")


def cancel_settle() -> None:
    global _settle_task
    if _settle_task is not None and not _settle_task.done():
        _settle_task.cancel()
    _settle_task = None
