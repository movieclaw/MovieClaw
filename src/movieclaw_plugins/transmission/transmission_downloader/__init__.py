"""Transmission 下载器插件（随应用携带的插件包，docs/design/downloader-adapters.md）。

协议客户端在 ``client``，只依赖 SDK 与 transmission_rpc。装一个同 id 的插件包就能替换它；
停用后这种下载器暂时不可用，已有的下载器配置保留。
"""

from __future__ import annotations

from pydantic import BaseModel, Field, SecretStr

from movieclaw_sdk import Context, plugin
from movieclaw_sdk.downloaders import DOWNLOADER_ADAPTERS, DownloaderAdapter

from .client import TransmissionDownloader


# 连接参数：添加下载器的表单按它画（叫法、示例、说明）
class Connection(BaseModel):
    url: str = Field(
        title="RPC 地址",
        description="路径缺省时自动补全为 /transmission/rpc",
        examples=["http://192.168.1.10:9091"],
    )
    username: str | None = Field(None, title="用户名", description="未开鉴权可留空")
    password: SecretStr | None = Field(None, title="密码", description="未开鉴权可留空")


ADAPTER = DownloaderAdapter(
    type="transmission",
    title="Transmission",
    factory=TransmissionDownloader,
    connection=Connection,
)


@plugin("transmission-downloader", title="Transmission 下载器", disableable=True, reloadable=True)
async def transmission_downloader(ctx: Context) -> None:
    """接入 Transmission：提交、查询、删除下载任务，同步做种状态。"""
    ctx.contribute(DOWNLOADER_ADAPTERS, "transmission", ADAPTER)
