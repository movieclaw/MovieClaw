"""内置插件诊断（设置 → 插件 → 内置；docs/design/plugin-kernel.md §10）。

后端的每个子系统都是插件内核上的一个内置插件。这里只读地列出每个插件的状态、启动耗时、
失败原因、缺失的依赖与运行指标，外加全部契约（服务、注册表、事件）——排查「某个功能
怎么没起来」「启动为什么慢」时看这一页。官方插件与插件包可以在这里停用 / 启用，官方插件还能
卸载 / 恢复（services/plugin_switches.py）；其余插件禁用走 ``data/plugins.yaml``，重启生效。

可靠事件（docs/design/plugin-phase2a.md §2）的消费进度与死信也在这里：死信可以重放或忽略。
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, File, Query, Request, Response, UploadFile
from pydantic import Field

from movieclaw_api.api.deps import require_admin
from movieclaw_api.exceptions import (
    BadRequestException,
    ConflictException,
    ForbiddenException,
    NotFoundException,
    ServiceUnavailableException,
)
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.auth import Principal

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
    switchable: bool = Field(
        default=False,
        description="能在插件页停用 / 启用（官方插件与已安装的插件包；"
        "docs/design/plugin-strm-prefetch.md §1）",
    )
    removable: bool = Field(
        default=False, description="是官方插件、能在插件页卸载（代码随应用携带，卸了能恢复）"
    )
    locked_by: str | None = Field(
        default=None,
        description="被 data/plugins.yaml / 环境变量关掉时的原因：停用开关锁住，要在那里改回来",
    )


class RemovedPluginView(BaseModel):
    id: str
    title: str
    description: str
    removed_at: str = Field(description="卸载时间（ISO 8601 UTC）")
    removed_by: str | None


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
    durable: bool | None = Field(default=None, description="事件能否被可靠订阅")
    listeners: list[str] | None = None


class ContractsView(BaseModel):
    services: list[ContractView]
    registries: list[ContractView]
    events: list[ContractView]


class DurableConsumerView(BaseModel):
    consumer_id: str = Field(description="<条目 id>:<监听器 id>")
    events: list[str] = Field(description="订阅的事件（一个消费者可订阅多个，按产生顺序投递）")
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
    removed: list[RemovedPluginView] = Field(
        default_factory=list, description="在插件页卸载了的官方插件（可恢复）"
    )


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
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.plugins.bundled import bundled_ids, replaceable_ids
    from movieclaw_api.plugins.features import tier_of
    from movieclaw_api.plugins.manifest import BUILTIN_GROUPS, builtin_group
    from movieclaw_api.plugins.packages import package_ids
    from movieclaw_api.services import plugin_switches
    from movieclaw_api.services.plugin_runtime import process_entries

    settings = get_settings()
    bundled = replaceable_ids()
    official = bundled_ids()
    installed = set(package_ids(settings))

    def switch(item: dict) -> dict:
        own = item["id"] in official or item["id"] in installed
        if item.get("parent") or not own or not item["disableable"]:
            return {}
        return {
            "switchable": True,
            "removable": item["source"] == "builtin" and item["id"] in official,
            "locked_by": plugin_switches.admin_lock(kernel.fiber(item["id"])),
        }

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
            **switch(item),
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
                "removed": plugin_switches.removed_views(settings),
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
    from movieclaw_api.services import plugin_deps

    plugin_deps.resume(kernel, settings)
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


class PluginEventView(BaseModel):
    name: str
    title: str


class PluginNotificationView(BaseModel):
    event: str
    title: str = Field(description="标题模板（{字段} 替换成事件里的值）")
    body: str
    audience: str = Field(description="admins / member:<字段> / media:<字段>")
    audience_label: str
    reaches_members: bool
    default: bool


class DependencyView(BaseModel):
    name: str
    version: str
    size: int | None = Field(description="这台服务器要下载的轮子大小（字节）；没有适用的轮子时为空")
    native: bool = Field(description="含本机代码（不是纯 Python）：更难审查，单独标出")
    available: bool = Field(description="有适用于这台服务器平台的轮子；没有则安装会失败")
    change: str | None = Field(description="相比已安装版本：added 新增 / changed 换版本 / 空 不变")
    previous_version: str | None = Field(description="已安装版本里的版本")


class PackageDependenciesView(BaseModel):
    lock_digest: str = Field(description="锁文件内容哈希：批准时原样交回表示同意这一份依赖")
    packages: list[DependencyView]
    total_size: int = Field(description="这台服务器上要下载的总字节数（已知的部分）")
    native: list[str] = Field(description="含本机代码的包")
    unavailable: list[str] = Field(description="没有适用于这台服务器平台的轮子的包")
    removed: list[str] = Field(description="相比已安装版本移除的包")
    index: str = Field(description="下载用的包索引地址")
    index_label: str
    needs_consent: bool = Field(description="锁文件与已批准的不同（或首次安装）：批准时须带上哈希")


class DependencyProgressView(BaseModel):
    phase: str = Field(description="installing 正在安装依赖 / failed 安装失败（可重试）")
    done: int = Field(description="已下载好的包数")
    total: int
    error: str | None = Field(description="失败原因")


class InstalledDependenciesView(BaseModel):
    packages: list[str] = Field(description="批准安装的第三方包（名字 版本）")
    progress: DependencyProgressView | None = Field(
        description="依赖正在安装或安装失败时的进度；就绪时为空"
    )


class PackageRequestView(BaseModel):
    id: str
    title: str
    version: str
    description: str
    runtime: str = Field(description="process：独立进程；inline：主进程里运行（须单独确认）")
    entry: str = Field(default="", description="入口模块；留空 = 没有后端代码（只带网页 / 主题）")
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
    events: list[PluginEventView] = Field(
        default_factory=list, description="插件会发出的事件（别的插件、Webhook 能订）"
    )
    notifications: list[PluginNotificationView] = Field(
        default_factory=list, description="插件会发的通知：发给谁、写什么"
    )
    sensitive_events: list[str] = Field(
        default_factory=list, description="要订阅的敏感事件（谁在什么时候看了什么）"
    )
    notifies_members: bool = Field(
        default=False, description="会给普通成员发通知：批准时须单独确认"
    )
    requires: dict[str, str]
    installed_version: str | None
    replaces_builtin: bool = Field(
        default=False, description="与随带的内置插件同 id：安装即替换它，卸载后随带版本回来"
    )
    dependencies: PackageDependenciesView | None = Field(
        default=None, description="要下载安装的第三方包（清单 [dependencies]）；没有则为空"
    )
    dependency_progress: DependencyProgressView | None = Field(
        default=None, description="批准后正在安装依赖时的进度"
    )
    web: PendingWebView | None = Field(
        default=None,
        description="带网页：侧边栏入口预览。批准时须 allow_web（网页以使用者的身份运行）",
    )
    theme: PendingThemeView | None = Field(
        default=None,
        description="网页主题：外观选择卡预览。带外框组件（has_code）的批准时须 allow_theme",
    )


class WebEntryView(BaseModel):
    label: str = Field(description="侧边栏文字（manifest 的 short_name / name）")
    path: str = Field(description="落点：相对插件网页根目录的子路径，主入口通常为空")
    icon: str | None = Field(
        default=None,
        description="图标地址；待批准的包是内嵌的 SVG data URL；没有则由前端用默认图标",
    )
    monochrome: bool = Field(
        default=False, description="manifest 标了 purpose: monochrome：按遮罩用当前文字颜色着色"
    )


class PendingThemePreview(BaseModel):
    bg: str
    accent: str


class PendingThemeView(BaseModel):
    label: str = Field(description="设置 → 外观里的主题名")
    description: str
    preview: PendingThemePreview
    layout: str = Field(description="版式：panel / cinema")
    glass: bool = Field(description="是否用液态玻璃")
    has_code: bool = Field(description="带外框组件（JS）：代码以使用者的身份运行，批准时须单独同意")


class PendingWebView(BaseModel):
    """待批准的包带网页：批准页预览侧边栏入口，并须单独同意授信运行。"""

    id: str
    name: str
    source: str
    base: str = Field(description="iframe 加载的地址前缀")
    entries: list[WebEntryView]


class WebConsentView(BaseModel):
    nav: bool = Field(description="加到侧边栏")
    members: bool = Field(description="成员也能看到（管理员总能看到）")


class WebPageView(BaseModel):
    """一个带网页的插件（插件包或本地插件），不论是否已同意。"""

    id: str
    name: str
    source: str = Field(description="package：插件包；local：本地插件")
    approved: bool = Field(description="用户已同意授信运行；没同意的不托管、不进侧边栏")
    nav: bool
    members: bool
    base: str
    entries: list[WebEntryView]


class WebConsentUpdate(BaseModel):
    nav: bool = Field(default=True, description="加到侧边栏")
    members: bool = Field(default=False, description="成员也能看到")


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
    dependencies: InstalledDependenciesView | None = Field(
        default=None, description="批准安装的第三方依赖；没有则为空"
    )
    web: WebConsentView | None = Field(
        default=None, description="插件网页的同意；不带网页或没同意为空"
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
    allow_member_notifications: bool = Field(
        default=False, description="插件会给普通成员发通知时，须显式确认"
    )
    dependencies: str | None = Field(
        default=None,
        description="同意安装的第三方依赖：填待批准包的 dependencies.lock_digest；"
        "锁文件与已安装版本相同时不用填",
    )
    allow_web: bool = Field(
        default=False,
        description="插件带网页时须显式确认：网页以正在使用它的人的身份运行"
        "（管理员打开时拥有管理员的全部权限）",
    )
    web_nav: bool = Field(default=True, description="带网页时：加到侧边栏")
    web_members: bool = Field(default=False, description="带网页时：成员也能看到")
    allow_theme: bool = Field(
        default=False,
        description="主题带外框组件时须显式确认：代码会在每个页面里以正在使用它的人的身份运行",
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
            allow_member_notifications=body.allow_member_notifications,
            dependencies=body.dependencies,
            allow_web=body.allow_web,
            web_nav=body.web_nav,
            web_members=body.web_members,
            allow_theme=body.allow_theme,
        )
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    except PackageError as exc:
        raise BadRequestException(str(exc)) from exc
    view = PackageResultView.model_validate(result)
    message = "已安装并运行" if view.status == "active" else f"没能运行，已回滚：{view.error}"
    return ok(view, message=message)


@router.post(
    "/packages/{entry_id}/dependencies/retry",
    response_model=ApiResponse[PackageResultView],
    summary="重试安装插件包的第三方依赖（按已批准的锁文件，不再询问）；装好即加载",
    operation_id="app.plugins.packages.retry-dependencies",
)
async def retry_package_dependencies(
    entry_id: str, request: Request
) -> ApiResponse[PackageResultView]:
    from movieclaw_api.plugins.packages import PackageError

    try:
        result = await _packages(request).retry_dependencies(entry_id)
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    except PackageError as exc:
        raise BadRequestException(str(exc)) from exc
    return ok(PackageResultView.model_validate(result), message="依赖已装好")


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
    entry_id: str,
    request: Request,
    purge_data: bool = Query(
        default=False, description="连同插件数据、界面保存的设置与私有目录一起删除（默认保留）"
    ),
) -> ApiResponse[PackageUninstallView]:
    try:
        result = await _packages(request).uninstall(entry_id, purge_data=purge_data)
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    return ok(PackageUninstallView.model_validate(result), message="已卸载")


# ---------------------------------------------- 停用 / 卸载（plugin-strm-prefetch.md §1）
class PluginSwitchPayload(BaseModel):
    enabled: bool = Field(description="true 启用，false 停用")


class PluginSwitchView(BaseModel):
    id: str
    state: str = Field(description="切换后的状态")


class BundledUninstallView(BaseModel):
    cancelled_jobs: int = Field(description="取消了的后台任务数")
    purged_rows: int = Field(description="删除的插件数据行数（没勾选删除数据为 0）")


def _switch_error(exc):  # noqa: ANN001, ANN202
    from movieclaw_api.exceptions import AppException

    return AppException(status_code=exc.status, code=exc.code, message=exc.message)


@router.put(
    "/{entry_id}/enabled",
    response_model=ApiResponse[PluginSwitchView],
    summary="停用 / 启用插件（官方插件与插件包）：运行中生效，重启后保持；停用会取消它的后台任务",
    operation_id="app.plugins.switch",
)
async def switch_plugin(
    entry_id: str,
    payload: PluginSwitchPayload,
    request: Request,
    principal: Principal = Depends(require_admin),
) -> ApiResponse[PluginSwitchView]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.plugin_switches import PluginSwitchError, set_enabled

    kernel = _kernel(request)
    try:
        await set_enabled(kernel, get_settings(), entry_id, payload.enabled, actor=principal.name)
    except PluginSwitchError as exc:
        raise _switch_error(exc) from exc
    fiber = kernel.fiber(entry_id)
    state = fiber.state.value if fiber is not None else "disposed"
    message = "已启用" if payload.enabled else "已停用"
    return ok(PluginSwitchView(id=entry_id, state=state), message=message)


@router.delete(
    "/{entry_id}/bundled",
    response_model=ApiResponse[BundledUninstallView],
    summary="卸载官方插件（随时能恢复）；默认保留插件数据，purge_data=true 连同数据删除",
    operation_id="app.plugins.bundled.uninstall",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def uninstall_bundled(
    entry_id: str,
    request: Request,
    purge_data: bool = Query(
        default=False, description="连同插件数据、界面保存的设置与私有目录一起删除（默认保留）"
    ),
    principal: Principal = Depends(require_admin),
) -> ApiResponse[BundledUninstallView]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services import plugin_switches

    try:
        result = await plugin_switches.uninstall_bundled(
            _kernel(request), get_settings(), entry_id, purge_data=purge_data, actor=principal.name
        )
    except plugin_switches.PluginSwitchError as exc:
        raise _switch_error(exc) from exc
    return ok(BundledUninstallView.model_validate(result), message="已卸载")


@router.post(
    "/{entry_id}/bundled/restore",
    response_model=ApiResponse[PluginSwitchView],
    summary="恢复卸载了的官方插件：当场加载",
    operation_id="app.plugins.bundled.restore",
)
async def restore_bundled(entry_id: str, request: Request) -> ApiResponse[PluginSwitchView]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services import plugin_switches

    try:
        state = await plugin_switches.restore_bundled(_kernel(request), get_settings(), entry_id)
    except plugin_switches.PluginSwitchError as exc:
        raise _switch_error(exc) from exc
    return ok(PluginSwitchView(id=entry_id, state=state), message="已恢复")


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
        description=(
            "channel / task / ingest / job / site / service（提供的服务）"
            " / background（常驻后台工作）/ delete（删除时的选项）"
            " / other（其他登记）"
            " / command / trigger / decision / event（会发出的事件）/ notification（会发的通知）"
        )
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


class PluginSourceView(BaseModel):
    path: str = Field(
        description="源码位置：应用源码按 src/… 显示（系统模块带行号），数据目录里的按 data/…"
    )
    entry: str | None = Field(
        default=None,
        description="入口名称：系统模块是函数名（如 downloads()），官方 / 本地插件是入口模块名",
    )


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
    data_path: str | None = Field(
        default=None, description="插件私有目录（data/plugins/data/<id>）"
    )
    children: list[str] = Field(description="它的子条目")
    source: PluginSourceView | None = Field(default=None, description="源码在哪")


@router.get(
    "/pages",
    response_model=ApiResponse[list[WebPageView]],
    summary="带网页的插件（插件包与本地插件）：是否已同意、侧边栏入口",
    operation_id="app.plugins.pages.list",
)
def list_web_pages() -> ApiResponse[list[WebPageView]]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services import plugin_web

    rows = []
    for item in plugin_web.web_plugins(get_settings()):
        view = plugin_web.app_view(item)
        rows.append(WebPageView.model_validate({**view, "approved": item.consent is not None}))
    return ok(rows)


@router.put(
    "/{entry_id}/web",
    response_model=ApiResponse[WebPageView],
    summary="同意插件网页授信运行，或改它加不加侧边栏、成员能不能看到（只能由人在网页里操作）",
    operation_id="app.plugins.web.update",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def update_web_consent(
    entry_id: str,
    body: WebConsentUpdate,
    request: Request,
    principal: Principal = Depends(require_admin),
) -> ApiResponse[WebPageView]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.plugins.packages import SOURCE as PACKAGE
    from movieclaw_api.services import plugin_web

    # 插件网页以使用者的身份运行：同意这一步必须是人在网页里点的，Agent 与命令行的凭证不行
    # （本地插件常由 Agent 写出来，不能让它替用户点同意）
    if not principal.interactive:
        raise ForbiddenException(
            "插件网页会以使用者的身份运行，同意只能由管理员在网页里操作（设置 → 插件），"
            "Agent 与命令行的凭证不能代为同意"
        )
    settings = get_settings()
    found = plugin_web.find(settings, entry_id)
    if found is None:
        raise NotFoundException(f"插件 {entry_id} 没有网页")
    consent = plugin_web.Consent(nav=body.nav, members=body.members)
    if found.source == PACKAGE:
        await _packages(request).set_web(entry_id, consent.record())
    else:
        plugin_web.write_local_consent(settings, entry_id, consent)
    updated = plugin_web.find(settings, entry_id)
    assert updated is not None
    return ok(
        WebPageView.model_validate({**plugin_web.app_view(updated), "approved": True}),
        message="已同意" if found.consent is None else "已保存",
    )


@router.delete(
    "/{entry_id}/web",
    response_model=ApiResponse[None],
    summary="撤销插件网页的同意：不再托管、从侧边栏撤下（插件本身照常运行）",
    operation_id="app.plugins.web.revoke",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def revoke_web_consent(entry_id: str, request: Request) -> ApiResponse[None]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.plugins.packages import SOURCE as PACKAGE
    from movieclaw_api.services import plugin_web

    settings = get_settings()
    found = plugin_web.find(settings, entry_id)
    if found is None:
        raise NotFoundException(f"插件 {entry_id} 没有网页")
    if found.source == PACKAGE:
        await _packages(request).set_web(entry_id, None)
    else:
        plugin_web.write_local_consent(settings, entry_id, None)
    return ok(None, message="已撤销")


# ---------------------------------------------------------------------- 插件市场
# 路径以 /market 开头，必须登记在 /{entry_id} 之前
class MarketAuthorView(BaseModel):
    name: str
    url: str | None


class MarketPermissionsView(BaseModel):
    operations: list[str]
    paths: list[dict[str, str]]
    network: bool
    callbacks: list[str]
    events: list[str] = Field(description="要订阅的敏感事件")


class MarketDependencyView(BaseModel):
    name: str
    version: str
    native: bool = Field(description="含本机代码")


class MarketVersionView(BaseModel):
    version: str
    prerelease: bool = Field(description="测试版（版本号带 - 后缀）")
    released_at: str | None
    yanked: str | None = Field(description="已撤回：原因；没撤回为空")
    notes: str = Field(description="这一版的更新说明（markdown）")
    changelog_url: str | None
    source_url: str | None = Field(description="这一版的源码目录")
    runtime: str
    requires: dict[str, str]
    permissions: MarketPermissionsView
    web: bool = Field(description="带插件网页")
    dependencies: list[MarketDependencyView] = Field(description="要下载的第三方包")
    size: int | None = Field(description="这台服务器要下载的插件包字节数")
    compatible: bool
    incompatible_reason: str | None


class MarketInstalledView(BaseModel):
    version: str
    source: str = Field(description="package：插件包；bundled：随应用提供")
    state: str
    previous_version: str | None = Field(description="插件包的上一版（可直接回退）")
    yanked: str | None = Field(description="装着的这一版已被撤回：原因")


class MarketDeprecatedView(BaseModel):
    reason: str
    replaced_by: str | None


class MarketPluginView(BaseModel):
    id: str
    name: str
    summary: str
    description: str
    category: str = Field(description="storage / downloader / messaging / sites / library / tools")
    author: MarketAuthorView
    homepage: str | None
    repository: str | None
    feedback_url: str | None = Field(
        default=None,
        description="反馈问题的地址（作者的 issue 页，或官方仓库预填的表单）；索引没写时为空",
    )
    downloads: int | None = Field(
        default=None, description="累计下载次数；索引没写、或写了没法当次数用的值时为空"
    )
    screenshots: list[str] = Field(
        default_factory=list, description="经本服务器代理的截图地址；没有截图时为空列表"
    )
    license: str
    icon_url: str | None = Field(description="经本服务器代理的图标地址；没有图标为空")
    deprecated: MarketDeprecatedView | None
    latest: str | None
    recommended: str | None = Field(
        description="该装的那一版：能装、没撤回的最新正式版；装着测试版或没有正式版时含测试版"
    )
    installed: MarketInstalledView | None
    update: str | None = Field(description="有更新时是要升到的版本")
    blocked: str | None = Field(description="不能安装的原因（同 id 已被内置或本地插件占用）")
    versions: list[MarketVersionView]


class MarketPluginDetailView(MarketPluginView):
    selected: str | None = Field(description="README 与依赖对应的版本")
    readme: str | None = Field(description="这一版的 README（markdown）")
    readme_error: str | None
    dependencies: PackageDependenciesView | None = Field(
        description="这一版在这台服务器上要下载的第三方依赖；没有依赖为空"
    )


class MarketSourceView(BaseModel):
    url: str
    repository: str | None
    generated_at: str | None = Field(description="索引生成时间（UTC）")
    signed: bool
    checked_at: datetime = Field(description="最近一次取到索引的时间")
    error: str | None = Field(description="最近一次检查失败的原因：用的是旧索引")


class MarketView(BaseModel):
    source: MarketSourceView
    plugins: list[MarketPluginView]
    updates: int = Field(description="有更新的已安装插件数")


class MarketInstall(BaseModel):
    version: str = Field(description="要装的版本：升级、降级、重装旧版都用它")


def _market_error(exc):  # noqa: ANN001, ANN202
    if exc.status == 404:
        return NotFoundException(exc.message)
    if exc.status == 409:
        return ConflictException(exc.message)
    if exc.status == 503:
        return ServiceUnavailableException(exc.message)
    return BadRequestException(exc.message)


@router.get(
    "/market",
    response_model=ApiResponse[MarketView],
    summary="插件市场：官方插件仓库里的插件、版本、兼容性与本机安装状态",
    operation_id="app.plugins.market.list",
)
async def list_market(request: Request) -> ApiResponse[MarketView]:
    from movieclaw_api.services import plugin_market

    try:
        catalog = await plugin_market.load_catalog()
    except plugin_market.MarketError as exc:
        raise _market_error(exc) from exc
    return ok(MarketView.model_validate(plugin_market.market_view(catalog, _kernel(request))))


@router.post(
    "/market/refresh",
    response_model=ApiResponse[MarketView],
    summary="插件市场：立即重新获取索引（检查更新）",
    operation_id="app.plugins.market.refresh",
)
async def refresh_market(request: Request) -> ApiResponse[MarketView]:
    from movieclaw_api.services import plugin_market

    try:
        catalog = await plugin_market.load_catalog(refresh=True)
    except plugin_market.MarketError as exc:
        raise _market_error(exc) from exc
    view = MarketView.model_validate(plugin_market.market_view(catalog, _kernel(request)))
    if view.source.error:
        raise ServiceUnavailableException(view.source.error)
    return ok(view, message="已是最新" if not view.updates else f"{view.updates} 个插件有更新")


@router.get(
    "/market/{plugin_id}",
    response_model=ApiResponse[MarketPluginDetailView],
    summary="插件市场：一个插件的详情、README 与这台服务器要下载的依赖",
    operation_id="app.plugins.market.show",
)
async def show_market_plugin(
    plugin_id: str,
    request: Request,
    version: str | None = Query(default=None, description="看哪一版的 README 与依赖；默认推荐版本"),
) -> ApiResponse[MarketPluginDetailView]:
    from movieclaw_api.services import plugin_market

    try:
        detail = await plugin_market.plugin_detail(plugin_id, _kernel(request), version=version)
    except plugin_market.MarketError as exc:
        raise _market_error(exc) from exc
    return ok(MarketPluginDetailView.model_validate(detail))


@router.get(
    "/market/{plugin_id}/icon",
    summary="插件市场：插件图标（按索引里的 sha256 核对后返回）",
    operation_id="app.plugins.market.icon",
    response_class=Response,
    openapi_extra={"x-cli-hidden": True},
)
async def market_icon(plugin_id: str) -> Response:
    from movieclaw_api.services import plugin_market

    try:
        data, media_type = await plugin_market.icon(plugin_id)
    except plugin_market.MarketError as exc:
        raise _market_error(exc) from exc
    return Response(
        content=data,
        media_type=media_type,
        headers={
            # 地址带内容哈希（?v=），可以长缓存；SVG 不许跑脚本、不许当页面打开
            "Cache-Control": "private, max-age=604800, immutable",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox",
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.get(
    "/market/{plugin_id}/screenshots/{index}",
    summary="插件市场：插件截图（按索引里的 sha256 核对后返回）",
    operation_id="app.plugins.market.screenshot",
    response_class=Response,
    openapi_extra={"x-cli-hidden": True},
)
async def market_screenshot(plugin_id: str, index: int) -> Response:
    from movieclaw_api.services import plugin_market

    try:
        data, media_type = await plugin_market.screenshot(plugin_id, index)
    except plugin_market.MarketError as exc:
        raise _market_error(exc) from exc
    return Response(
        content=data,
        media_type=media_type,
        headers={
            "Cache-Control": "private, max-age=604800, immutable",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox",
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.post(
    "/market/{plugin_id}/install",
    response_model=ApiResponse[PackageRequestView],
    summary="从插件市场下载一个版本（核对签名索引里的 sha256），放进待批准；升级、降级都走这里",
    operation_id="app.plugins.market.install",
)
async def install_from_market(
    plugin_id: str, body: MarketInstall, request: Request
) -> ApiResponse[PackageRequestView]:
    from movieclaw_api.plugins.packages import PackageError
    from movieclaw_api.services import plugin_market

    try:
        data = await plugin_market.download(plugin_id, body.version, _kernel(request))
        view = await _packages(request).upload(data)
    except plugin_market.MarketError as exc:
        raise _market_error(exc) from exc
    except PackageError as exc:
        raise BadRequestException(str(exc)) from exc
    return ok(PackageRequestView.model_validate(view), message="已下载，等待批准")


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


# ---------------------------------------------------------------------- 通用设置
class PluginSettingsView(BaseModel):
    """插件通用设置（docs/design/plugin-phase4.md §3）。"""

    editable: bool = Field(description="能否在界面上修改")
    reason: str | None = Field(
        default=None, description="不能修改的原因（例如配置里有界面不支持的类型）；没有配置为空"
    )
    settings_schema: dict | None = Field(
        default=None,
        alias="schema",
        description="参数的界面描述（JSON Schema 子集）；敏感字段带 writeOnly",
    )
    values: dict = Field(default_factory=dict, description="当前值（不含敏感字段）")
    secrets_set: list[str] = Field(default_factory=list, description="已设置过的敏感字段")


class PluginSettingsPayload(BaseModel):
    values: dict = Field(description="要保存的值；敏感字段留空表示不改；没给的字段保持原值")


@router.get(
    "/{entry_id}/settings",
    response_model=ApiResponse[PluginSettingsView],
    response_model_by_alias=True,
    summary="插件通用设置：参数的界面描述与当前值（敏感字段只告诉是否已设置）",
    operation_id="app.plugins.settings.show",
)
async def show_plugin_settings(entry_id: str, request: Request) -> ApiResponse[PluginSettingsView]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services import plugin_settings

    data = plugin_settings.view(_kernel(request), get_settings(), entry_id)
    return ok(PluginSettingsView.model_validate(data))


@router.put(
    "/{entry_id}/settings",
    response_model=ApiResponse[PluginSettingsView],
    response_model_by_alias=True,
    summary="保存插件通用设置并重启插件；重启失败会恢复原设置并报原因",
    operation_id="app.plugins.settings.update",
)
async def update_plugin_settings(
    entry_id: str, payload: PluginSettingsPayload, request: Request
) -> ApiResponse[PluginSettingsView]:
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services import plugin_settings

    data = await plugin_settings.update(_kernel(request), get_settings(), entry_id, payload.values)
    return ok(PluginSettingsView.model_validate(data), message="设置已保存，插件已按新设置重启")
