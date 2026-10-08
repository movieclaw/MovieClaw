from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from movieclaw_api.core.config import Settings
from movieclaw_api.plugins.manifest import BUILTIN_MANIFEST, env_patches
from movieclaw_kernel import Kernel

logger = logging.getLogger("movieclaw_api.lifespan")


def build_lifespan(settings: Settings):
    """构造 FastAPI 生命周期管理器：启动与关闭交给插件内核（docs/design/plugin-kernel.md）。

    后端的每个子系统都是 ``movieclaw_api/plugins/`` 里的一个内置插件，``manifest.py`` 按顺序
    列出全部条目。内核按依赖关系启动（同层按清单顺序）、按激活逆序关闭；非关键子系统启动失败
    只影响它自己，关键子系统（数据库、配置、加密、网络出口、站点）失败则中止启动。

    用闭包接收 settings，避免在生命周期函数内部再次读取全局配置。
    """

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        kernel = Kernel(settings=settings)
        app.state.kernel = kernel
        if not settings.scheduler_enabled:
            logger.info("定时任务调度器已按配置关闭（SCHEDULER_ENABLED=false）")
        await kernel.start(BUILTIN_MANIFEST, patches=env_patches(settings))
        logger.info("应用启动完成，数据库就绪")
        try:
            yield
        finally:
            await kernel.stop()
            logger.info("应用已关闭，数据库连接已释放")

    return lifespan
