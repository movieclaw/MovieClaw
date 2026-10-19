"""网盘接口（docs/design/cloud-storage.md §11）。

网盘是插件：可用的网盘来自注册表 ``drive-backends``，设置页按每个后端声明的登录方式通用渲染。

- 扫码登录：``POST /drives/logins`` 带网盘与扫码前选的项开始，轮询
  ``GET /drives/logins/{id}`` 拿二维码与状态；扫完码宿主在后台就把账号建好（前端不轮询也行）；
- Cookie 登录：浏览器扩展推送走 ``/extension/cookies``（按插件声明的域名分发到这里的服务），
  手动粘贴走 ``POST /drives/accounts/cookie``；
- 填表登录（开放平台的 Client ID / 密钥等）：``POST /drives/accounts/form``，表单按插件声明的
  ``login.form`` 画；
- 同一网盘用户只有一个账号，重新登录更新原账号；带 ``relogin`` 时登进来的必须是那个账号。

提供网盘的插件不在时账号照常列出（``backend_available=false``），登录给出明确提示，不报 500。
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Query

from movieclaw_api.api.routes.channels import _qrcode_data_url
from movieclaw_api.exceptions import BadRequestException, ConflictException, NotFoundException
from movieclaw_api.schemas.drives import (
    DriveAccountUpdatePayload,
    DriveAccountView,
    DriveBackendView,
    DriveCapabilitiesView,
    DriveCookiePayload,
    DriveDirView,
    DriveFormLoginPayload,
    DriveLoginChoiceView,
    DriveLoginOptionView,
    DriveLoginPayload,
    DriveLoginSpecView,
    DriveLoginView,
    DriveSettingsPayload,
    DriveSettingsView,
    DriveStatusView,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.drives import accounts, gateway
from movieclaw_api.services.drives.registry import BackendUnavailable, backends
from movieclaw_db.engine import get_database
from movieclaw_db.models.drive_account import DriveAccount
from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository
from movieclaw_sdk import drives as dv
from movieclaw_sdk.config_schema import SchemaNotSupported

logger = logging.getLogger("movieclaw_api.drives")

router = APIRouter(prefix="/drives", tags=["drives"])


def _form_schema(item: dv.DriveBackend) -> dict | None:
    try:
        return dv.form_schema(item.login)
    except SchemaNotSupported as exc:
        # 插件的表单模型写错了：不让它拖垮整个网盘列表，只是不提供填表登录
        logger.warning("网盘 %s 的登录表单界面画不了：%s", item.type, exc)
        return None


def _backend_view(item: dv.DriveBackend) -> DriveBackendView:
    caps = item.capabilities
    login = item.login
    return DriveBackendView(
        type=item.type,
        title=item.title,
        description=item.description,
        accent_color=item.accent_color,
        capabilities=DriveCapabilitiesView(
            writable=caps.writable,
            rapid_upload_hashes=list(caps.rapid_upload_hashes),
            range_challenge=caps.range_challenge,
            list_hashes=caps.list_hashes,
            change_feed=caps.change_feed,
            original_link=caps.original_link,
            link_needs_ua=caps.link_needs_ua,
            recycle_bin=caps.recycle_bin,
            default_qps=caps.default_qps,
            default_daily_budget=caps.default_daily_budget,
            default_read_slots=caps.default_read_slots,
        ),
        login=DriveLoginSpecView(
            scan=login.scan,
            cookie=bool(login.cookie_domains),
            cookie_domains=list(login.cookie_domains),
            form=_form_schema(item),
            hint=login.hint,
            options=[
                DriveLoginOptionView(
                    key=o.key,
                    label=o.label,
                    default=o.default,
                    help=o.help,
                    choices=[
                        DriveLoginChoiceView(value=c.value, label=c.label, help=c.help)
                        for c in o.choices
                    ],
                )
                for o in login.options
            ],
        ),
    )


def account_view(row: DriveAccount) -> DriveAccountView:
    backend = backends().get(row.backend)
    qps, budget, slots = gateway.effective(row, backend)
    assert row.id is not None
    return DriveAccountView(
        id=row.id,
        backend=row.backend,
        backend_title=backend.title if backend is not None else row.backend,
        backend_available=backend is not None,
        accent_color=backend.accent_color if backend is not None else "",
        name=row.name,
        login_method=row.login_method,
        login_detail=row.login_detail,
        status=row.status,
        status_message=row.status_message,
        status_until=row.status_until,
        qps=qps,
        daily_budget=budget,
        read_slots=slots,
        qps_custom=row.qps is not None,
        daily_budget_custom=row.daily_budget is not None,
        read_slots_custom=row.read_slots is not None,
        used_today=gateway.usage_today(row.id),
        vip=row.vip,
        quota_total=row.quota_total,
        quota_used=row.quota_used,
        profile_at=row.profile_at,
        created_at=row.created_at,
    )


@router.get(
    "/backends",
    response_model=ApiResponse[list[DriveBackendView]],
    summary="可用的网盘（有插件提供后端的）",
    operation_id="drives.backends.list",
)
async def list_backends() -> ApiResponse[list[DriveBackendView]]:
    return ok([_backend_view(item) for item in backends().values()])


@router.get(
    "/status",
    response_model=ApiResponse[DriveStatusView],
    summary="网盘功能是否启用、有几个账号（各端决定网盘入口出不出现）",
    operation_id="drives.status",
)
async def drive_status() -> ApiResponse[DriveStatusView]:
    from sqlalchemy import func
    from sqlmodel import select

    async with get_database().session() as session:
        count = (await session.execute(select(func.count()).select_from(DriveAccount))).scalar_one()
    return ok(DriveStatusView(active=bool(backends()), accounts=int(count)))


@router.get(
    "/settings",
    response_model=ApiResponse[DriveSettingsView],
    summary="网盘的全局选项",
    operation_id="drives.settings.get",
)
async def get_settings_view() -> ApiResponse[DriveSettingsView]:
    from movieclaw_api.settings import DriveReleaseSetting, get_setting_store

    current = await get_setting_store().get(DriveReleaseSetting)
    return ok(DriveSettingsView(remove_download_tasks=current.remove_download_tasks))


@router.put(
    "/settings",
    response_model=ApiResponse[DriveSettingsView],
    summary="改网盘的全局选项",
    operation_id="drives.settings.update",
)
async def update_settings_view(payload: DriveSettingsPayload) -> ApiResponse[DriveSettingsView]:
    from movieclaw_api.settings import DriveReleaseSetting, get_setting_store

    store = get_setting_store()
    current = await store.get(DriveReleaseSetting)
    if payload.remove_download_tasks is not None:
        current = current.model_copy(
            update={"remove_download_tasks": payload.remove_download_tasks}
        )
        await store.set(current)
    return ok(
        DriveSettingsView(remove_download_tasks=current.remove_download_tasks), message="已保存"
    )


@router.get(
    "/accounts",
    response_model=ApiResponse[list[DriveAccountView]],
    summary="网盘账号列表",
    operation_id="drives.accounts.list",
)
async def list_accounts() -> ApiResponse[list[DriveAccountView]]:
    async with get_database().session() as session:
        rows = await DriveAccountRepository(session).list_all()
    return ok([account_view(row) for row in rows])


@router.patch(
    "/accounts/{account_id}",
    response_model=ApiResponse[DriveAccountView],
    summary="改网盘账号的名字、速率、每日预算、同时播放数",
    operation_id="drives.accounts.update",
)
async def update_account(
    account_id: int, payload: DriveAccountUpdatePayload
) -> ApiResponse[DriveAccountView]:
    try:
        row = await accounts.update_settings(
            account_id,
            name=payload.name,
            qps=payload.qps,
            daily_budget=payload.daily_budget,
            read_slots=payload.read_slots,
            reset=frozenset(payload.reset),
        )
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    except ValueError as exc:
        raise BadRequestException(str(exc)) from exc
    return ok(account_view(row), message="已保存")


@router.get(
    "/accounts/{account_id}/dirs",
    response_model=ApiResponse[list[DriveDirView]],
    summary="列网盘目录的子目录（给媒体库选网盘文件夹）",
    operation_id="drives.accounts.dirs",
)
async def list_dirs(
    account_id: int,
    parent_id: str = Query(default="", description="上层目录 id；空 = 网盘根目录"),
    path: str = Query(default="", description="上层目录的网盘路径（拼出子目录的完整路径）"),
) -> ApiResponse[list[DriveDirView]]:
    """按需展开，不预先遍历整个网盘；已经挂在媒体库上的目录（含上下层）标出是哪个库。"""
    from movieclaw_db.models.library import Library
    from movieclaw_db.repositories.library_cloud_repo import LibraryCloudRepository

    try:
        dirs = await gateway.call(
            account_id, "list_dir", priority=gateway.Priority.USER, dir_id=parent_id
        )
    except BackendUnavailable as exc:
        raise ConflictException(str(exc)) from exc
    except dv.NotFound as exc:
        raise NotFoundException(exc.message) from exc
    except dv.DriveError as exc:
        raise BadRequestException(exc.message) from exc
    base = "/".join(p for p in path.split("/") if p)
    async with get_database().session() as session:
        mounted = []
        for folder in await LibraryCloudRepository(session).folders_of_account(account_id):
            library = await session.get(Library, folder.library_id)
            mounted.append((folder, library.name if library is not None else ""))
    views = []
    for item in dirs:
        full = f"{base}/{item.name}" if base else item.name
        owner = next(
            (
                (folder.library_id, name)
                for folder, name in mounted
                if folder.remote_dir_id == item.remote_id
                or full == folder.display_path
                or full.startswith(folder.display_path + "/")
                or folder.display_path.startswith(full + "/")
            ),
            None,
        )
        views.append(
            DriveDirView(
                id=item.remote_id,
                name=item.name,
                path=full,
                has_children=item.has_children,
                video_count=item.video_count,
                library_id=owner[0] if owner else None,
                library_name=owner[1] if owner else None,
            )
        )
    return ok(views)


@router.delete(
    "/accounts/{account_id}",
    response_model=ApiResponse[dict],
    summary="移除网盘账号（只删 MovieClaw 里的记录，不动网盘上的文件）",
    operation_id="drives.accounts.delete",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def delete_account(account_id: int) -> ApiResponse[dict]:
    try:
        removed = await accounts.delete_account(account_id)
    except ValueError as exc:
        raise ConflictException(str(exc)) from exc
    if not removed:
        raise NotFoundException("网盘账号不存在")
    return ok({"removed": True}, message="已移除")


@router.post(
    "/accounts/{account_id}/refresh",
    response_model=ApiResponse[DriveAccountView],
    summary="刷新网盘账号的昵称与容量",
    operation_id="drives.accounts.refresh",
)
async def refresh_account(account_id: int) -> ApiResponse[DriveAccountView]:
    try:
        row = await accounts.refresh_profile(account_id)
    except BackendUnavailable as exc:
        raise ConflictException(str(exc)) from exc
    except dv.NotFound as exc:
        raise NotFoundException(exc.message) from exc
    except dv.DriveError as exc:
        raise BadRequestException(exc.message) from exc
    return ok(account_view(row))


@router.post(
    "/accounts/cookie",
    response_model=ApiResponse[DriveLoginView],
    status_code=201,
    summary="用 Cookie 登录网盘（粘贴整页 Cookie）",
    operation_id="drives.accounts.cookie",
)
async def import_cookie(payload: DriveCookiePayload) -> ApiResponse[DriveLoginView]:
    try:
        row, created = await accounts.import_cookie(
            payload.backend, payload.cookie, relogin=payload.relogin
        )
    except BackendUnavailable as exc:
        raise ConflictException(str(exc)) from exc
    except ValueError as exc:
        raise BadRequestException(str(exc)) from exc
    return _done_view(payload.backend, row, created)


@router.post(
    "/accounts/form",
    response_model=ApiResponse[DriveLoginView],
    status_code=201,
    summary="填表登录网盘（开放平台的 Client ID / 密钥等，字段由插件声明）",
    operation_id="drives.accounts.form",
)
async def login_with_form(payload: DriveFormLoginPayload) -> ApiResponse[DriveLoginView]:
    try:
        row, created = await accounts.login_with_form(
            payload.backend, payload.values, relogin=payload.relogin
        )
    except BackendUnavailable as exc:
        raise ConflictException(str(exc)) from exc
    except ValueError as exc:
        raise BadRequestException(str(exc)) from exc
    return _done_view(payload.backend, row, created)


def _done_view(backend: str, row: DriveAccount, created: bool) -> ApiResponse[DriveLoginView]:
    """一步完成的登录（Cookie、填表）也按扫码登录的结果形状返回，前端一套处理。"""
    view = DriveLoginView(
        login_id="",
        backend=backend,
        status="confirmed",
        message=f"已添加：{row.name}" if created else f"已重新登录：{row.name}",
        qr_image="",
        account=account_view(row),
        created=created,
    )
    return ok(view, message=view.message)


async def _login_view(login_id: str) -> DriveLoginView:
    item = accounts.login_session(login_id)
    if item is None:
        raise NotFoundException("登录不存在或已过期，请重新扫码")
    account = None
    if item.status == "confirmed" and item.account_id is not None:
        async with get_database().session() as session:
            row = await DriveAccountRepository(session).get(item.account_id)
        if row is not None:
            account = account_view(row)
    return DriveLoginView(
        login_id=item.login_id,
        backend=item.backend,
        status=item.status,
        message=item.message,
        qr_image=_qrcode_data_url(item.qr or "") if not item.terminal else "",
        account=account,
        created=item.created,
    )


@router.post(
    "/logins",
    response_model=ApiResponse[DriveLoginView],
    status_code=201,
    summary="开始扫码登录网盘",
    operation_id="drives.logins.start",
)
async def start_login(payload: DriveLoginPayload) -> ApiResponse[DriveLoginView]:
    try:
        item = await accounts.begin_login(payload.backend, payload.options, relogin=payload.relogin)
    except BackendUnavailable as exc:
        raise ConflictException(str(exc)) from exc
    except ValueError as exc:
        raise BadRequestException(str(exc)) from exc
    except dv.DriveError as exc:
        raise BadRequestException(f"发起扫码失败：{exc.message}") from exc
    return ok(await _login_view(item.login_id), message="请用手机扫码")


@router.get(
    "/logins/{login_id}",
    response_model=ApiResponse[DriveLoginView],
    summary="查询扫码登录状态（前端轮询）",
    operation_id="drives.logins.status",
)
async def get_login(login_id: str) -> ApiResponse[DriveLoginView]:
    return ok(await _login_view(login_id))


@router.delete(
    "/logins/{login_id}",
    response_model=ApiResponse[dict],
    summary="取消扫码登录",
    operation_id="drives.logins.cancel",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def cancel_login(login_id: str) -> ApiResponse[dict]:
    await accounts.cancel_login(login_id)
    return ok({"cancelled": True})
