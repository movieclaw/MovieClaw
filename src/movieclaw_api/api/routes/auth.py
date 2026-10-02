"""登录鉴权路由：首次初始化、登录、登出、会话查询、修改密码。

安全分区（与 api/router.py 的三分区对应）：
- 公开：GET/POST /auth/bootstrap、POST /auth/login、POST /auth/logout。
  其中 POST /auth/bootstrap 由服务层的一次性锁自我封闭（管理员已存在即 409），
  logout 只是清 Cookie，无需登录也无危害（会话过期后也能顺利登出）。
- 登录后：GET /auth/me、PUT /auth/password、PUT /auth/profile、
  POST/GET /auth/avatar（头像上传与读取；头像属于个人信息，读取也要求登录，
  同源部署下 <img> 自动携带会话 Cookie，前端零改造）、
  GET/POST/DELETE /auth/accounts*（多账号列表 / 切换 / 移除）。

会话凭证放 HttpOnly Cookie（同源部署下前端零改造自动携带；XSS 偷不走，
SameSite=Lax 挡跨站请求伪造）。Cookie 里装的是一枚登录设备令牌
（docs/design/login-devices.md）：网页每次登录都是「我的设备」里的一行，
退出登录即作废这一行，不再只是删掉浏览器里的 Cookie。

登录设备（原生 App、命令行、转码器）走同一张表：
- POST /auth/device/login：App 用账号密码换设备令牌（公开，限速同网页登录）；
- /auth/device/authorize、/auth/device/token：命令行、转码器的配对流（公开）；
- /auth/devices*：「我的设备」列表、改名、注销，按配对码批准 / 拒绝。

多账号（docs/design/account-switching.md）：除激活会话 Cookie 外，还有一个同样
HttpOnly 的"账号袋" Cookie 装着本浏览器登录过的全部会话令牌。登录总是并入袋子，
切换账号就是把袋子里的一枚令牌写回激活 Cookie——鉴权层只认激活 Cookie，零改动。
"""

from __future__ import annotations

import logging
import time

from fastapi import APIRouter, Depends, File, Query, Request, Response, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.api.client_address import client_address
from movieclaw_api.api.deps import (
    require_admin_session,
    require_device_principal,
    require_interactive,
    require_login,
)
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import (
    BadRequestException,
    ForbiddenException,
    NotFoundException,
    UnauthorizedException,
)
from movieclaw_api.schemas.auth import (
    AccountView,
    ApiTokenCreatedView,
    ApiTokenCreateRequest,
    BootstrapRequest,
    BootstrapStatus,
    ChangePasswordRequest,
    DeviceAuthorizeRequest,
    DeviceAuthorizeView,
    DeviceBrief,
    DeviceLoginRequest,
    DeviceLoginView,
    DeviceRequestView,
    DeviceTokenRequest,
    DeviceTokenView,
    LoginDeviceView,
    LoginRequest,
    LogoutRequest,
    RenameDeviceRequest,
    SessionCapabilities,
    SessionView,
    SwitchAccountRequest,
    UpdateProfileRequest,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services import auth as auth_service
from movieclaw_api.services import avatar as avatar_media
from movieclaw_api.services import login_devices
from movieclaw_api.services import members as members_service
from movieclaw_api.services.auth import Principal, SavedAccount
from movieclaw_api.settings import (
    AdminAccountSetting,
    AppServerSetting,
    get_setting_store,
    mark_initialized,
)
from movieclaw_db.engine import get_database, get_session
from movieclaw_db.models import JellyfinDevice
from movieclaw_db.models.login_device import LoginDevice
from movieclaw_db.models.member import Member

logger = logging.getLogger("movieclaw_api.auth")

router = APIRouter(prefix="/auth", tags=["auth"])


def _avatar_url(stem: str | None = None) -> str | None:
    """构造头像的带版本号相对地址；未上传过头像时返回 None（前端显示首字徽标）。

    版本号取文件 mtime 纳秒值：换头像 → URL 变化，绕开浏览器 <img> 缓存。
    超管与成员共用 GET /auth/avatar 端点（各读各的槽位），URL 形态一致。
    """
    version = (
        avatar_media.avatar_version(stem) if stem else avatar_media.avatar_version()
    )
    if version is None:
        return None
    return f"{get_settings().api_v1_prefix}/auth/avatar?v={version}"


def _session_view(account: AdminAccountSetting) -> SessionView:
    """超管账号 → 会话视图。老账号可能没存过昵称（字段后加的），回退到用户名。"""
    return SessionView(
        username=account.username,
        nickname=account.nickname or account.username,
        avatar_url=_avatar_url(),
        role="admin",
        capabilities=SessionCapabilities(),
    )


def _member_session_view(member: Member) -> SessionView:
    """成员行 → 会话视图（能力开关快照供前端裁剪入口，安全边界仍在后端）。"""
    return SessionView(
        username=member.username,
        nickname=member.nickname or member.username,
        avatar_url=_avatar_url(avatar_media.member_stem(member.id)),
        role="member",
        capabilities=SessionCapabilities(
            allow_subscribe=member.allow_subscribe,
            allow_search=member.allow_search,
            allow_direct_download=member.allow_direct_download,
        ),
    )


async def _principal_session_view(principal: Principal) -> SessionView:
    """请求主体 → 会话视图。成员主体已携带成员行；其余（含 Agent）按超管展示。
    带上本次请求所用的登录设备，客户端据此标出「当前设备」。"""
    if principal.kind == "member" and principal.member is not None:
        view = _member_session_view(principal.member)
    else:
        view = _session_view(await auth_service.get_admin_account())
    if principal.device is not None:
        view.device = DeviceBrief(
            id=login_devices.playback_device_id(principal.device.id),
            kind=principal.device.kind,
            name=principal.device.name,
        )
    return view


async def _issue_web_session(
    request: Request, *, owner_id: int, remember: bool
) -> tuple[str, int]:
    """网页登录：签发一枚浏览器会话令牌（「我的设备」里的一行），返回 (令牌, 有效秒数)。"""
    max_age = (
        auth_service.SESSION_TTL_REMEMBER_SECONDS if remember else auth_service.SESSION_TTL_SECONDS
    )
    token = await login_devices.issue_web_session(
        member_id=owner_id,
        ttl_seconds=max_age,
        user_agent=request.headers.get("user-agent"),
        ip=client_address(request) or None,
    )
    return token, max_age


def _set_session_cookie(response: Response, token: str, max_age: int) -> None:
    """统一的会话 Cookie 写入口，安全属性集中在这一处维护。"""
    response.set_cookie(
        key=auth_service.SESSION_COOKIE_NAME,
        value=token,
        max_age=max_age,
        httponly=True,  # JS 不可读，XSS 无法窃取会话
        samesite="lax",  # 跨站发起的 POST 不携带，天然防 CSRF
        # 自托管常见 LAN 内 http 直连，Secure 默认关闭；公网 https 部署时开启
        secure=get_settings().session_cookie_secure,
        path="/",
    )


async def _set_accounts_cookie(response: Response, accounts: list[SavedAccount]) -> None:
    """写账号袋 Cookie。空列表直接删掉 Cookie，不留一个签过名的空袋子。

    有效期取"记住我"的 30 天上限：袋子里每枚令牌自带过期时间，袋子本身活得
    久一点既无意义也无危害，但活得短会把仍然有效的令牌提前丢掉。
    """
    if not accounts:
        response.delete_cookie(auth_service.ACCOUNTS_COOKIE_NAME, path="/")
        return
    response.set_cookie(
        key=auth_service.ACCOUNTS_COOKIE_NAME,
        value=await auth_service.encode_saved_accounts(accounts),
        max_age=auth_service.SESSION_TTL_REMEMBER_SECONDS,
        httponly=True,
        samesite="lax",
        secure=get_settings().session_cookie_secure,
        path="/",
    )


async def _saved_accounts(request: Request) -> list[SavedAccount]:
    """解析本浏览器持有的全部有效账号（激活账号排第一）。"""
    return await auth_service.resolve_saved_accounts(
        request.cookies.get(auth_service.ACCOUNTS_COOKIE_NAME),
        request.cookies.get(auth_service.SESSION_COOKIE_NAME),
    )


async def _remember_login(
    request: Request, response: Response, token: str, max_age: int, principal: Principal
) -> None:
    """登录成功后的统一收尾：种激活 Cookie，并把新账号并入账号袋。

    普通登录与"添加账号"在后端没有区别——会话过期后重新登录，袋子里其余账号
    照样保留，这正是用户期望的行为。

    被挤出袋子的令牌（同一个账号在这个浏览器里又登录了一次、或超过上限被淘汰的
    最久未用账号）在服务端一并作废：浏览器里已经没有它了，留着只会在「我的设备」
    里多出一行再也用不到、却仍然有效的会话。
    """
    _set_session_cookie(response, token, max_age)
    before = await _saved_accounts(request)
    accounts = auth_service.merge_saved_account(before, token, principal)
    kept = {saved.token for saved in accounts}
    for saved in before:
        if saved.token not in kept:
            await login_devices.revoke_token(saved.token)
    await _set_accounts_cookie(response, accounts)


async def _activate(
    response: Response, accounts: list[SavedAccount], target: SavedAccount | None
) -> SessionView | None:
    """把 target 写成激活会话并回写袋子；target 为空表示袋子已空，清掉两个 Cookie。

    切换时激活 Cookie 的 max_age 统一给 30 天：真正的有效期由令牌内的过期
    时间戳决定（过期照样 401 → 登录页），Cookie 多活几天没有危害；而给短了
    会把"记住我"登录的账号提前踢掉。
    """
    if target is None:
        response.delete_cookie(auth_service.SESSION_COOKIE_NAME, path="/")
        await _set_accounts_cookie(response, [])
        return None
    _set_session_cookie(response, target.token, auth_service.SESSION_TTL_REMEMBER_SECONDS)
    ordered = [target, *[a for a in accounts if a.token != target.token]]
    await _set_accounts_cookie(response, ordered)
    return await _principal_session_view(target.principal)


async def _account_view(saved: SavedAccount, *, active: bool) -> AccountView:
    """账号袋里的一个账号 → 列表项。头像地址带 account 参数，让 <img> 能读到
    非激活账号的头像（GET /auth/avatar?account=）。"""
    view = await _principal_session_view(saved.principal)
    avatar_url = view.avatar_url
    if avatar_url is not None:
        avatar_url = f"{avatar_url}&account={view.username}"
    return AccountView(
        username=view.username,
        nickname=view.nickname,
        avatar_url=avatar_url,
        role=view.role,
        active=active,
    )


def _find_account(accounts: list[SavedAccount], username: str) -> SavedAccount | None:
    """按用户名在袋子里找账号（用户名在超管与成员间全局唯一，大小写不敏感）。"""
    wanted = username.strip().lower()
    for saved in accounts:
        if saved.principal.name.lower() == wanted:
            return saved
    return None


@router.get(
    "/bootstrap",
    response_model=ApiResponse[BootstrapStatus],
    summary="查询系统是否已完成首次初始化",
    operation_id="auth.bootstrap.status",
)
async def bootstrap_status() -> ApiResponse[BootstrapStatus]:
    """公开接口：仅返回布尔状态，供前端决定进 /setup 还是 /login。"""
    return ok(BootstrapStatus(initialized=await auth_service.is_admin_initialized()))


@router.post(
    "/bootstrap",
    response_model=ApiResponse[SessionView],
    summary="首次初始化：创建超级管理员（全生命周期仅一次）",
    operation_id="auth.bootstrap.create",
)
async def bootstrap_create(
    payload: BootstrapRequest, request: Request, response: Response
) -> ApiResponse[SessionView]:
    """创建管理员并自动登录。管理员已存在时一律 409，锁在服务端，不可绕过。"""
    account = await auth_service.create_admin(payload.username, payload.password)
    await mark_initialized()

    token, max_age = await _issue_web_session(request, owner_id=0, remember=False)
    await _remember_login(
        request, response, token, max_age, Principal(kind="admin", name=account.username)
    )
    return ok(_session_view(account), message="初始化完成，已自动登录")


@router.post(
    "/login",
    response_model=ApiResponse[SessionView],
    summary="管理员登录",
    operation_id="auth.login",
    # CLI 侧登录/登出由精选命令 mclaw login/logout 负责（要持久化本地凭证），
    # 生成层隐藏本端点避免出现语义不完整的同名命令
    openapi_extra={"x-cli-hidden": True},
)
async def login(
    payload: LoginRequest, request: Request, response: Response
) -> ApiResponse[SessionView]:
    """校验账号密码并种下会话 Cookie（超管或成员）。连续失败触发限速（429）。

    登录成功的账号同时并入账号袋（docs/design/account-switching.md §3）：
    浏览器里其余已登录账号原样保留，用户菜单里可一键切换。
    """
    identity = await auth_service.authenticate(payload.username, payload.password)
    if isinstance(identity, Member):
        token, max_age = await _issue_web_session(
            request, owner_id=identity.id or 0, remember=payload.remember
        )
        principal = Principal(
            kind="member",
            name=identity.username,
            member_id=identity.id,
            is_admin=False,
            member=identity,
        )
        await _remember_login(request, response, token, max_age, principal)
        return ok(_member_session_view(identity), message="登录成功")

    token, max_age = await _issue_web_session(request, owner_id=0, remember=payload.remember)
    await _remember_login(
        request, response, token, max_age, Principal(kind="admin", name=identity.username)
    )
    return ok(_session_view(identity), message="登录成功")


@router.post(
    "/logout",
    response_model=ApiResponse[SessionView | None],
    summary="退出当前账号（自动切到浏览器里的下一个账号）；all=true 退出全部",
    operation_id="auth.logout",
    # CLI 侧登录/登出由精选命令 mclaw login/logout 负责（要持久化本地凭证），
    # 生成层隐藏本端点避免出现语义不完整的同名命令
    openapi_extra={"x-cli-hidden": True},
)
async def logout(
    request: Request, response: Response, payload: LogoutRequest | None = None
) -> ApiResponse[SessionView | None]:
    """退出当前账号。无需登录态即可调用（会话已过期时也能正常登出）。

    返回体是退出后浏览器所处的账号：袋子里还有别的账号就自动切过去并返回它，
    空则返回 null（前端据此决定回首页还是去登录页）。``all=true`` 清空全部。

    退出即在服务端作废这枚会话令牌（「我的设备」里那一行随之消失），而不只是
    删掉浏览器里的 Cookie——Cookie 被人拷走过的话，退出之后它也用不了了。
    """
    active_token = request.cookies.get(auth_service.SESSION_COOKIE_NAME)
    if payload is not None and payload.all:
        for saved in await _saved_accounts(request):
            await login_devices.revoke_token(saved.token)
        if active_token:
            await login_devices.revoke_token(active_token)
        await _activate(response, [], None)
        return ok(None, message="已退出全部账号")

    if active_token:
        await login_devices.revoke_token(active_token)
    remaining = [a for a in await _saved_accounts(request) if a.token != active_token]
    view = await _activate(response, remaining, remaining[0] if remaining else None)
    if view is None:
        return ok(None, message="已退出登录")
    return ok(view, message=f"已退出登录，已切换到 {view.nickname}")


@router.get(
    "/me",
    response_model=ApiResponse[SessionView],
    summary="查询当前登录状态",
    operation_id="auth.me",
)
async def me(principal: Principal = Depends(require_login)) -> ApiResponse[SessionView]:
    return ok(await _principal_session_view(principal))


@router.put(
    "/profile",
    response_model=ApiResponse[SessionView],
    summary="修改个人信息（昵称）",
    operation_id="auth.profile.update",
)
async def update_profile(
    payload: UpdateProfileRequest,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[SessionView]:
    """昵称只影响界面展示；登录用户名与会话均不受影响。按身份分流到
    超管配置域或成员表。"""
    if principal.kind == "member" and principal.member_id is not None:
        member = await members_service.update_own_nickname(
            session, principal.member_id, payload.nickname
        )
        return ok(_member_session_view(member), message="个人信息已更新")
    account = await auth_service.update_nickname(payload.nickname.strip())
    return ok(_session_view(account), message="个人信息已更新")


def _avatar_stem_for(principal: Principal) -> str | None:
    """当前主体的头像槽位；超管（含 PAT/Agent）用默认槽位（返回 None）。"""
    if principal.kind == "member" and principal.member_id is not None:
        return avatar_media.member_stem(principal.member_id)
    return None


@router.post(
    "/avatar",
    response_model=ApiResponse[SessionView],
    summary="上传（替换）头像",
    operation_id="auth.avatar.upload",
)
async def upload_avatar(
    file: UploadFile = File(...),
    principal: Principal = Depends(require_login),
) -> ApiResponse[SessionView]:
    """接收一张图片存为头像；已有头像直接替换（按主体分槽位，不保留历史）。

    校验：只接受常见位图格式（拒绝可内嵌脚本的 SVG）、大小有上限。
    错误信息为中文，方便非开发者按提示处理。
    """
    if not avatar_media.is_supported_content_type(file.content_type):
        raise BadRequestException("不支持的图片格式，请上传 JPG / PNG / WebP / GIF / AVIF 图片")

    data = await file.read()
    if not data:
        raise BadRequestException("上传的图片为空，请重新选择")
    if len(data) > avatar_media.MAX_AVATAR_BYTES:
        limit_mb = avatar_media.MAX_AVATAR_BYTES // (1024 * 1024)
        raise BadRequestException(f"图片过大，请控制在 {limit_mb}MB 以内")

    stem = _avatar_stem_for(principal)
    # 已在上面校验过 content_type 属于受支持集合，此处必定命中
    if stem is None:
        avatar_media.save_avatar(data, file.content_type)  # type: ignore[arg-type]
    else:
        avatar_media.save_avatar(data, file.content_type, stem)  # type: ignore[arg-type]
    return ok(await _principal_session_view(principal), message="头像已更新")


@router.get(
    "/avatar",
    summary="读取头像文件",
    response_class=Response,
    operation_id="auth.avatar.download",
)
async def read_avatar(
    request: Request,
    principal: Principal = Depends(require_login),
    account: str | None = Query(default=None, description="读取账号袋里某个账号的头像"),
) -> FileResponse:
    """直接返回当前主体的头像本体，供 <img> 加载；地址由会话视图的 avatar_url 给出。

    带 ``account`` 时读取的是账号袋里另一个账号的头像——只有本浏览器确实持有
    该账号的登录态才能读到，天然按持有者隔离，不会变成"按用户名查任何人头像"。
    """
    if account is not None:
        saved = _find_account(await _saved_accounts(request), account)
        if saved is None:
            raise NotFoundException("尚未上传头像")
        principal = saved.principal
    stem = _avatar_stem_for(principal)
    path = avatar_media.find_avatar(stem) if stem else avatar_media.find_avatar()
    if path is None:
        raise NotFoundException("尚未上传头像")
    return FileResponse(
        path,
        media_type=avatar_media.content_type_for(path),
        # URL 带版本号做缓存键，这里可放心让浏览器长期缓存，换头像时 URL 会变。
        headers={"Cache-Control": "private, max-age=31536000"},
    )


@router.put(
    "/password",
    response_model=ApiResponse[SessionView],
    summary="修改密码（本人其余会话强制下线）",
    operation_id="auth.password.update",
)
async def change_password(
    payload: ChangePasswordRequest,
    request: Request,
    response: Response,
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[SessionView]:
    """改密后本人的其他登录下线，操作者当前这台设备保留不踢。

    失效范围（docs/design/login-devices.md「失效联动」）：
    - 用密码登录的设备（网页、App、Jellyfin 播放器）：除当前这台外全部注销；
    - 配对 / 手工创建的（命令行、转码器、手工令牌）：默认保留，
      ``sign_out_paired`` 为真时一并注销；
    - 超管另外轮换全局签名密钥（升级前的签名会话、在途取流 token 一并作废）；
      成员 token_version+1（升级前的签名会话失效）。

    当前请求若来自升级前签发的签名会话 Cookie，它会随改密失效，这里当场为这个
    浏览器补发一枚新的网页会话，操作者不被踢出。
    """
    current_id = principal.device.id if principal.device is not None else None
    families = ("login", "paired") if payload.sign_out_paired else ("login",)
    # 改密前先把账号袋里的令牌读出来：超管改密会轮换签名密钥，袋子本身的签名
    # 随之失效——不先读出来，同一浏览器里登着的其他账号就都丢了。
    bag_before = await _saved_accounts(request)
    if principal.kind == "member" and principal.member_id is not None:
        member = await members_service.change_own_password(
            session,
            principal.member_id,
            old_password=payload.old_password,
            new_password=payload.new_password,
        )
        revoked = await login_devices.revoke_for_member(
            session, principal.member_id, families=families, except_id=current_id
        )
        refreshed = Principal(
            kind="member",
            name=member.username,
            member_id=member.id,
            is_admin=False,
            member=member,
            device=principal.device,
        )
        view = _member_session_view(member)
    else:
        revoked = await auth_service.change_password(
            payload.old_password,
            payload.new_password,
            keep_device_id=current_id,
            sign_out_paired=payload.sign_out_paired,
        )
        refreshed = Principal(kind="admin", name=str(principal), device=principal.device)
        view = _session_view(await auth_service.get_admin_account())

    if principal.device is None:
        # 升级前签发的签名会话随改密失效：为这个浏览器补发一枚网页会话
        token, max_age = await _issue_web_session(
            request, owner_id=refreshed.owner_id, remember=True
        )
        await _remember_login(request, response, token, max_age, refreshed)
    elif principal.device.kind == "web":
        # 当前会话仍然有效；用改密后的签名密钥重写账号袋，只留仍然有效的账号
        # （超管改密轮换了密钥，旧袋子的签名已经对不上了）
        kept: list[SavedAccount] = []
        for saved in bag_before:
            try:
                await auth_service.verify_cookie_token(saved.token, touch=False)
            except UnauthorizedException:
                continue
            kept.append(saved)
        await _set_accounts_cookie(response, kept)

    message = "密码已修改，其他登录已全部下线"
    paired = [r for r in revoked if login_devices.spec_of(r.kind).family == "paired"]
    if paired:
        message += f"，命令行与转码器也已注销（{len(paired)} 台）"
    return ok(view, message=message)


# ---------------------------------------------------------------------------
# 多账号：列表 / 切换 / 移除（docs/design/account-switching.md §3）
# ---------------------------------------------------------------------------
# 三个接口都只操作本浏览器的两个 Cookie，不碰数据库里的任何账号数据；成员
# 也可用（已登记进成员白名单守护测试）。


@router.get(
    "/accounts",
    response_model=ApiResponse[list[AccountView]],
    summary="列出本浏览器已登录的全部账号（激活账号排第一）",
    dependencies=[Depends(require_login)],
    operation_id="auth.accounts.list",
    openapi_extra={"x-cli-hidden": True},
)
async def list_accounts(request: Request) -> ApiResponse[list[AccountView]]:
    accounts = await _saved_accounts(request)
    return ok(
        [await _account_view(saved, active=index == 0) for index, saved in enumerate(accounts)]
    )


@router.post(
    "/accounts/switch",
    response_model=ApiResponse[SessionView],
    summary="切换到本浏览器已登录的另一个账号（无需再输密码）",
    dependencies=[Depends(require_login)],
    operation_id="auth.accounts.switch",
    openapi_extra={"x-cli-hidden": True},
)
async def switch_account(
    payload: SwitchAccountRequest, request: Request, response: Response
) -> ApiResponse[SessionView]:
    """把袋子里对应的令牌写回激活 Cookie。目标账号的登录态已失效（过期 /
    被停用 / 改密）时返回 404，前端引导用户重新登录该账号。"""
    accounts = await _saved_accounts(request)
    target = _find_account(accounts, payload.username)
    if target is None:
        raise NotFoundException("该账号的登录状态已失效，请重新登录该账号")
    view = await _activate(response, accounts, target)
    assert view is not None  # target 非空时 _activate 必有返回
    return ok(view, message=f"已切换到 {view.nickname}")


@router.delete(
    "/accounts/{username}",
    response_model=ApiResponse[SessionView | None],
    summary="从本浏览器移除一个已登录账号（移除的是当前账号时自动切到下一个）",
    dependencies=[Depends(require_login)],
    operation_id="auth.accounts.remove",
    # confirm：只是让本浏览器忘掉一个登录态，不删任何数据；契约测试要求所有 DELETE 都声明
    openapi_extra={"x-cli-dangerous": "confirm", "x-cli-hidden": True},
)
async def remove_account(
    username: str, request: Request, response: Response
) -> ApiResponse[SessionView | None]:
    """返回体语义与 /auth/logout 相同：移除后浏览器所处的账号，null 表示已全部退出。"""
    accounts = await _saved_accounts(request)
    target = _find_account(accounts, username)
    if target is None:
        raise NotFoundException("该账号不在本浏览器的已登录列表里")
    # 从本浏览器移除 = 这个账号在本浏览器退出登录：服务端一并作废这枚会话
    await login_devices.revoke_token(target.token)
    remaining = [a for a in accounts if a.token != target.token]
    view = await _activate(response, remaining, remaining[0] if remaining else None)
    return ok(view, message="已移除该账号")


# ---------------------------------------------------------------------------
# 原生 App 登录：账号密码换一枚设备令牌（docs/design/login-devices.md）
# ---------------------------------------------------------------------------


@router.post(
    "/device/login",
    response_model=ApiResponse[DeviceLoginView],
    summary="原生 App 用账号密码登录，换取设备令牌（明文仅返回这一次）",
    operation_id="auth.device.login",
    # 客户端之间的协议端点：mclaw 走配对码，不该出现在命令树里
    openapi_extra={"x-cli-hidden": True},
)
async def device_login(
    payload: DeviceLoginRequest, request: Request
) -> ApiResponse[DeviceLoginView]:
    """App 登录。与网页登录同一套密码校验与限速（连续失败 429），区别只在凭证形态：

    网页拿 HttpOnly Cookie，App 拿一枚设备令牌存进系统钥匙串、每个请求带
    ``Authorization: Bearer``。令牌长期有效（不再「满 30 天必须重新输密码」），
    失效只靠注销或改密；这台设备随之出现在「我的设备」里，写明是谁在用。
    """
    identity = await auth_service.authenticate(payload.username, payload.password)
    owner_id = (identity.id or 0) if isinstance(identity, Member) else 0
    client = payload.client
    async with get_database().session() as session:
        token, device = await login_devices.issue(
            session,
            member_id=owner_id,
            kind=client.kind,
            name=client.name or login_devices.spec_of(client.kind).label,
            installation_id=client.installation_id,
            client_version=client.client_version,
            platform=client.platform,
            user_agent=request.headers.get("user-agent"),
            ip=client_address(request) or None,
        )
        owners = await _owner_labels(session)
    assert device.id is not None
    ref = auth_service.DeviceRef(
        id=device.id, kind=device.kind, scope=device.scope, name=device.name
    )
    if isinstance(identity, Member):
        session_view = _member_session_view(identity)
        principal = Principal(
            kind="member",
            name=identity.username,
            member_id=identity.id,
            is_admin=False,
            member=identity,
            device=ref,
        )
    else:
        session_view = _session_view(identity)
        principal = Principal(kind="admin", name=identity.username, device=ref)
    session_view.device = DeviceBrief(
        id=login_devices.playback_device_id(device.id), kind=device.kind, name=device.name
    )
    return ok(
        DeviceLoginView(
            token=token,
            device=_device_view(device, principal=principal, owners=owners),
            session=session_view,
        ),
        message="登录成功",
    )


# ---------------------------------------------------------------------------
# 手工令牌：给没有人能按批准的无人值守环境（定时任务、命令行模式的转码器）
# ---------------------------------------------------------------------------


@router.post(
    "/tokens",
    response_model=ApiResponse[ApiTokenCreatedView],
    summary="手工创建一枚令牌（明文仅返回这一次，请立即保存）",
    dependencies=[Depends(require_admin_session)],
    operation_id="auth.tokens.create",
    # 签发凭证只能是人在网页或 App 里的动作，CLI 调不动，也就不该出现在命令树里
    openapi_extra={"x-cli-hidden": True},
)
async def create_api_token(payload: ApiTokenCreateRequest) -> ApiResponse[ApiTokenCreatedView]:
    """令牌归属超管、长期有效，在「设备」列表里与其他设备一起管理和注销。"""
    plaintext, device = await auth_service.create_manual_token(
        payload.name.strip(), scope=payload.scope
    )
    assert device.id is not None
    return ok(
        ApiTokenCreatedView(
            id=login_devices.playback_device_id(device.id),
            name=device.name,
            scope=device.scope,
            created_at=device.created_at,
            token=plaintext,
        ),
        message="令牌已创建；明文不会再次显示，请立即保存",
    )


# ---------------------------------------------------------------------------
# 设备授权：客户端出示配对码，人在网页或 App 上批准
# ---------------------------------------------------------------------------
#
# 两个匿名端点是配对流唯一的匿名可达面（已在 tests/api/test_auth.py 的公开
# 白名单里登记）。它们必须匿名——设备在拿到令牌之前无凭可用；防滥用靠
# 服务层的三道约束：单 IP 未决请求上限、轮询退避、挑战全程不落库。
# 设计见 docs/design/device-auth.md §2 与 docs/design/login-devices.md「配对」。


async def _verification_uri(request: Request) -> str:
    """用户应当打开的网页地址（批准页 /activate，独立于「设置 → 设备」）。

    优先用配置好的「外部访问地址」——那是用户平时访问 movieclaw 的地址，
    也是他浏览器里已经登录着的那个源。没配置时回落到本次请求的地址：
    设备既然能连上这里，同一局域网的浏览器多半也能。
    """
    setting = await get_setting_store().get(AppServerSetting)
    base = (setting.external_url or "").strip().rstrip("/")
    if not base:
        base = str(request.base_url).rstrip("/")
    return f"{base}/activate"


@router.post(
    "/device/authorize",
    response_model=ApiResponse[DeviceAuthorizeView],
    summary="设备发起接入请求，取得配对码（匿名）",
    operation_id="auth.device.authorize",
    openapi_extra={"x-cli-hidden": True},
)
async def authorize_device(
    payload: DeviceAuthorizeRequest, request: Request
) -> ApiResponse[DeviceAuthorizeView]:
    """受理一次接入请求。客户端不声明权限，能做什么由批准者决定。

    x-cli-hidden：这是客户端之间的协议端点，不该出现在 CLI 命令树里——
    用户面对的是 ``mclaw login``，而不是手工拼装配对流程。
    """
    device_code, challenge = auth_service.authorize_device(
        client_type=payload.client_type,
        client_name=payload.client_name,
        source_ip=client_address(request),
        installation_id=payload.installation_id,
        platform=payload.platform,
        client_version=payload.client_version,
    )
    uri = await _verification_uri(request)
    return ok(
        DeviceAuthorizeView(
            user_code=challenge.user_code,
            device_code=device_code,
            verification_uri=uri,
            verification_uri_complete=f"{uri}?code={challenge.user_code}",
            interval=auth_service.DEVICE_POLL_INTERVAL_SECONDS,
            expires_in=auth_service.DEVICE_CODE_TTL_SECONDS,
        ),
        message="请在浏览器或 App 里核对配对码并批准",
    )


@router.post(
    "/device/token",
    # data 可空：202「等待批准」与 429「轮询过快」都是成功响应，只是还没有令牌
    response_model=ApiResponse[DeviceTokenView | None],
    summary="设备轮询兑换令牌（匿名）",
    operation_id="auth.device.token",
    openapi_extra={"x-cli-hidden": True},
)
async def redeem_device_token(
    payload: DeviceTokenRequest, response: Response
) -> ApiResponse[DeviceTokenView | None]:
    """轮询兑换。四种结论各自对应明确的 HTTP 语义，客户端据此决定继续还是停止。

    - 202 尚未批准，按 interval 继续轮询；
    - 429 轮询过快，退避后再来（挑战不作废，正常重试不该被当成攻击）；
    - 200 已批准，令牌明文仅此一次，挑战立即作废；
    - 400 已拒绝 / 已过期 / 不存在——**停止轮询**，重新发起。
    """
    result = await auth_service.redeem_device_code(payload.device_code)

    if result.status == "pending":
        response.status_code = 202
        return ok(None, code="AUTHORIZATION_PENDING", message="等待用户在浏览器或 App 里批准")
    if result.status == "slow_down":
        response.status_code = 429
        return ok(None, code="SLOW_DOWN", message="轮询过快，请按 interval 退避后重试")
    if result.status == "denied":
        raise BadRequestException("接入请求已被拒绝，请重新发起配对")
    if result.status == "expired":
        raise BadRequestException("配对码已过期或不存在，请重新发起配对")

    assert result.token is not None and result.device is not None  # status == "granted"
    return ok(
        DeviceTokenView(
            token=result.token,
            client_name=result.device.name,
            client_type=result.device.kind,
            granted_by=result.approver_name or "",
        ),
        message="配对成功；令牌明文不会再次显示，请立即保存",
    )


@router.get(
    "/devices/requests/{user_code}",
    response_model=ApiResponse[DeviceRequestView],
    summary="按配对码查看一条待批准的接入请求",
    dependencies=[Depends(require_interactive)],
    operation_id="auth.devices.request",
    openapi_extra={"x-cli-hidden": True},
)
async def get_device_request(user_code: str) -> ApiResponse[DeviceRequestView]:
    """批准页的数据源：只显示用户手里这个配对码对应的一条（不列出全部待批准请求）。"""
    challenge = auth_service.get_device_request(user_code)
    return ok(
        DeviceRequestView(
            user_code=challenge.user_code,
            client_type=challenge.client_type,
            client_name=challenge.client_name,
            source_ip=challenge.source_ip,
            expires_in=max(0, int(challenge.expires_at - time.monotonic())),
            platform=challenge.platform,
            client_version=challenge.client_version,
            requires_admin=challenge.client_type == "worker",
        )
    )


@router.post(
    "/devices/requests/{user_code}/approve",
    response_model=ApiResponse[None],
    summary="批准一台设备接入（此刻才签发令牌，令牌归属批准者）",
    operation_id="auth.devices.approve",
    openapi_extra={"x-cli-hidden": True},
)
async def approve_device_request(
    user_code: str, principal: Principal = Depends(require_interactive)
) -> ApiResponse[None]:
    """批准前请核对配对码与设备上显示的一致——这是防钓鱼的唯一一道人工闸。

    谁批准，令牌就是谁的：成员批准自己的命令行，它的权限就是这个成员的权限。
    转码器只能由超管批准。
    """
    challenge = await auth_service.approve_device_request(user_code, principal)
    return ok(None, message=f"已批准「{challenge.client_name}」以 {principal.name} 的身份接入")


@router.post(
    "/devices/requests/{user_code}/deny",
    response_model=ApiResponse[None],
    summary="拒绝一台设备接入",
    dependencies=[Depends(require_interactive)],
    operation_id="auth.devices.deny",
    openapi_extra={"x-cli-hidden": True},
)
async def deny_device_request(user_code: str) -> ApiResponse[None]:
    """拒绝不生成任何令牌，也不在磁盘上留痕。"""
    challenge = auth_service.deny_device_request(user_code)
    return ok(None, message=f"已拒绝「{challenge.client_name}」的接入请求")


# ---------------------------------------------------------------------------
# 我的设备：列表 / 改名 / 注销（docs/design/login-devices.md）
# ---------------------------------------------------------------------------
# 管理别人的设备（列出、改名、注销）只能由人在网页或 App 里做
# （require_interactive）；注销**自己**所有凭证都能做（require_device_principal），
# 命令行 ``mclaw logout``、转码器「断开并重新配置」都走它。


async def _owner_labels(session: AsyncSession) -> dict[int, tuple[str, str]]:
    """主人 id → (用户名, 昵称)。超管为 0。"""
    from sqlalchemy import select

    admin = await auth_service.get_admin_account()
    labels = {0: (admin.username, admin.nickname or admin.username)}
    for member in (await session.execute(select(Member))).scalars().all():
        if member.id is not None:
            labels[member.id] = (member.username, member.nickname or member.username)
    return labels


def _connected_device_ids() -> set[int]:
    """此刻连着转码控制面的登录设备（转码器只在握手时验一次凭证，在线与否以连接为准）。"""
    from movieclaw_api.services.playback.remote_worker import get_remote_worker_registry

    return get_remote_worker_registry().connected_login_device_ids()


def _device_view(
    device: LoginDevice,
    *,
    principal: Principal,
    owners: dict[int, tuple[str, str]],
    connected: set[int] | None = None,
) -> LoginDeviceView:
    assert device.id is not None
    spec = login_devices.spec_of(device.kind)
    username, nickname = owners.get(device.member_id, (f"#{device.member_id}", "已删除的成员"))
    return LoginDeviceView(
        id=login_devices.playback_device_id(device.id),
        kind=device.kind,
        kind_label=spec.label,
        family=spec.family,
        name=device.name,
        scope=device.scope,
        platform=device.platform,
        client_version=device.client_version,
        created_at=device.created_at,
        last_seen_at=device.last_seen_at,
        last_seen_ip=device.last_seen_ip,
        expires_at=device.expires_at,
        current=principal.device is not None and principal.device.id == device.id,
        connected=connected is not None and device.id in connected,
        renamable=True,
        owner_id=device.member_id,
        owner_username=username,
        owner_nickname=nickname,
    )


def _jellyfin_view(
    device: JellyfinDevice, *, owners: dict[int, tuple[str, str]]
) -> LoginDeviceView:
    """Jellyfin 播放器（Infuse 等）：凭证仍在自己的表里，只在列表上合并展示。"""
    assert device.id is not None
    username, nickname = owners.get(device.member_id, (f"#{device.member_id}", "已删除的成员"))
    return LoginDeviceView(
        id=f"jf-{device.id}",
        kind="jellyfin",
        kind_label=device.client or "Jellyfin 播放器",
        family="login",
        name=device.device_name or device.client or "播放器",
        scope="full",
        platform=None,
        client_version=device.version or None,
        created_at=device.created_at,
        last_seen_at=device.last_seen_at,
        last_seen_ip=None,
        expires_at=None,
        current=False,
        renamable=False,
        owner_id=device.member_id,
        owner_username=username,
        owner_nickname=nickname,
    )


def _sort_key(view: LoginDeviceView) -> tuple[int, float]:
    """当前设备置顶，其余按最近活跃从新到旧。"""
    seen = view.last_seen_at or view.created_at
    return (0 if view.current else 1, -seen.timestamp())


def _assert_manageable(principal: Principal, owner_id: int) -> None:
    """只能管理自己的设备；超管能管理所有人的。"""
    if principal.is_admin or principal.owner_id == owner_id:
        return
    raise NotFoundException("设备不存在或已被注销")


async def _find_device(
    session: AsyncSession, device_id: str
) -> LoginDevice | JellyfinDevice:
    """``ld-<n>`` / ``jf-<n>`` → 设备行；找不到一律 404。"""
    if device_id.startswith("jf-") and device_id[3:].isdigit():
        row = await session.get(JellyfinDevice, int(device_id[3:]))
        if row is not None:
            return row
    elif (parsed := login_devices.parse_playback_device_id(device_id)) is not None:
        found = await login_devices.get_device(session, parsed)
        if found is not None:
            return found
    raise NotFoundException("设备不存在或已被注销")


@router.get(
    "/devices",
    response_model=ApiResponse[list[LoginDeviceView]],
    summary="我的设备：登录着我的账号的浏览器、App、命令行、转码器与播放器",
    operation_id="auth.devices.list",
    openapi_extra={"x-cli-hidden": True},
)
async def list_devices(
    principal: Principal = Depends(require_interactive),
    session: AsyncSession = Depends(get_session),
    all_members: bool = Query(
        default=False, alias="all", description="管理员查看全部成员的设备"
    ),
) -> ApiResponse[list[LoginDeviceView]]:
    """当前设备置顶，其余按最近活跃排序。``all=true`` 仅超管可用，带上每台设备的主人。

    转码器多带一个 ``connected``：它只在握手时验一次凭证，之后靠长连接心跳在线，
    按「最近验签时间」判断的话，连着的转码器 5 分钟后就会被显示成离线。
    """
    from sqlalchemy import select

    if all_members and not principal.is_admin:
        raise ForbiddenException("只有管理员能查看全部成员的设备")
    owner_filter = None if all_members else principal.owner_id
    owners = await _owner_labels(session)
    connected = _connected_device_ids()
    views = [
        _device_view(row, principal=principal, owners=owners, connected=connected)
        for row in await login_devices.list_devices(session, member_id=owner_filter)
    ]
    stmt = select(JellyfinDevice)
    if owner_filter is not None:
        stmt = stmt.where(JellyfinDevice.member_id == owner_filter)
    views.extend(
        _jellyfin_view(row, owners=owners) for row in (await session.execute(stmt)).scalars()
    )
    views.sort(key=_sort_key)
    return ok(views)


@router.get(
    "/devices/current",
    response_model=ApiResponse[LoginDeviceView],
    summary="当前这台设备（命令行 mclaw status 用）",
    operation_id="auth.devices.current",
    openapi_extra={"x-cli-hidden": True},
)
async def current_device(
    principal: Principal = Depends(require_device_principal),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LoginDeviceView]:
    if principal.device is None:
        raise NotFoundException("当前登录不是设备凭证（升级前的旧网页会话），重新登录后即可查看")
    device = await login_devices.get_device(session, principal.device.id)
    if device is None:
        raise NotFoundException("设备不存在或已被注销")
    return ok(
        _device_view(
            device,
            principal=principal,
            owners=await _owner_labels(session),
            connected=_connected_device_ids(),
        )
    )


@router.delete(
    "/devices/current",
    response_model=ApiResponse[None],
    summary="注销当前这台设备（退出登录 / 断开配对）",
    operation_id="auth.devices.revoke-current",
    openapi_extra={"x-cli-dangerous": "confirm", "x-cli-hidden": True},
)
async def revoke_current_device(
    principal: Principal = Depends(require_device_principal),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[None]:
    """所有凭证都能注销自己：命令行 ``mclaw logout``、App 退出登录、转码器断开配对。"""
    if principal.device is None:
        raise NotFoundException("当前登录不是设备凭证（升级前的旧网页会话），请直接退出登录")
    device = await login_devices.get_device(session, principal.device.id)
    if device is None:
        raise NotFoundException("设备不存在或已被注销")
    await login_devices.revoke(session, device)
    return ok(None, message=f"已注销「{device.name}」")


@router.patch(
    "/devices/{device_id}",
    response_model=ApiResponse[LoginDeviceView],
    summary="给设备改名",
    operation_id="auth.devices.rename",
    openapi_extra={"x-cli-hidden": True},
)
async def rename_device(
    device_id: str,
    payload: RenameDeviceRequest,
    principal: Principal = Depends(require_interactive),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LoginDeviceView]:
    device = await _find_device(session, device_id)
    _assert_manageable(principal, device.member_id)
    if isinstance(device, JellyfinDevice):
        raise BadRequestException("播放器的名字由它自己上报，不能在这里修改")
    device = await login_devices.rename(session, device, payload.name)
    return ok(
        _device_view(
            device,
            principal=principal,
            owners=await _owner_labels(session),
            connected=_connected_device_ids(),
        ),
        message="设备已改名",
    )


@router.delete(
    "/devices/{device_id}",
    response_model=ApiResponse[None],
    summary="注销一台设备（凭证立即失效，正在播放与转码的一并停止）",
    operation_id="auth.devices.revoke",
    openapi_extra={"x-cli-dangerous": "confirm", "x-cli-hidden": True},
)
async def revoke_device(
    device_id: str,
    principal: Principal = Depends(require_interactive),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[None]:
    """只能注销自己的设备，超管能注销任何人的。注销是唯一的事后止损手段，立即生效。"""
    device = await _find_device(session, device_id)
    _assert_manageable(principal, device.member_id)
    if isinstance(device, JellyfinDevice):
        from movieclaw_api.services.playback_activity import revoke_device as revoke_player

        label = await revoke_player(session, device.device_id)
        return ok(None, message=f"已注销「{label or device.device_name}」")
    await login_devices.revoke(session, device)
    return ok(None, message=f"已注销「{device.name}」")
