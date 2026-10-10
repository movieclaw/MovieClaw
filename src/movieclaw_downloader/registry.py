"""下载器适配器注册表（docs/design/downloader-adapters.md）。

下载器类型不再写死：每种下载器是一个适配器（实现 ``BaseDownloader``），由插件登记进来。
qBittorrent、Transmission 是随应用提供的官方插件（``src/movieclaw_plugins/``），装一个同 id 的插件包
就能替换；第三方插件可以登记新的类型（Deluge、Aria2……）。

没有插件内核时（命令行工具、单独驱动下载器的测试）回落到内置的两个适配器。
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from pydantic import BaseModel, Field, SecretStr

from movieclaw_downloader.base import BaseDownloader
from movieclaw_downloader.models import DownloaderConfig
from movieclaw_kernel import Registry, RegistryKey, Stability

#: 下载器配置里存连接参数的三栏；适配器的连接模型只能从这三个里取
CONNECTION_FIELDS = ("url", "username", "password")


class Connection(BaseModel):
    """默认的连接参数：地址（必填）+ 用户名、密码（未开鉴权可留空）。"""

    url: str = Field(title="地址", examples=["http://192.168.1.10:8080"])
    username: str | None = Field(None, title="用户名", description="未开鉴权可留空")
    password: SecretStr | None = Field(None, title="密码", description="未开鉴权可留空")


@dataclass(frozen=True)
class DownloaderAdapter:
    type: str
    """存进下载器配置的类型值，如 ``qbittorrent``；全局唯一。"""
    title: str
    """给人看的名字，如「qBittorrent」。"""
    factory: Callable[[DownloaderConfig], BaseDownloader]
    connection: type[BaseModel] | dict[str, Any] | None = None
    """连接参数长什么样（pydantic 模型）。

    字段只能取 ``url`` / ``username`` / ``password``，``url`` 必须有；
    用 ``title`` / ``description`` / ``examples`` 写各栏的叫法与示例，不需要的栏不写。
    不填用 :class:`Connection`。进程外运行时宿主拿到的是它的 JSON Schema（dict）。
    """
    help: str = ""

    def __post_init__(self) -> None:
        connection = self.connection
        if connection is None:
            return
        if isinstance(connection, dict):
            names = set((connection.get("properties") or {}).keys())
        else:
            names = set(getattr(connection, "model_fields", {}))
        extra = names - set(CONNECTION_FIELDS)
        if extra or "url" not in names:
            raise ValueError(
                f"下载器 {self.type} 的连接参数只能取 {'、'.join(CONNECTION_FIELDS)}，且必须有 url"
                + (f"（多了 {'、'.join(sorted(extra))}）" if extra else "")
            )


DOWNLOADER_ADAPTERS: RegistryKey[DownloaderAdapter] = RegistryKey(
    "downloader-adapters",
    schema=DownloaderAdapter,
    stability=Stability.EXPERIMENTAL,
    doc="下载器类型：每种下载器一个适配器（提交、查询、删除任务……），新增下载器就登记一个",
)

_bound: Registry[DownloaderAdapter] | None = None


def bind_adapters(registry: Registry[DownloaderAdapter]) -> Callable[[], None]:
    global _bound
    _bound = registry

    def unbind() -> None:
        global _bound
        if _bound is registry:
            _bound = None

    return unbind


def builtin_adapters() -> dict[str, DownloaderAdapter]:
    """随应用提供的两个官方下载器插件里的适配器（没有插件内核时直接用）。"""
    from movieclaw_plugins.qbittorrent.qbittorrent_downloader import ADAPTER as QB
    from movieclaw_plugins.transmission.transmission_downloader import ADAPTER as TR

    return {QB.type: QB, TR.type: TR}


def adapters() -> dict[str, DownloaderAdapter]:
    """当前可用的下载器类型：类型值 → 适配器。"""
    if _bound is None:
        return builtin_adapters()
    return {item.type: item for item in _bound}
