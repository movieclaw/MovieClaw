"""访问地址簿（docs/design/server-addresses.md §3.2）：App 据此在内外网地址之间自动选。

读对所有成员开放（各端 App 登录后都要拿）；增删只有管理员（「设置 → 网络 → 访问地址」）。
"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from movieclaw_api.api.deps import require_admin
from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.schemas.server_addresses import (
    ServerAddressesView,
    ServerAddressItem,
    ServerAddressPayload,
    ServerAddressRemovePayload,
)
from movieclaw_api.services import host_key
from movieclaw_api.services.server_addresses import address_book, lan_subnets
from movieclaw_api.settings.schemas import get_jellyfin_compat

router = APIRouter(prefix="/server/addresses", tags=["server"])


async def _view() -> ServerAddressesView:
    addresses = await address_book.list()
    return ServerAddressesView(
        instance_id=(await get_jellyfin_compat()).server_id,
        host_key=await host_key.public_key(),
        addresses=[ServerAddressItem(**a.model_dump()) for a in addresses],
        lan_subnets=lan_subnets(addresses),
    )


@router.get(
    "",
    response_model=ApiResponse[ServerAddressesView],
    summary="这台服务器的访问地址（内网 / 外网）",
    operation_id="app.addresses.list",
)
async def list_addresses() -> ApiResponse[ServerAddressesView]:
    return ok(await _view())


@router.post(
    "",
    response_model=ApiResponse[ServerAddressesView],
    summary="手动添加一个访问地址",
    operation_id="app.addresses.add",
    dependencies=[Depends(require_admin)],
)
async def add_address(payload: ServerAddressPayload) -> ApiResponse[ServerAddressesView]:
    try:
        await address_book.add_manual(payload.url, payload.kind)
    except ValueError as exc:
        raise BadRequestException(str(exc)) from exc
    return ok(await _view())


@router.post(
    "/remove",
    response_model=ApiResponse[ServerAddressesView],
    summary="删掉一个访问地址（学到的之后再有人用会重新出现）",
    operation_id="app.addresses.remove",
    dependencies=[Depends(require_admin)],
)
async def remove_address(payload: ServerAddressRemovePayload) -> ApiResponse[ServerAddressesView]:
    try:
        removed = await address_book.remove(payload.url)
    except ValueError as exc:
        raise BadRequestException(str(exc)) from exc
    if not removed:
        raise NotFoundException("没有这个地址；外部访问地址请在下方修改")
    return ok(await _view())
