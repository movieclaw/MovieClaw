"""内置插件诊断（设置 → 插件 → 内置；docs/design/plugin-kernel.md §10）。

后端的每个子系统都是插件内核上的一个内置插件。这里只读地列出每个插件的状态、启动耗时、
失败原因、缺失的依赖与运行指标，外加全部契约（服务、注册表、事件）——排查「某个功能
怎么没起来」「启动为什么慢」时看这一页。禁用插件走 ``data/plugins.yaml``，重启生效。

可靠事件（docs/design/plugin-phase2a.md §2）的消费进度与死信也在这里：死信可以重放或忽略。
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from fastapi import APIRouter, File, Request, UploadFile
from pydantic import Field

from movieclaw_api.exceptions import (
    BadRequestException,
    ConflictException,
    NotFoundException,
    ServiceUnavailableException,
)
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok

router = APIRouter(prefix="/app/plugins", tags=["app"])


class BlockedBy(BaseModel):
    key: str
    reason: str
    provider: str | None = Field(default=None, description="提供这个服务的插件；没有插件提供为空")
    provider_state: str | None = Field(default=None, description="提供方当前的状态")


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


class HealthView(BaseModel):
    key: str
    ok: bool
    message: str
    action_href: str | None = None
    since: str


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
    tier: Literal["official", "system"] | None = Field(
        default=None,
        description="内置插件在插件页的分层：官方插件（可被插件包替换，替换它的插件包也算）/ "
        "系统模块（默认不展示，异常时浮出）；其余第三方与本地插件为空"
        "（docs/design/plugin-page-tiers.md）",
    )
    health: list[HealthView] = Field(
        default_factory=list, description="插件自己报告的运行状况（PLUGIN_HEALTH）"
    )
    data_rows: int = Field(default=0, description="插件数据行数（PLUGIN_DATA）")
    group: str | None = Field(
        default=None, description="内置插件的功能分组（设置 → 插件 → 内置）；本地 / 第三方插件为空"
    )
    runtime: str = Field(
        default="inline", description="inline：主进程里运行；process：独立进程（第三阶段）"
    )


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


class SafeModeView(BaseModel):
    active: bool = Field(description="本次启动是否跳过了全部本地 / 第三方插件")
    reason: str
    since: float | None = Field(description="进入安全模式的时间（Unix 秒）")
    skipped: list[str] = Field(description="被跳过的插件")
    forced: str | None = Field(description="env / file：手动强制；空：自动进入或未进入")


class PluginsView(BaseModel):
    plugins: list[PluginView]
    groups: list[str] = Field(default_factory=list, description="内置插件分组的展示顺序")
    contracts: ContractsView
    durable: DurableView | None = Field(
        default=None, description="可靠事件的消费进度与死信；投递插件未运行时为空"
    )
    safe_mode: SafeModeView = Field(description="插件安全模式（docs/design/plugin-phase3.md §5）")


class SafeModeExitView(BaseModel):
    mounted: dict[str, str] = Field(description="重新加载的插件 → 加载后的状态")


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
    summary="插件诊断：各插件的状态、启动耗时、失败原因与契约",
    operation_id="app.plugins.list",
)
async def list_plugins(request: Request) -> ApiResponse[PluginsView]:
    from movieclaw_api.plugins.keys import PLUGIN_DATA, PLUGIN_HEALTH
    from movieclaw_kernel import DURABLE_EVENTS

    kernel = _kernel(request)
    store = kernel.service(DURABLE_EVENTS)
    durable = await store.describe() if store is not None else None
    health_service = kernel.service(PLUGIN_HEALTH)
    health = health_service.snapshot() if health_service is not None else {}
    data_service = kernel.service(PLUGIN_DATA)
    data_rows = await data_service.counts() if data_service is not None else {}
    from movieclaw_api.plugins.bundled import replaceable_ids
    from movieclaw_api.plugins.features import tier_of
    from movieclaw_api.plugins.manifest import BUILTIN_GROUPS, builtin_group
    from movieclaw_api.services.plugin_runtime import process_entries

    bundled = replaceable_ids()

    def layer(item: dict) -> dict:
        owner = item.get("parent") or item["id"]
        # 替换随带插件包的插件包仍在「官方插件」里那一行（标「已被插件包替换」）
        if item["source"] != "builtin" and owner not in bundled:
            return {"tier": None}
        return {"tier": tier_of(owner, bundled=bundled)}

    plugins = [
        {
            **item,
            **layer(item),
            "health": health.get(item["id"], []),
            "data_rows": data_rows.get(item["id"], 0),
            "runtime": "process" if item["id"] in process_entries else "inline",
            "group": (
                builtin_group(item.get("parent") or item["id"])
                if item["source"] == "builtin"
                else None
            ),
        }
        for item in kernel.snapshot()
    ]
    from movieclaw_api.plugins import safe_mode

    return ok(
        PluginsView.model_validate(
            {
                "plugins": plugins,
                "contracts": kernel.contracts(),
                "durable": durable,
                "safe_mode": safe_mode.current().view(),
                "groups": [label for label, _ in BUILTIN_GROUPS],
            }
        )
    )


@router.post(
    "/safe-mode/exit",
    response_model=ApiResponse[SafeModeExitView],
    summary="退出插件安全模式：当场重新加载被跳过的本地 / 第三方插件",
    operation_id="app.plugins.safe-mode.exit",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def exit_safe_mode(request: Request) -> ApiResponse[SafeModeExitView]:
    """插件若再把应用拖垮，下次启动会重新进入安全模式。"""
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.plugins import packages, safe_mode
    from movieclaw_api.plugins.local import load_local_entries, local_specs
    from movieclaw_api.plugins.notices import publish_safe_mode

    kernel = _kernel(request)
    if not safe_mode.current().active:
        raise ConflictException("当前没有处于安全模式")
    settings = get_settings()
    ids = [spec.id for spec in local_specs(settings) if not spec.disabled]
    ids += packages.package_ids(settings)
    try:
        safe_mode.exit_safe_mode(settings, ids)
    except PermissionError as exc:
        raise ConflictException(str(exc)) from exc
    await publish_safe_mode(safe_mode.current())
    mounted: dict[str, str] = {}
    for entry in (*load_local_entries(settings), *packages.load_package_entries(settings)):
        if kernel.fiber(entry.id) is None:
            mounted[entry.id] = (await kernel.mount(entry)).state.value
    safe_mode.schedule_settle(settings)
    return ok(SafeModeExitView(mounted=mounted), message="已退出安全模式")


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


# ---------------------------------------------------------------------- 插件包（第三阶段 C5）
class OperationDetailView(BaseModel):
    id: str
    summary: str = Field(description="这个操作做什么（中文）")
    dangerous: bool = Field(description="危险操作（删除、改配置等），批准页标红")


class PackageRequestView(BaseModel):
    id: str
    title: str
    version: str
    description: str
    runtime: str = Field(description="process：独立进程；inline：主进程里运行（须单独确认）")
    operations: list[str] = Field(description="插件申请的宿主操作")
    new_operations: list[str] = Field(description="相比当前已安装版本新增的申请")
    operation_details: list[OperationDetailView] = Field(default_factory=list)
    paths: list[dict[str, str]] = Field(description="插件申请的路径授权（path、mode）")
    new_paths: list[dict[str, str]] = Field(description="相比当前已安装版本新增的路径申请")
    callbacks: list[str] = Field(
        default_factory=list,
        description="要开放的回调端点名：外部平台能不登录直接调进来的地址，批准页单独列出",
    )
    new_callbacks: list[str] = Field(default_factory=list, description="相比当前已安装版本新增的")
    requires: dict[str, str]
    installed_version: str | None
    replaces_builtin: bool = Field(
        default=False, description="与随带的内置插件同 id：安装即替换它，卸载后随带版本回来"
    )


class InstalledPackageView(BaseModel):
    id: str
    title: str
    version: str
    runtime: str
    operations: list[str]
    operation_details: list[OperationDetailView] = Field(default_factory=list)
    paths: list[dict[str, str]]
    callbacks: list[str] = Field(default_factory=list, description="开放的回调端点名")
    previous_version: str | None
    bad_versions: list[str] = Field(description="激活失败过、已自动回滚的版本")
    state: str
    error: str | None
    watching: bool = Field(description="是否还在安装后的宽限期观察中")
    replaces_builtin: bool = Field(
        default=False, description="替换了随带的内置插件；卸载后随带版本回来"
    )


class PackagesView(BaseModel):
    installed: list[InstalledPackageView]
    pending: list[PackageRequestView] = Field(description="已上传、等待批准的包")


class PackageApprove(BaseModel):
    version: str
    operations: list[str] = Field(
        default_factory=list, description="批准的宿主操作，须与插件申请的完全一致"
    )
    allow_inline: bool = Field(
        default=False, description="插件申请在主进程里运行时，须显式确认（与主程序同权限）"
    )
    paths: list[dict[str, str]] = Field(
        default_factory=list, description="批准的路径授权，须与插件申请的完全一致"
    )


class PackageResultView(BaseModel):
    status: str = Field(description="active / rolled_back / failed 等")
    version: str | None
    state: str
    error: str | None = None


class PackageUninstallView(BaseModel):
    purged_rows: int


def _packages(request: Request):
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.plugin_packages import PackageManager

    kernel = _kernel(request)
    manager = getattr(request.app.state, "package_manager", None)
    if manager is None or manager.kernel is not kernel:
        manager = PackageManager(kernel, get_settings())
        request.app.state.package_manager = manager
    return manager


@router.get(
    "/packages",
    response_model=ApiResponse[PackagesView],
    summary="插件包：已安装的与等待批准的",
    operation_id="app.plugins.packages.list",
)
async def list_packages(request: Request) -> ApiResponse[PackagesView]:
    return ok(PackagesView.model_validate(_packages(request).overview()))


@router.post(
    "/packages",
    response_model=ApiResponse[PackageRequestView],
    summary="上传插件包（.mcplugin）：校验后进入待批准，返回它申请的权限",
    operation_id="app.plugins.packages.upload",
)
async def upload_package(
    request: Request, file: UploadFile = File(...)
) -> ApiResponse[PackageRequestView]:
    from movieclaw_api.plugins.packages import MAX_ARCHIVE_BYTES, PackageError

    data = await file.read(MAX_ARCHIVE_BYTES + 1)
    try:
        view = await _packages(request).upload(data)
    except PackageError as exc:
        raise BadRequestException(str(exc)) from exc
    return ok(PackageRequestView.model_validate(view), message="已上传，等待批准")


@router.post(
    "/packages/{entry_id}/approve",
    response_model=ApiResponse[PackageResultView],
    summary="批准并安装插件包：按申请授予宿主操作，当场加载；激活失败自动回滚",
    operation_id="app.plugins.packages.approve",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def approve_package(
    entry_id: str, body: PackageApprove, request: Request
) -> ApiResponse[PackageResultView]:
    from movieclaw_api.plugins.packages import PackageError

    try:
        result = await _packages(request).approve(
            entry_id,
            body.version,
            operations=body.operations,
            allow_inline=body.allow_inline,
            paths=body.paths,
        )
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    except PackageError as exc:
        raise BadRequestException(str(exc)) from exc
    view = PackageResultView.model_validate(result)
    message = "已安装并运行" if view.status == "active" else f"没能运行，已回滚：{view.error}"
    return ok(view, message=message)


@router.delete(
    "/packages/{entry_id}/pending",
    response_model=ApiResponse[None],
    summary="放弃一个等待批准的插件包",
    operation_id="app.plugins.packages.discard",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def discard_package(entry_id: str, request: Request) -> ApiResponse[None]:
    try:
        await _packages(request).discard(entry_id)
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    return ok(None, message="已放弃")


@router.post(
    "/packages/{entry_id}/rollback",
    response_model=ApiResponse[PackageResultView],
    summary="插件包回到上一版",
    operation_id="app.plugins.packages.rollback",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def rollback_package(entry_id: str, request: Request) -> ApiResponse[PackageResultView]:
    from movieclaw_api.plugins.packages import PackageError

    try:
        result = await _packages(request).rollback(entry_id)
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    except PackageError as exc:
        raise ConflictException(str(exc)) from exc
    return ok(PackageResultView.model_validate(result), message="已回到上一版")


@router.delete(
    "/packages/{entry_id}",
    response_model=ApiResponse[PackageUninstallView],
    summary="卸载插件包（默认保留插件数据；purge_data=true 连同数据删除）",
    operation_id="app.plugins.packages.uninstall",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def uninstall_package(
    entry_id: str, request: Request, purge_data: bool = False
) -> ApiResponse[PackageUninstallView]:
    try:
        result = await _packages(request).uninstall(entry_id, purge_data=purge_data)
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    return ok(PackageUninstallView.model_validate(result), message="已卸载")


# ---------------------------------------------------- 回调端点（plugin-callbacks.md §4.4）
class CallbackKeyView(BaseModel):
    id: int
    entry_id: str = Field(description="插件条目 id")
    endpoint: str = Field(description="端点名")
    scope: str = Field(description="归属：plugin / account:<通道>:<账号> / entity:<类型>:<id>")
    url: str = Field(description="地址（密钥打码；要完整地址就换一个新的）")
    created_at: datetime
    running: bool = Field(description="插件在运行、端点已登记（否则调进来回 503）")
    calls: int = Field(description="本次启动以来的调用次数")
    failures: int = Field(description="本次启动以来插件回 401 / 403 的次数（验证没通过）")
    last_called_at: datetime | None
    last_status: int | None


class CallbackIssuedView(BaseModel):
    id: int
    endpoint: str
    scope: str
    url: str = Field(description="完整地址，填到平台后台；只在这里出现一次")
    absolute: bool = Field(
        description="是否带上了外部访问地址；为 false 时要先在设置里配外部访问地址"
    )


def _callbacks():  # noqa: ANN202 -- 回调底座关着时 503
    from movieclaw_api.services.plugin_callbacks import get_service

    service = get_service()
    if service is None:
        raise ServiceUnavailableException("插件回调端点没有启用")
    return service


@router.get(
    "/callbacks",
    response_model=ApiResponse[list[CallbackKeyView]],
    summary="插件开放的回调地址（外部平台调进来的地址，密钥打码）",
    operation_id="app.plugins.callbacks.list",
)
async def list_callbacks(plugin: str | None = None) -> ApiResponse[list[CallbackKeyView]]:
    rows = await _callbacks().overview(plugin)
    return ok([CallbackKeyView.model_validate(r) for r in rows])


@router.post(
    "/callbacks/{key_id}/rotate",
    response_model=ApiResponse[CallbackIssuedView],
    summary="换一个回调地址：旧地址立即失效，返回新地址（要重新填到平台后台）",
    operation_id="app.plugins.callbacks.rotate",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def rotate_callback(key_id: int) -> ApiResponse[CallbackIssuedView]:
    try:
        issued = await _callbacks().rotate(key_id)
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    view = CallbackIssuedView(
        id=issued.id,
        endpoint=issued.endpoint,
        scope=issued.scope,
        url=issued.url,
        absolute=issued.absolute,
    )
    return ok(view, message="已换新地址，旧地址已失效")


@router.delete(
    "/callbacks/{key_id}",
    response_model=ApiResponse[None],
    summary="作废一个回调地址（外部平台再调进来一律 404）",
    operation_id="app.plugins.callbacks.revoke",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def revoke_callback(key_id: int) -> ApiResponse[None]:
    try:
        await _callbacks().revoke_id(key_id)
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    return ok(None, message="已作废")


# ---------------------------------------------------- 插件详情（设置 → 插件 → 点一个插件）
class AddedView(BaseModel):
    kind: str = Field(
        description="channel / task / ingest / job / site / command / trigger / decision"
    )
    title: str = Field(description="人话：它给系统加了什么、什么时候被触发、会影响什么")
    detail: str
    href: str | None = Field(default=None, description="去哪里看 / 调整（站内路径）")


class PluginPackageDetailView(BaseModel):
    version: str
    installed_at: float | None = Field(description="安装时间（Unix 秒）")
    previous_version: str | None = Field(description="能回到的上一版")
    bad_versions: list[str] = Field(description="起不来、已自动回滚过的版本")
    operations: list[OperationDetailView] = Field(description="批准它调用的系统操作")
    paths: list[dict[str, str]] = Field(description="批准它读写的目录")
    callbacks: list[str] = Field(description="批准它开放的回调端点")
    replaces_builtin: bool


class DetailConsumerView(DurableConsumerView):
    title: str = Field(description="事件的人话名字")


class DetailDeadLetterView(DeadLetterView):
    title: str = Field(description="事件的人话名字")


class PluginDetailView(BaseModel):
    plugin: PluginView
    kind: Literal["official", "package", "local", "system"] = Field(
        description="official：随应用提供；package：第三方插件包；local：本地插件；system：系统模块"
    )
    description: str
    version: str | None
    network: bool | None = Field(description="是否声明了联网（插件包才有）")
    package: PluginPackageDetailView | None
    adds: list[AddedView] = Field(description="装了它，系统多了什么")
    consumers: list[DetailConsumerView] = Field(description="它订阅的可靠事件与积压")
    dead_letters: list[DetailDeadLetterView] = Field(description="它没处理成功、搁置下来的事件")
    callbacks: list[CallbackKeyView] = Field(description="它开放的回调地址（密钥打码）")
    data_rows: int
    disk_bytes: int = Field(description="插件私有目录占用（字节）")
    children: list[str] = Field(description="它的子条目")


@router.get(
    "/{entry_id}",
    response_model=ApiResponse[PluginDetailView],
    summary="插件详情：它是什么、状态、权限、给系统加了什么、最近的处理情况与存储",
    operation_id="app.plugins.show",
)
async def show_plugin(entry_id: str, request: Request) -> ApiResponse[PluginDetailView]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.plugin_detail import plugin_detail

    kernel = _kernel(request)
    listed = (await list_plugins(request)).data
    assert listed is not None
    item = next((p for p in listed.plugins if p.id == entry_id), None)
    if item is None:
        raise NotFoundException(f"没有插件 {entry_id}")
    detail = await plugin_detail(kernel, get_settings(), entry_id, item.model_dump(mode="json"))
    return ok(PluginDetailView.model_validate({"plugin": item, **detail}))
