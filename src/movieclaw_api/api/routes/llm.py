from __future__ import annotations

from collections import Counter

from fastapi import APIRouter, BackgroundTasks, Depends, Query
from pydantic import Field
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.i18n import t
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.schemas.llm import (
    LlmCatalogProviderView,
    LlmDefaultsPayload,
    LlmDefaultsView,
    LlmModelDiscoveryPayload,
    LlmModelOptionView,
    LlmModelVisibilityPayload,
    LlmPresetView,
    LlmProviderModelView,
    LlmProviderPayload,
    LlmProviderView,
)
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.chatgpt_auth import complete_sign_in, start_sign_in
from movieclaw_api.services.llm_catalog import get_public_catalog, refresh_all
from movieclaw_api.services.llm_config import LlmConfigService, verify_llm_provider
from movieclaw_db.engine import get_session
from movieclaw_llm.providers import list_presets

router = APIRouter(prefix="/llm", tags=["llm"])


class ChatGPTAuthorizePayload(BaseModel):
    redirect_uri: str = Field(max_length=200)
    name: str = Field(default="ChatGPT", min_length=1, max_length=100)
    app_name: str = Field(default="MovieClaw", min_length=1, max_length=80)
    provider_id: int | None = None


class ChatGPTAuthorizeView(BaseModel):
    attempt_id: str
    state: str
    authorize_url: str


class ChatGPTCompletePayload(BaseModel):
    attempt_id: str = Field(max_length=100)
    state: str = Field(max_length=100)
    code: str = Field(min_length=1, max_length=4096)
    client_id: str | None = Field(default=None, max_length=200)


@router.post(
    "/chatgpt/authorize",
    response_model=ApiResponse[ChatGPTAuthorizeView],
    operation_id="llm.chatgpt.authorize",
    summary="开始电脑端 ChatGPT 订阅授权",
    openapi_extra={"x-cli-hidden": True, "x-cli-covered-by": "llm chatgpt login"},
)
async def authorize_chatgpt(
    payload: ChatGPTAuthorizePayload,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ChatGPTAuthorizeView]:
    result = await start_sign_in(session, **payload.model_dump())
    return ok(ChatGPTAuthorizeView(**result))


@router.post(
    "/chatgpt/complete",
    response_model=ApiResponse[LlmProviderView],
    operation_id="llm.chatgpt.complete",
    summary="完成一次性 ChatGPT 订阅授权",
    openapi_extra={"x-cli-hidden": True, "x-cli-covered-by": "llm chatgpt login"},
)
async def finish_chatgpt(
    payload: ChatGPTCompletePayload,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LlmProviderView]:
    row = await complete_sign_in(session, **payload.model_dump())
    service = LlmConfigService(session)
    row = await service.start_verification(row.id)
    background_tasks.add_task(verify_llm_provider, row.id)
    return ok(LlmProviderView.from_model(row), message=t("settings.llm.chatgptConnected"))


@router.post(
    "/models/discover",
    response_model=ApiResponse[list[str]],
    summary="查询端点上报的模型 ID（不保存配置）",
    operation_id="llm.models.discover",
)
async def discover_llm_models(
    payload: LlmModelDiscoveryPayload,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[str]]:
    models = await LlmConfigService(session).discover_models(payload)
    return ok(models)


@router.get(
    "/presets",
    response_model=ApiResponse[list[LlmPresetView]],
    summary="列出可接入的供应商类型及其模型目录",
    operation_id="llm.presets",
)
async def list_llm_presets() -> ApiResponse[list[LlmPresetView]]:
    """返回内置供应商预设（OpenAI / 阿里云百炼 / 通用兼容端点），
    设置页据此渲染类型选项、端点默认值与模型选择提示。"""
    return ok([LlmPresetView.from_preset(p) for p in list_presets()])


@router.get(
    "/models",
    response_model=ApiResponse[list[LlmModelOptionView]],
    summary="列出对话框可选的全部模型（跨实例）",
    operation_id="llm.models",
)
async def list_llm_models(
    all_models: bool = Query(
        False, alias="all", description="true 返回全部参数已知的模型（含菜单里隐藏的）"
    ),
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[LlmModelOptionView]]:
    """已接入实例里显示在菜单中的模型（按实例添加顺序，实例内旗舰/新模型在前）。
    ref 一律是「实例名/模型id」，原样填进 session.start 的 model 或 AI 设定即可；
    同一模型 id 出现在多个实例时 label 带括号标注实例名。is_default 标记智能体
    默认模型；AI 设定引用的模型总在其中。"""
    options = await LlmConfigService(session).list_model_options()
    if not all_models:
        options = [option for option in options if option.shown]
    counts = Counter(option.model_id for option in options)
    return ok(
        [
            option.model_copy(
                update={
                    "label": t(
                        "settings.llm.modelWithProvider",
                        model=option.model_id,
                        provider=option.provider_name,
                    )
                }
            )
            if counts[option.model_id] > 1
            else option
            for option in options
        ]
    )


@router.get(
    "/defaults",
    response_model=ApiResponse[LlmDefaultsView],
    summary="查看 AI 设定（各用途的默认模型）",
    operation_id="llm.defaults.show",
)
async def get_llm_defaults(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LlmDefaultsView]:
    """agent_model / subtitle_model 首次接入供应商时自动设为其目录第一个模型，之后
    由用户改；一个实例都没有时为 null。effective_* 为实际生效值，正常与之一致。"""
    return ok(await LlmConfigService(session).get_defaults())


@router.put(
    "/defaults",
    response_model=ApiResponse[LlmDefaultsView],
    summary="保存 AI 设定（各用途的默认模型）",
    operation_id="llm.defaults.update",
)
async def update_llm_defaults(
    payload: LlmDefaultsPayload,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LlmDefaultsView]:
    """引用取自 llm.models 的 ref；传 null 则回到自动推荐（最早实例的第一个模型）。"""
    view = await LlmConfigService(session).update_defaults(
        agent_model=payload.agent_model, subtitle_model=payload.subtitle_model
    )
    return ok(view, message=t("settings.ai.saved"))


@router.get(
    "/providers",
    response_model=ApiResponse[list[LlmProviderView]],
    summary="列出已接入的模型供应商实例",
    operation_id="llm.providers.list",
)
async def list_llm_providers(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[LlmProviderView]]:
    """按添加顺序；一个都没接入时 data 为空数组，设置页据此渲染空态。
    listing 是模型目录概况（来源、更新时间、显示数/总数）。"""
    return ok(await LlmConfigService(session).provider_views())


@router.post(
    "/providers",
    response_model=ApiResponse[LlmProviderView],
    summary="接入一个模型供应商实例（保存后异步测试连接）",
    operation_id="llm.providers.create",
)
async def create_llm_provider(
    payload: LlmProviderPayload,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LlmProviderView]:
    """保存后状态置 pending 并在后台用连接测试模型（目录里第一个）发一次最小
    对话验证；调用方可轮询实例（CLI：mclaw llm providers show）观察
    status：pending → verifying → active / failed（见 last_error）。"""
    service = LlmConfigService(session)
    row = await service.create(
        name=payload.name,
        provider_type=payload.provider_type,
        base_url=payload.base_url,
        api_key=payload.api_key,
        default_model=payload.default_model,
        extra_models=payload.extra_models,
        user_agent=payload.user_agent,
        api_protocol=payload.api_protocol,
        catalog_id=payload.catalog_id,
    )
    assert row.id is not None
    row = await service.start_verification(row.id)
    background_tasks.add_task(verify_llm_provider, row.id)
    return ok(LlmProviderView.from_model(row), message=t("settings.llm.connectionSaved"))


@router.get(
    "/providers/{provider_id}",
    response_model=ApiResponse[LlmProviderView],
    summary="查看一个模型供应商实例",
    operation_id="llm.providers.show",
)
async def get_llm_provider(
    provider_id: int,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LlmProviderView]:
    service = LlmConfigService(session)
    (view,) = await service.provider_views([await service.get(provider_id)])
    return ok(view)


@router.put(
    "/providers/{provider_id}",
    response_model=ApiResponse[LlmProviderView],
    summary="修改一个模型供应商实例（保存后异步测试连接）",
    operation_id="llm.providers.update",
)
async def update_llm_provider(
    provider_id: int,
    payload: LlmProviderPayload,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LlmProviderView]:
    """整体覆盖接入配置（API Key 留空沿用原 Key；改了类型或端点须重填）。"""
    service = LlmConfigService(session)
    await service.update(
        provider_id,
        name=payload.name,
        provider_type=payload.provider_type,
        base_url=payload.base_url,
        api_key=payload.api_key,
        default_model=payload.default_model,
        extra_models=payload.extra_models,
        user_agent=payload.user_agent,
        # 请求没带该字段（老客户端）时沿用原值，不能当成「清空」
        api_protocol=(payload.api_protocol if "api_protocol" in payload.model_fields_set else ...),
        catalog_id=(payload.catalog_id if "catalog_id" in payload.model_fields_set else ...),
    )
    row = await service.start_verification(provider_id)
    background_tasks.add_task(verify_llm_provider, provider_id)
    return ok(LlmProviderView.from_model(row), message=t("settings.llm.connectionSaved"))


@router.post(
    "/providers/{provider_id}/verify",
    response_model=ApiResponse[LlmProviderView],
    summary="手动重新测试一个实例的模型连接",
    operation_id="llm.providers.verify",
)
async def reverify_llm_provider(
    provider_id: int,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LlmProviderView]:
    """行为：不存在 → 404；已在测试中 → 409；否则同步占位为 VERIFYING
    并在后台重新测试。"""
    row = await LlmConfigService(session).start_verification(provider_id)
    background_tasks.add_task(verify_llm_provider, provider_id)
    return ok(LlmProviderView.from_model(row), message=t("settings.llm.connectionRetested"))


@router.delete(
    "/providers/{provider_id}",
    response_model=ApiResponse[dict],
    summary="删除一个模型供应商实例",
    operation_id="llm.providers.delete",
    openapi_extra={"x-cli-dangerous": "confirm"},
)
async def delete_llm_provider(
    provider_id: int,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[dict]:
    """AI 设定里指向它的默认模型会自动改指最早剩下的实例；全部删除时清空。"""
    revoked = await LlmConfigService(session).delete(provider_id)
    return ok(
        {"remote_revoked": revoked},
        message=t("settings.llm.connectionDeleted")
        if revoked
        else t("settings.llm.remoteRevocationPending"),
    )


@router.get(
    "/providers/{provider_id}/models",
    response_model=ApiResponse[list[LlmProviderModelView]],
    summary="列出一个实例目录里的全部模型（管理模型）",
    operation_id="llm.providers.models",
)
async def list_llm_provider_models(
    provider_id: int,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[LlmProviderModelView]]:
    """含菜单里隐藏的与参数未知的模型，按菜单顺序：预设旗舰在前，其余按发布日期新 → 旧。"""
    return ok(await LlmConfigService(session).provider_models(provider_id))


@router.post(
    "/providers/{provider_id}/models/visibility",
    response_model=ApiResponse[list[LlmProviderModelView]],
    summary="在模型菜单里显示或隐藏一个模型",
    operation_id="llm.providers.models.visibility",
)
async def set_llm_model_visibility(
    provider_id: int,
    payload: LlmModelVisibilityPayload,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[list[LlmProviderModelView]]:
    """参数未知的模型要先补录参数（编辑实例的自定义模型）才能显示。返回更新后的模型列表。"""
    service = LlmConfigService(session)
    await service.set_model_visibility(provider_id, payload.model_id, payload.shown)
    return ok(await service.provider_models(provider_id))


@router.post(
    "/providers/{provider_id}/models/refresh",
    response_model=ApiResponse[LlmProviderView],
    summary="立即刷新一个实例的模型列表",
    operation_id="llm.providers.models.refresh",
)
async def refresh_llm_provider_models(
    provider_id: int,
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[LlmProviderView]:
    """向服务商重新拉模型列表，并顺带检查公共模型目录（models.dev）有没有更新；
    等结果返回。拉取失败时保留原列表，原因见 listing.error。"""
    service = LlmConfigService(session)
    await service.get(provider_id)
    await refresh_all(force=True, provider_ids={provider_id})
    session.expire_all()
    (view,) = await service.provider_views([await service.get(provider_id)])
    return ok(view)


@router.get(
    "/catalog/providers",
    response_model=ApiResponse[list[LlmCatalogProviderView]],
    summary="列出公共模型目录（models.dev）里的服务商",
    operation_id="llm.catalog.providers",
)
async def list_llm_catalog_providers() -> ApiResponse[list[LlmCatalogProviderView]]:
    """兼容端点选「模型资料来源」用；按 id 排序。"""
    return ok([LlmCatalogProviderView(**p) for p in get_public_catalog().index()])
