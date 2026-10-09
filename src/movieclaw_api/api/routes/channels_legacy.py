"""旧版通道接口（已发布的 iPhone / Mac App 的「IM 推送」页在用）。

通道插件化之后，网页与命令行改用 ``/channels`` 通用接口（api/routes/channels.py）。这里保留
旧路径与旧响应形状，内部全部转给通道中枢，已安装的旧版 App 照常可用；不进命令行
（``x-cli-hidden``）。App 改用通用接口并发版、旧版退出支持后整文件删除
（docs/design/plugin-channels.md §6）。
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.api.routes.channels import _hub, _qrcode_data_url
from movieclaw_api.exceptions import BadRequestException, ConflictException, NotFoundException
from movieclaw_api.schemas.channels import (
    FeishuBindPayload,
    ImAccountView,
    ImBindingView,
    ImBindTokenPayload,
    WeixinAccountView,
    WeixinBindingStartView,
    WeixinBindingStatusView,
    WeixinVerifyCodePayload,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.channel_hub import Binding, ChannelHub, ChannelUnavailable
from movieclaw_db.engine import get_database, get_session
from movieclaw_db.models.channel_account import ChannelAccount
from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository
from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository

router = APIRouter(prefix="/channels", tags=["channels"])

_LEGACY = {"x-cli-hidden": True}
_IM_CHANNELS = ("telegram", "discord", "feishu")


async def _require_llm(session: AsyncSession) -> None:
    if not await LlmProviderRepository(session).has_any():
        raise BadRequestException(
            "绑定需要先完成 AI 模型配置：请先在「设置 → 模型接入」接入模型供应商，再进行绑定"
        )


async def _begin(hub: ChannelHub, channel_id: str, fields: dict[str, str]) -> Binding:
    try:
        return await hub.begin_binding(channel_id, fields)
    except ValueError as exc:
        raise BadRequestException(str(exc)) from exc
    except ChannelUnavailable as exc:
        raise ConflictException(str(exc)) from exc
    except Exception as exc:  # noqa: BLE001 -- 网关不可达等，转成中文业务错误
        raise BadRequestException(f"发起绑定失败：{exc}") from exc


async def _row(channel_id: str, account_id: str | None) -> ChannelAccount | None:
    if not account_id:
        return None
    async with get_database().session() as session:
        return await ChannelAccountRepository(session).get(channel_id, account_id)


def _weixin_account(row: ChannelAccount, hub: ChannelHub) -> WeixinAccountView:
    return WeixinAccountView(
        account_id=row.account_id,
        bound_user_id=row.bound_user_id,
        status=row.status,
        running=hub.is_running(row.channel_id, row.account_id),
        last_error=row.last_error,
        bound_at=row.created_at,
    )


def _im_account(row: ChannelAccount, hub: ChannelHub) -> ImAccountView:
    return ImAccountView(
        channel_id=row.channel_id,
        account_id=row.account_id,
        bound_user_id=row.bound_user_id,
        status=row.status,
        running=hub.is_running(row.channel_id, row.account_id),
        last_error=row.last_error,
        bound_at=row.created_at,
    )


def _require_im(channel: str) -> str:
    if channel not in _IM_CHANNELS:
        raise NotFoundException(f"未知通道：{channel}")
    return channel


# ---------------------------------------------------------------------- 微信


@router.get(
    "/weixin/accounts",
    response_model=ApiResponse[list[WeixinAccountView]],
    summary="已绑定的微信账号列表（旧接口）",
    operation_id="channels.weixin.accounts.list",
    openapi_extra=_LEGACY,
)
async def list_weixin_accounts(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[WeixinAccountView]]:
    hub = _hub()
    rows = await ChannelAccountRepository(session).list_by_channel("weixin")
    return ok([_weixin_account(row, hub) for row in rows])


@router.post(
    "/weixin/bindings",
    response_model=ApiResponse[WeixinBindingStartView],
    status_code=201,
    summary="发起微信扫码绑定（旧接口）",
    operation_id="channels.weixin.bindings.start",
    openapi_extra=_LEGACY,
)
async def start_weixin_binding(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[WeixinBindingStartView]:
    hub = _hub()
    await _require_llm(session)
    binding = await _begin(hub, "weixin", {})
    return ok(
        WeixinBindingStartView(
            challenge_id=binding.binding_id,
            qrcode_url=binding.qr or "",
            qrcode_image=_qrcode_data_url(binding.qr or ""),
            message=binding.message,
        ),
        message="绑定已发起",
    )


@router.get(
    "/weixin/bindings/{challenge_id}",
    response_model=ApiResponse[WeixinBindingStatusView],
    summary="查询微信绑定状态（旧接口）",
    operation_id="channels.weixin.bindings.status",
    openapi_extra=_LEGACY,
)
async def get_weixin_binding_status(challenge_id: str) -> ApiResponse[WeixinBindingStatusView]:
    hub = _hub()
    binding = hub.binding(challenge_id)
    if binding is None:
        raise NotFoundException("绑定流程不存在或已过期，请重新发起")
    row = await _row("weixin", binding.account_id) if binding.status == "confirmed" else None
    return ok(
        WeixinBindingStatusView(
            challenge_id=binding.binding_id,
            status="need_verify_code" if binding.status == "need_input" else binding.status,
            message=binding.message,
            qrcode_url=binding.qr or "",
            qrcode_image=_qrcode_data_url(binding.qr or ""),
            account=_weixin_account(row, hub) if row is not None else None,
        )
    )


@router.post(
    "/weixin/bindings/{challenge_id}/verify-code",
    response_model=ApiResponse[dict],
    summary="提交扫码配对数字（旧接口）",
    operation_id="channels.weixin.bindings.verify",
    openapi_extra=_LEGACY,
)
async def submit_weixin_verify_code(
    challenge_id: str, payload: WeixinVerifyCodePayload
) -> ApiResponse[dict]:
    try:
        await _hub().binding_input(challenge_id, payload.code.strip())
    except LookupError as exc:
        raise NotFoundException("绑定流程不存在或已结束，请重新发起") from exc
    return ok({}, message="配对码已提交，正在校验")


@router.delete(
    "/weixin/accounts/{account_id}",
    response_model=ApiResponse[dict],
    summary="解绑微信账号（旧接口）",
    operation_id="channels.weixin.accounts.unbind",
    openapi_extra={**_LEGACY, "x-cli-dangerous": "confirm"},
)
async def unbind_weixin_account(account_id: str) -> ApiResponse[dict]:
    if not await _hub().unbind("weixin", account_id):
        raise NotFoundException("账号不存在或已解绑")
    return ok({}, message="已解绑")


# ---------------------------------------------------------------------- Telegram / Discord / 飞书


@router.get(
    "/im/{channel}/accounts",
    response_model=ApiResponse[list[ImAccountView]],
    summary="已绑定的 Telegram / Discord / 飞书账号列表（旧接口）",
    operation_id="channels.im.accounts.list",
    openapi_extra=_LEGACY,
)
async def list_im_accounts(
    channel: str, session: AsyncSession = Depends(get_session)
) -> ApiResponse[list[ImAccountView]]:
    channel_id = _require_im(channel)
    hub = _hub()
    rows = await ChannelAccountRepository(session).list_by_channel(channel_id)
    return ok([_im_account(row, hub) for row in rows])


# 字面量路径须先于 /im/{channel} 参数路由注册，否则会被参数路由吞掉
@router.post(
    "/im/feishu/bindings",
    response_model=ApiResponse[ImAccountView],
    status_code=201,
    summary="接入飞书群机器人（旧接口）",
    operation_id="channels.im.feishu.bind",
    openapi_extra=_LEGACY,
)
async def start_feishu_binding(payload: FeishuBindPayload) -> ApiResponse[ImAccountView]:
    hub = _hub()
    binding = await _begin(
        hub, "feishu", {"webhook_url": payload.webhook_url, "secret": payload.secret}
    )
    row = await _row("feishu", binding.account_id)
    if row is None:
        raise BadRequestException("接入飞书失败：账号没有保存")
    return ok(_im_account(row, hub), message="接入成功，欢迎消息已发送到群聊")


async def _im_binding_view(hub: ChannelHub, binding: Binding) -> ImBindingView:
    row = (
        await _row(binding.channel_id, binding.account_id)
        if binding.status == "confirmed"
        else None
    )
    return ImBindingView(
        challenge_id=binding.binding_id,
        status=binding.status,
        pair_code=binding.pair_code,
        bot_name=binding.display_name,
        message=binding.message,
        account=_im_account(row, hub) if row is not None else None,
    )


@router.post(
    "/im/{channel}/bindings",
    response_model=ApiResponse[ImBindingView],
    status_code=201,
    summary="发起配对绑定（旧接口）",
    operation_id="channels.im.bindings.start",
    openapi_extra=_LEGACY,
)
async def start_im_binding(
    channel: str, payload: ImBindTokenPayload, session: AsyncSession = Depends(get_session)
) -> ApiResponse[ImBindingView]:
    channel_id = _require_im(channel)
    if channel_id == "feishu":
        raise BadRequestException("飞书通道不支持配对码绑定：请粘贴群机器人 Webhook 地址接入")
    hub = _hub()
    await _require_llm(session)
    binding = await _begin(hub, channel_id, {"token": payload.token.strip()})
    return ok(await _im_binding_view(hub, binding), message="绑定已发起")


@router.get(
    "/im/{channel}/bindings/{challenge_id}",
    response_model=ApiResponse[ImBindingView],
    summary="查询配对状态（旧接口）",
    operation_id="channels.im.bindings.status",
    openapi_extra=_LEGACY,
)
async def get_im_binding_status(channel: str, challenge_id: str) -> ApiResponse[ImBindingView]:
    _require_im(channel)
    hub = _hub()
    binding = hub.binding(challenge_id)
    if binding is None:
        raise NotFoundException("绑定流程不存在或已过期，请重新发起")
    return ok(await _im_binding_view(hub, binding))


@router.delete(
    "/im/{channel}/accounts/{account_id}",
    response_model=ApiResponse[dict],
    summary="解绑 Telegram / Discord / 飞书账号（旧接口）",
    operation_id="channels.im.accounts.unbind",
    openapi_extra={**_LEGACY, "x-cli-dangerous": "confirm"},
)
async def unbind_im_account(channel: str, account_id: str) -> ApiResponse[dict]:
    channel_id = _require_im(channel)
    if not await _hub().unbind(channel_id, account_id):
        raise NotFoundException("账号不存在或已解绑")
    return ok({}, message="已解绑")
