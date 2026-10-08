"""运行模块诊断（设置 → 更新与维护 → 模块；docs/design/plugin-kernel.md §10）。

后端的每个子系统都是插件内核上的一个内置插件。这里只读地列出每个插件的状态、启动耗时、
失败原因、缺失的依赖与运行指标，外加全部契约（服务、注册表、事件）——排查「某个功能
怎么没起来」「启动为什么慢」时看这一页。第一阶段不提供任何操作按钮：禁用插件走
``data/plugins.yaml``，重启生效。
"""

from __future__ import annotations

from fastapi import APIRouter, Request

from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok

router = APIRouter(prefix="/app/plugins", tags=["app"])


class BlockedBy(BaseModel):
    key: str
    reason: str


class PluginStats(BaseModel):
    events: int
    failures: int
    timeouts: int
    dropped: int
    handler_max_ms: float
    handler_avg_ms: float
    last_error: str | None
    tasks: int
    listeners: int
    breaker: str


class PluginView(BaseModel):
    id: str
    plugin: str
    title: str
    state: str
    critical: bool
    disableable: bool
    reloadable: bool
    source: str
    parent: str | None
    provides: list[str]
    inject: list[str]
    blocked_by: list[BlockedBy]
    incompatible: str | None
    disabled_by: str | None
    error: str | None
    apply_ms: float | None
    dispose_ms: float | None
    unsettled: bool
    stats: PluginStats


class ContributionView(BaseModel):
    id: str
    entry: str
    priority: int
    shadows: list[str]


class ContractView(BaseModel):
    name: str
    kind: str
    version: str
    stability: str
    doc: str
    provider: str | None = None
    contributions: list[ContributionView] | None = None
    mode: str | None = None
    delivery: str | None = None
    listeners: list[str] | None = None


class ContractsView(BaseModel):
    services: list[ContractView]
    registries: list[ContractView]
    events: list[ContractView]


class PluginsView(BaseModel):
    plugins: list[PluginView]
    contracts: ContractsView


@router.get(
    "",
    response_model=ApiResponse[PluginsView],
    summary="运行模块：各内置插件的状态、启动耗时、失败原因与契约",
    operation_id="app.plugins.list",
)
async def list_plugins(request: Request) -> ApiResponse[PluginsView]:
    kernel = getattr(request.app.state, "kernel", None)
    if kernel is None:
        raise NotFoundException("插件内核未运行")
    return ok(
        PluginsView.model_validate({"plugins": kernel.snapshot(), "contracts": kernel.contracts()})
    )
