"""插件的停用与官方插件的卸载（docs/design/plugin-strm-prefetch.md §1）。

随带插件包（``plugins/bundled.py``）与已安装的插件包可以在插件页停用 / 启用；随带插件包还可以卸载 /
恢复（代码随应用携带，卸了随时能装回）。运行中切换立即生效，重启后保持。

- **状态**存 ``data/plugins-switches.json``，只记偏离默认的项（与功能开关 ``plugins-features.json``
  同一种写法）。不放数据库：启动时内核要在数据库就绪之前决定哪些插件不加载。
- **启动**：``switch_patches`` 把停用的翻成禁用补丁；``removed_ids`` 里的随带包不加载。
- **优先级**：管理员的硬覆盖（``data/plugins.yaml``、环境变量）高于开关，被它们关掉的插件开关锁住。
- **任务**：停用 / 卸载时取消插件的全部活动任务。不取消的话，重启后它排着的任务没有处理器，会被
  领走并报「当前版本无法执行这类任务，请更新 MovieClaw」——那不是真正的原因。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import secrets
import shutil
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from movieclaw_kernel import Patch, State

logger = logging.getLogger("movieclaw_api.plugin_switches")

STATE_FILE = "plugins-switches.json"
SOURCE = "switch"

_lock = asyncio.Lock()


class PluginSwitchError(Exception):
    """切换不了：原因直接给用户看。"""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass(frozen=True)
class SwitchRecord:
    #: 时间（ISO 8601 UTC）
    at: str
    #: 谁操作的（用户名）
    by: str | None


@dataclass(frozen=True)
class Switches:
    disabled: dict[str, SwitchRecord]
    removed: dict[str, SwitchRecord]


# ---------------------------------------------------------------------- 状态文件
def state_path(settings: object) -> Path:
    return Path(getattr(settings, "data_dir", "./data")) / STATE_FILE


def read_switches(settings: object) -> Switches:
    """文件不存在 = 全部照常；读不出来只告警、按全部照常处理（不拦启动）。"""
    path = state_path(settings)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return Switches({}, {})
    except (OSError, ValueError) as exc:
        logger.warning("插件开关状态 %s 读不出来（%s），按全部照常处理", path, exc)
        return Switches({}, {})
    if not isinstance(data, dict):
        logger.warning("插件开关状态 %s 格式不对，按全部照常处理", path)
        return Switches({}, {})
    return Switches(_records(data.get("disabled")), _records(data.get("removed")))


def _records(items: object) -> dict[str, SwitchRecord]:
    if not isinstance(items, dict):
        return {}
    result: dict[str, SwitchRecord] = {}
    for key, record in items.items():
        record = record if isinstance(record, dict) else {}
        result[str(key)] = SwitchRecord(at=str(record.get("at") or ""), by=record.get("by"))
    return result


def _write(settings: object, switches: Switches) -> None:
    """原子写入（临时文件 + 改名，临时名唯一）；写不进去抛 OSError，由调用方回滚。"""
    path = state_path(settings)

    def dump(records: dict[str, SwitchRecord]) -> dict[str, Any]:
        return {key: {"at": r.at, "by": r.by} for key, r in sorted(records.items())}

    data = {"version": 1, "disabled": dump(switches.disabled), "removed": dump(switches.removed)}
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, path)
    finally:
        with contextlib.suppress(OSError):
            tmp.unlink()


def forget(settings: object, entry_id: str) -> None:
    """插件包卸掉了：它的停用记录一并清掉，重装回来是启用的。"""
    before = read_switches(settings)
    if entry_id in before.disabled:
        disabled = {k: v for k, v in before.disabled.items() if k != entry_id}
        with contextlib.suppress(OSError):
            _write(settings, Switches(disabled, before.removed))


def _stamp(actor: str | None) -> SwitchRecord:
    return SwitchRecord(at=datetime.now(UTC).isoformat(timespec="seconds"), by=actor)


# ---------------------------------------------------------------------- 启动
def switch_patches(settings: object) -> list[Patch]:
    """停用的插件 → 禁用补丁（来源 ``switch``，排在管理员补丁之前）。"""
    return [
        Patch(entry_id, disabled=True, source=SOURCE)
        for entry_id in read_switches(settings).disabled
    ]


def removed_ids(settings: object) -> set[str]:
    """卸载了的随带插件包：启动时不加载。"""
    return set(read_switches(settings).removed)


# ---------------------------------------------------------------------- 查询
def admin_lock(fiber: Any) -> str | None:
    """被管理员硬覆盖关掉：返回给人看的原因；开关因此锁住。"""
    from movieclaw_api.services.plugin_features import SOURCE_PREFIX, locked_text

    source = getattr(fiber, "disabled_by", None)
    if fiber.state is not State.DISABLED or not source:
        return None
    if source == SOURCE or source.startswith(SOURCE_PREFIX):
        return None
    return locked_text(source)


def removed_views(settings: object) -> list[dict[str, Any]]:
    """已卸载的随带插件包（插件页「官方插件」里显示，带恢复入口）。"""
    from movieclaw_api.plugins.bundled import bundled

    packages = bundled()
    views = []
    for entry_id, record in sorted(read_switches(settings).removed.items()):
        package = packages.get(entry_id)
        if package is None:
            continue  # 随带包已不在这个版本里：不显示，也不碍事
        views.append(
            {
                "id": entry_id,
                "title": package.manifest.plugin.title,
                "description": package.manifest.plugin.description,
                "removed_at": record.at,
                "removed_by": record.by,
            }
        )
    return views


def _switchable(kernel: Any, settings: object, entry_id: str) -> Any:
    """能停用的插件：随带插件包或已安装的插件包，且允许停用。"""
    from movieclaw_api.plugins import packages as pkg
    from movieclaw_api.plugins.bundled import bundled_ids

    fiber = kernel.fiber(entry_id)
    if fiber is None:
        raise PluginSwitchError(404, "PLUGIN_NOT_FOUND", f"没有这个插件：{entry_id}")
    if entry_id not in bundled_ids() and entry_id not in pkg.package_ids(settings):
        raise PluginSwitchError(400, "PLUGIN_NOT_SWITCHABLE", "系统模块不能在这里停用")
    if not fiber.plugin.disableable:
        raise PluginSwitchError(400, "PLUGIN_NOT_SWITCHABLE", f"「{fiber.plugin.title}」不能停用")
    return fiber


# ---------------------------------------------------------------------- 停用 / 启用
async def set_enabled(
    kernel: Any, settings: object, entry_id: str, enabled: bool, *, actor: str | None
) -> None:
    async with _lock:
        fiber = _switchable(kernel, settings, entry_id)
        lock = admin_lock(fiber)
        if lock:
            raise PluginSwitchError(
                409, "PLUGIN_LOCKED", f"「{fiber.plugin.title}」{lock}，要在那里改回来并重启应用"
            )
        before = read_switches(settings)
        if (entry_id not in before.disabled) == enabled:
            return
        disabled = dict(before.disabled)
        if enabled:
            disabled.pop(entry_id)
        else:
            disabled[entry_id] = _stamp(actor)
        _save(settings, Switches(disabled, before.removed))
        try:
            if enabled:
                await kernel.enable(entry_id)
            else:
                cancelled = await cancel_plugin_jobs(kernel, entry_id, reason="插件已停用")
                await kernel.disable(entry_id, source=SOURCE)
                logger.info("插件 %s 已停用（%s），取消任务 %d 个", entry_id, actor, cancelled)
        except Exception:
            logger.exception(
                "插件 %s %s失败，开关状态已回滚", entry_id, "启用" if enabled else "停用"
            )
            with contextlib.suppress(OSError):
                _write(settings, before)
            raise
        if enabled:
            logger.info("插件 %s 已启用（%s）", entry_id, actor)


# ---------------------------------------------------------------------- 卸载 / 恢复
async def uninstall_bundled(
    kernel: Any, settings: object, entry_id: str, *, purge_data: bool, actor: str | None
) -> dict[str, int]:
    """卸载随带插件包：撤下、取消任务、记住不再加载；``purge_data`` 时一并清掉它的数据。"""
    from movieclaw_api.plugins import packages as pkg
    from movieclaw_api.plugins.bundled import bundled_ids, canonical

    async with _lock:
        if entry_id not in bundled_ids():
            raise PluginSwitchError(400, "PLUGIN_NOT_BUNDLED", "只有官方插件能在这里卸载")
        if entry_id in {canonical(i) for i in pkg.package_ids(settings)}:
            raise PluginSwitchError(
                409, "PLUGIN_REPLACED", "它已被同名插件包替换：要卸载的是那个插件包"
            )
        fiber = kernel.fiber(entry_id)
        if fiber is not None:
            if not fiber.plugin.disableable:
                raise PluginSwitchError(
                    400, "PLUGIN_NOT_SWITCHABLE", f"「{fiber.plugin.title}」不能卸载"
                )
            lock = admin_lock(fiber)
            if lock:
                raise PluginSwitchError(409, "PLUGIN_LOCKED", f"「{fiber.plugin.title}」{lock}")
        before = read_switches(settings)
        removed = {**before.removed, entry_id: _stamp(actor)}
        disabled = {k: v for k, v in before.disabled.items() if k != entry_id}
        _save(settings, Switches(disabled, removed))
        cancelled = await cancel_plugin_jobs(kernel, entry_id, reason="插件已卸载")
        if fiber is not None:
            await kernel.unmount(entry_id)
        purged = await _purge(kernel, settings, entry_id) if purge_data else 0
        logger.info(
            "官方插件 %s 已卸载（%s）：取消任务 %d 个，删除数据 %d 行",
            entry_id,
            actor,
            cancelled,
            purged,
        )
        return {"cancelled_jobs": cancelled, "purged_rows": purged}


async def restore_bundled(kernel: Any, settings: object, entry_id: str) -> str:
    """装回卸载了的随带插件包；返回挂上后的状态。"""
    from movieclaw_api.plugins.bundled import bundled, entry

    async with _lock:
        package = bundled().get(entry_id)
        before = read_switches(settings)
        if package is None or entry_id not in before.removed:
            raise PluginSwitchError(404, "PLUGIN_NOT_REMOVED", f"没有卸载过的官方插件：{entry_id}")
        removed = {k: v for k, v in before.removed.items() if k != entry_id}
        _save(settings, Switches(before.disabled, removed))
        if kernel.fiber(entry_id) is not None:
            return kernel.fiber(entry_id).state.value
        try:
            fiber = await kernel.mount(entry(package))
        except Exception:
            with contextlib.suppress(OSError):
                _write(settings, before)
            raise
        logger.info("官方插件 %s 已恢复（%s）", entry_id, fiber.state.value)
        return fiber.state.value


def _save(settings: object, switches: Switches) -> None:
    try:
        _write(settings, switches)
    except OSError as exc:
        raise PluginSwitchError(
            500, "PLUGIN_STATE_WRITE_FAILED", f"开关状态写不进去：{exc}"
        ) from exc


async def _purge(kernel: Any, settings: object, entry_id: str) -> int:
    """插件数据、界面保存的设置、私有目录。"""
    from movieclaw_api.plugins import settings_store
    from movieclaw_api.plugins.keys import PLUGIN_DATA

    purged = 0
    service = kernel.service(PLUGIN_DATA)
    if service is not None:
        purged = await service.purge(entry_id)
    with contextlib.suppress(OSError):
        settings_store._path(settings, entry_id).unlink()
    data_dir = Path(getattr(settings, "data_dir", "./data"))
    shutil.rmtree(data_dir / "plugins" / "data" / entry_id, ignore_errors=True)
    return purged


# ---------------------------------------------------------------------- 任务
async def cancel_plugin_jobs(kernel: Any, entry_id: str, *, reason: str) -> int:
    """取消插件的全部活动任务。类型取自它在 ``JOB_HANDLERS`` 里的贡献，加上带它前缀的类型
    （插件已经不在、贡献已撤下时靠前缀认）。"""
    from sqlalchemy import or_, select

    from movieclaw_api.services.jobs import JOB_HANDLERS, request_cancel, wake_job_dispatcher
    from movieclaw_db.engine import get_database
    from movieclaw_db.models.job import ACTIVE_JOB_STATUSES, Job

    types = set(kernel.registry(JOB_HANDLERS).owned_by(entry_id))
    conditions = [Job.job_type.like(f"{entry_id}:%")]
    if types:
        conditions.append(Job.job_type.in_(types))
    cancelled = 0
    async with get_database().session() as session:
        ids = (
            (
                await session.execute(
                    select(Job.id).where(
                        Job.status.in_([s.value for s in ACTIVE_JOB_STATUSES]), or_(*conditions)
                    )
                )
            )
            .scalars()
            .all()
        )
        for job_id in ids:
            job, changed = await request_cancel(
                session, job_id, requested_by="system", reason=reason
            )
            cancelled += int(changed)
        await session.commit()
    if cancelled:
        wake_job_dispatcher()
    return cancelled
