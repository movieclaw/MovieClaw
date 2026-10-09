"""播放插件（plugin-kernel.md §7）。

远程转码配置、远程 Worker、转码会话、字幕能力预热、数据目录守卫。
"""

from __future__ import annotations

import asyncio
import logging

from movieclaw_api.plugins.keys import REMOTE_WORKERS, SETTING_STORE
from movieclaw_kernel import Context, plugin

logger = logging.getLogger("movieclaw_api.plugins.playback")


@plugin("playback.remote-config", title="远程转码配置", inject=(SETTING_STORE,), reloadable=True)
async def remote_config(ctx: Context) -> None:
    from movieclaw_api.services.playback.remote_config import load_remote_transcode_config

    # 播放决策与 Worker WebSocket 的同步读取通过进程内快照即时生效
    await load_remote_transcode_config()


@plugin("storage.guard", title="数据目录登记检查", reloadable=True)
async def storage_guard(ctx: Context) -> None:
    from movieclaw_api.services.storage.registry import unregistered_entries

    # data/ 根下出现登记表之外的目录说明有代码绕过了登记（cache-management.md §3），只告警不动它
    for stray in await asyncio.to_thread(unregistered_entries):
        logger.warning("数据目录下发现未登记的条目：%s（请在 storage/registry.py 登记）", stray)


async def _warm_pgs_capability() -> None:
    from movieclaw_api.services.subtitle_gen import pgs

    try:
        await asyncio.to_thread(pgs.warm_capability)
    except Exception:
        logger.warning("PGS 图片字幕识别自检未能完成，将在首次预检时再检测", exc_info=True)


@plugin("subtitle.pgs-warm", title="PGS 字幕识别能力预热", reloadable=True)
async def pgs_warm(ctx: Context) -> None:
    # seconv/Tesseract 是部署环境的属性，启动时在后台探测一次；AI 字幕预检只查缓存
    ctx.task(_warm_pgs_capability(), name="warm-pgs")


@plugin(
    "playback.remote-workers", title="远程转码 Worker", provides=(REMOTE_WORKERS,), reloadable=True
)
async def remote_workers(ctx: Context) -> None:
    from movieclaw_api.services.playback.remote_worker import get_remote_worker_registry

    registry = get_remote_worker_registry()
    # 远程 Worker 没有本地 PID：转码会话先发 job.stop，再关 WebSocket 控制面，
    # 避免 Worker 继续向已经删除的 NAS 会话目录上传（转码会话依赖本服务，故先于它释放）
    ctx.effect(registry.shutdown, label="shutdown-remote-workers")
    ctx.provide(REMOTE_WORKERS, registry)


async def _warm_hardware_probe() -> None:
    from movieclaw_api.services.playback.hwprobe import probe_backends_async

    try:
        await probe_backends_async()
    except Exception:
        logger.warning("硬件加速自检未能完成，按「无可用硬件」处理", exc_info=True)


@plugin("playback.transcode", title="网页播放转码会话", inject=(REMOTE_WORKERS,), reloadable=True)
async def transcode(ctx: Context) -> None:
    """清单最后一项：关闭时第一个释放。

    ffmpeg 起在独立进程组里，后端退出前必须 killpg 整组，否则会留下满负荷烧 GPU、持续写盘的
    孤儿进程（§4.2 契约 3）；entrypoint.sh 的 trap 只 kill 后端自己，不会连坐孙子进程。
    """
    from movieclaw_api.services.playback.session import get_session_manager

    sessions = get_session_manager()
    # 会话状态只在内存：先清上次退出遗留的分片目录（不能假设上次是干净退出的），再起心跳巡检
    await asyncio.to_thread(sessions.cleanup_orphans)
    sessions.start_reaper()
    ctx.effect(sessions.shutdown, label="shutdown-transcode-sessions")
    # 硬件加速自检放后台：逐个后端真跑一秒编码要几秒，不该拖慢启动，也不能等到首次播放
    ctx.task(_warm_hardware_probe(), name="warm-hwprobe")
