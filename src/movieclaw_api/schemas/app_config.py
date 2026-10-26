"""应用设置的请求/响应模型（「设置 → 应用设置」页）。"""

from __future__ import annotations

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel


class AppConfigPayload(BaseModel):
    """保存请求体：与 ``AppServerSetting`` 配置域字段一一对应（整体覆盖语义）。"""

    external_url: str = Field(
        default="",
        description="网络可访问到本应用的完整地址（http/https），"
        "如 http://192.168.1.10:3000；空 = 未配置",
    )


class AppConfigView(AppConfigPayload):
    """读取响应 = 可保存字段 + 对外端口的运行时状态（只读，端口另有专用端点）。

    端口没有并进 ``AppConfigPayload``：其它字段是「失焦即存、保存即生效」，
    而改端口要重启整个应用、且改错会把用户关在门外，两者的交互语义完全不同，
    混在一个整体覆盖的请求体里会让改地址时误触发重启。
    """

    web_port: int = Field(description="当前生效的对外端口（前端监听口）")
    web_port_source: str = Field(
        description="端口来源：setting（应用内设置）/ env（环境变量）/ default（默认）"
    )
    web_port_default: int = Field(description="内置默认端口，用于「恢复默认」的展示")
    web_port_reset_target: int | None = Field(
        default=None, description="Port after clearing the override, including environment defaults"
    )
    web_port_rejected: int | None = Field(
        default=None,
        description="上次启动时因无法绑定而被自动废弃的端口；null = 无",
    )
    web_port_configurable: bool = Field(
        description="当前部署形态是否支持应用内改端口（仅由容器入口托管进程的 Docker 部署）"
    )


class WebPortPayload(BaseModel):
    """对外端口的保存请求体（PUT /app/port）。"""

    port: int | None = Field(
        default=None,
        description="要监听的对外端口（1~65535）；null 或 0 = 清除设置、恢复默认",
    )
