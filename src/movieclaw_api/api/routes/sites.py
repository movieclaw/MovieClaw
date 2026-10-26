from __future__ import annotations

import json
from typing import Any

import httpx
from fastapi import APIRouter, BackgroundTasks, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import (
    BadRequestException,
    ConflictException,
    NotFoundException,
    ServiceUnavailableException,
    exception_fields,
)
from movieclaw_api.i18n import t
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.schemas.site import (
    BoostCleanupRequest,
    BoostCleanupResult,
    BoostPoolView,
    CatalogItem,
    ConfiguredSite,
    SiteBoostPauseUpdate,
    SiteBoostStatsView,
    SiteConfigCreate,
    SiteConfigUpdate,
    SiteProtectionUpdate,
    SiteProxyRequest,
    SiteProxyResponse,
    SiteRatioBoostUpdate,
    SiteStatusUpdate,
    SiteSyncStatsView,
    join_proxy_url,
    proxy_base_url,
    proxy_path_error,
    proxy_response_text,
    proxy_same_origin,
    sanitize_proxy_headers,
    sanitize_proxy_response_headers,
)
from movieclaw_api.services import SiteCatalogService, SiteConfigService, verify_site
from movieclaw_api.services.site_access import SiteUnavailableError, get_site_access
from movieclaw_db.engine import get_session
from movieclaw_db.models.site_credential import SiteCredential
from movieclaw_db.repositories.torrent_repo import TorrentRepository
from movieclaw_tracker.exceptions import TrackerAuthError

router = APIRouter(prefix="/sites", tags=["sites"])


async def _to_view(service: SiteConfigService, row: SiteCredential) -> ConfiguredSite:
    """把 ORM 记录组装成对外视图，并附上该站点的用户资料快照。

    所有返回 ConfiguredSite 的端点都必须走这里带上 profile —— 前端在启停、
    重验等操作后会用响应整体替换本地状态，若响应缺 profile 会把已展示的
    资料"冲掉"。
    """
    return ConfiguredSite.from_model(row, await service.profile_of(row.site_id))


# ---------------------------------------------------------------------------
# 目录（可选项）
# ---------------------------------------------------------------------------


@router.get(
    "/catalog",
    response_model=ApiResponse[list[CatalogItem]],
    summary="列出系统支持的可配置站点及授权要求",
    operation_id="site.catalog",
)
async def list_catalog() -> ApiResponse[list[CatalogItem]]:
    """返回所有"可选项"。前端据此展示可配置的站点，以及每个站点支持的
    授权类型和各自要填的字段。"""
    catalog = SiteCatalogService()
    items = [CatalogItem.from_config(c) for c in catalog.list_catalog()]
    return ok(items)


# ---------------------------------------------------------------------------
# 已配置站点（可用站点）
# ---------------------------------------------------------------------------


@router.get(
    "",
    response_model=ApiResponse[list[ConfiguredSite]],
    summary="列出用户已配置的站点及验证状态",
    operation_id="site.list",
)
async def list_configured(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[ConfiguredSite]]:
    service = SiteConfigService(session)
    rows = await service.list_configured()
    # 一次批量查出全部站点的资料快照再拼装，避免逐站查询（N+1）
    profiles = await service.profiles_of([r.site_id for r in rows])
    return ok([ConfiguredSite.from_model(r, profiles.get(r.site_id)) for r in rows])


@router.get(
    "/sync-stats",
    response_model=ApiResponse[dict[str, SiteSyncStatsView]],
    summary="各站点的种子缓存量与同步节奏",
    operation_id="site.stats",
)
async def list_sync_stats(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[dict[str, SiteSyncStatsView]]:
    """按 site_id 返回定时同步任务维护的本地缓存统计：已缓存种子数、
    上次/下次同步时间、当前轮询间隔等，供站点配置页展示。

    从未同步过且无游标的站点不会出现在结果里，前端按「尚未同步」处理缺失键。
    注意：本路由必须注册在 ``/{site_id}`` 之前，否则会被当成站点 ID 匹配。
    """
    repo = TorrentRepository(session)
    counts = await repo.count_by_site()
    cursors = {c.site_id: c for c in await repo.all_cursors()}
    stats = {
        site_id: SiteSyncStatsView.from_parts(counts.get(site_id, 0), cursors.get(site_id))
        for site_id in counts.keys() | cursors.keys()
    }
    return ok(stats)


@router.get(
    "/boost-pool",
    response_model=ApiResponse[BoostPoolView],
    summary="刷流在池种子概况（按站点，含能否立即清理）",
    operation_id="site.boost-pool.show",
)
async def get_boost_pool(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[BoostPoolView]:
    """还在下载器里的刷流种子：按站点汇总刷流开关 / 暂停、体积，以及现在就能删的与
    还在保留期内的（提前删可能被记 H&R）各有多少；逐种子给出保留期到期时刻与是否已
    请求清理。关闭刷流不会删种，这里是看清残留、决定清理的依据。
    注意：本路由必须注册在 ``/{site_id}`` 之前。"""
    from movieclaw_api.services.ratio_boost import boost_pool_overview

    return ok(await boost_pool_overview(session))


@router.post(
    "/boost-pool/cleanup",
    response_model=ApiResponse[BoostCleanupResult],
    summary="清理残留的刷流种子（连数据删除）",
    operation_id="site.boost-pool.cleanup",
    openapi_extra={"x-cli-dangerous": "destructive"},
)
async def cleanup_boost_pool(
    payload: BoostCleanupRequest,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[BoostCleanupResult]:
    """从下载器删除刷流种子及其数据文件（无法恢复）。默认先关闭目标站点的刷流；
    已过保留期或没下完的立即删，还在保留期内的标记后由引擎到期自动删除——
    ``force=true`` 才立即全删（可能被站点记 H&R）。只动刷流引擎自己抢下的种子，
    用户自己加的、已被订阅 / 手动下载接管的永远不碰。"""
    result = await SiteConfigService(session).cleanup_boost_pool(
        site_ids=payload.site_ids, disable_boost=payload.disable_boost, force=payload.force
    )
    parts = (
        [t("settings.sites.boostDeleted", count=result.deleted_count)]
        if result.deleted_count
        else []
    )
    if result.scheduled_count:
        parts.append(t("settings.sites.boostDeferred", count=result.scheduled_count))
    if result.failed_count:
        parts.append(t("settings.sites.boostCleanupRetry", count=result.failed_count))
    return ok(
        result,
        message=t("common.list.issueSeparator").join(parts) or t("settings.sites.noBoostCleanup"),
    )


@router.get(
    "/boost-stats",
    response_model=ApiResponse[dict[str, SiteBoostStatsView]],
    summary="各站点的刷流运行统计",
    operation_id="site.boost-stats",
)
async def list_boost_stats(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[dict[str, SiteBoostStatsView]]:
    """按 site_id 返回刷流台账聚合：在池任务数/占用、累计上传、汰换数。

    从未有过刷流任务且未开刷流的站点不会出现在结果里。
    注意：本路由必须注册在 ``/{site_id}`` 之前，否则会被当成站点 ID 匹配。
    """
    from movieclaw_api.services.ratio_boost import collect_boost_stats

    return ok(await collect_boost_stats(session))


@router.get(
    "/{site_id}",
    response_model=ApiResponse[ConfiguredSite],
    summary="获取单个已配置站点详情",
    operation_id="site.show",
)
async def get_configured(
    site_id: str,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ConfiguredSite]:
    service = SiteConfigService(session)
    row = await service.get_configured(site_id)
    return ok(await _to_view(service, row))


@router.post(
    "",
    response_model=ApiResponse[ConfiguredSite],
    summary="配置一个站点（保存后异步验证）",
    operation_id="site.add",
)
async def configure_site(
    payload: SiteConfigCreate,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ConfiguredSite]:
    """保存站点授权信息（状态置为 pending），并在后台异步发起有效性验证。

    接口立即返回，调用方可轮询站点详情（CLI：mclaw site show <id>）观察 status 变化：
    pending → verifying → active（可用）/ failed（见 last_error）。
    """
    service = SiteConfigService(session)
    await service.configure(
        site_id=payload.site_id,
        auth_type=payload.auth_type,
        cookie=payload.cookie,
        api_key=payload.api_key,
        username=payload.username,
        password=payload.password,
        enabled=payload.enabled,
    )
    # 同步占位为 VERIFYING（关闭并发窗口），再排队后台任务执行真实验证
    row = await service.start_verification(payload.site_id)
    background_tasks.add_task(verify_site, payload.site_id)
    return ok(await _to_view(service, row), message=t("settings.sites.created"))


@router.put(
    "/{site_id}",
    response_model=ApiResponse[ConfiguredSite],
    summary="更新站点授权信息（更新后重新异步验证）",
    operation_id="site.update",
)
async def update_site(
    site_id: str,
    payload: SiteConfigUpdate,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ConfiguredSite]:
    service = SiteConfigService(session)
    await service.configure(
        site_id=site_id,
        auth_type=payload.auth_type,
        cookie=payload.cookie,
        api_key=payload.api_key,
        username=payload.username,
        password=payload.password,
        enabled=payload.enabled,
    )
    row = await service.start_verification(site_id)
    background_tasks.add_task(verify_site, site_id)
    return ok(await _to_view(service, row), message=t("settings.sites.updated"))


@router.patch(
    "/{site_id}/status",
    response_model=ApiResponse[ConfiguredSite],
    summary="启用 / 停用站点",
    operation_id="site.status.set",
)
async def set_site_status(
    site_id: str,
    payload: SiteStatusUpdate,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ConfiguredSite]:
    service = SiteConfigService(session)
    row = await service.set_enabled(site_id, payload.enabled)
    return ok(await _to_view(service, row))


@router.patch(
    "/{site_id}/protection",
    response_model=ApiResponse[ConfiguredSite],
    summary="打开 / 关闭站点保护",
    operation_id="site.protection.set",
)
async def set_site_protection(
    site_id: str,
    payload: SiteProtectionUpdate,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ConfiguredSite]:
    """保护开关：打开后订阅链路（被动匹配/缺口搜索/换源/洗版）不再选中该站点，
    但手动搜索、手动下载、种子同步照常。用于分享率尚未养起来的新站点。"""
    service = SiteConfigService(session)
    row = await service.set_protected(site_id, payload.protected)
    return ok(await _to_view(service, row))


@router.patch(
    "/{site_id}/ratio-boost",
    response_model=ApiResponse[ConfiguredSite],
    summary="设置自动刷分享率（开关、存储预算与刷流下载器）",
    operation_id="site.ratio-boost.set",
)
async def set_site_ratio_boost(
    site_id: str,
    payload: SiteRatioBoostUpdate,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ConfiguredSite]:
    """开启后引擎自动抢站点新发布的免费种子做种，在预算内汰换低效任务。
    机制与安全约束见 docs/design/site-protection-ratio-boost.md。"""
    service = SiteConfigService(session)
    row = await service.set_ratio_boost(
        site_id,
        enabled=payload.enabled,
        budget_bytes=payload.budget_bytes,
        hold_days=payload.hold_days,
        downloader_id=payload.downloader_id,
    )
    return ok(await _to_view(service, row))


@router.patch(
    "/{site_id}/ratio-boost/pause",
    response_model=ApiResponse[ConfiguredSite],
    summary="暂停 / 恢复站点刷流",
    operation_id="site.ratio-boost.pause",
)
async def set_site_boost_paused(
    site_id: str,
    payload: SiteBoostPauseUpdate,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ConfiguredSite]:
    """刷流上行占满带宽影响前台使用（如看视频）时的临时闸：暂停会把该站
    在池做种批量压到极低上传限速，并停止汰换与拉新种（任务与数据全部保留）；
    恢复则解除限速、回到正常刷流节奏。与关闭刷流不同，暂停随时可无损恢复。"""
    service = SiteConfigService(session)
    row = await service.set_boost_paused(site_id, payload.paused)
    return ok(
        await _to_view(service, row),
        message=t("settings.sites.boostPaused")
        if payload.paused
        else t("settings.sites.boostResumed"),
    )


@router.post(
    "/{site_id}/verify",
    response_model=ApiResponse[ConfiguredSite],
    summary="手动重新触发验证",
    operation_id="site.verify",
)
async def reverify_site(
    site_id: str,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ConfiguredSite]:
    """手动触发一次验证（如站点临时故障后想重试）。

    行为：站点未配置 → 404；已在验证中 → 409（避免重复触发）；否则同步占位为
    VERIFYING 并在后台重新走验证流程。"""
    service = SiteConfigService(session)
    row = await service.start_verification(site_id)  # 404/409/占位一步到位
    background_tasks.add_task(verify_site, site_id)
    return ok(await _to_view(service, row), message=t("settings.sites.retested"))


@router.post(
    "/{site_id}/proxy",
    response_model=ApiResponse[SiteProxyResponse],
    summary="借宿主已认证会话对站点发一个请求（凭据不出宿主）",
    operation_id="site.proxy.request",
    # 能以用户的站点身份发任意 POST：插件要逐个声明并经用户批准（通配不覆盖），
    # CLI 要 --yes（docs/design/plugin-extension-model.md §3.2）
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def proxy_site_request(
    site_id: str,
    payload: SiteProxyRequest,
) -> ApiResponse[SiteProxyResponse]:
    """站点代请求：调用方（插件）声明想对站点发什么请求，宿主用它自己的已认证
    会话执行并回传脱敏后的响应。给保活/签到类插件复用站点登录态用。

    安全边界：``path`` 只能是站内相对路径（完整 URL 由宿主按站点注册的域名拼接，
    防 SSRF）；``headers`` 里认证相关头（cookie / authorization / x-api-key）被剥除，
    由宿主会话统一附加；响应剥掉 set-cookie 等凭据头、正文按上限截断；站点回 3xx
    时不跟随、原样返回（认证头不会跟着跳转带到别的主机）。

    行为：站点未配置 / 停用 / 未验证通过 → 409（可读中文原因）；认证失败 → 409
    （凭据已失效）；超时 / 连不上 → 503。
    """
    from movieclaw_tracker.exceptions import SiteNotFoundError
    from movieclaw_tracker.registry import get_site_config

    if (reason := proxy_path_error(payload.path)) is not None:
        raise BadRequestException(reason)
    try:
        config = get_site_config(site_id)
    except SiteNotFoundError:
        raise NotFoundException(
            message_key="errors.network.siteUnknown", params={"id": site_id}
        ) from None
    base = proxy_base_url(config, payload.base)
    url = join_proxy_url(base, payload.path)
    if not proxy_same_origin(base, url):
        raise BadRequestException(message_key="errors.sites.relativePathRequired")

    try:
        site = await get_site_access().get(site_id)
    except SiteUnavailableError as exc:
        raise ConflictException(**exception_fields(exc)) from exc
    except TrackerAuthError as exc:
        raise ConflictException(
            message_key="errors.sites.authenticationFailed", params={"error": exc.message}
        ) from exc

    headers = sanitize_proxy_headers(payload.headers)
    # POST 体：字典按 JSON 发；字符串按原始内容发（调用方自带 content-type）
    json_body: Any = payload.body if isinstance(payload.body, dict) else None
    content: str | None = payload.body if isinstance(payload.body, str) else None

    try:
        response = await site.client.raw_request(
            payload.method,
            url,
            headers=headers or None,
            json=json_body,
            content=content,
            timeout=payload.timeout_seconds,
            # 站点客户端默认跟随跳转，而 x-api-key 这类认证头挂在客户端的默认头上：
            # 站点若有开放重定向，跟到外站就会把它带出去。校验只做了发请求前这一次
            follow_redirects=False,
        )
    except httpx.TimeoutException as exc:
        raise ServiceUnavailableException(
            message_key="errors.sites.requestTimeout",
            params={"seconds": f"{payload.timeout_seconds:g}"},
        ) from exc
    except httpx.TransportError as exc:
        raise ServiceUnavailableException(
            message_key="errors.sites.connectionFailed", params={"error": exc}
        ) from exc

    content_type = str(response.headers.get("content-type", ""))
    text, truncated = proxy_response_text(response.content, content_type)
    parsed: Any = None
    if text is not None and "json" in content_type.lower():
        try:
            parsed = json.loads(text) if not truncated else None
        except ValueError:
            parsed = None
    return ok(
        SiteProxyResponse(
            status_code=response.status_code,
            headers=sanitize_proxy_response_headers(response.headers),
            text=text,
            json_body=parsed,
            truncated=truncated,
        )
    )


@router.delete(
    "/{site_id}",
    response_model=ApiResponse[dict],
    summary="删除站点配置（连带清理 cookie 缓存）",
    operation_id="site.delete",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def delete_site(
    site_id: str,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[dict]:
    service = SiteConfigService(session)
    await service.delete(site_id)
    return ok({"site_id": site_id}, message=t("settings.sites.deleted"))
