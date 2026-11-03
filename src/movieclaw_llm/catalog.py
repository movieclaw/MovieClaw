"""模型目录：公共目录投影、思考方言推导、多层按字段合并与菜单规则（docs/design/llm-model-catalog.md）。

纯函数、无 IO——拉取与落盘在应用层（movieclaw_api/services/llm_catalog.py），
构建时的同步脚本（scripts/sync_model_catalog.py）与运行时刷新共用这里的投影代码。

一个模型的每个字段按下面的顺序取第一个有值的来源（低 → 高逐层覆盖）：

    公共目录（实例 catalog_id 那一家；兼容端点没有 catalog_id 时向原厂目录借）
    → 列表响应自带的参数（OpenRouter 等）
    → 预设 yaml 的模型条目（内置修正）
    → 实例 extra_models（用户补录）

上层只覆盖自己**显式写了**的字段（pydantic 的 fields_set），所以 yaml 想表达
「这个模型没有思考控制」时要写 ``thinking_control: null``，不能省略。
"""

from __future__ import annotations

import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass

from movieclaw_llm.models import (
    THINKING_LEVELS,
    ModelCost,
    ModelInfo,
    ProviderPreset,
    ThinkingControl,
)

#: 投影保留的上游字段（其余丢弃）。保留原始形状而非转换后的 ModelInfo：转换规则
#: 迭代时（如推导偏好变了）不必重新下载
PROJECTED_FIELDS = (
    "name",
    "reasoning",
    "reasoning_options",
    "tool_call",
    "interleaved",
    "temperature",
    "release_date",
    "modalities",
    "limit",
    "cost",
    "status",
    "type",
)

#: 公共目录 type 为这些值的不是对话模型
NON_CHAT_TYPES = frozenset(
    {"embedding", "image", "video", "speech", "transcription", "reranking", "realtime"}
)

#: 没有 catalog_id 的兼容端点（自建中转、反代）按 id 借用参数的原厂目录，依次查找
BORROW_SOURCES = (
    "openai",
    "anthropic",
    "google",
    "deepseek",
    "moonshotai-cn",
    "zhipuai",
    "alibaba-cn",
    "xai",
)

#: 没有预设目录的实例（兼容端点、聚合服务商）默认显示的新模型数
DEFAULT_SHOWN = 12

#: 单个实例列表最多收录的模型数；超出部分丢弃
MAX_LISTED = 5000

_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}")
_MEDIA = ("text", "image", "video")


# ---------------------------------------------------------------------------
# 投影：models.dev api.json → 只含需要的家、需要的字段
# ---------------------------------------------------------------------------


def project_catalog(api: dict, catalog_ids: Iterable[str]) -> dict[str, dict]:
    """把 models.dev 的完整响应投影成 ``{catalog_id: {"name", "api", "models"}}``。

    结构不对（不是对象、缺 models、模型不是对象）抛 ValueError：调用方据此让
    整次刷新作废、保留原缓存，绝不落半份坏数据。上游没有的家直接跳过。
    """
    if not isinstance(api, dict):
        raise ValueError("公共目录响应不是 JSON 对象")
    result: dict[str, dict] = {}
    for catalog_id in sorted(set(catalog_ids)):
        provider = api.get(catalog_id)
        if provider is None:
            continue
        models = provider.get("models") if isinstance(provider, dict) else None
        if not isinstance(models, dict):
            raise ValueError(f"公共目录服务商「{catalog_id}」缺少 models")
        projected: dict[str, dict] = {}
        for model_id, raw in sorted(models.items()):
            if not isinstance(raw, dict) or not _valid_id(model_id):
                raise ValueError(f"公共目录服务商「{catalog_id}」的模型「{model_id}」格式不对")
            projected[model_id] = {f: raw[f] for f in PROJECTED_FIELDS if f in raw}
            # 能解析成参数才算合格；类型错的字段在这里炸出来，整份作废
            try:
                public_model_fields(projected[model_id], ["effort"], None)
            except Exception as exc:  # noqa: BLE001 -- 任何形状错误都归为格式不对
                raise ValueError(
                    f"公共目录服务商「{catalog_id}」的模型「{model_id}」字段格式不对：{exc}"
                ) from exc
        result[catalog_id] = {
            "name": provider.get("name") or catalog_id,
            "api": provider.get("api"),
            "models": projected,
        }
    return result


def provider_index(api: dict) -> list[dict]:
    """全部服务商的 ``{id, name, api}`` 索引（按 id 排序），供兼容端点按地址识别。"""
    return [
        {"id": pid, "name": p.get("name") or pid, "api": p.get("api")}
        for pid, p in sorted(api.items())
        if isinstance(p, dict)
    ]


def normalize_base_url(url: str | None) -> str:
    """比较端点用的归一化：小写、去协议、去尾斜杠。"""
    if not url:
        return ""
    return re.sub(r"^https?://", "", url.strip().lower()).rstrip("/")


def match_catalog_id(base_url: str | None, index: Iterable[dict]) -> str | None:
    """按 base_url 在服务商索引里找对应的公共目录 id；找不到返回 None。"""
    target = normalize_base_url(base_url)
    if not target:
        return None
    return next((p["id"] for p in index if normalize_base_url(p.get("api")) == target), None)


# ---------------------------------------------------------------------------
# 字段转换
# ---------------------------------------------------------------------------


def derive_thinking(
    options: list[dict], prefer: list[str], off_body: dict | None
) -> tuple[ThinkingControl | None, int | None]:
    """公共目录的 reasoning_options → (thinking_control, max_thinking_tokens)。

    一个模型可能同时给出多种方式；发哪种字段由服务商的线协议决定，所以按预设
    的 ``prefer`` 依次取第一个出现的。我们的档位词汇表已含 xhigh/max，effort
    原词直用，不做映射。
    """
    by_type = {o.get("type"): o for o in options if isinstance(o, dict)}
    has_toggle = "toggle" in by_type
    for kind in prefer:
        option = by_type.get(kind)
        if option is None:
            continue
        if kind == "effort":
            values = [v for v in option.get("values") or [] if isinstance(v, str)]
            levels = [v for v in THINKING_LEVELS if v in values and v != "off"]
            control = ThinkingControl(
                kind="effort",
                levels=levels,
                supports_off="none" in values or (has_toggle and off_body is not None),
                off_body=off_body if has_toggle and "none" not in values else None,
            )
            return control, None
        if kind == "budget_tokens":
            budget = option.get("max")
            control = ThinkingControl(
                kind="budget",
                supports_off=has_toggle or option.get("min") == 0,
                off_body=off_body,
            )
            return control, budget if isinstance(budget, int) and budget > 0 else None
        return ThinkingControl(kind="toggle", supports_off=True, off_body=off_body), None
    return None, None


def public_model_fields(raw: dict, prefer: list[str], off_body: dict | None) -> dict:
    """公共目录的一个模型 → ModelInfo 的显式字段（只含上游给出的）。"""
    fields: dict = {}
    limit = raw.get("limit") or {}
    for source, target in (
        ("context", "context_window"),
        ("output", "max_output_tokens"),
        ("input", "max_input_tokens"),
    ):
        value = limit.get(source)
        if isinstance(value, int) and value > 0:
            fields[target] = value
    if isinstance(raw.get("name"), str) and raw["name"]:
        fields["display_name"] = raw["name"]
    if isinstance(raw.get("tool_call"), bool):
        fields["supports_tools"] = raw["tool_call"]
    # interleaved 说明思考内容走 API 字段（reasoning_content 等）返回，与我们
    # supports_thinking 的语义一致；OpenAI 等只有加密推理的没有它
    if raw.get("interleaved"):
        fields["supports_thinking"] = True
    if raw.get("temperature") is False:
        fields["fixed_sampling"] = True
    inputs = (raw.get("modalities") or {}).get("input")
    if isinstance(inputs, list):
        fields["modalities"] = [m for m in _MEDIA if m in inputs] or ["text"]
    if raw.get("status") == "deprecated":
        fields["deprecated"] = True
    released = raw.get("release_date")
    if isinstance(released, str) and _DATE.match(released):
        fields["released"] = released[:10]
    cost = _cost(raw.get("cost"), scale=1.0)
    if cost is not None:
        fields["cost"] = cost
    if raw.get("reasoning"):
        control, budget = derive_thinking(raw.get("reasoning_options") or [], prefer, off_body)
        if control is not None:
            fields["thinking_control"] = control
        if budget is not None:
            fields["max_thinking_tokens"] = budget
    return fields


def listing_model_fields(entry: dict) -> dict:
    """列表接口条目自带的参数（OpenRouter 形状），没有就返回空 dict。

    只认结构化字段；``created`` 时间戳不当发布日期（OpenAI 的 created 是内部时间）。
    """
    fields: dict = {}
    context = entry.get("context_length")
    if isinstance(context, int) and context > 0:
        fields["context_window"] = context
    top = entry.get("top_provider") or {}
    output = top.get("max_completion_tokens") if isinstance(top, dict) else None
    if isinstance(output, int) and output > 0:
        fields["max_output_tokens"] = output
    arch = entry.get("architecture") or {}
    inputs = arch.get("input_modalities") if isinstance(arch, dict) else None
    if isinstance(inputs, list):
        fields["modalities"] = [m for m in _MEDIA if m in inputs] or ["text"]
    params = entry.get("supported_parameters")
    if isinstance(params, list) and params:
        fields["supports_tools"] = "tools" in params
    pricing = entry.get("pricing")
    if isinstance(pricing, dict):
        cost = _cost(
            {
                "input": pricing.get("prompt"),
                "output": pricing.get("completion"),
                "cache_read": pricing.get("input_cache_read"),
                "cache_write": pricing.get("input_cache_write"),
            },
            scale=1_000_000,  # OpenRouter 报的是每 token 美元
        )
        if cost is not None:
            fields["cost"] = cost
    if fields and isinstance(entry.get("name"), str) and entry["name"]:
        fields["display_name"] = entry["name"]
    return fields


def _cost(raw: object, *, scale: float) -> ModelCost | None:
    if not isinstance(raw, dict):
        return None
    values: dict[str, float] = {}
    for key in ("input", "output", "cache_read", "cache_write"):
        try:
            value = float(raw[key]) * scale if raw.get(key) is not None else 0.0
        except (TypeError, ValueError):
            continue
        if value > 0:
            values[key] = round(value, 6)
    # 价格为 0 视为未知；输入输出都未知就整体不给
    if not values.get("input") and not values.get("output"):
        return None
    return ModelCost(**values)


def is_chat_model(raw: dict) -> bool:
    """公共目录条目是不是对话模型（非嵌入/图像/语音等、输出含文本）。"""
    if raw.get("type") in NON_CHAT_TYPES:
        return False
    outputs = (raw.get("modalities") or {}).get("output")
    return not isinstance(outputs, list) or "text" in outputs


def sanitize_listing(entries: Iterable[object]) -> list[dict]:
    """列表接口条目校验：id 合法、去重保序、最多 MAX_LISTED 条；不合格条目丢弃。"""
    seen: set[str] = set()
    result: list[dict] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        model_id = entry.get("id")
        if not isinstance(model_id, str) or not _valid_id(model_id) or model_id in seen:
            continue
        seen.add(model_id)
        result.append(entry)
        if len(result) >= MAX_LISTED:
            break
    return result


def _valid_id(model_id: str) -> bool:
    return (
        0 < len(model_id.encode()) <= 256
        and model_id.isprintable()
        and not any(c.isspace() for c in model_id)
    )


def explicit_fields(model: ModelInfo) -> dict:
    """一条 ModelInfo 显式写了的字段（合并时上层只覆盖这些）。"""
    return model.model_dump(exclude_unset=True, exclude={"id", "sources"})


# ---------------------------------------------------------------------------
# 合并与菜单规则
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CatalogEntry:
    """实例目录里的一个模型及菜单判定需要的标注。"""

    model: ModelInfo
    #: 参数已知（有上下文窗口，或是预设/补录的模型）——只有已知的能进菜单
    known: bool
    #: 是否在服务商列表里；None = 实例没有成功拉到过列表
    listed: bool | None
    in_preset: bool
    custom: bool

    @property
    def id(self) -> str:
        return self.model.id

    @property
    def qualifies(self) -> bool:
        """满足默认显示的前提：参数已知、没停用、不是「列表未包含」。

        预设模型例外于最后一条：各家 /models 是否列全尚未逐家实测，列表漏了就把
        升级前菜单里的模型藏起来代价太大；真下线的由 yaml 修正或停用标记处理。
        """
        return (
            self.known
            and not self.model.deprecated
            and (self.listed is not False or self.in_preset)
        )


def merge_model(model_id: str, layers: list[tuple[str, dict]]) -> ModelInfo:
    """按字段合并（layers 低 → 高优先），sources 记参与的来源（高优先在前）。"""
    data: dict = {"id": model_id}
    sources: list[str] = []
    for source, fields in layers:
        if fields:
            data.update(fields)
            sources.append(source)
    data["sources"] = sources[::-1]
    return ModelInfo.model_validate(data)


def build_catalog(
    *,
    preset: ProviderPreset,
    protocol: str,
    public_models: dict[str, dict],
    listing: list[dict] | None,
    extras: list[ModelInfo],
    borrow: Callable[[str], dict | None] | None = None,
    declared: Iterable[str] = (),
) -> list[CatalogEntry]:
    """合成一个实例的完整目录（可路由的全部模型），按菜单排序。

    候选集合：列表成功时 = 列表 ∪ 预设 ∪ 补录；没有列表时 = 预设 ∪ 补录（与
    升级前一致）；``declared`` 是另外总要收录的 id（实例的连接测试模型——兼容
    端点可以只填一个公共目录查得到的测试模型就接入）。资格不合格的（非对话
    模型、调不了工具）不收录，但补录的模型例外——用户明说要的不替他过滤。
    """
    preset_models = {m.id: m for m in preset.models}
    extra_models = {m.id: m for m in extras}
    listed_entries = {e["id"]: e for e in listing or []}
    ids = list(dict.fromkeys([*listed_entries, *preset_models, *extra_models, *declared]))

    entries: list[CatalogEntry] = []
    for model_id in ids:
        layers: list[tuple[str, dict]] = []
        raw = public_models.get(model_id)
        source = "public"
        if raw is None and borrow is not None:
            raw, source = borrow(model_id), "borrowed"
        if raw is not None:
            layers.append(
                (source, public_model_fields(raw, preset.thinking_prefer, preset.thinking_off_body))
            )
        if model_id in listed_entries:
            layers.append(("listing", listing_model_fields(listed_entries[model_id])))
        if model_id in preset_models:
            layers.append(("preset", explicit_fields(preset_models[model_id])))
        custom = model_id in extra_models
        if custom:
            layers.append(("custom", explicit_fields(extra_models[model_id])))
        model = merge_model(model_id, layers)
        if not custom and (
            (raw is not None and not is_chat_model(raw)) or not model.supports_tools
        ):
            continue
        # 当前协议调不了工具的模型（只能走 Responses 的）对 agent 没用
        if protocol == "openai_chat" and model.requires_responses_for_tools:
            continue
        entries.append(
            CatalogEntry(
                model=model,
                # 预设是策展过的、补录是用户（或 ChatGPT 账号目录）明说的，都算已知
                known=model_id in preset_models or custom or bool(model.context_window),
                listed=None if listing is None else model_id in listed_entries,
                in_preset=model_id in preset_models,
                custom=custom,
            )
        )
    # 预设按 yaml 顺序在前（旗舰在前的约定），其余按发布日期新 → 旧、同日按 id，无日期垫底
    order = {m: i for i, m in enumerate(preset_models)}
    head = sorted((e for e in entries if e.in_preset), key=lambda e: order[e.id])
    tail = sorted((e for e in entries if not e.in_preset), key=lambda e: e.id)
    tail.sort(key=lambda e: e.model.released or "", reverse=True)
    return [*head, *tail]


def default_shown(entries: list[CatalogEntry]) -> set[str]:
    """默认进菜单的模型 id。

    - 补录的模型总是显示；
    - 预设模型：满足前提（已知、未停用）就显示——它们是策展过的；
    - 其余模型：有预设目录的实例只显示**比预设里最新的还新**的（新出的模型自动
      出现，老旧型号不刷屏）；没有预设目录的实例显示最新的 DEFAULT_SHOWN 个。
    """
    shown = {e.id for e in entries if e.custom}
    shown |= {e.id for e in entries if e.in_preset and e.qualifies}
    newest_preset = max((e.model.released or "" for e in entries if e.in_preset), default="")
    has_preset = any(e.in_preset for e in entries)
    fresh = [
        e
        for e in entries
        if not e.in_preset
        and not e.custom
        and e.qualifies
        and (not has_preset or (e.model.released or "") > newest_preset)
    ]
    shown |= {e.id for e in fresh[:DEFAULT_SHOWN]}
    return shown


def visible_ids(
    entries: list[CatalogEntry], visibility: dict | None, pinned: Iterable[str] = ()
) -> set[str]:
    """最终显示集合 = （默认显示 ∪ 用户显示 ∪ pinned）− 用户隐藏。

    pinned 是 AI 设定引用的模型：用户隐藏了也照样显示，否则设置页的默认模型
    下拉框里找不到当前值。用户「显示」参数未知的模型无效——菜单里的模型一定有参数。
    """
    visibility = visibility or {}
    known = {e.id for e in entries if e.known}
    show = set(visibility.get("show") or []) & known
    hide = set(visibility.get("hide") or [])
    return ((default_shown(entries) | show) - hide) | (set(pinned) & {e.id for e in entries})
