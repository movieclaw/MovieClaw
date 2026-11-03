"""LLM 供应商配置服务：实例接入、AI 设定（各用途默认模型）、连接验证与模型清单。

接入与设定是两件事：
- **接入**（llm_provider 表，多实例）只回答「怎么连上」：实例名、类型、端点、
  Key、自定义模型目录。连接测试用目录里第一个模型发一次 max_tokens=1 的
  最小对话——比只调 /models 列表更真实，能一次性证明 key、端点、模型三者
  都有效；模型列表另行 best-effort 拉取，仅作设置页补录提示；
- **设定**（LlmDefaultsSetting）回答「什么场景用哪个模型」：智能体默认模型、
  字幕处理默认模型，值是对话框同款的模型引用。不变量：**只要还有实例，两个
  默认就都已设置且可解析**——首次接入时自动设为该实例目录里的第一个模型，
  被引用的实例删除时自动改指最早剩下的一家，全部删除时清空（见
  reconcile_defaults）。设置页显示的就是真实存的值，不靠运行时隐式兜底；
  resolve_defaults 里的兜底只是预设目录变动等漂移场景的安全网。

模型清单（对话框「模型」入口与 AI 设定的选项）的口径（docs/design/llm-model-catalog.md）：
- 一个实例的目录 = 服务商列表 ∪ 预设 ∪ 用户补录，参数按字段合并公共目录
  （models.dev）、列表自带参数、预设修正与补录（services.llm_catalog）；
- 只有**参数已知**的模型进清单（菜单里的模型一定有上下文窗口，自动压缩与
  思维链菜单才不会失效）；清单里 shown 标出默认显示规则 + 用户选择的结果；
- 引用一律「实例名/模型id」：目录是动态的，裸 id 会在另一个实例的列表里冒出
  同名模型后静默换服务商。展示只在同 id 出现在多个实例的菜单里时加括号
  「模型id（实例名）」。升级前存下的裸 id 由 qualify_ref 改写成限定形式。
"""

from __future__ import annotations

import logging
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass
from types import EllipsisType
from typing import Literal

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import (
    BadRequestException,
    ConflictException,
    NotFoundException,
)
from movieclaw_api.i18n.llm import error_reference, preset_name
from movieclaw_api.i18n.stored import reference, render_value, source_text
from movieclaw_api.schemas.llm import (
    LlmDefaultsView,
    LlmListingView,
    LlmModelDiscoveryPayload,
    LlmModelOptionView,
    LlmProviderModelView,
    LlmProviderView,
)
from movieclaw_api.services.chatgpt_auth import (
    build_server_protocol,
    revoke_credentials,
    token_store,
)
from movieclaw_api.services.llm_catalog import (
    CATALOG_DISABLED,
    catalog_digest,
    catalog_entries,
    draft_entry,
    effective_catalog_id,
    get_public_catalog,
    listing_after_error,
    listing_from_entries,
)
from movieclaw_api.settings import LlmDefaultsSetting, get_setting_store
from movieclaw_db.engine import get_database
from movieclaw_db.models.llm_provider import LlmProvider
from movieclaw_db.models.site_credential import ConfigStatus
from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository
from movieclaw_llm import ChatMessage, ChatRequest, LlmError, LlmRouter, ModelInfo, ModelSettings
from movieclaw_llm.catalog import default_shown, visible_ids
from movieclaw_llm.chatgpt import RESOURCE, ChatGPTCredentials, restore_account_model_controls
from movieclaw_llm.models import LlmProviderConfig, ProviderPreset
from movieclaw_llm.protocols import build_protocol
from movieclaw_llm.providers import get_preset, list_presets

logger = logging.getLogger("movieclaw_api.llm_config")

# 验证用较短超时：只回答"通不通"，没必要等 SDK 默认的十分钟
_TEST_TIMEOUT = 30.0

#: 有默认模型设定的用途；新增用途时同步扩展 LlmDefaultsSetting 与 resolve_defaults
Purpose = Literal["agent", "subtitle"]


def to_domain_config(row: LlmProvider, api_key: str) -> LlmProviderConfig:
    """ORM 记录 → movieclaw_llm 领域配置（LlmRouter 按它构建协议客户端）。"""
    return LlmProviderConfig(
        name=row.name,
        provider_id=row.id,
        provider_type=row.provider_type,
        api_key=api_key,
        base_url=row.base_url,
        default_model=row.default_model,
        extra_models=_extra_models(row),
        user_agent=row.user_agent,
        api_protocol=row.api_protocol,
        catalog=provider_catalog(row),
        catalog_version=catalog_digest(row),
    )


def _extra_models(row: LlmProvider) -> list[ModelInfo]:
    models = [ModelInfo.model_validate(m) for m in row.extra_models or []]
    return restore_account_model_controls(models) if row.provider_type == "chatgpt" else models


def provider_catalog(row: LlmProvider) -> list[ModelInfo]:
    """实例可路由的完整目录（合并结果，含隐藏与参数未知的模型）。"""
    return [e.model for e in catalog_entries(row)]


def build_model_options(
    rows: list[LlmProvider], agent_default: str | None = None, pinned: Iterable[str] = ()
) -> list[LlmModelOptionView]:
    """把全部实例里参数已知的模型拍平成清单（rows 按添加顺序），shown 标出是否进菜单。

    引用一律「实例名/模型id」（LlmRouter 的显式分支）；展示文案在同一 id 出现在
    多个实例的菜单里时加括号「模型id（实例名）」让用户分得清走哪家。
    ``agent_default`` 命中的选项标 is_default；``pinned`` 是 AI 设定引用的模型，
    用户隐藏了也照样显示（否则设置页的默认模型下拉框里找不到当前值）。
    """
    pinned = set(pinned)
    options: list[LlmModelOptionView] = []
    for row in rows:
        entries = [e for e in catalog_entries(row) if e.known]
        prefix = f"{row.name}/"
        row_pinned = {ref.removeprefix(prefix) for ref in pinned if ref.startswith(prefix)}
        shown = visible_ids(entries, row.model_visibility, row_pinned)
        chat_protocol = (
            row.api_protocol or get_preset(row.provider_type).protocol
        ) == "openai_chat"
        for entry in entries:
            model = entry.model
            ref = f"{row.name}/{model.id}"
            options.append(
                LlmModelOptionView(
                    ref=ref,
                    label=model.id,
                    model_id=model.id,
                    provider_id=row.id or 0,
                    provider_name=row.name,
                    is_default=ref == agent_default,
                    thinking_levels=(
                        ["off"]
                        if chat_protocol and model.chat_tools_require_no_reasoning
                        else model.thinking_levels
                    ),
                    shown=entry.id in shown,
                    deprecated=model.deprecated,
                    released=model.released,
                    display_name=model.display_name,
                    context_window=model.context_window,
                    cost=model.cost,
                )
            )
    counts = Counter(o.model_id for o in options if o.shown)
    for option in options:
        if counts[option.model_id] > 1:
            option.label = f"{option.model_id}（{option.provider_name}）"
    return options


def qualify_ref(ref: str | None, options: list[LlmModelOptionView]) -> str | None:
    """把存下的引用对齐到清单：已在清单里的原样返回；升级前存的裸 id 改写成
    「实例名/模型id」（按实例添加顺序取第一个归属）；对不上返回 None。"""
    if not ref:
        return None
    if any(o.ref == ref for o in options):
        return ref
    return next((o.ref for o in options if o.model_id == ref), None)


@dataclass(frozen=True)
class ResolvedDefaults:
    """各用途实际生效的模型引用（None = 一个实例都没有）。"""

    agent: str | None
    subtitle: str | None

    def ref(self, purpose: Purpose) -> str | None:
        return self.agent if purpose == "agent" else self.subtitle


def recommended_default(rows: list[LlmProvider], options: list[LlmModelOptionView]) -> str | None:
    """自动设定的默认模型：最早接入实例目录里的第一个模型（即它的连接测试模型）。

    预设目录按 yaml 顺序排列、旗舰在前，所以「第一个」就是该供应商的推荐
    主力模型；自定义端点则是用户补录的第一个。一个实例都没有时为 None。
    ``options`` 是 build_model_options(rows) 的结果，由调用方构建一次传入。
    """
    if not rows:
        return None
    first = rows[0]
    return next(
        (o.ref for o in options if o.provider_id == first.id and o.model_id == first.default_model),
        next((o.ref for o in options if o.shown), options[0].ref if options else None),
    )


def resolve_defaults(
    rows: list[LlmProvider],
    setting: LlmDefaultsSetting,
    options: list[LlmModelOptionView] | None = None,
) -> ResolvedDefaults:
    """设定 → 实际生效：设定的引用仍能在清单里找到就用它，否则按推荐默认兜底。

    正常情况下 reconcile_defaults 已保证设定可解析，这里的兜底只是安全网
    （如预设目录升级后删掉了某个模型 id）。热路径调用方把已构建的 options 传进来。
    """
    options = build_model_options(rows) if options is None else options
    fallback = recommended_default(rows, options)

    def pick(configured: str | None) -> str | None:
        return qualify_ref(configured, options) or fallback

    return ResolvedDefaults(agent=pick(setting.agent_model), subtitle=pick(setting.subtitle_model))


async def reconcile_defaults(
    rows: list[LlmProvider], previous: list[LlmModelOptionView]
) -> None:
    """实例增删改后维护不变量：有实例则两个默认都已设置且可解析，无实例则清空。

    ``previous`` 是改动前的模型清单。引用的拼写会随实例集合变化（同 id 出现
    在第二家后裸 id 变成「实例名/模型id」、实例改名后前半段变了），所以不能
    按字符串判断设定是否还有效——先用改动前的清单把设定还原成
    (实例 id, 模型 id) 这个稳定身份，再到新清单里找同身份的新引用：
    - 身份仍在：改写成新拼写（用户的选择原样保留）；
    - 身份不在（实例被删、模型从目录移除）：改指最早剩下实例的第一个模型；
    - 设定不在改动前清单里（漂移遗留）：字符串仍可解析就保留，否则同上兜底；
    - 首次接入：两个默认都设为该实例目录里的第一个模型；全部删除：清空。
    """
    store = get_setting_store()
    setting = await store.get(LlmDefaultsSetting)
    options = build_model_options(rows)
    by_identity = {(o.provider_id, o.model_id): o.ref for o in options}
    fallback = recommended_default(rows, options)

    def carry(stored: str | None) -> str | None:
        if stored is None:
            return fallback
        before = next((o for o in previous if o.ref == stored), None)
        if before is not None:
            return by_identity.get((before.provider_id, before.model_id), fallback)
        # 不在改动前的清单里：升级前的裸 id（改写成限定形式）或漂移遗留
        return qualify_ref(stored, options) or fallback

    agent, subtitle = carry(setting.agent_model), carry(setting.subtitle_model)
    if (agent, subtitle) != (setting.agent_model, setting.subtitle_model):
        await store.set(LlmDefaultsSetting(agent_model=agent, subtitle_model=subtitle))
        logger.info("AI 设定已自动调整：智能体默认模型=%s，字幕处理默认模型=%s", agent, subtitle)


async def default_model_ref(session: AsyncSession, purpose: Purpose) -> str:
    """某用途实际生效的默认模型引用；一个实例都没有时返回空串（交给路由报错）。"""
    rows = await LlmProviderRepository(session).list_all()
    setting = await get_setting_store().get(LlmDefaultsSetting)
    return resolve_defaults(rows, setting).ref(purpose) or ""


def _owner_of(
    rows: list[LlmProvider], ref: str | None, options: list[LlmModelOptionView]
) -> tuple[LlmProvider, str] | None:
    """模型引用 → (所属实例, 模型 id)；引用为空或解析不到返回 None。"""
    if not ref:
        return None
    for option in options:
        if option.ref == ref:
            row = next((r for r in rows if r.id == option.provider_id), None)
            return (row, option.model_id) if row is not None else None
    return None


async def resolve_provider_endpoint(session: AsyncSession) -> tuple[str, str, str | None]:
    """解析智能体默认模型所属实例的接入参数，返回 ``(base_url, api_key, user_agent)``。

    端点取值：显式配置 → 预设默认；两者皆空抛 BadRequest。
    user_agent 未配置时为 None（调用方保持自己的默认 UA）。
    这是端点/密钥/UA 解析的唯一判据来源——网络连通性测试（routes/network）
    复用本函数，不允许在别处再实现一遍取值顺序。
    """
    repo = LlmProviderRepository(session)
    rows = await repo.list_all()
    if not rows:
        raise BadRequestException(message_key="errors.llm.providerRequired")
    setting = await get_setting_store().get(LlmDefaultsSetting)
    options = build_model_options(rows)
    owner = _owner_of(rows, resolve_defaults(rows, setting, options).agent, options)
    row = owner[0] if owner else rows[0]
    if row.provider_type == "chatgpt":
        # OAuth bundles include refresh tokens and must never become probe headers.
        raise BadRequestException(message_key="errors.llm.chatgptNetworkProbe")
    base = row.base_url or (get_preset(row.provider_type).base_url or "")
    if not base:
        raise BadRequestException(
            message_key="errors.llm.endpointMissing", params={"name": row.name}
        )
    return base, repo.decrypted_api_key(row) or "", row.user_agent


def _publicly_known(draft: LlmProvider, model_id: str) -> bool:
    """模型的参数能否在公共目录查到（实例对应的那一家，或兼容端点向原厂目录借）。"""
    entry = draft_entry(draft, model_id)
    return (
        entry is not None
        and bool(entry.model.context_window)
        and bool({"public", "borrowed"} & set(entry.model.sources or []))
    )


class LlmConfigService:
    """LLM 供应商实例接入与 AI 设定的业务服务。绑定一个数据库会话。"""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session
        self._repo = LlmProviderRepository(session)

    @staticmethod
    def _assert_not_verifying(row: LlmProvider) -> None:
        """若正在测试连接，拒绝当前操作（409）。"""
        if row.status == ConfigStatus.VERIFYING:
            raise ConflictException(message_key="errors.llm.testing", params={"name": row.name})

    # -- 查询 --------------------------------------------------------------

    async def list_all(self) -> list[LlmProvider]:
        """全部实例，按添加顺序。"""
        return await self._repo.list_all()

    async def get(self, provider_id: int) -> LlmProvider:
        """按 id 取实例；不存在抛 404。"""
        row = await self._repo.get(provider_id)
        if row is None:
            raise NotFoundException(message_key="errors.llm.providerMissing")
        return row

    async def list_model_options(self) -> list[LlmModelOptionView]:
        """对话框与 AI 设定的模型清单（口径见模块说明），智能体默认项标 is_default。"""
        rows = await self._repo.list_all()
        setting = await get_setting_store().get(LlmDefaultsSetting)
        effective = resolve_defaults(rows, setting)
        # 设置页 / 对话框入口，不在热路径；再构建一次只为标记 is_default 与钉住默认模型
        pinned = [ref for ref in (effective.agent, effective.subtitle) if ref]
        return build_model_options(rows, effective.agent, pinned)

    # -- 模型目录（docs/design/llm-model-catalog.md） -------------------------

    async def _pinned(self, rows: list[LlmProvider]) -> list[str]:
        """AI 设定引用的模型（总是显示）。"""
        setting = await get_setting_store().get(LlmDefaultsSetting)
        effective = resolve_defaults(rows, setting)
        return [ref for ref in (effective.agent, effective.subtitle) if ref]

    @staticmethod
    def _listing_view(row: LlmProvider, pinned: list[str]) -> LlmListingView:
        listing = row.model_listing or {}
        error = listing.get("error") or None
        options = build_model_options([row], pinned=pinned)
        catalog_id = effective_catalog_id(row)
        return LlmListingView(
            source=listing.get("source") or "none",
            fetched_at=listing.get("fetched_at") if listing.get("source") == "provider" else None,
            error=(render_value(error["ref"]) if error.get("ref") else error.get("message"))
            if error
            else None,
            total=len(options),
            shown=sum(1 for o in options if o.shown),
            catalog_id=catalog_id,
            catalog_updated_at=get_public_catalog().fetched_at(catalog_id),
        )

    async def provider_views(self, rows: list[LlmProvider] | None = None) -> list[LlmProviderView]:
        """实例视图（带模型目录概况）。"""
        everything = await self._repo.list_all()
        pinned = await self._pinned(everything)
        return [
            LlmProviderView.from_model(row, self._listing_view(row, pinned))
            for row in (everything if rows is None else rows)
        ]

    async def provider_models(self, provider_id: int) -> list[LlmProviderModelView]:
        """「管理模型」：实例目录里的全部模型（含参数未知、已隐藏的），按菜单排序。"""
        row = await self.get(provider_id)
        pinned = await self._pinned(await self._repo.list_all())
        prefix = f"{row.name}/"
        entries = catalog_entries(row)
        shown = visible_ids(
            entries,
            row.model_visibility,
            [ref.removeprefix(prefix) for ref in pinned if ref.startswith(prefix)],
        )
        return [
            LlmProviderModelView(
                model=e.model,
                known=e.known,
                shown=e.id in shown,
                listed=e.listed,
                in_preset=e.in_preset,
                custom=e.custom,
            )
            for e in entries
        ]

    async def set_model_visibility(self, provider_id: int, model_id: str, shown: bool) -> None:
        """显示或隐藏一个模型；与默认规则相同的选择不存（以后默认规则变了照样跟上）。"""
        row = await self.get(provider_id)
        entries = catalog_entries(row)
        entry = next((e for e in entries if e.id == model_id), None)
        if entry is None:
            raise NotFoundException(
                message_key="errors.llm.catalogModelMissing", params={"id": model_id}
            )
        if shown and not entry.known:
            raise BadRequestException(
                message_key="errors.llm.modelParamsUnknown", params={"id": model_id}
            )
        visibility = row.model_visibility or {}
        show = [m for m in visibility.get("show") or [] if m != model_id]
        hide = [m for m in visibility.get("hide") or [] if m != model_id]
        if shown != (model_id in default_shown(entries)):
            (show if shown else hide).append(model_id)
        await self._repo.save_visibility(
            provider_id, {"show": show, "hide": hide} if show or hide else None
        )

    async def discover_models(self, payload: LlmModelDiscoveryPayload) -> list[str]:
        """只读查询；编辑时仅在类型与地址均未改变时允许沿用已存密钥。"""
        try:
            preset = get_preset(payload.provider_type)
        except LlmError as exc:
            raise BadRequestException(render_value(error_reference(exc))) from exc
        if preset.requires_base_url and not payload.base_url:
            raise BadRequestException(
                message_key="errors.llm.endpointRequired", params={"name": preset_name(preset)}
            )
        key = payload.api_key
        if payload.provider_type == "chatgpt":
            if not payload.provider_id or key or payload.base_url not in (None, RESOURCE):
                raise BadRequestException(message_key="errors.llm.chatgptConnectFirst")
            row = await self.get(payload.provider_id)
            if row.provider_type != "chatgpt":
                raise BadRequestException(message_key="errors.llm.notChatgpt")
            config = to_domain_config(row, self._repo.decrypted_api_key(row))
            config.timeout_seconds = _TEST_TIMEOUT
            protocol = build_server_protocol(config, preset)
            try:
                return sorted(set((await protocol.test_connection()).models))
            except LlmError as exc:
                raise BadRequestException(render_value(error_reference(exc))) from exc
            finally:
                await protocol.close()
        if not key and payload.provider_id:
            row = await self.get(payload.provider_id)
            if payload.provider_type != row.provider_type or payload.base_url != row.base_url:
                raise BadRequestException(message_key="errors.llm.apiKeyRefreshRequired")
            key = self._repo.decrypted_api_key(row)
        if not key:
            raise BadRequestException(message_key="errors.llm.apiKeyRequired")
        config = LlmProviderConfig(
            name=payload.name,
            provider_type=payload.provider_type,
            api_key=key,
            base_url=payload.base_url,
            user_agent=payload.user_agent,
            timeout_seconds=_TEST_TIMEOUT,
        )
        protocol = build_protocol(config, preset)
        try:
            info = await protocol.test_connection()
            return sorted(set(info.models))
        except LlmError as exc:
            raise BadRequestException(
                message_key="errors.llm.modelListFailed", params={"error": error_reference(exc)}
            ) from exc
        finally:
            await protocol.close()

    # -- AI 设定 -----------------------------------------------------------

    async def get_defaults(self) -> LlmDefaultsView:
        rows = await self._repo.list_all()
        # 顺手维护不变量：升级前存的裸 id 在这里改写成限定形式落库
        await reconcile_defaults(rows, build_model_options(rows))
        setting = await get_setting_store().get(LlmDefaultsSetting)
        effective = resolve_defaults(rows, setting)
        return LlmDefaultsView(
            agent_model=setting.agent_model,
            subtitle_model=setting.subtitle_model,
            effective_agent_model=effective.agent,
            effective_subtitle_model=effective.subtitle,
        )

    async def update_defaults(
        self, *, agent_model: str | None, subtitle_model: str | None
    ) -> LlmDefaultsView:
        """保存各用途默认模型；引用必须能在当前清单里找到。

        传 null 表示「回到自动推荐」（最早实例的第一个模型），不会把设定清成
        空——只要还有实例，两个默认就始终有值，设置页显示的就是真实生效值。
        """
        rows = await self._repo.list_all()
        options = build_model_options(rows)
        for label, ref in (
            (reference("settings.llm.agentScope"), agent_model),
            (reference("settings.llm.subtitleScope"), subtitle_model),
        ):
            if ref is not None and qualify_ref(ref, options) is None:
                raise BadRequestException(
                    message_key="errors.llm.defaultModelMissing",
                    params={"scope": label, "ref": ref},
                )
        # API / CLI 直接传裸 id 时存成限定形式
        agent_model = qualify_ref(agent_model, options)
        subtitle_model = qualify_ref(subtitle_model, options)
        recommended = recommended_default(rows, options)
        await get_setting_store().set(
            LlmDefaultsSetting(
                agent_model=agent_model or recommended,
                subtitle_model=subtitle_model or recommended,
            )
        )
        return await self.get_defaults()

    # -- 接入写入 ----------------------------------------------------------

    @staticmethod
    def _assert_model_configured(
        preset: ProviderPreset,
        extra_models: list[ModelInfo],
        model_id: str,
        draft: LlmProvider | None = None,
    ) -> None:
        """连接测试模型的严格校验，按供应商类型分两条规则：

        - 固定官方渠道：模型必须在预设目录内；
        - OpenAI 与兼容端点：预设外模型要么能在公共目录查到参数（实例对应的那一家，
          兼容端点没有对应家时向原厂目录借，见 services.llm_catalog），要么在
          extra_models 里带完整参数。「借用」自其它预设目录的模型（按 id 识别）
          参数随目录，同样豁免手填——共享窗口类模型（如 Kimi）本就没有独立输出上限。

        agent 做上下文预算、思考预算、并发决策都依赖这些参数，
        缺参数会让下游全部退化成瞎猜，所以在入口就拦住。
        """
        if preset.models and preset.id != "openai":
            if any(m.id == model_id for m in preset.models):
                return
            raise BadRequestException(
                message_key="errors.llm.modelNotInCatalog",
                params={"id": model_id, "name": preset_name(preset)},
            )
        if any(m.id == model_id for m in preset.models):
            return
        if draft is not None and _publicly_known(draft, model_id):
            return
        custom = next((m for m in extra_models if m.id == model_id), None)
        if custom is None:
            raise BadRequestException(
                message_key="errors.llm.modelParametersRequired", params={"id": model_id}
            )
        # 借用目录模型：任一预设目录里有同 id 条目即豁免手填参数规则
        if any(m.id == custom.id for p in list_presets() for m in p.models):
            return
        if not custom.context_window or not custom.max_output_tokens:
            raise BadRequestException(
                message_key="errors.llm.customModelParameters", params={"id": model_id}
            )
        if (
            custom.thinking_control
            and custom.thinking_control.kind == "budget"
            and not custom.max_thinking_tokens
        ):
            raise BadRequestException(
                message_key="errors.llm.thinkingBudgetRequired", params={"id": model_id}
            )

    async def _validate(
        self,
        *,
        name: str,
        provider_type: str,
        base_url: str | None,
        default_model: str | None,
        extra_models: list[ModelInfo],
        api_protocol: str | None = None,
        catalog_id: str | None = None,
        exclude_id: int | None = None,
    ) -> str:
        """新增与编辑共用的入参校验，返回实际使用的连接测试模型 id。

        校验：类型存在、端点必填、实例名唯一；测试模型未指定时取目录第一个
        （预设目录 → 自定义目录），兼容端点一个模型都没补录时拒绝——没有
        目录的实例接入了也无模型可用。自定义目录里的每个模型都要参数齐全。
        """
        try:
            preset = get_preset(provider_type)
        except LlmError as exc:
            # 未知供应商类型：领域错误翻译成 400（错误信息本身已含可选项提示）
            raise BadRequestException(render_value(error_reference(exc))) from exc
        if preset.requires_base_url and not base_url:
            raise BadRequestException(
                message_key="errors.llm.endpointRequired", params={"name": preset_name(preset)}
            )
        if provider_type == "chatgpt" and base_url not in (None, RESOURCE):
            raise BadRequestException(message_key="errors.llm.chatgptEndpointOnly")
        if api_protocol is not None and api_protocol not in (
            preset.selectable_protocols or [preset.protocol]
        ):
            raise BadRequestException(
                message_key="errors.llm.protocolUnsupported",
                params={
                    "name": preset_name(preset),
                    "protocol": api_protocol,
                    "available": {
                        "message_list": preset.selectable_protocols or [preset.protocol],
                        "separator_key": "common.list.separator",
                    },
                },
            )
        if catalog_id not in (None, CATALOG_DISABLED) and not any(
            p["id"] == catalog_id for p in get_public_catalog().index()
        ):
            raise BadRequestException(
                message_key="errors.llm.catalogUnknown", params={"id": catalog_id}
            )
        # 还没保存的草稿实例：用来在公共目录里查参数（兼容端点按地址识别对应的家）
        draft = LlmProvider(
            name=name,
            provider_type=provider_type,
            base_url=base_url,
            api_key="",
            default_model="",
            extra_models=[m.model_dump(exclude_unset=True) for m in extra_models] or None,
            api_protocol=api_protocol,
            catalog_id=catalog_id,
        )
        if not preset.models or preset.id == "openai":
            if (
                not preset.models
                and not extra_models
                and not (default_model and _publicly_known(draft, default_model))
            ):
                raise BadRequestException(
                    message_key="errors.llm.modelEntryRequired",
                    params={"name": preset_name(preset)},
                )
            for model in extra_models:
                self._assert_model_configured(preset, extra_models, model.id, draft)
        catalog = [*preset.models, *extra_models]
        if default_model and not any(m.id == default_model for m in catalog):
            # 目录外的测试模型：先确认参数来路（查不到会报「须补录参数」），再并入候选
            self._assert_model_configured(preset, extra_models, default_model, draft)
            entry = draft_entry(draft, default_model)
            if entry is not None:
                catalog.append(entry.model)
        effective_protocol = api_protocol or preset.protocol
        compatible = [
            m
            for m in catalog
            if not (effective_protocol == "openai_chat" and m.requires_responses_for_tools)
        ]
        if not compatible:
            raise BadRequestException(message_key="errors.llm.responsesRequired")
        test_model = default_model or compatible[0].id
        self._assert_model_configured(preset, extra_models, test_model, draft)
        model = next(m for m in catalog if m.id == test_model)
        if effective_protocol == "openai_chat" and model.requires_responses_for_tools:
            raise BadRequestException(
                message_key="errors.llm.modelResponsesRequired", params={"id": test_model}
            )
        existing = await self._repo.get_by_name(name)
        if existing is not None and existing.id != exclude_id:
            raise ConflictException(message_key="errors.llm.nameInUse", params={"name": name})
        return test_model

    async def create(
        self,
        *,
        name: str,
        provider_type: str,
        base_url: str | None,
        api_key: str | None,
        default_model: str | None = None,
        extra_models: list[ModelInfo] | None = None,
        user_agent: str | None = None,
        api_protocol: str | None = None,
        catalog_id: str | None = None,
    ) -> LlmProvider:
        """新增实例。状态置 PENDING，等待后台验证。"""
        if not api_key:
            raise BadRequestException(message_key="errors.llm.apiKeyRequired")
        if provider_type == "chatgpt":
            try:
                ChatGPTCredentials.parse(api_key)
            except LlmError as exc:
                raise BadRequestException(render_value(error_reference(exc))) from None
        extras = extra_models or []
        test_model = await self._validate(
            name=name,
            provider_type=provider_type,
            base_url=base_url,
            default_model=default_model,
            extra_models=extras,
            api_protocol=api_protocol,
            catalog_id=catalog_id,
        )
        before = build_model_options(await self._repo.list_all())
        row = await self._repo.create(
            name=name,
            provider_type=provider_type,
            base_url=base_url,
            api_key=api_key,
            default_model=test_model,
            # 只存用户写了的字段：补录按字段覆盖公共目录（docs/design/llm-model-catalog.md §5.1）
            extra_models=[m.model_dump(exclude_unset=True) for m in extras] or None,
            user_agent=user_agent,
            api_protocol=api_protocol,
            catalog_id=catalog_id,
        )
        await reconcile_defaults(await self._repo.list_all(), before)
        return row

    async def update(
        self,
        provider_id: int,
        *,
        name: str,
        provider_type: str,
        base_url: str | None,
        api_key: str | None,
        default_model: str | None = None,
        extra_models: list[ModelInfo] | None = None,
        user_agent: str | None = None,
        api_protocol: str | None | EllipsisType = ...,
        catalog_id: str | None | EllipsisType = ...,
    ) -> LlmProvider:
        """整体覆盖一个实例的接入配置。不存在抛 404，正在验证中抛 409。

        ``api_key`` 为 None 时沿用原 Key；但类型或端点变了必须重填——
        否则只改个端点就能把已存的 Key 发到任意地址。

        ``api_protocol`` 为 ``...`` 表示请求没带这个字段（不认识它的老客户端），
        沿用原值；换了供应商类型时原值未必还合法，回到跟随预设默认。
        """
        row = await self.get(provider_id)
        self._assert_not_verifying(row)
        if row.provider_type == "chatgpt" and provider_type != "chatgpt":
            raise BadRequestException(message_key="errors.llm.chatgptDeleteRequired")
        if provider_type == "chatgpt" and api_key:
            try:
                ChatGPTCredentials.parse(api_key)
            except LlmError as exc:
                raise BadRequestException(render_value(error_reference(exc))) from None
        if not api_key and (provider_type != row.provider_type or base_url != row.base_url):
            raise BadRequestException(message_key="errors.llm.apiKeyRefreshRequired")
        if api_protocol is ...:
            api_protocol = row.api_protocol if provider_type == row.provider_type else None
        if catalog_id is ...:
            catalog_id = row.catalog_id if provider_type == row.provider_type else None
        extras = extra_models or []
        test_model = await self._validate(
            name=name,
            provider_type=provider_type,
            base_url=base_url,
            default_model=default_model,
            extra_models=extras,
            api_protocol=api_protocol,
            catalog_id=catalog_id,
            exclude_id=provider_id,
        )
        before = build_model_options(await self._repo.list_all())
        updated = await self._repo.update(
            provider_id,
            name=name,
            provider_type=provider_type,
            base_url=base_url,
            api_key=api_key,
            default_model=test_model,
            extra_models=[m.model_dump(exclude_unset=True) for m in extras] or None,
            user_agent=user_agent,
            api_protocol=api_protocol,
            catalog_id=catalog_id,
        )
        assert updated is not None  # 上面 get 已确认存在
        # 实例改名或目录改动会改变引用的拼写，按稳定身份改写设定
        await reconcile_defaults(await self._repo.list_all(), before)
        return updated

    async def start_verification(self, provider_id: int) -> LlmProvider:
        """同步占位为 VERIFYING 并返回，随后由调用方排队后台测试任务。

        并发守卫原理见 SiteConfigService.start_verification。
        """
        row = await self.get(provider_id)
        self._assert_not_verifying(row)
        await self._repo.update_status(provider_id, ConfigStatus.VERIFYING)
        return await self.get(provider_id)

    async def delete(self, provider_id: int) -> bool:
        """删除实例；不存在抛 404，正在验证中抛 409。"""
        row = await self.get(provider_id)
        self._assert_not_verifying(row)
        before = build_model_options(await self._repo.list_all())
        revoked = True
        if row.provider_type == "chatgpt":
            async with token_store.lock(row.id):
                await self._session.refresh(row)
                try:
                    revoked = await revoke_credentials(
                        ChatGPTCredentials.parse(self._repo.decrypted_api_key(row))
                    )
                except (LlmError, ValueError):
                    revoked = False
                await self._repo.delete(provider_id)
        else:
            await self._repo.delete(provider_id)
        await reconcile_defaults(await self._repo.list_all(), before)
        return revoked


# ---------------------------------------------------------------------------
# 进程级 LlmRouter 单例：所有 LLM 调用（agent 等）的运行时入口
# ---------------------------------------------------------------------------

_runtime_router = LlmRouter(protocol_factory=build_server_protocol)


async def acquire_llm_router(session: AsyncSession) -> LlmRouter:
    """读取全部实例配置并组装进程级 LlmRouter。

    每次取用都重新读配置并 update_providers：配置指纹未变时底层客户端
    缓存直接复用（零开销），变了则自动重建——不需要「配置已修改」的
    显式通知链路。一个实例都没有时抛 404（中文提示引导去设置页）。

    路由层的 ``default`` / 空引用 = 智能体默认模型：把它所属的实例标为
    is_default 并把该实例的 default_model 设成它，所有不显式选模型的调用
    （IM 通道、会话续聊、手动压缩、CLI）就都跟着 AI 设定走，不必逐处传参。
    """
    repo = LlmProviderRepository(session)
    rows = await repo.list_all()
    if not rows:
        raise NotFoundException(message_key="errors.llm.connectionRequired")
    setting = await get_setting_store().get(LlmDefaultsSetting)
    # 每条消息都经过这里：清单只构建一次，解析默认与找归属都复用它
    options = build_model_options(rows)
    owner = _owner_of(rows, resolve_defaults(rows, setting, options).agent, options)
    configs = []
    for row in rows:
        config = to_domain_config(row, repo.decrypted_api_key(row))
        if owner is not None and owner[0].id == row.id:
            config.is_default = True
            config.default_model = owner[1]
        configs.append(config)
    await _runtime_router.update_providers(configs)
    return _runtime_router


# ---------------------------------------------------------------------------
# 后台连接测试（与 verify_downloader 同构的背景任务）
# ---------------------------------------------------------------------------


async def verify_llm_provider(provider_id: int) -> None:
    """异步验证一个 LLM 供应商实例，并把结论写回状态字段。

    验证判据：用连接测试模型（default_model）发一次 max_tokens=1 的最小
    对话，能收到响应即证明 key、端点、模型 id 均有效。可用模型列表
    best-effort 拉取（部分兼容端点不提供 /models），失败只记日志不影响结论。

    前置约定：调用前状态已被 start_verification 置为 VERIFYING。
    作为背景任务：自开独立数据库会话，绝不向外抛异常 ——
    任何失败都转成 FAILED + last_error。
    """
    async with get_database().session() as session:
        repo = LlmProviderRepository(session)
        row = await repo.get(provider_id)
        if row is None:
            logger.warning("测试连接时 LLM 供应商实例（id=%s）已被删除", provider_id)
            return

        config = to_domain_config(row, repo.decrypted_api_key(row))
        config.timeout_seconds = _TEST_TIMEOUT
        preset = get_preset(row.provider_type)
        protocol = build_server_protocol(config, preset)
        try:
            await protocol.chat(
                ChatRequest(
                    messages=[ChatMessage(role="user", content="ping")],
                    settings=ModelSettings(max_tokens=1),
                ),
                row.default_model,
            )
        except LlmError as exc:
            # 原始中文保留；引用在读取时按当前语言渲染
            logger.info("LLM 连接测试失败「%s」：%s", row.name, exc)
            await repo.update_status(
                provider_id,
                ConfigStatus.FAILED,
                last_error=str(exc),
                last_error_ref=error_reference(exc) if exc.message_key else None,
            )
            return
        except Exception as exc:  # noqa: BLE001 -- 背景任务兜底，绝不外抛
            logger.exception("LLM 连接测试发生未知错误「%s」", row.name)
            await repo.update_status(
                provider_id,
                ConfigStatus.FAILED,
                last_error=source_text(
                    "errors.llm.connection.verificationUnknown",
                    type=type(exc).__name__,
                    error=str(exc),
                ),
                last_error_ref=reference(
                    "errors.llm.connection.verificationUnknown",
                    type=type(exc).__name__,
                    error=str(exc),
                ),
            )
            return
        else:
            # 对话验证已通过；顺手拉模型列表进目录（llm_catalog），拉不到不影响结论
            available: list[str] | None = None
            try:
                info = await protocol.test_connection()
                available = sorted(info.models)
                if row.provider_type == "chatgpt":
                    # 订阅目录来自账号（带账号上报的能力），仍走补录层
                    if info.model_catalog:
                        row.extra_models = [m.model_dump() for m in info.model_catalog]
                else:
                    entries = info.entries or [{"id": m} for m in info.models]
                    await repo.save_listing(provider_id, listing_from_entries(entries))
            except LlmError as exc:
                logger.info("拉取模型列表失败，不影响验证结论：%s", exc)
                if row.provider_type != "chatgpt":
                    listing = listing_after_error(row.model_listing, exc)
                    await repo.save_listing(provider_id, listing)
            except Exception:  # noqa: BLE001
                logger.info("端点未提供模型列表接口，跳过（不影响验证结论）")
            logger.info("LLM 连接测试通过：%s / %s", row.name, row.default_model)
            await repo.update_status(provider_id, ConfigStatus.ACTIVE, available_models=available)
        finally:
            await protocol.close()
