"""IM 通道接口（docs/design/plugin-channels.md §6）。

通道是插件：列表来自注册表 ``im-channels``，设置页按每个通道声明的绑定方式通用渲染。

- 表单绑定：``POST /channels/bindings`` 带通道与字段；``pairing=code`` 的（Telegram / Discord）
  返回 6 位配对码，用户私聊 bot 发码，前端轮询 ``GET /channels/bindings/{id}`` 等 confirmed；
  不带配对的（飞书 Webhook）当场完成；
- 交互式绑定（微信扫码）：``POST`` 不带字段开始，轮询拿二维码与状态，需要时
  ``POST /channels/bindings/{id}/input`` 提交手机上的配对数字。

通道插件没启用时它的账号照常列出（``channel_available=false``），绑定 / 解绑给出明确提示，不报 500。
推送开关与测试推送仍在 ``/channels/im/*``（已发布的 iOS 在用）。
"""

from __future__ import annotations

import base64
from functools import lru_cache

import qrcode
import qrcode.image.svg
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import (
    BadRequestException,
    ConflictException,
    NotFoundException,
    ServiceUnavailableException,
)
from movieclaw_api.schemas.channels import (
    ChannelAccountView,
    ChannelBindingInputPayload,
    ChannelBindingSpecView,
    ChannelBindingView,
    ChannelBindPayload,
    ChannelFieldView,
    ChannelPushConfigView,
    ChannelsView,
    ChannelView,
    PushTestPayload,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.channel_hub import ChannelHub, ChannelUnavailable, get_hub
from movieclaw_api.services.channel_push import push_to_all_channels
from movieclaw_api.settings import ChannelPushSetting, get_setting_store
from movieclaw_db.engine import get_session
from movieclaw_db.models.channel_account import ChannelAccount
from movieclaw_db.repositories.channel_account_repo import ChannelAccountRepository
from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository

router = APIRouter(prefix="/channels", tags=["channels"])


@lru_cache(maxsize=8)
def _qrcode_data_url(content: str) -> str:
    """二维码内容 → SVG data URL（纯 Python）；同一绑定每秒轮询，内容不变不重复编码。"""
    if not content:
        return ""
    img = qrcode.make(content, image_factory=qrcode.image.svg.SvgPathImage, box_size=12)
    return "data:image/svg+xml;base64," + base64.b64encode(img.to_string()).decode()


def _hub() -> ChannelHub:
    hub = get_hub()
    if hub is None:
        raise ServiceUnavailableException("IM 通道中枢没有运行，请到「设置 → 插件 → 内置」查看原因")
    return hub


def _account_view(row: ChannelAccount, hub: ChannelHub | None) -> ChannelAccountView:
    available = hub is not None and row.channel_id in hub.drivers()
    return ChannelAccountView(
        channel_id=row.channel_id,
        account_id=row.account_id,
        display_name=row.display_name or row.account_id,
        bound_user_id=row.bound_user_id,
        status=row.status,
        running=bool(hub and hub.is_running(row.channel_id, row.account_id)),
        channel_available=available,
        last_error=row.last_error,
        bound_at=row.created_at,
    )


@router.get(
    "",
    response_model=ApiResponse[ChannelsView],
    summary="IM 通道：可用的通道（来自通道插件）与已绑定的账号",
    operation_id="channels.list",
)
async def list_channels(session: AsyncSession = Depends(get_session)) -> ApiResponse[ChannelsView]:
    hub = get_hub()
    channels: list[ChannelView] = []
    if hub is not None:
        for channel_id, driver in hub.drivers().items():
            spec = driver.binding
            channels.append(
                ChannelView(
                    id=channel_id,
                    title=driver.title or channel_id,
                    description=driver.description,
                    entry_id=hub.contributor(channel_id),
                    receive=driver.capabilities.receive,
                    webhook=driver.capabilities.webhook,
                    photo=driver.capabilities.photo,
                    binding=ChannelBindingSpecView(
                        kind=spec.kind,
                        fields=[
                            ChannelFieldView(
                                key=f.key,
                                label=f.label,
                                secret=f.secret,
                                placeholder=f.placeholder,
                                help=f.help,
                                required=f.required,
                            )
                            for f in spec.fields
                        ],
                        pairing=spec.pairing,
                        hint=spec.hint,
                    ),
                )
            )
    rows = await ChannelAccountRepository(session).list_all()
    return ok(ChannelsView(channels=channels, accounts=[_account_view(r, hub) for r in rows]))


async def _binding_view(hub: ChannelHub, binding_id: str) -> ChannelBindingView:
    binding = hub.binding(binding_id)
    if binding is None:
        raise NotFoundException("绑定不存在或已过期，请重新发起")
    account = None
    if binding.status == "confirmed" and binding.account_id:
        from movieclaw_db.engine import get_database

        async with get_database().session() as session:
            row = await ChannelAccountRepository(session).get(
                binding.channel_id, binding.account_id
            )
        if row is not None:
            account = _account_view(row, hub)
    return ChannelBindingView(
        binding_id=binding.binding_id,
        channel_id=binding.channel_id,
        kind=binding.kind,
        status=binding.status,
        message=binding.message,
        pair_code=binding.pair_code,
        qr_image=_qrcode_data_url(binding.qr or ""),
        qr=binding.qr or "",
        input_label=binding.input_label,
        account=account,
        callback_url=binding.callback_url,
        callback_note=binding.callback_note,
    )


@router.post(
    "/bindings",
    response_model=ApiResponse[ChannelBindingView],
    status_code=201,
    summary="发起绑定（表单字段；交互式绑定不带字段）",
    operation_id="channels.bindings.start",
)
async def start_binding(
    payload: ChannelBindPayload,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ChannelBindingView]:
    hub = _hub()
    channel_id = payload.channel_id
    try:
        driver = hub.driver(channel_id)
    except ChannelUnavailable as exc:
        raise ConflictException(str(exc)) from exc
    # 能对话的通道完全由 AI 模型驱动：没配模型时绑定了也用不了，在入口拦下并引导去设置
    if driver.capabilities.receive and not await LlmProviderRepository(session).has_any():
        raise BadRequestException(
            "绑定需要先完成 AI 模型配置：请先在「设置 → 模型接入」接入模型供应商，再进行绑定"
        )
    try:
        binding = await hub.begin_binding(channel_id, payload.fields)
    except ValueError as exc:
        raise BadRequestException(str(exc)) from exc
    except ChannelUnavailable as exc:
        raise ConflictException(str(exc)) from exc
    except Exception as exc:  # noqa: BLE001 -- 网关不可达等，转成中文业务错误
        raise BadRequestException(f"发起绑定失败：{exc}") from exc
    return ok(await _binding_view(hub, binding.binding_id), message="绑定已发起")


@router.get(
    "/bindings/{binding_id}",
    response_model=ApiResponse[ChannelBindingView],
    summary="查询绑定状态（前端轮询）",
    operation_id="channels.bindings.status",
)
async def get_binding(binding_id: str) -> ApiResponse[ChannelBindingView]:
    return ok(await _binding_view(_hub(), binding_id))


@router.post(
    "/bindings/{binding_id}/input",
    response_model=ApiResponse[ChannelBindingView],
    summary="交互式绑定里提交输入（如微信配对数字）",
    operation_id="channels.bindings.input",
)
async def submit_binding_input(
    binding_id: str, payload: ChannelBindingInputPayload
) -> ApiResponse[ChannelBindingView]:
    hub = _hub()
    try:
        await hub.binding_input(binding_id, payload.value.strip())
    except LookupError as exc:
        raise NotFoundException(str(exc)) from exc
    return ok(await _binding_view(hub, binding_id))


# 账号 id 由通道插件定，可能带斜杠（如 ntfy 的「服务器/主题」）：最后一段按路径匹配
@router.delete(
    "/{channel_id}/accounts/{account_id:path}",
    response_model=ApiResponse[dict],
    summary="解绑通道账号（停收发、删凭据；历史对话保留）",
    operation_id="channels.accounts.unbind",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def unbind_account(channel_id: str, account_id: str) -> ApiResponse[dict]:
    if not await _hub().unbind(channel_id, account_id):
        raise NotFoundException("账号不存在")
    return ok({}, message="已解绑")


# ---------------------------------------------------------------------- 推送（路径不变）


@router.post(
    "/im/push-test",
    response_model=ApiResponse[dict],
    summary="向所有已绑定通道发送测试推送",
    operation_id="channels.im.push.test",
)
async def send_test_push(payload: PushTestPayload) -> ApiResponse[dict]:
    text = payload.text.strip() or "📣 这是一条来自 MovieClaw 的测试推送。收到说明通道工作正常！"
    sent = await push_to_all_channels(text)
    if sent == 0:
        raise BadRequestException("没有可推送的通道账号：请先完成绑定且确保通道在运行")
    return ok({"sent": sent}, message=f"已推送到 {sent} 个账号")


@router.get(
    "/im/push-config",
    response_model=ApiResponse[ChannelPushConfigView],
    summary="读取推送内容开关",
    operation_id="channels.im.push.config.get",
)
async def get_push_config() -> ApiResponse[ChannelPushConfigView]:
    setting = await get_setting_store().get(ChannelPushSetting)
    return ok(
        ChannelPushConfigView(
            push_dispatch=setting.push_dispatch, push_imported=setting.push_imported
        )
    )


@router.put(
    "/im/push-config",
    response_model=ApiResponse[ChannelPushConfigView],
    summary="保存推送内容开关",
    operation_id="channels.im.push.config.update",
)
async def update_push_config(payload: ChannelPushConfigView) -> ApiResponse[ChannelPushConfigView]:
    await get_setting_store().set(
        ChannelPushSetting(push_dispatch=payload.push_dispatch, push_imported=payload.push_imported)
    )
    return ok(payload, message="推送设置已保存")
