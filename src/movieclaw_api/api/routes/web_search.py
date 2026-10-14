"""智能体网页搜索的设置接口（「设置 → AI 设定 → 搜索能力接入」）。

管理区路由：密钥是服务器凭据。响应里只有供应商 id 和末四位，没有明文。
四个接口都对 CLI 隐藏——这是设置页的事，不进 mclaw 的命令面，
避免对话式 Agent 经 mclaw 读到或改写搜索密钥。
"""

from __future__ import annotations

from fastapi import APIRouter
from pydantic import Field

from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.web_search_config import (
    clear_web_search,
    get_status,
    save_web_search,
    test_web_search,
)

router = APIRouter(prefix="/llm/web-search", tags=["llm"])

_HIDDEN = {"x-cli-hidden": True}


class WebSearchProviderOption(BaseModel):
    id: str
    label: str
    signup_url: str
    note: str


class WebSearchConfigView(BaseModel):
    provider: str | None = Field(default=None, description="当前供应商 id；未配置为 null")
    configured: bool = Field(description="是否已保存可用的供应商和密钥")
    key_hint: str = Field(default="", description="密钥末四位；未配置或过短时为空")
    providers: list[WebSearchProviderOption]


class WebSearchSavePayload(BaseModel):
    provider: str = Field(min_length=1, max_length=40, description="tavily / exa / brave")
    api_key: str | None = Field(
        default=None,
        max_length=500,
        description="API Key。编辑时留空沿用原密钥；更换供应商时必须重填",
    )


class WebSearchTestPayload(BaseModel):
    provider: str | None = Field(default=None, max_length=40)
    api_key: str | None = Field(
        default=None,
        max_length=500,
        description="留空则测试已保存的密钥。本接口不保存",
    )


class WebSearchTestView(BaseModel):
    ok: bool
    message: str
    sample_title: str | None = None


def _view(data: dict) -> WebSearchConfigView:
    return WebSearchConfigView.model_validate(data)


@router.get(
    "",
    response_model=ApiResponse[WebSearchConfigView],
    summary="查看智能体网页搜索的接入状态（不含密钥明文）",
    operation_id="llm.web-search.show",
    openapi_extra=_HIDDEN,
)
async def show_web_search() -> ApiResponse[WebSearchConfigView]:
    return ok(_view(await get_status()))


@router.put(
    "",
    response_model=ApiResponse[WebSearchConfigView],
    summary="保存智能体网页搜索的供应商和 API Key",
    operation_id="llm.web-search.update",
    openapi_extra=_HIDDEN,
)
async def update_web_search(payload: WebSearchSavePayload) -> ApiResponse[WebSearchConfigView]:
    """保存即生效，下一次对话才会把 web_search 放进工具列表。不强制先测通。"""
    data = await save_web_search(provider=payload.provider, api_key=payload.api_key)
    return ok(_view(data), message="网页搜索已保存")


@router.delete(
    "",
    response_model=ApiResponse[WebSearchConfigView],
    summary="关闭智能体网页搜索并清除已保存的 API Key",
    operation_id="llm.web-search.clear",
    openapi_extra={**_HIDDEN, "x-cli-dangerous": "confirm"},
)
async def delete_web_search() -> ApiResponse[WebSearchConfigView]:
    return ok(_view(await clear_web_search()), message="已关闭网页搜索")


@router.post(
    "/test",
    response_model=ApiResponse[WebSearchTestView],
    summary="测试搜索供应商的 API Key（不保存）",
    operation_id="llm.web-search.test",
    openapi_extra=_HIDDEN,
)
async def test_web_search_connection(
    payload: WebSearchTestPayload,
) -> ApiResponse[WebSearchTestView]:
    result = await test_web_search(provider=payload.provider, api_key=payload.api_key)
    return ok(WebSearchTestView.model_validate(result), message=result["message"])
