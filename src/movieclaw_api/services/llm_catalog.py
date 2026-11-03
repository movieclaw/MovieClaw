"""模型目录的 IO 部分：公共目录的快照与刷新、实例模型列表的拉取。

设计见 docs/design/llm-model-catalog.md。

合并与菜单规则是纯函数，在 movieclaw_llm.catalog；这里只管数据从哪来、存哪去：

- 公共目录：随包快照（src/movieclaw_llm/providers/catalog）+ 本地缓存
  （<data_dir>/cache/llm-catalog），逐家取较新者。每日任务带 ETag 刷新，任何
  一家投影失败整次作废、保留原缓存；缓存可随时删除，只损失时间；
- 实例列表：服务商 /models 的结果存在 llm_provider.model_listing，验证通过时、
  每日任务（超过 24 小时）、手动刷新时更新；失败保留旧列表并记下原因。
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx

import movieclaw_llm
from movieclaw_api.core.config import get_settings
from movieclaw_api.i18n.llm import error_reference
from movieclaw_api.settings import LlmCatalogSetting, get_setting_store
from movieclaw_db.engine import get_database
from movieclaw_db.models.llm_provider import LlmProvider
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository
from movieclaw_llm import LlmError
from movieclaw_llm.catalog import (
    BORROW_SOURCES,
    CatalogEntry,
    build_catalog,
    match_catalog_id,
    project_catalog,
    provider_index,
    sanitize_listing,
)
from movieclaw_llm.models import ModelInfo
from movieclaw_llm.providers import get_preset
from movieclaw_net.egress import egress_transport
from movieclaw_scheduler.registry import register_task

logger = logging.getLogger("movieclaw_api.llm_catalog")

PUBLIC_CATALOG_URL = "https://models.dev/api.json"
#: 公共目录响应体上限（2026-10 实测约 6 MB）
_MAX_BYTES = 32 * 1024 * 1024
_TIMEOUT = 30.0
#: 公共目录与实例列表的刷新间隔
REFRESH_AFTER = timedelta(hours=24)
#: 实例 catalog_id 取这个值表示「不使用公共目录」（NULL 是自动识别）
CATALOG_DISABLED = "none"
#: 列表条目只保留目录第 3 层会用到的键，大列表（OpenRouter）不把描述等存进库
_LISTING_KEYS = (
    "id",
    "name",
    "context_length",
    "top_provider",
    "architecture",
    "pricing",
    "supported_parameters",
)
#: 每日任务里同时刷新的实例数
_LISTING_CONCURRENCY = 4

_BUNDLED = Path(movieclaw_llm.__file__).parent / "providers" / "catalog"


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(value: datetime) -> str:
    # 精确到微秒：列表的 fetched_at 同时是合并结果的缓存键，同一秒内连刷两次也要能区分
    return value.isoformat(timespec="microseconds").replace("+00:00", "Z")


def _parse(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def _write_json(path: Path, data: object) -> None:
    """先写临时文件再 rename，读者永远看不到半个文件。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


# ---------------------------------------------------------------------------
# 公共目录
# ---------------------------------------------------------------------------


class PublicCatalog:
    """随包快照 + 本地缓存，逐家取 fetched_at 较新的一份。进程内单例。"""

    def __init__(self, bundled_dir: Path, cache_dir: Path) -> None:
        self._bundled = bundled_dir
        self._cache = cache_dir
        self._providers: dict[str, dict] = {}
        self._index: list[dict] | None = None
        self._lock = asyncio.Lock()
        #: 内容版本：刷新有变化时 +1，合并结果的缓存键带上它
        self.version = 0

    def _load(self, catalog_id: str) -> dict:
        if catalog_id not in self._providers:
            best: dict = {}
            for base in (self._bundled, self._cache):
                path = base / f"{catalog_id}.json"
                try:
                    data = json.loads(path.read_text(encoding="utf-8"))
                except FileNotFoundError:
                    continue
                except (OSError, ValueError):
                    logger.warning("公共模型目录文件损坏，已忽略：%s", path)
                    continue
                if (data.get("fetched_at") or "") >= (best.get("fetched_at") or ""):
                    best = data
            self._providers[catalog_id] = best
        return self._providers[catalog_id]

    def models(self, catalog_id: str | None) -> dict[str, dict]:
        return self._load(catalog_id).get("models") or {} if catalog_id else {}

    def fetched_at(self, catalog_id: str | None) -> str | None:
        return self._load(catalog_id).get("fetched_at") if catalog_id else None

    def borrow(self, model_id: str) -> dict | None:
        """按 id 在原厂目录里找（没有 catalog_id 的兼容端点用）。"""
        for source in BORROW_SOURCES:
            raw = self.models(source).get(model_id)
            if raw is not None:
                return raw
        return None

    def index(self) -> list[dict]:
        if self._index is None:
            self._index = []
            for base in (self._cache, self._bundled):
                try:
                    self._index = json.loads((base / "_index.json").read_text(encoding="utf-8"))
                    break
                except (OSError, ValueError):
                    continue
        return self._index

    def known_ids(self) -> set[str]:
        """快照收录的家：刷新时至少投影这些。"""
        return {p.stem for p in self._bundled.glob("*.json") if not p.name.startswith("_")}

    def _state(self) -> dict:
        try:
            return json.loads((self._cache / "state.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def checked_at(self) -> datetime | None:
        return _parse(self._state().get("checked_at"))

    async def refresh(self, extra_ids: set[str], *, force: bool = False) -> bool:
        """拉 models.dev 并更新本地缓存；返回内容是否有变化。失败只记日志。"""
        async with self._lock:
            state = self._state()
            checked = _parse(state.get("checked_at"))
            if not force and checked is not None and _now() - checked < REFRESH_AFTER:
                return False
            headers = {"If-None-Match": state["etag"]} if state.get("etag") else {}
            try:
                status, etag, body = await _fetch(PUBLIC_CATALOG_URL, headers)
                if status == 304:
                    _write_json(self._cache / "state.json", {**state, "checked_at": _iso(_now())})
                    return False
                api = json.loads(body)
                projected = project_catalog(api, self.known_ids() | extra_ids)
                index = provider_index(api)
            except Exception as exc:  # noqa: BLE001 -- 目录刷新失败不影响任何功能
                logger.warning("更新公共模型目录失败，继续使用现有版本：%s", exc)
                return False
            fetched_at = _iso(_now())
            changed = False
            for catalog_id, data in projected.items():
                if self.models(catalog_id) != data["models"]:
                    changed = True
                _write_json(self._cache / f"{catalog_id}.json", {**data, "fetched_at": fetched_at})
            _write_json(self._cache / "_index.json", index)
            _write_json(self._cache / "state.json", {"etag": etag, "checked_at": fetched_at})
            self._providers.clear()
            self._index = None
            if changed:
                self.version += 1
            logger.info(
                "公共模型目录已更新（%d 家，%s）", len(projected), "有变化" if changed else "无变化"
            )
            return changed


async def _fetch(url: str, headers: dict) -> tuple[int, str | None, bytes]:
    """GET，带大小上限；只接受 HTTPS（调用方只传固定地址，这里再兜一层）。"""
    if not url.startswith("https://"):
        # i18n-ignore: internal diagnostic, only written to the log
        raise ValueError("公共模型目录只接受 HTTPS 地址")
    async with (
        httpx.AsyncClient(transport=egress_transport("llm"), timeout=_TIMEOUT) as client,
        client.stream("GET", url, headers=headers) as response,
    ):
        if response.status_code == 304:
            return 304, None, b""
        response.raise_for_status()
        chunks: list[bytes] = []
        size = 0
        async for chunk in response.aiter_bytes():
            size += len(chunk)
            if size > _MAX_BYTES:
                # i18n-ignore: internal diagnostic, only written to the log
                raise ValueError("公共模型目录响应超过 32 MiB")
            chunks.append(chunk)
        return response.status_code, response.headers.get("etag"), b"".join(chunks)


_public: PublicCatalog | None = None


def get_public_catalog() -> PublicCatalog:
    global _public
    if _public is None:
        cache = Path(get_settings().data_dir) / "cache" / "llm-catalog"
        _public = PublicCatalog(_BUNDLED, cache)
    return _public


def set_public_catalog(catalog: PublicCatalog | None) -> None:
    """测试用：替换进程内单例。"""
    global _public
    _public = catalog
    _entries_memo.clear()


# ---------------------------------------------------------------------------
# 实例目录（合并结果）
# ---------------------------------------------------------------------------


def effective_catalog_id(row: LlmProvider) -> str | None:
    """实例用哪一家的公共目录：用户指定 → 预设声明 → 按 base_url 自动识别。"""
    if row.catalog_id == CATALOG_DISABLED:
        return None
    if row.catalog_id:
        return row.catalog_id
    preset = get_preset(row.provider_type)
    if preset.catalog_id:
        return preset.catalog_id
    if preset.requires_base_url:
        return match_catalog_id(row.base_url, get_public_catalog().index())
    return None


def _extras(row: LlmProvider) -> list[ModelInfo]:
    from movieclaw_llm.chatgpt import restore_account_model_controls

    models = [ModelInfo.model_validate(m) for m in row.extra_models or []]
    return restore_account_model_controls(models) if row.provider_type == "chatgpt" else models


_entries_memo: dict[int, tuple[str, list[CatalogEntry]]] = {}


def _build(row: LlmProvider, listing: list[dict] | None) -> list[CatalogEntry]:
    public = get_public_catalog()
    catalog_id = effective_catalog_id(row)
    preset = get_preset(row.provider_type)
    borrow = (
        public.borrow
        if catalog_id is None and row.catalog_id != CATALOG_DISABLED and preset.requires_base_url
        else None
    )
    return build_catalog(
        preset=preset,
        protocol=row.api_protocol or preset.protocol,
        public_models=public.models(catalog_id),
        listing=listing,
        extras=_extras(row),
        borrow=borrow,
        declared=[row.default_model] if row.default_model else [],
    )


def catalog_entries(row: LlmProvider) -> list[CatalogEntry]:
    """实例的完整合并目录（按菜单排序）。按配置与数据版本缓存，热路径可反复调用。"""
    listing = row.model_listing or {}
    key = json.dumps(
        [
            row.provider_type,
            row.api_protocol,
            row.base_url,
            row.catalog_id,
            row.default_model,
            row.extra_models,
            listing.get("fetched_at"),
            listing.get("source"),
            get_public_catalog().version,
        ],
        sort_keys=True,
        default=str,
    )
    cached = _entries_memo.get(row.id) if row.id else None
    if cached and cached[0] == key:
        return cached[1]
    entries = _build(row, listing.get("models") if listing.get("source") == "provider" else None)
    # 还没落库的草稿实例（新增前的校验）不进缓存：id 为空会互相串
    if row.id:
        _entries_memo[row.id] = (key, entries)
    return entries


def draft_entry(row: LlmProvider, model_id: str) -> CatalogEntry | None:
    """把某个模型当作出现在列表里，看它在这个（可能还没保存的）实例里合并成什么样。

    接入表单用：兼容端点填的测试模型若能在公共目录查到参数，就不必手填。
    不合格（非对话模型、调不了工具）返回 None。
    """
    return next((e for e in _build(row, [{"id": model_id}]) if e.id == model_id), None)


def catalog_digest(row: LlmProvider) -> str:
    """合并目录的内容摘要（进 LlmRouter 客户端缓存指纹）。"""
    entries = catalog_entries(row)
    # 缓存键已涵盖目录的全部输入，摘要它即可；草稿实例才整份序列化
    memo = _entries_memo.get(row.id) if row.id else None
    payload = (
        memo[0]
        if memo
        else json.dumps([e.model.model_dump(mode="json") for e in entries], sort_keys=True)
    )
    return hashlib.sha1(payload.encode()).hexdigest()


# ---------------------------------------------------------------------------
# 实例列表
# ---------------------------------------------------------------------------


def listing_from_entries(entries: list[dict]) -> dict:
    """列表接口的原始条目 → 存库的 model_listing（成功）。"""
    models = [
        {k: e[k] for k in _LISTING_KEYS if e.get(k) is not None} for e in sanitize_listing(entries)
    ]
    return {"fetched_at": _iso(_now()), "source": "provider", "error": None, "models": models}


def listing_after_error(previous: dict | None, exc: LlmError) -> dict:
    """列表拉取失败：404/405 记为端点不提供列表；其余保留旧列表并记下原因。"""
    status = (exc.params or {}).get("status")
    if status in (404, 405):
        return {"fetched_at": _iso(_now()), "source": "unsupported", "error": None, "models": []}
    kept = dict(previous or {"source": "none", "models": []})
    kept["error"] = {
        "message": str(exc)[:500],
        "ref": error_reference(exc) if exc.message_key else None,
        "at": _iso(_now()),
    }
    return kept


async def refresh_listing(provider_id: int) -> bool:
    """立即拉一次实例的模型列表并落库；返回是否成功。ChatGPT 订阅的目录来自账号，跳过。"""
    from movieclaw_api.services.chatgpt_auth import build_server_protocol
    from movieclaw_api.services.llm_config import _TEST_TIMEOUT, to_domain_config

    async with get_database().session() as session:
        repo = LlmProviderRepository(session)
        row = await repo.get(provider_id)
        if row is None or row.provider_type == "chatgpt":
            return False
        config = to_domain_config(row, repo.decrypted_api_key(row))
        config.timeout_seconds = _TEST_TIMEOUT
        protocol = build_server_protocol(config, get_preset(row.provider_type))
        try:
            info = await protocol.test_connection()
            entries = info.entries or [{"id": m} for m in info.models]
            listing, ok = listing_from_entries(entries), True
        except LlmError as exc:
            logger.info("拉取模型列表失败「%s」：%s", row.name, exc)
            listing, ok = listing_after_error(row.model_listing, exc), False
        finally:
            await protocol.close()
        await repo.save_listing(provider_id, listing)
        return ok


def listing_stale(row: LlmProvider) -> bool:
    listing = row.model_listing or {}
    error = listing.get("error") or {}
    last = _parse(error.get("at")) or _parse(listing.get("fetched_at"))
    return last is None or _now() - last >= REFRESH_AFTER


async def refresh_all(*, force: bool = False, provider_ids: set[int] | None = None) -> None:
    """刷新公共目录与（超过 24 小时的）实例列表，有变化时维护 AI 设定的不变量。"""
    from movieclaw_api.services.llm_config import build_model_options, reconcile_defaults

    async with get_database().session() as session:
        rows = await LlmProviderRepository(session).list_all()
    before = build_model_options(rows)
    # 关掉联网开关后连手动刷新也不碰 models.dev（只刷实例列表）
    if (await get_setting_store().get(LlmCatalogSetting)).online:
        needed = {cid for row in rows if (cid := effective_catalog_id(row))}
        await get_public_catalog().refresh(needed, force=force)
    targets = [
        row
        for row in rows
        if row.provider_type != "chatgpt"
        and (provider_ids is None or row.id in provider_ids)
        and (force or listing_stale(row))
    ]
    semaphore = asyncio.Semaphore(_LISTING_CONCURRENCY)

    async def one(row: LlmProvider) -> None:
        async with semaphore:
            await refresh_listing(row.id or 0)

    await asyncio.gather(*(one(row) for row in targets))
    async with get_database().session() as session:
        rows = await LlmProviderRepository(session).list_all()
    await reconcile_defaults(rows, before)


@register_task(
    "llm_catalog_refresh",
    title="更新模型目录",
    title_key="settings.scheduledTasks.catalog.llmCatalogRefreshTitle",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=6 * 3600,
    description=(
        "从各模型服务商拉取最新的可用模型列表，并从 models.dev 更新模型参数。"
        "距上次更新不足 24 小时的会跳过；没有接入任何模型服务时什么也不做。"
    ),
    description_key="settings.scheduledTasks.catalog.llmCatalogRefreshDescription",
)
async def refresh_model_catalog() -> None:
    async with get_database().session() as session:
        if not await LlmProviderRepository(session).has_any():
            return
    await refresh_all()
