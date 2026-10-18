"""网盘后端注册表的绑定（cloud-storage.md §11.1）。

后端由插件登记（随应用提供的、插件包、本地插件都一样），按插件声明的 ``type`` 识别：
账号表里存的是类型值，换一个实现同一网盘的插件时账号接得上。没有插件内核时
（命令行工具、单独的测试）注册表为空。

**没有任何插件提供网盘后端时，网盘功能整体休眠**（cloud-storage.md §11.8）：定时任务不挂、
片源不登记、扫描不碰网盘表、接口不带网盘字段，主程序与没有网盘功能时一样。``active`` 回答
「现在醒着没有」，``follow`` 让各处在后端从无到有、从有到无时挂上 / 撤下自己的部分。
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable

from movieclaw_kernel import Context, Registry
from movieclaw_sdk.drives import DRIVE_BACKENDS, DriveBackend

logger = logging.getLogger(__name__)

_bound: Registry[DriveBackend] | None = None


class BackendUnavailable(LookupError):
    """账号用的网盘后端没有插件提供（没装、被停用或卸载）。"""


def bind_backends(registry: Registry[DriveBackend]) -> Callable[[], None]:
    global _bound
    _bound = registry

    def unbind() -> None:
        global _bound
        if _bound is registry:
            _bound = None

    return unbind


def backends() -> dict[str, DriveBackend]:
    """当前可用的后端：类型值 → 后端。同一类型有多个提供方时取注册表里排在前面的。"""
    if _bound is None:
        return {}
    out: dict[str, DriveBackend] = {}
    for item in _bound:
        if item.type and item.type not in out:
            out[item.type] = item
    return out


def backend(backend_type: str) -> DriveBackend:
    found = backends().get(backend_type)
    if found is None:
        raise BackendUnavailable(f"没有安装能连接「{backend_type}」网盘的存储插件")
    return found


def backend_for_domain(host: str) -> DriveBackend | None:
    """浏览器扩展推来的 Cookie 该交给哪个后端：按插件声明的 ``cookie_domains`` 匹配（含子域名）。"""
    host = host.lower().strip(".")
    for item in backends().values():
        for domain in item.login.cookie_domains:
            domain = domain.lower().strip(".")
            if host == domain or host.endswith("." + domain):
                return item
    return None


def active() -> bool:
    """有插件提供网盘后端。没有时网盘功能整体休眠，见模块说明。"""
    return bool(backends())


def follow(ctx: Context, on_change: Callable[[bool], Awaitable[None]]) -> None:
    """网盘后端从无到有调 ``on_change(True)``、从有到无调 ``on_change(False)``。

    插件启动时已有后端也算「从无到有」。注册表回调是同步的，这里排队串行处理；插件卸载时
    停止跟随（醒着的部分由调用方自己用 ``ctx.effect`` 撤下）。
    """
    registry = ctx.registry(DRIVE_BACKENDS)
    changes: asyncio.Queue[None] = asyncio.Queue()
    ctx.watch(DRIVE_BACKENDS, lambda _change: changes.put_nowait(None))

    async def run() -> None:
        awake = False
        while True:
            now = len(registry) > 0
            if now != awake:
                awake = now
                try:
                    await on_change(now)
                except Exception:  # noqa: BLE001 -- 一次挂上 / 撤下出错不能让跟随停掉
                    logger.exception("网盘功能%s时出错", "启用" if now else "休眠")
            await changes.get()

    ctx.task(run(), name="follow-drive-backends")
