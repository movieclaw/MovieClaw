"""插件包的安装、批准、升级、回滚、卸载（docs/design/plugin-phase3.md §3，C5）。

上传只校验并放进「待批准」区；用户看过插件申请的权限、点了批准才真正安装，并在运行中当场挂载。
新版本激活失败，或在宽限期内反复崩溃，自动回到上一版（首次安装则不留安装记录），坏版本打标记；
卸载默认保留插件数据（含签名密钥），「连同数据删除」须显式选择。
"""

from __future__ import annotations

import asyncio
import logging
import shutil
from typing import Any

from movieclaw_api.plugins import packages as pkg
from movieclaw_kernel import Kernel, State

logger = logging.getLogger("movieclaw_api.plugin_packages")

#: 新版本挂上后观察多久：这段时间里失败或崩溃成循环就自动回滚
GRACE_SECONDS = 120.0
GRACE_POLL = 2.0
NOTICE_PREFIX = "plugin-package:"
#: 回滚通知「去处理」落到插件管理页（设置 → 插件 → 已安装）
MANAGE_HREF = "/settings/plugins"


def _reserved(kernel: Kernel, settings: object) -> set[str]:
    """不能被插件包占用的条目 id：内置插件与本地插件。

    随带的插件包（plugins/bundled.py）不在其列：装同 id 的插件包就是替换它。
    """
    from movieclaw_api.plugins.local import local_specs
    from movieclaw_api.plugins.manifest import BUILTIN_MANIFEST

    return {e.id for e in BUILTIN_MANIFEST} | {s.id for s in local_specs(settings)}


async def _restore_bundled(kernel: Kernel, entry_id: str) -> None:
    """插件包卸下后，同 id 的随带插件包回来（plugin-channels.md §7）。"""
    from movieclaw_api.plugins.bundled import bundled, entry

    package = bundled().get(entry_id)
    if package is None or kernel.fiber(entry_id) is not None:
        return
    fiber = await kernel.mount(entry(package))
    logger.info("随带插件包 %s 已恢复（%s）", entry_id, fiber.state.value)


def _operations() -> set[str]:
    from movieclaw_api.services.host_ops import _operation_index

    return set(_operation_index())


def operation_details(patterns: list[str]) -> list[dict[str, Any]]:
    """宿主操作 → 给人看的说明（管理页的批准抽屉逐项列出，危险操作标红）。"""
    from movieclaw_api.services.host_ops import _operation_index

    index = _operation_index()
    details: list[dict[str, Any]] = []
    for pattern in patterns:
        if pattern.endswith(".*"):
            details.append(
                {
                    "id": pattern,
                    "summary": f"「{pattern[:-2]}」领域的全部非危险操作",
                    "dangerous": False,
                }
            )
            continue
        op = index.get(pattern)
        details.append(
            {
                "id": pattern,
                "summary": (op.summary if op is not None else "") or pattern,
                "dangerous": bool(op is not None and op.dangerous),
            }
        )
    return details


def _view(manifest: pkg.Manifest, current: pkg.Installed | None) -> dict[str, Any]:
    plugin = manifest.plugin
    approved = set(current.operations) if current else set()
    approved_paths = [dict(p) for p in current.paths] if current else []
    paths = [dict(p) for p in manifest.permissions.paths]
    return {
        "id": plugin.id,
        "title": plugin.title,
        "version": plugin.version,
        "description": plugin.description,
        "runtime": plugin.runtime,
        "operations": manifest.permissions.operations,
        "new_operations": [op for op in manifest.permissions.operations if op not in approved],
        "operation_details": operation_details(manifest.permissions.operations),
        "paths": paths,
        "new_paths": [p for p in paths if p not in approved_paths],
        "requires": manifest.requires,
        "installed_version": current.version if current else None,
        "replaces_builtin": _replaces_builtin(plugin.id),
    }


def _replaces_builtin(entry_id: str) -> bool:
    from movieclaw_api.plugins.bundled import bundled_ids

    return entry_id in bundled_ids()


class PackageManager:
    """一个应用实例一份（挂在 ``app.state`` 上）：串行化安装操作、持有宽限期观察任务。"""

    def __init__(self, kernel: Kernel, settings: object) -> None:
        self._kernel = kernel
        self.kernel = kernel
        self._settings = settings
        self._lock = asyncio.Lock()
        self._watches: dict[str, asyncio.Task[None]] = {}

    # ------------------------------------------------------------------ 查看
    def overview(self) -> dict[str, Any]:
        packages = pkg.installed(self._settings)
        rows = []
        for item in packages.values():
            fiber = self._kernel.fiber(item.id)
            rows.append(
                {
                    "id": item.id,
                    "title": item.title,
                    "version": item.version,
                    "runtime": item.runtime,
                    "operations": item.operations,
                    "operation_details": operation_details(item.operations),
                    "paths": item.paths,
                    "previous_version": (item.previous or {}).get("version"),
                    "bad_versions": item.bad,
                    "state": fiber.state.value if fiber else "unloaded",
                    "error": fiber.error if fiber else None,
                    "watching": item.id in self._watches,
                    "replaces_builtin": _replaces_builtin(item.id),
                }
            )
        waiting = [
            _view(manifest, packages.get(manifest.plugin.id))
            for manifest, _path in pkg.pending(self._settings)
        ]
        return {"installed": rows, "pending": waiting}

    # ------------------------------------------------------------------ 上传
    async def upload(self, data: bytes) -> dict[str, Any]:
        """校验并放进待批准区；同一条目已有待批准的包会被替换。"""
        manifest, archive = pkg.read_archive(data)
        packages = pkg.installed(self._settings)
        current = packages.get(manifest.plugin.id)
        reserved = _reserved(self._kernel, self._settings)
        pkg.check_compat(manifest, reserved=reserved, operations=_operations())
        if current is not None and current.version == manifest.plugin.version:
            raise pkg.PackageError(f"{manifest.plugin.title} v{current.version} 已经安装")
        async with self._lock:
            base = pkg.root(self._settings) / manifest.plugin.id
            for stale in base.glob("*.pending") if base.is_dir() else ():
                shutil.rmtree(stale, ignore_errors=True)
            target = pkg.pending_dir(self._settings, manifest.plugin.id, manifest.plugin.version)
            await asyncio.to_thread(pkg.extract, archive, target)
        logger.info("插件包 %s v%s 已上传，等待批准", manifest.plugin.id, manifest.plugin.version)
        return _view(manifest, current)

    async def discard(self, entry_id: str) -> None:
        async with self._lock:
            found = [p for m, p in pkg.pending(self._settings) if m.plugin.id == entry_id]
            if not found:
                raise LookupError(f"没有待批准的插件包 {entry_id}")
            for path in found:
                shutil.rmtree(path, ignore_errors=True)

    # ------------------------------------------------------------------ 批准
    async def approve(
        self,
        entry_id: str,
        version: str,
        *,
        operations: list[str],
        allow_inline: bool,
        paths: list[dict[str, str]] | None = None,
    ) -> dict[str, Any]:
        """用户批准：安装并当场挂载；激活失败自动回滚。返回挂载结果。"""
        async with self._lock:
            path = pkg.pending_dir(self._settings, entry_id, version)
            match = [m for m, p in pkg.pending(self._settings) if p == path]
            if not match:
                raise LookupError(f"没有待批准的插件包 {entry_id} v{version}")
            manifest = match[0]
            requested = manifest.permissions.operations
            if sorted(set(operations)) != sorted(set(requested)):
                raise pkg.PackageError(
                    "批准的宿主操作须与插件申请的完全一致："
                    + ("、".join(requested) if requested else "（不申请任何操作）")
                )
            requested_paths = [dict(p) for p in manifest.permissions.paths]
            given = [{"path": p["path"], "mode": p.get("mode", "read")} for p in paths or []]
            want = [{"path": p["path"], "mode": p.get("mode", "read")} for p in requested_paths]
            if sorted(map(str, given)) != sorted(map(str, want)):
                raise pkg.PackageError(
                    "批准的路径授权须与插件申请的完全一致："
                    + ("、".join(f"{p['path']}（{p['mode']}）" for p in want) or "（不申请路径）")
                )
            if manifest.plugin.runtime == "inline" and not allow_inline:
                raise pkg.PackageError(
                    "这个插件申请在主进程里运行，拥有与主程序相同的系统权限，须单独确认"
                )
            # 重新检查一遍：上传之后内置插件 / 本地插件 / 契约可能变了
            pkg.check_compat(
                manifest,
                reserved=_reserved(self._kernel, self._settings),
                operations=_operations(),
            )
            packages = pkg.installed(self._settings)
            current = packages.get(entry_id)
            target = pkg.version_dir(self._settings, entry_id, version)
            if target.exists():
                shutil.rmtree(target)
            path.rename(target)
            record = pkg.Installed(
                id=entry_id,
                version=version,
                title=manifest.plugin.title,
                entry=manifest.plugin.entry,
                runtime=manifest.plugin.runtime,
                operations=list(requested),
                paths=requested_paths,
                previous=current.snapshot() if current else None,
                bad=[v for v in (current.bad if current else []) if v != version],
                installed_at=pkg.now(),
            )
            packages[entry_id] = record
            pkg.save(self._settings, packages)
            state, error = await self._activate(record)
            if state != State.ACTIVE.value:
                await self._roll_back(entry_id, version, error or f"激活后状态为 {state}")
                return {"status": "rolled_back", "error": error, **self._status(entry_id)}
            self._prune(entry_id)
            self._watch(entry_id, version)
            await _resolve_notice(entry_id)
            logger.info("插件包 %s v%s 已安装并运行", entry_id, version)
            return {"status": "active", "error": None, **self._status(entry_id)}

    async def _activate(self, record: pkg.Installed) -> tuple[str, str | None]:
        from movieclaw_api.plugins.keys import HOST_OPS, PLUGIN_FILES
        from movieclaw_api.services.plugin_files import parse_grants

        host = self._kernel.service(HOST_OPS)
        if host is not None:
            host.configure(record.id, grants=record.operations)
        files = self._kernel.service(PLUGIN_FILES)
        if files is not None:
            files.configure(record.id, parse_grants(record.paths))
        if self._kernel.fiber(record.id) is not None:
            await self._kernel.unmount(record.id)
        fiber = await self._kernel.mount(pkg.entry_for(self._settings, record))
        return fiber.state.value, fiber.error

    def _status(self, entry_id: str) -> dict[str, Any]:
        record = pkg.installed(self._settings).get(entry_id)
        fiber = self._kernel.fiber(entry_id)
        return {
            "version": record.version if record else None,
            "state": fiber.state.value if fiber else "unloaded",
        }

    def _prune(self, entry_id: str) -> None:
        """只留当前版与上一版。"""
        record = pkg.installed(self._settings)[entry_id]
        keep = {record.version, (record.previous or {}).get("version")}
        base = pkg.root(self._settings) / entry_id
        for path in base.iterdir():
            if path.is_dir() and not path.name.endswith(".pending") and path.name not in keep:
                shutil.rmtree(path, ignore_errors=True)

    # ------------------------------------------------------------------ 回滚
    async def _roll_back(self, entry_id: str, failed: str, reason: str) -> None:
        """新版本不行：回到上一版；首次安装则撤掉安装记录。坏版本打标记、删目录。"""
        packages = pkg.installed(self._settings)
        record = packages.get(entry_id)
        if record is None:
            return
        if self._kernel.fiber(entry_id) is not None:
            await self._kernel.unmount(entry_id)
        shutil.rmtree(pkg.version_dir(self._settings, entry_id, failed), ignore_errors=True)
        previous = record.previous
        if previous and pkg.version_dir(self._settings, entry_id, previous["version"]).is_dir():
            restored = pkg.Installed(
                id=entry_id,
                **previous,
                previous=None,
                bad=sorted({*record.bad, failed}),
                installed_at=pkg.now(),
            )
            packages[entry_id] = restored
            pkg.save(self._settings, packages)
            await self._activate(restored)
            message = f"v{failed} 没能正常运行（{reason}），已自动回到 v{restored.version}"
        else:
            packages.pop(entry_id)
            pkg.save(self._settings, packages)
            await _restore_bundled(self._kernel, entry_id)
            message = f"v{failed} 没能正常运行（{reason}），已撤销安装"
        logger.error("插件包 %s：%s", entry_id, message)
        await _notice(entry_id, record.title, message)

    async def rollback(self, entry_id: str) -> dict[str, Any]:
        """用户手动回到上一版（上一版成为当前版，原当前版成为上一版）。"""
        async with self._lock:
            packages = pkg.installed(self._settings)
            record = packages.get(entry_id)
            if record is None:
                raise LookupError(f"没有安装插件包 {entry_id}")
            previous = record.previous
            if (
                not previous
                or not pkg.version_dir(self._settings, entry_id, previous["version"]).is_dir()
            ):
                raise pkg.PackageError("没有可以回退的上一版")
            self._cancel_watch(entry_id)
            swapped = pkg.Installed(
                id=entry_id,
                **previous,
                previous=record.snapshot(),
                bad=record.bad,
                installed_at=pkg.now(),
            )
            packages[entry_id] = swapped
            pkg.save(self._settings, packages)
            state, error = await self._activate(swapped)
            if state == State.ACTIVE.value:
                await _resolve_notice(entry_id)
            return {"status": state, "error": error, **self._status(entry_id)}

    # ------------------------------------------------------------------ 卸载
    async def uninstall(self, entry_id: str, *, purge_data: bool) -> dict[str, Any]:
        async with self._lock:
            packages = pkg.installed(self._settings)
            if entry_id not in packages:
                raise LookupError(f"没有安装插件包 {entry_id}")
            self._cancel_watch(entry_id)
            if self._kernel.fiber(entry_id) is not None:
                await self._kernel.unmount(entry_id)
            packages.pop(entry_id)
            pkg.save(self._settings, packages)
            shutil.rmtree(pkg.root(self._settings) / entry_id, ignore_errors=True)
            await _restore_bundled(self._kernel, entry_id)
            purged = 0
            if purge_data:
                from movieclaw_api.plugins.keys import PLUGIN_DATA

                service = self._kernel.service(PLUGIN_DATA)
                if service is not None:
                    purged = await service.purge(entry_id)
            await _resolve_notice(entry_id)
            logger.info("插件包 %s 已卸载（删除数据 %d 行）", entry_id, purged)
            return {"purged_rows": purged}

    # ------------------------------------------------------------------ 宽限期
    def _watch(self, entry_id: str, version: str) -> None:
        self._cancel_watch(entry_id)
        task = asyncio.get_running_loop().create_task(
            self._grace(entry_id, version), name=f"plugin-package-grace:{entry_id}"
        )
        self._watches[entry_id] = task
        task.add_done_callback(lambda _t: self._watches.pop(entry_id, None))

    def _cancel_watch(self, entry_id: str) -> None:
        task = self._watches.pop(entry_id, None)
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()

    async def _grace(self, entry_id: str, version: str) -> None:
        """新版本挂上后的宽限期：失败、或进程崩溃到放弃重启，就自动回滚。"""
        loop = asyncio.get_running_loop()
        deadline = loop.time() + GRACE_SECONDS
        while loop.time() < deadline:
            await asyncio.sleep(GRACE_POLL)
            fiber = self._kernel.fiber(entry_id)
            record = pkg.installed(self._settings).get(entry_id)
            if fiber is None or record is None or record.version != version:
                return
            crashed = fiber.stats.last_error and "已停止重启" in fiber.stats.last_error
            if fiber.state is State.FAILED or crashed:
                async with self._lock:
                    await self._roll_back(
                        entry_id, version, fiber.error or fiber.stats.last_error or "运行失败"
                    )
                return

    async def close(self) -> None:
        for task in list(self._watches.values()):
            task.cancel()
        await asyncio.gather(*self._watches.values(), return_exceptions=True)


async def _notice(entry_id: str, title: str, message: str) -> None:
    from movieclaw_api.services.system_notice import upsert_notice
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeSeverity

    try:
        async with get_database().session() as session:
            await upsert_notice(
                session,
                dedupe_key=f"{NOTICE_PREFIX}{entry_id}",
                severity=NoticeSeverity.WARNING,
                source="plugin",
                title=f"插件「{title}」已自动回滚",
                message=message,
                payload={"entry_id": entry_id, "action_href": MANAGE_HREF},
            )
    except Exception:  # noqa: BLE001 -- 通知写不进去不影响回滚本身
        logger.exception("插件包回滚通知写入失败")


async def _resolve_notice(entry_id: str) -> None:
    """回滚过的问题已经翻篇（新版本跑起来了、手动换了版本、卸载了）：消退那条通知。"""
    from movieclaw_api.services.system_notice import resolve_notices
    from movieclaw_db.engine import get_database

    try:
        async with get_database().session() as session:
            await resolve_notices(session, dedupe_key=f"{NOTICE_PREFIX}{entry_id}")
    except Exception:  # noqa: BLE001 -- 消退失败不影响安装 / 卸载本身
        logger.exception("插件包通知消退失败")
