from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from movieclaw_api.core.config import Settings
from movieclaw_api.plugins import packages, safe_mode
from movieclaw_api.plugins.bundled import load_bundled_entries
from movieclaw_api.plugins.local import load_local_entries, local_specs
from movieclaw_api.plugins.manifest import load_patches, with_bundled
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
        from movieclaw_api.services import host_ops

        kernel = Kernel(settings=settings)
        app.state.kernel = kernel
        # 宿主操作要经 ASGI 调本进程应用；内核不认识 FastAPI，由这里绑定
        host_ops.bind_app(app)
        if not settings.scheduler_enabled:
            logger.info("定时任务调度器已按配置关闭（SCHEDULER_ENABLED=false）")
        # 内置插件 + 用户在 plugins.yaml 里显式开启的本地受信插件（plugins/local.py）+ 已安装的
        # 插件包（plugins/packages.py）。先定安全模式（plugins/safe_mode.py）：上次带着插件没能
        # 稳定运行，这次连插件代码都不导入
        local_ids = [spec.id for spec in local_specs(settings) if not spec.disabled]
        safe = safe_mode.decide(settings, [*local_ids, *packages.package_ids(settings)])
        local = (
            []
            if safe.active
            else [*load_local_entries(settings), *packages.load_package_entries(settings)]
        )
        # 随带的插件包（plugins/bundled.py）也是内置插件；被同 id 插件包替换的跳过（安全模式下插件包
        # 不加载，随带版本照常）
        replaced = set() if safe.active else set(packages.package_ids(settings))
        bundled = load_bundled_entries(replaced)
        await kernel.start((*with_bundled(bundled), *local), patches=load_patches(settings))
        logger.info("应用启动完成，数据库就绪")
        safe_mode.schedule_settle(settings)
        try:
            yield
        finally:
            safe_mode.cancel_settle()
            manager = getattr(app.state, "package_manager", None)
            if manager is not None:
                await manager.close()
                del app.state.package_manager
            await kernel.stop()
            host_ops.unbind_app(app)
            # 正常停机：这次启动没有把应用拖垮
            safe_mode.mark_settled(settings)
            logger.info("应用已关闭，数据库连接已释放")

    return lifespan
