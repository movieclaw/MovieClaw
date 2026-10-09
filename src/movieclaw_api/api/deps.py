from __future__ import annotations

import hmac

from fastapi import Cookie, Depends, Header, WebSocketException, status
from starlette.requests import HTTPConnection

from movieclaw_api.api.client_address import client_address
from movieclaw_api.exceptions import AppException, ForbiddenException, UnauthorizedException
from movieclaw_api.services import auth as auth_service
from movieclaw_api.services import demo as demo_service
from movieclaw_api.services.auth import Principal
from movieclaw_api.settings.schemas import get_sync_setting
from movieclaw_kernel import Origin, current_origin


async def demo_guard(connection: HTTPConnection) -> None:
    """公开演示站的只读守卫（docs/design/demo-site.md）：挂在全部业务路由上。

    未开演示模式时直接放行。开了之后按路由的 operation_id 判定：写请求默认
    拒绝、只放行白名单；少数读接口（目录浏览、日志……）也拒绝。判定表与理由
    文案都在 services/demo.py，这里只负责把结论变成 403。

    放在路由级依赖而不是 ASGI 中间件：依赖里拿得到已匹配的路由（operation_id
    是稳定标识，比按路径正则匹配可靠），抛出的业务异常也走统一的错误响应格式。
    唯一的 WebSocket 路由（转码 Worker 控制面）演示站用不上，直接拒绝握手。
    """
    if not demo_service.is_demo_mode():
        return
    if connection.scope.get("type") == "websocket":
        raise WebSocketException(
            code=status.WS_1008_POLICY_VIOLATION, reason="演示站不支持转码 Worker 接入"
        )
    route = connection.scope.get("route")
    operation_id = getattr(route, "operation_id", None) or ""
    method = connection.scope.get("method", "GET")
    reason = demo_service.rejection_for(method, operation_id)
    # 审核账号（demo-site.md §9）：只在要拒绝时才看凭证，公开访客的请求不多付一次计算
    if reason is not None and demo_service.is_review_token(_presented_token(connection)):
        reason = demo_service.review_rejection_for(method, operation_id)
    if reason is not None:
        raise AppException(status_code=403, code=demo_service.DEMO_READ_ONLY_CODE, message=reason)


def _presented_token(connection: HTTPConnection) -> str | None:
    """请求带的登录凭证：App 走 Authorization Bearer，网页走会话 Cookie。"""
    bearer = _extract_bearer(connection.headers.get("authorization"))
    return bearer or connection.cookies.get(auth_service.SESSION_COOKIE_NAME)


def _extract_bearer(authorization: str | None) -> str | None:
    """从 Authorization 头中取出 Bearer 令牌；格式不符返回 None。"""
    if not authorization:
        return None
    scheme, _, value = authorization.partition(" ")
    if scheme.lower() != "bearer" or not value:
        return None
    return value.strip()


async def require_sync_token(authorization: str | None = Header(default=None)) -> None:
    """扩展侧接口的鉴权依赖：校验请求头里的同步令牌。

    校验流程：
    1. 后端从未生成令牌（同步未启用）→ 401，提示先去后台生成令牌。
    2. 请求未带 Bearer 令牌或与后端不一致 → 401，提示令牌无效/已重置。

    比较使用 ``hmac.compare_digest`` 做常量时间比较，避免时序侧信道。
    错误信息为清晰中文，方便非开发者按提示操作。
    """
    setting = await get_sync_setting()
    if not setting.token:
        raise UnauthorizedException("后端未启用同步，请先在后台生成令牌")

    provided = _extract_bearer(authorization)
    if not provided or not hmac.compare_digest(provided, setting.token):
        raise UnauthorizedException("令牌无效或已重置，请重新填写")


async def optional_login(
    connection: HTTPConnection,
    session_token: str | None = Cookie(default=None, alias=auth_service.SESSION_COOKIE_NAME),
    authorization: str | None = Header(default=None),
) -> Principal | None:
    """解析可选登录主体；未携带凭据返回 None，携带无效凭据仍返回 401。

    仅用于少量“匿名可读、登录后按账号分流”的接口，例如背景图库。不能用它
    替代业务接口的 ``require_login``，否则会把默认拒绝边界改成匿名放行。

    来源地址与 User-Agent 顺带交给验签：登录设备的「最近活跃」据此记录
    （按分钟节流落盘），「我的设备」页才答得出这台设备最近在哪儿用过。
    """
    ip = client_address(connection) or None  # type: ignore[arg-type]
    user_agent = connection.headers.get("user-agent")
    principal: Principal | None = None
    if session_token:
        principal = await auth_service.verify_cookie_token(
            session_token, ip=ip, user_agent=user_agent
        )
    elif bearer := _extract_bearer(authorization):
        principal = await auth_service.verify_bearer_token(bearer, ip=ip, user_agent=user_agent)
    if principal is not None:
        _attribute(principal)
    return principal


def _attribute(principal: Principal) -> None:
    """把请求主体记成本次请求的发起方（插件内核的因果链，docs/design/plugin-phase2a.md §3）。

    这次请求里写下的可靠事件据此带上「谁触发的」：插件能认出自己引起的事件，因果链上限也能
    穿过宿主操作生效（插件经 ASGI 调本进程接口时，上下文里已经带着它的因果链）。
    """
    origin = current_origin.get()
    if principal.plugin is not None:
        current_origin.set(Origin(kind="plugin", id=principal.plugin.entry_id, chain=origin.chain))
    elif origin.kind == "system" and not origin.chain:
        if principal.kind == "member":
            current_origin.set(Origin(kind="member", id=str(principal.member_id)))
        elif principal.kind == "admin":
            current_origin.set(Origin(kind="user", id=principal.name))
        else:
            current_origin.set(Origin(kind=principal.kind, id=principal.name))


async def require_login(
    connection: HTTPConnection,
    principal: Principal | None = Depends(optional_login),
) -> Principal:
    """业务接口的登录鉴权依赖：会话 Cookie **或** Bearer 令牌，返回请求主体。

    两条通道（docs/design/cli.md §8.1）：
    - Web 端：会话 Cookie（超管或成员，由令牌负载区分）；
    - CLI / 产品内 Agent：``Authorization: Bearer <令牌>``——PAT 长期令牌
      或 Agent 短时效签名令牌，同一验签入口。

    全站默认拒绝的执行点——除公开白名单与浏览器扩展侧接口外，所有路由都必须挂
    本依赖（api/router.py 按组挂载，tests 里有守护测试兜底防漏挂）。
    未登录 / 会话过期 / 令牌无效统一 401。授权（管理员/能力开关）不在
    这里判——挂 ``require_admin`` 或在服务层消费 Principal。

    唯一的例外是**转码器凭证的形态上限**（docs/design/device-auth.md §4.3）：
    scope=transcode 的凭证只为转码链路签发，在这里直接拒绝。这样做是默认拒绝而
    不是白名单枚举——新增的任何业务路由只要照常挂本依赖，就自动把转码器凭证挡在
    外面，不需要记得给它加标注。放行它的白名单只有两处：``resolve_worker_principal``
    （转码控制面）与 ``require_device_principal``（注销自己）。
    """
    if principal is None:
        raise UnauthorizedException("未登录，请先登录")
    if principal.device is not None and principal.device.scope == "transcode":
        raise ForbiddenException("转码器的凭证只能用于转码，不能访问业务接口")
    if principal.plugin is not None:
        # 插件主体按操作授权：只放行授权集合里的 operationId（同样是默认拒绝）
        route = connection.scope.get("route")
        operation_id = getattr(route, "operation_id", None)
        if operation_id is None or operation_id not in principal.plugin.operations:
            raise AppException(
                status_code=403,
                code="PLUGIN_OPERATION_DENIED",
                message=(
                    f"插件 {principal.plugin.entry_id} 没有获得调用 "
                    f"{operation_id or connection.url.path} 的授权"
                ),
            )
    return principal


async def require_device_principal(
    principal: Principal | None = Depends(optional_login),
) -> Principal:
    """「管理我自己这台设备」的接口专用：任何登录设备的凭证都行，含转码器。

    注销自己是所有凭证都该有的能力——命令行 ``mclaw logout``、转码器「断开并
    重新配置」都要能在服务端把自己作废，而不是只删本地文件、留一枚还能用的
    令牌在服务端。升级前的签名会话 Cookie 没有设备行，这里返回 404 由调用方说明。
    """
    if principal is None:
        raise UnauthorizedException("未登录，请先登录")
    return principal


async def resolve_worker_principal(
    authorization: str | None, *, ip: str | None = None, user_agent: str | None = None
) -> Principal | None:
    """从 Authorization 头解析转码器主体；不是转码凭证（scope=transcode）一律返回 None。

    抽成普通函数是因为 WebSocket 与 HTTP 两条入口要共用它：WS 握手不能抛
    HTTPException（只能关连接并给关闭码），FastAPI 的依赖那套在那里用不上。
    判定逻辑只此一份，两边不会走偏。
    """
    token = _extract_bearer(authorization)
    if not token:
        return None
    try:
        principal = await auth_service.verify_bearer_token(token, ip=ip, user_agent=user_agent)
    except UnauthorizedException:
        return None
    if principal.device is None or principal.device.scope != "transcode":
        return None
    return principal


async def require_transcode_worker(
    authorization: str | None = Header(default=None),
) -> Principal:
    """转码控制面专用：只接受 Worker 令牌。

    与 ``require_login`` 互补——业务接口拒绝 Worker，转码接口只认 Worker。
    两边都是显式判定，不存在「既能转码又能改订阅」的凭证。
    """
    principal = await resolve_worker_principal(authorization)
    if principal is None:
        raise UnauthorizedException("需要转码 Worker 凭证，请在 Worker 应用里完成配对")
    return principal


async def require_admin(principal: Principal = Depends(require_login)) -> Principal:
    """管理员鉴权依赖：在登录之上断言管理员身份，成员访问一律 403。

    与守护测试的契约（tests/api/test_member_auth.py）：不在成员白名单里的
    路由必须由本依赖（或服务层等价判定）挡住成员——新增管理路由挂本依赖
    即自动满足契约。
    """
    if not principal.is_admin:
        raise ForbiddenException("该操作需要管理员权限")
    return principal


async def require_interactive(principal: Principal = Depends(require_login)) -> Principal:
    """要求「人在第一方客户端里亲自操作」（浏览器或 App），成员也可以。

    用在两类接口上：**签发凭证**（批准配对、创建令牌）与**管理别的设备**
    （列出、改名、注销他人的设备）。按客户端类型判断而不是按登录方式
    （docs/design/login-devices.md「签发权」）：

    - 程序类客户端（命令行、转码器、手工令牌、Agent、MCP）一旦能签发新凭证，
      泄露的令牌就能给自己造一枚备份，注销原来那枚也止不住损——而注销是这套
      设计唯一的事后止损手段；
    - 它们也不能注销别的设备：一枚泄露的命令行令牌不该能把主人的手机踢下线。
      注销**自己**不受此限，见 ``require_device_principal``。
    """
    if not principal.interactive:
        raise ForbiddenException(
            "这个操作只能由人在网页或 App 里完成，命令行、转码器与 Agent 的凭证不能执行"
        )
    return principal


async def require_admin_session(
    principal: Principal = Depends(require_admin),
) -> Principal:
    """管理员 + 人在第一方客户端里亲自操作（浏览器或 App），见 ``require_interactive``。

    用于只有超管才能做的凭证签发：手工创建令牌、签发 / 轮换 MCP 端点令牌。
    """
    if not principal.interactive:
        raise ForbiddenException(
            "签发凭证只能由人在网页或 App 里完成，请用管理员账号登录 movieclaw 后操作"
        )
    return principal


async def require_search_capability(
    principal: Principal = Depends(require_login),
) -> Principal:
    """站点搜索能力依赖：管理员直通；成员须开启 ``allow_search`` 开关。

    搜索消耗站点配额、暴露站点存在，因此默认对成员关闭，由管理员在成员
    管理页逐人开启（docs/design/member-management.md §2.2）。
    """
    if principal.is_admin:
        return principal
    if principal.member is None or not principal.member.allow_search:
        raise ForbiddenException("管理员未对你开放站点搜索，请联系管理员开启")
    return principal


async def require_subscribe_capability(
    principal: Principal = Depends(require_login),
) -> Principal:
    """订阅能力依赖：管理员直通；成员须开启 ``allow_subscribe`` 开关。"""
    if principal.is_admin:
        return principal
    if principal.member is None or not principal.member.allow_subscribe:
        raise ForbiddenException("管理员未对你开放订阅功能，请联系管理员开启")
    return principal


async def require_direct_download_capability(
    principal: Principal = Depends(require_login),
) -> Principal:
    """一键下载能力依赖：管理员直通；成员须开启 ``allow_direct_download``。

    成员版一键下载还会在服务端强制自动路由（拒绝手选 save_path），
    见 routes/downloaders.py 的 submit 处理器。
    """
    if principal.is_admin:
        return principal
    if principal.member is None or not principal.member.allow_direct_download:
        raise ForbiddenException("管理员未对你开放一键下载，请联系管理员开启")
    return principal
