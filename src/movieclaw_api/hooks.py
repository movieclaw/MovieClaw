"""决策钩子（docs/design/plugin-phase2b.md §1、§2）。

插件经钩子**改变决策**：waterfall 是洋葱式中间件（``handler(payload, next)``，可以改输入、
改结果），bail 是「第一个给出答案的说了算」。规则：

- **钩子里不许有副作用**：一次被否决的决策不能留下插件的痕迹；要做事，放到可靠事件或宿主操作里。
- **默认实现永远兜底**：没有监听器时直接走默认实现，零额外开销；监听器出错、超时、返回值不合法，
  按「这个监听器不存在」处理（内核隔离 + 调用方校验）。
- 载荷是冻结模型，监听器要改就构造新的传给 ``next``。

业务代码拿不到内核总线，所以由内置插件 ``core.registries`` 在启动时 ``bind_bus``；
没绑（命令行、单测）时一切走默认实现。
"""

from __future__ import annotations

import inspect
import logging
from collections.abc import Awaitable, Callable
from typing import Any, TypeVar

from pydantic import BaseModel, ConfigDict

from movieclaw_kernel import Event, Mode, Stability
from movieclaw_kernel.events import EventBus

logger = logging.getLogger("movieclaw_api.hooks")

P = TypeVar("P")
R = TypeVar("R")

_bus: EventBus | None = None


def bind_bus(bus: EventBus) -> None:
    global _bus
    _bus = bus


def unbind_bus(bus: EventBus) -> None:
    global _bus
    if _bus is bus:
        _bus = None


def active(event: Event[Any, Any]) -> bool:
    """有没有插件在听：没有就不必构造载荷（零开销的前半段）。"""
    return _bus is not None and bool(_bus.listeners(event))


async def waterfall(
    event: Event[P, R], payload: P, *, terminal: Callable[[P], R | Awaitable[R]]
) -> R:
    if not active(event):
        result = terminal(payload)
        return await result if inspect.isawaitable(result) else result  # type: ignore[return-value]
    assert _bus is not None
    return await _bus.waterfall(event, payload, terminal=terminal)


async def bail(event: Event[P, R], payload: P) -> R | None:
    if not active(event):
        return None
    assert _bus is not None
    return await _bus.bail(event, payload)


class _Frozen(BaseModel):
    model_config = ConfigDict(frozen=True)


def _hook(name: str, mode: Mode, payload: type, result: type, doc: str) -> Event[Any, Any]:
    return Event(
        name,
        mode,
        payload=payload,
        result=result,
        stability=Stability.EXPERIMENTAL,
        doc=doc,
        # 单个监听器 2 秒，整条链 5 秒：超时的跳过，直接走默认实现，决策不会被插件拖住
        timeout=2.0,
        budget=5.0,
    )


# ---------------------------------------------------------------------- 订阅链路
class MediaBrief(_Frozen):
    id: int
    kind: str
    title: str
    original_title: str | None = None
    english_title: str | None = None
    year: int | None = None
    tmdb_id: int | None = None


class Keywords(_Frozen):
    """搜索关键词。``purpose``：``wanted``（补缺搜索）/ ``replacement``（死种换源）。"""

    media: MediaBrief
    subscription_id: int | None
    purpose: str
    keywords: tuple[str, ...]


class CandidateView(_Frozen):
    """一个候选种子（规则已经评估通过）。"""

    key: str
    """``站点/种子编号``，淘汰和排序都用它指代候选。"""
    site_id: str
    torrent_id: str
    title: str
    subtitle: str = ""
    size_bytes: int | None = None
    seeders: int | None = None
    is_free: bool | None = None
    hit_and_run: bool | None = None
    resolution: str | None = None
    media_source: str | None = None
    video_codec: str | None = None
    hdr: tuple[str, ...] = ()
    release_group: str | None = None
    remux: bool = False
    is_pack: bool = False
    units: tuple[tuple[int, int], ...] = ()
    """这个候选能补上的季集（洗版候选为它覆盖的在库季集）。"""
    score: int = 0


class CandidateBatch(_Frozen):
    """一个条目的一批候选。``purpose``：``wanted`` / ``replacement``。"""

    media: MediaBrief
    subscription_id: int | None
    selection_mode: str
    purpose: str
    candidates: tuple[CandidateView, ...]


class Rejection(_Frozen):
    key: str
    reason_code: str
    reason_text: str


class FilterResult(_Frozen):
    rejected: tuple[Rejection, ...] = ()


class RankResult(_Frozen):
    order: tuple[str, ...]
    """候选键的新顺序；必须是原集合的重排，否则忽略。"""


class DownloaderQuery(_Frozen):
    """要为一次投递选下载器。只在调用方没有显式指定下载器时询问。

    ``site_id`` / ``size_bytes`` 在投递预览里可能未知（预览不针对某个具体种子）。
    """

    site_id: str | None = None
    title: str | None = None
    size_bytes: int | None = None
    media_kind: str | None = None
    category: str | None = None
    tags: tuple[str, ...] = ()


class DownloaderChoice(_Frozen):
    downloader_id: int
    reason: str = ""


class TorrentDeletion(_Frozen):
    """即将从下载器删除一个任务（演练不询问）。"""

    downloader_id: int
    info_hash: str
    delete_files: bool


class Veto(_Frozen):
    reason: str


SEARCH_KEYWORDS = _hook(
    "subscription.search.keywords",
    Mode.WATERFALL,
    Keywords,
    tuple,
    "搜索关键词：在内部推导的关键词基础上追加或替换（核心截到 6 个以内）",
)
CANDIDATES_FILTER = _hook(
    "subscription.candidates.filter",
    Mode.WATERFALL,
    CandidateBatch,
    FilterResult,
    "候选淘汰：规则评估之后按插件规则再淘汰（只能淘汰不能添加，淘汰原因写进订阅动态）",
)
CANDIDATES_RANK = _hook(
    "subscription.candidates.rank",
    Mode.WATERFALL,
    CandidateBatch,
    RankResult,
    "候选排序：在核心排序的基础上重排（必须是原集合的重排）",
)
DOWNLOADER_SELECT = _hook(
    "dl.downloader.select",
    Mode.BAIL,
    DownloaderQuery,
    DownloaderChoice,
    "选下载器：按体积 / 站点 / 类型分流（只在没有显式指定时询问；须启用且可用）",
)
TORRENT_BEFORE_DELETE = _hook(
    "dl.torrent.before-delete",
    Mode.BAIL,
    TorrentDeletion,
    Veto,
    "删种前否决：例如 H&R 未达标不许删（否决后删除返回 409）",
)

#: 关键词上限：每个关键词都是一次全站搜索
MAX_KEYWORDS = 6


def media_brief(item: Any) -> MediaBrief:
    return MediaBrief(
        id=item.id,
        kind=item.kind,
        title=item.title,
        original_title=item.original_title,
        english_title=getattr(item, "english_title", None),
        year=item.year,
        tmdb_id=item.tmdb_id,
    )


async def search_keywords(
    item: Any, keywords: list[str], *, subscription_id: int | None, purpose: str
) -> list[str]:
    """关键词钩子；结果去重、去空、截断。"""
    if not active(SEARCH_KEYWORDS):
        return keywords
    payload = Keywords(
        media=media_brief(item),
        subscription_id=subscription_id,
        purpose=purpose,
        keywords=tuple(keywords),
    )
    result = await waterfall(SEARCH_KEYWORDS, payload, terminal=lambda p: p.keywords)
    cleaned = list(dict.fromkeys(str(k).strip() for k in result if str(k).strip()))
    if len(cleaned) > MAX_KEYWORDS:
        logger.info("插件给出的关键词超过 %d 个，只用前 %d 个", MAX_KEYWORDS, MAX_KEYWORDS)
    return cleaned[:MAX_KEYWORDS]
