"""功能开关：插件页「功能」里可停用功能的状态管理（docs/design/plugin-page-tiers.md §6）。

停用一个功能 = 它的组成插件全部不运行。运行中切换立即生效（内核的运行中启停），重启后保持。

- **状态**存 ``data/plugins-features.json``，只记偏离默认（默认全部开启）的项：谁、什么时候停用的。
  不放数据库：启动时内核要在数据库就绪之前决定哪些插件不启动（与 ``plugins-boot.json`` 同理）。
- **启动**：``feature_patches`` 把停用的功能翻成补丁层的禁用补丁（来源 ``feature:<key>``）。
- **优先级**：管理员的硬覆盖（``data/plugins.yaml``、环境变量）高于开关。被它们关掉的功能，
  开关锁住并写明原因（``locked_by``），网页上打不开。
- **切换**：先写状态文件，再动内核（停用按逆序、开启按正序）；内核这步出错时把文件改回去。
  同一时刻只处理一个切换。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from movieclaw_api.plugins.features import FEATURES, Feature, feature
from movieclaw_kernel import Patch, State

logger = logging.getLogger("movieclaw_api.plugin_features")

STATE_FILE = "plugins-features.json"
SOURCE_PREFIX = "feature:"

_lock = asyncio.Lock()


class FeatureSwitchError(Exception):
    """切换不了：原因直接给用户看。"""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass(frozen=True)
class SwitchRecord:
    #: 停用时间（ISO 8601 UTC）
    at: str
    #: 谁停用的（用户名）
    by: str | None


# ---------------------------------------------------------------------- 状态文件
def state_path(settings: object) -> Path:
    return Path(getattr(settings, "data_dir", "./data")) / STATE_FILE


def read_disabled(settings: object) -> dict[str, SwitchRecord]:
    """停用了哪些功能。文件不存在 = 全部开启；读不出来只告警、按全部开启处理（不拦启动）。"""
    path = state_path(settings)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        logger.warning("功能开关状态 %s 读不出来（%s），按全部开启处理", path, exc)
        return {}
    items = data.get("disabled") if isinstance(data, dict) else None
    if not isinstance(items, dict):
        logger.warning("功能开关状态 %s 格式不对，按全部开启处理", path)
        return {}
    result: dict[str, SwitchRecord] = {}
    for key, record in items.items():
        f = feature(key)
        if f is None or not f.switchable:
            # 功能被改名 / 不再可停用：忽略，避免一个旧开关永远关着某个插件
            logger.warning("功能开关状态里的 %s 不是可停用的功能，已忽略", key)
            continue
        record = record if isinstance(record, dict) else {}
        result[key] = SwitchRecord(at=str(record.get("at") or ""), by=record.get("by"))
    return result


def _write_disabled(settings: object, disabled: dict[str, SwitchRecord]) -> None:
    """原子写入（临时文件 + 改名，临时名唯一）；写不进去抛 OSError，由调用方回滚。"""
    path = state_path(settings)
    data = {
        "version": 1,
        "disabled": {key: {"at": r.at, "by": r.by} for key, r in sorted(disabled.items())},
    }
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, path)
    finally:
        with contextlib.suppress(OSError):
            tmp.unlink()


# ---------------------------------------------------------------------- 启动
def feature_patches(settings: object) -> list[Patch]:
    """停用的功能 → 组成插件的禁用补丁。要排在管理员补丁之前：同一插件被两边都关时，
    诊断显示管理员那一边（它才是开关被锁住的原因）。"""
    return [
        Patch(entry, disabled=True, source=f"{SOURCE_PREFIX}{key}")
        for key in read_disabled(settings)
        for entry in feature(key).entries  # type: ignore[union-attr] -- read_disabled 已校验
    ]


# ---------------------------------------------------------------------- 查询
def locked_text(source: str) -> str:
    if source.startswith("env:"):
        return f"已按环境变量 {source[4:]} 关闭"
    if source == "patch":
        return "已在 data/plugins.yaml 中关闭"
    return f"已被 {source} 关闭"


def _lock_source(kernel: Any, f: Feature) -> str | None:
    """被管理员硬覆盖关掉的组成插件：开关因此锁住。"""
    for entry in f.entries:
        fiber = kernel.fiber(entry)
        source = getattr(fiber, "disabled_by", None) if fiber is not None else None
        disabled = fiber is not None and fiber.state is State.DISABLED
        if disabled and source and not source.startswith(SOURCE_PREFIX):
            return source
    return None


def feature_views(kernel: Any, settings: object) -> list[dict[str, Any]]:
    """功能目录 + 每个功能的开关状态（插件页与各端判断入口显隐都用它）。"""
    disabled = read_disabled(settings)
    views: list[dict[str, Any]] = []
    for f in FEATURES:
        lock = _lock_source(kernel, f) if kernel is not None else None
        record = disabled.get(f.key)
        views.append(
            {
                "key": f.key,
                "title": f.title,
                "description": f.description,
                "entries": list(f.entries),
                "settings_href": f.settings_href,
                "switchable": f.switchable,
                "enabled": record is None and lock is None,
                "locked_by": locked_text(lock) if lock else None,
                "changed_at": record.at if record else None,
                "changed_by": record.by if record else None,
            }
        )
    return views


# ---------------------------------------------------------------------- 切换
async def set_enabled(
    kernel: Any, settings: object, key: str, enabled: bool, *, actor: str | None
) -> None:
    f = feature(key)
    if f is None:
        raise FeatureSwitchError(404, "FEATURE_NOT_FOUND", f"没有这个功能：{key}")
    if not f.switchable:
        raise FeatureSwitchError(400, "FEATURE_NOT_SWITCHABLE", f"「{f.title}」不能停用")
    async with _lock:
        lock = _lock_source(kernel, f)
        if lock:
            raise FeatureSwitchError(
                409,
                "FEATURE_LOCKED",
                f"「{f.title}」{locked_text(lock)}，要在那里改回来并重启应用",
            )
        before = read_disabled(settings)
        if (key not in before) == enabled:
            return
        after = dict(before)
        if enabled:
            after.pop(key)
        else:
            stamp = datetime.now(UTC).isoformat(timespec="seconds")
            after[key] = SwitchRecord(at=stamp, by=actor)
        try:
            _write_disabled(settings, after)
        except OSError as exc:
            raise FeatureSwitchError(
                500, "FEATURE_STATE_WRITE_FAILED", f"开关状态写不进去：{exc}"
            ) from exc
        try:
            await _apply(kernel, f, enabled)
        except Exception:
            action = "开启" if enabled else "停用"
            logger.exception("功能「%s」%s失败，开关状态已回滚", f.title, action)
            with contextlib.suppress(OSError):
                _write_disabled(settings, before)
            with contextlib.suppress(Exception):
                await _apply(kernel, f, not enabled)
            raise
        logger.info("功能「%s」已%s（%s）", f.title, "开启" if enabled else "停用", actor or "未知")


async def _apply(kernel: Any, f: Feature, enabled: bool) -> None:
    """开启按清单正序（依赖在前），停用按逆序（依赖它的先停）。"""
    if enabled:
        for entry in f.entries:
            await kernel.enable(entry)
    else:
        for entry in reversed(f.entries):
            await kernel.disable(entry, source=f"{SOURCE_PREFIX}{f.key}")
