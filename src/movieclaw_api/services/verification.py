from __future__ import annotations

import logging

import httpx

from movieclaw_api.i18n.stored import source_text, stored_fields
from movieclaw_api.services.auth_factory import build_auth_provider
from movieclaw_api.services.site_access import invalidate_site_access
from movieclaw_db.engine import get_database
from movieclaw_db.models.site_credential import ConfigStatus
from movieclaw_db.repositories.credential_repo import CredentialRepository
from movieclaw_db.repositories.profile_repo import ProfileRepository
from movieclaw_db.stores import SqlCookieStore
from movieclaw_tracker import create_site
from movieclaw_tracker.exceptions import (
    TrackerAuthError,
    TrackerNetworkError,
    TrackerParseError,
)

logger = logging.getLogger("movieclaw_api.verification")


def friendly_error_message(exc: Exception) -> dict:
    """Keep a Chinese fallback and semantic reference for a site failure."""
    if isinstance(exc, TrackerAuthError):
        return stored_fields("errors.siteDiagnostic.auth", error=exc.message_ref or exc.message)
    if isinstance(exc, (TrackerNetworkError, httpx.TimeoutException, httpx.ConnectError)):
        return stored_fields("errors.siteDiagnostic.network")
    if isinstance(exc, TrackerParseError):
        if (exc.details or {}).get("login_redirect"):
            return stored_fields("errors.siteDiagnostic.loginRedirect")
        return stored_fields("errors.siteDiagnostic.parse")
    if isinstance(exc, httpx.HTTPStatusError):
        code = exc.response.status_code
        if exc.response.headers.get("cf-mitigated") == "challenge":
            return stored_fields("errors.siteDiagnostic.challenge", code=code)
        if code in (401, 403):
            return stored_fields("errors.siteDiagnostic.forbidden", code=code)
        if code == 429:
            return stored_fields("errors.siteDiagnostic.rateLimited", code=code)
        if code >= 500:
            return stored_fields("errors.siteDiagnostic.unavailable", code=code)
        return stored_fields("errors.siteDiagnostic.http", code=code)
    return stored_fields("errors.siteDiagnostic.unknown", kind=type(exc).__name__, error=str(exc))


def friendly_error(exc: Exception) -> str:
    """Chinese compatibility value for existing verification/history producers."""
    return friendly_error_message(exc)["message"]


def is_transient_error(exc: Exception) -> bool:
    """判断失败是否为「瞬时故障」——站点/网络暂时不可用，等待即可自愈。

    这是失败降级策略的分流依据（见 torrent_sync）：
    - **瞬时**（返回 True）：网络不可达、超时、5xx（含 Cloudflare 520-526）、429 限流。
      处理方式是指数退避后重试，**不作废**已认证会话——对着挂掉的站反复重登录
      既无意义，还可能触发站点的登录频控。
    - **非瞬时**（返回 False）：认证失败、其余 4xx、解析异常（可能站点改版，也可能
      凭据失效被重定向到登录页）。此时作废共享会话，下轮重建并重新认证以自愈。
    """
    if isinstance(exc, (TrackerNetworkError, httpx.TransportError)):
        # httpx.TransportError 覆盖 ConnectError / ReadError / TimeoutException 等
        return True
    if isinstance(exc, httpx.HTTPStatusError):
        code = exc.response.status_code
        return code >= 500 or code == 429
    return False


async def verify_site(site_id: str) -> None:
    """异步验证某站点配置是否真实可用，并把结论写回状态字段。

    验证判据：用配置的凭据实际认证，再拉取一次用户资料 —— 能拿到用户名，
    就证明凭据真实有效（这一判据对 cookie / 账号密码 / API-Key 都成立，
    因为 get_user_profile 会发起需要认证的真实请求）。

    前置约定：调用本函数前，站点状态**已被 start_verification 同步置为 VERIFYING**
    （并发守卫需要在请求内就抢占该状态）。因此这里不再改 VERIFYING，只负责跑验证
    并写最终结论。

    本函数被设计为"背景任务"，因此：
    - **自开独立数据库会话**：不复用已随请求关闭的会话。
    - **绝不向外抛异常**：任何失败都转成 FAILED 状态 + last_error 记录，
      否则会变成无人处理的后台异常。

    状态流转（由本函数负责的部分）：VERIFYING → ACTIVE / FAILED。
    """
    db = get_database()

    # 1. 读取待验证凭据快照（独立短会话）
    async with db.session() as session:
        repo = CredentialRepository(session)
        credential = await repo.get_by_site(site_id)
        if credential is None:
            logger.warning("待验证的站点配置不存在，跳过：site=%s", site_id)
            return
        # 取出验证需要的快照（会话关闭后仍可用，expire_on_commit=False 已保证）
        credential_snapshot = credential

    # 2. 执行真实认证 + 拉取资料
    status = ConfigStatus.FAILED
    error: str | None = None
    error_ref: dict | None = None
    profile = None  # 验证成功时保留资料，稍后落库为站点资料快照
    site = None
    try:
        provider = build_auth_provider(credential_snapshot)
        site = await create_site(
            site_id,
            auth_provider=provider,
            cookie_store=SqlCookieStore(),
        )
        auth_result = await site.authenticate()
        if not auth_result.success:
            error = auth_result.message or source_text("errors.siteDiagnostic.authNotPassed")
            reason = getattr(auth_result, "message_ref", None)
            if reason:
                error_ref = {"message": error, **reason}
            elif not auth_result.message:
                error_ref = stored_fields("errors.siteDiagnostic.authNotPassed")
        else:
            profile = await site.get_user_profile()
            if profile and profile.username:
                status = ConfigStatus.ACTIVE
                logger.info("站点验证成功：site=%s 用户=%s", site_id, profile.username)
            else:
                error = source_text("errors.siteDiagnostic.profileMissing")
                error_ref = stored_fields("errors.siteDiagnostic.profileMissing")
    except Exception as exc:  # noqa: BLE001 -- 背景任务需吞掉所有异常并记录原因
        error_ref = friendly_error_message(exc)
        error = error_ref["message"]
        # 日志里保留完整堆栈便于开发者排查，落库的 last_error 则是友好中文
        logger.warning("站点验证失败：site=%s，原因：%s", site_id, error, exc_info=True)
    finally:
        # 关闭 HTTP 连接，避免验证过程遗留未释放的连接
        if site is not None:
            try:
                await site.client.close()
            except Exception:  # noqa: BLE001
                logger.debug("关闭站点 HTTP 客户端时出错（忽略）", exc_info=True)

    # 3. 写回最终结论（又一个独立短会话）
    async with db.session() as session:
        repo = CredentialRepository(session)
        await repo.update_status(site_id, status, last_error=error, last_error_ref=error_ref)
        # 全局红灯：凭据失效意味着该站点的搜索/投递静默缺席，必须被感受到；
        # 验证恢复则红灯熄灭
        from movieclaw_api.services.system_notice import resolve_notices, upsert_notice
        from movieclaw_db.models import NoticeSeverity

        if status == ConfigStatus.ACTIVE:
            await resolve_notices(session, dedupe_key=f"site:{site_id}")
            # 复位同步游标的失败状态：熔断/连续失败留下的旧错误文案与小时级
            # 退避排期，在凭据重验成功后已无意义——清掉并标记立即到期，
            # 下一个 tick（≤2 分钟）即恢复同步，页面不再挂着过时的失败提示
            from movieclaw_db.repositories.torrent_repo import TorrentRepository

            await TorrentRepository(session).reset_failure_state(site_id)
        else:
            await upsert_notice(
                session,
                dedupe_key=f"site:{site_id}",
                severity=NoticeSeverity.ERROR,
                source="site",
                title_key="notify.siteVerification.title",
                message_key="notify.siteVerification.body",
                message_params={
                    "site": site_id,
                    "reason": error_ref
                    or error
                    or {"message_key": "notify.siteVerification.unknown"},
                },
                payload={"site_id": site_id},
            )
        # 验证成功时顺手把刚拉到的用户资料落为快照（零额外站点请求）；
        # 失败不动旧快照，保留上一次成功的数据供页面继续展示
        if status == ConfigStatus.ACTIVE and profile is not None:
            await ProfileRepository(session).upsert(
                site_id=site_id,
                user_id=profile.user_id,
                username=profile.username,
                user_class=profile.user_class,
                uploaded_bytes=profile.uploaded_bytes,
                downloaded_bytes=profile.downloaded_bytes,
                ratio=profile.ratio,
                bonus=profile.bonus,
                seeding_count=profile.seeding_count,
                leeching_count=profile.leeching_count,
                avatar_url=profile.avatar_url,
                join_date=profile.join_date,
            )
    # 4. 验证结论已变（尤其转 ACTIVE）：作废共享缓存，下次访问按新状态/新会话重建
    await invalidate_site_access(site_id)
