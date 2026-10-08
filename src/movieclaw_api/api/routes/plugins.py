"""运行模块诊断（设置 → 更新与维护 → 模块；docs/design/plugin-kernel.md §10）。

后端的每个子系统都是插件内核上的一个内置插件。这里只读地列出每个插件的状态、启动耗时、
失败原因、缺失的依赖与运行指标，外加全部契约（服务、注册表、事件）——排查「某个功能
怎么没起来」「启动为什么慢」时看这一页。禁用插件走 ``data/plugins.yaml``，重启生效。

可靠事件（docs/design/plugin-phase2a.md §2）的消费进度与死信也在这里：死信可以重放或忽略。
"""

from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Request
from pydantic import Field

from movieclaw_api.exceptions import ConflictException, NotFoundException
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
    permissions: list[str] = Field(default_factory=list, description="插件声明需要的宿主操作")
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


class DurableConsumerView(BaseModel):
    consumer_id: str = Field(description="<条目 id>:<监听器 id>")
    event: str
    active: bool = Field(description="订阅它的插件当前是否在运行")
    backlog: int = Field(description="尚未处理的事件数")
    attempts: int = Field(description="当前事件已失败的次数（0 = 正常）")
    next_attempt_at: datetime | None
    last_error: str | None


class DeadLetterView(BaseModel):
    id: int
    consumer_id: str
    event: str
    event_id: str
    error: str
    attempts: int
    created_at: datetime


class DurableView(BaseModel):
    consumers: list[DurableConsumerView]
    dead_letters: list[DeadLetterView] = Field(description="未处理的死信（最近 50 条）")


class PluginsView(BaseModel):
    plugins: list[PluginView]
    contracts: ContractsView
    durable: DurableView | None = Field(
        default=None, description="可靠事件的消费进度与死信；投递插件未运行时为空"
    )


def _kernel(request: Request):
    kernel = getattr(request.app.state, "kernel", None)
    if kernel is None:
        raise NotFoundException("插件内核未运行")
    return kernel


def _durable_store(request: Request):
    from movieclaw_kernel import DURABLE_EVENTS

    store = _kernel(request).service(DURABLE_EVENTS)
    if store is None:
        raise ConflictException("可靠事件投递插件当前没有运行")
    return store


@router.get(
    "",
    response_model=ApiResponse[PluginsView],
    summary="运行模块：各内置插件的状态、启动耗时、失败原因与契约",
    operation_id="app.plugins.list",
)
async def list_plugins(request: Request) -> ApiResponse[PluginsView]:
    from movieclaw_kernel import DURABLE_EVENTS

    kernel = _kernel(request)
    store = kernel.service(DURABLE_EVENTS)
    durable = await store.describe() if store is not None else None
    return ok(
        PluginsView.model_validate(
            {"plugins": kernel.snapshot(), "contracts": kernel.contracts(), "durable": durable}
        )
    )


@router.post(
    "/dead-letters/{letter_id}/replay",
    response_model=ApiResponse[None],
    summary="重放一条可靠事件死信：把事件再交给对应插件处理一次",
    operation_id="app.plugins.dead-letters.replay",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def replay_dead_letter(letter_id: int, request: Request) -> ApiResponse[None]:
    from movieclaw_api.services.durable_events import ReplayError

    store = _durable_store(request)
    try:
        await store.replay(letter_id)
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    except ReplayError as exc:
        raise ConflictException(f"重放失败：{exc}") from exc
    return ok(None, message="已重放")


@router.post(
    "/dead-letters/{letter_id}/dismiss",
    response_model=ApiResponse[None],
    summary="忽略一条可靠事件死信（不再重放）",
    operation_id="app.plugins.dead-letters.dismiss",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def dismiss_dead_letter(letter_id: int, request: Request) -> ApiResponse[None]:
    store = _durable_store(request)
    try:
        await store.dismiss(letter_id)
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    return ok(None, message="已忽略")
