"""网盘后端注册表的绑定（cloud-storage.md §11.1）。

后端由插件登记（随应用提供的、插件包、本地插件都一样），按插件声明的 ``type`` 识别：
账号表里存的是类型值，换一个实现同一网盘的插件时账号接得上。没有插件内核时
（命令行工具、单独的测试）注册表为空。
"""

from __future__ import annotations

from collections.abc import Callable

from movieclaw_kernel import Registry
from movieclaw_sdk.drives import DriveBackend

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
