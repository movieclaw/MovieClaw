"""并发配置仅在首次迁移和用户修改时落盘，派单只读注册表内存。"""

from __future__ import annotations

import asyncio

from movieclaw_api.settings.remote_transcode import WorkerLimitsSetting
from movieclaw_api.settings.store import get_setting_store

_save_lock = asyncio.Lock()


async def worker_limits() -> dict[str, int]:
    setting = await get_setting_store().get(WorkerLimitsSetting)
    return dict(setting.limits)


async def ensure_worker_limit(device_id: int, initial: int) -> int:
    """升级时接收一次旧客户端的设置；以后重连一律以服务器为准。"""
    async with _save_lock:
        store = get_setting_store()
        setting = await store.get(WorkerLimitsSetting)
        key = str(device_id)
        if key not in setting.limits:
            limits = {**setting.limits, key: initial}
            await store.set(WorkerLimitsSetting(limits=limits))
        else:
            return setting.limits[key]
        return initial


async def save_worker_limit(device_id: int, max_jobs: int) -> None:
    from movieclaw_api.services.playback.remote_worker import get_remote_worker_registry

    async with _save_lock:
        store = get_setting_store()
        setting = await store.get(WorkerLimitsSetting)
        if setting.limits.get(str(device_id)) != max_jobs:
            await store.set(
                WorkerLimitsSetting(limits={**setting.limits, str(device_id): max_jobs})
            )
        await get_remote_worker_registry().configure_device(device_id, max_jobs)
