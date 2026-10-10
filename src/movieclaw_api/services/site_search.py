"""跨站点聚合搜索/浏览——把一次查询并发投递给所有可用站点，合并结果。

两种模式共用一条管线
------------------
关键词非空 = **搜索**（打各站搜索页）；关键词留空 = **浏览**（打各站种子浏览页，
只按分类翻页看最新发布）。分岔只发生在 ``_fetch_one`` 里选调 ``search`` 还是
``list_torrents`` 这一处，扇出、错误隔离、结果富化、流式事件全部共用，
因此前端也只需要一套渲染。

为什么可以并发
--------------
搜索是**只读**操作，不像种子同步那样对同站有写唯一键约束，因此天然适合并发扇出：
本模块对所有「已启用且验证通过」的站点同时发起 ``search``，并以两种口径消费结果——
``stream_search_all_sites`` 按站点完成先后**流式**产出事件（SSE 端点用，快站先出结果），
``search_all_sites`` 等全部完成后合并返回（阻塞版，基于前者实现）。

错误隔离（核心不变量）
--------------------
单站失败（认证过期 / 网络异常 / 站点改版解析失败）**绝不能拖垮整次搜索**。每个站点
的取数都包在 ``_fetch_one`` 的 try/except 里，失败降级为「该站 0 条 + 可读中文原因」，
其它站点照常返回。错误文案复用 ``verification.friendly_error``，与站点验证的报错口径一致。

站点实例一律通过 ``SiteAccessManager`` 复用（已认证、连接池共享），调用方**不 close**。
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator

from pydantic import BaseModel

from movieclaw_api.schemas.search import (
    SearchResponse,
    SearchStreamDone,
    SearchStreamSite,
    SearchStreamStart,
    SiteSearchStatus,
    SiteStreamError,
    SiteStreamResult,
    TorrentHit,
)
from movieclaw_api.services.site_access import get_site_access
from movieclaw_api.services.verification import friendly_error
from movieclaw_db.engine import get_database
from movieclaw_db.models.site_credential import ConfigStatus, SiteCredential
from movieclaw_db.repositories.credential_repo import CredentialRepository
from movieclaw_enrich import enrich
from movieclaw_matcher import normalize_title
from movieclaw_tracker.models import SearchQuery, TorrentCategory, TorrentListItem
from movieclaw_tracker.registry import SiteNotFoundError, get_site_config

logger = logging.getLogger("movieclaw_api.site_search")

#: 一次搜索最多几个词（主词 + 同搜词）。与订阅召回词同口径（英文名/中文名/原名），
#: 每多一个词每站就多一次请求，3 个已覆盖站点命名的全部常见写法
MAX_SEARCH_KEYWORDS = 3


def also_keywords_of(keyword: str, also: list[str] | None) -> list[str]:
    """同搜词清洗：去空白，按匹配内核的归一化形式去重（含与主词重复的），至多补齐到
    ``MAX_SEARCH_KEYWORDS`` 个。浏览模式（主词为空）没有同搜词。

    去重口径与订阅的 ``recall_keywords`` 一致：大小写/分隔符的差异不值得多打一次站点，
    但下发原样文本——站点搜索吃的是原文。
    """
    if not keyword:
        return []
    seen = {normalize_title(keyword)}
    picked: list[str] = []
    for raw in also or []:
        text = raw.strip()
        key = normalize_title(text)
        if not key or key in seen:
            continue
        seen.add(key)
        picked.append(text)
        if len(picked) >= MAX_SEARCH_KEYWORDS - 1:
            break
    return picked


def _build_hits(site_id: str, name: str, items: list[TorrentListItem]) -> list[TorrentHit]:
    """把单站结果映射为 TorrentHit（含扩充属性计算）。**必须在工作线程调用**。

    ``enrich`` 自 v3 起含同步 NER 模型推理（CPU 密集，弱机型单条可达几十毫秒），
    整页上百条在事件循环里内联算会卡住 SSE 流、健康检查与其它并发请求——
    口径与种子同步侧一致（torrent_sync._to_observations）。多站并发完成时本函数
    会在多个线程同时执行：模型层的懒加载有锁，ONNX session 与 tokenizer 的
    推理调用本身线程安全。
    """
    return [
        TorrentHit(
            site_id=site_id,
            site_name=name,
            attrs=enrich(
                item.title,
                item.subtitle,
                item.category.value if item.category else None,
            ),
            **item.model_dump(),
        )
        for item in items
    ]


def _display_name(site_id: str) -> str:
    """取站点展示名；站点未注册时退回 site_id，保证结果始终可标注来源。"""
    try:
        return get_site_config(site_id).display_name
    except SiteNotFoundError:
        return site_id


async def _active_sites() -> list[SiteCredential]:
    """取所有「已启用且验证通过」的站点——只有这些才参与搜索。

    判据与种子同步保持一致（``enabled`` 且 ``status == ACTIVE``）：``enabled`` 只是用户
    意愿开关，真正「能发起访问」还要求验证通过。
    """
    async with get_database().session() as session:
        creds = await CredentialRepository(session).list_all()
    return [c for c in creds if c.enabled and c.status == ConfigStatus.ACTIVE]


async def _fetch_one(
    cred: SiteCredential,
    *,
    keyword: str,
    also_keywords: list[str] | None = None,
    categories: list[TorrentCategory] | None = None,
    page: int = 1,
) -> tuple[list[TorrentHit], SiteSearchStatus]:
    """从单个站点取一页种子，全程吞异常：失败降级为带 error 的状态，不向上抛。

    **关键词有无决定走哪个入口**，这是「搜索」与「浏览」共用一条管线的分岔点：
    - ``keyword`` 非空 → ``site.search``，站点的搜索页（torrents.php?search=…）；
    - ``keyword`` 为空 → ``site.list_torrents``，站点的**种子浏览页**（分类 + 翻页），
      对应"不输关键词、只挑分类逛最新发布"的场景。

    两个入口返回的条目类型完全相同（``TorrentListItem``），因此下游的富化、
    错误隔离、流式事件全部无需区分模式。

    成功与失败的状态里都带 ``elapsed_ms``：失败站的耗时尤其有诊断价值
    （十几秒后才失败的基本是超时，秒失败的多半是认证/解析问题）。

    **同搜词**（``also_keywords``，详情页「搜索资源」带上英文名/原名）：在本站内**依次**
    搜主词和每个同搜词，按种子 id 合并成一份结果——对外仍是这个站的一次结果，事件与
    载荷结构不变。依次而非并发：对同一站点同时打几次搜索页更容易撞上站点限流。
    任一个词成功即算成功（失败的词只记日志）；全部失败才降级为该站失败。
    ``has_more``：任一个词明确还有下一页即为 True，否则有一个不确定就是 None。
    """
    site_id = cred.site_id
    name = _display_name(site_id)
    started = time.monotonic()
    elapsed = lambda: int((time.monotonic() - started) * 1000)  # noqa: E731
    terms = [keyword, *(also_keywords or [])] if keyword else [""]
    items: list[TorrentListItem] = []
    seen: set[str] = set()
    pages_more: list[bool | None] = []
    reason: str | None = None
    for term in terms:
        try:
            site = await get_site_access().get(site_id)  # 已认证共享实例，勿 close
            if term:
                result = await site.search(
                    SearchQuery(keyword=term, categories=categories or None, page=page)
                )
                found, has_more = result.items, result.has_more
            else:
                listed = await site.list_torrents(categories=categories or None, page=page)
                found, has_more = listed.items, listed.has_more
        except Exception as exc:  # noqa: BLE001 —— 单站失败必须隔离，不能拖垮整次搜索
            reason = reason or friendly_error(exc)
            logger.warning(
                "站点 %s %s失败：%s",
                site_id,
                f"搜索「{term}」" if term else "浏览种子列表",
                friendly_error(exc),
            )
            continue
        pages_more.append(has_more)
        for item in found:
            if item.torrent_id not in seen:
                seen.add(item.torrent_id)
                items.append(item)
    if not pages_more:  # 每个词都失败了
        return [], SiteSearchStatus(
            site_id=site_id, site_name=name, count=0, error=reason, elapsed_ms=elapsed()
        )
    try:
        # 给每条结果挂上来源站点标识 + 扩充属性；扩充含 NER 推理，整批进工作线程
        hits = await asyncio.to_thread(_build_hits, site_id, name, items)
    except Exception as exc:  # noqa: BLE001 —— 同上，富化失败也只算这一站失败
        reason = friendly_error(exc)
        logger.warning("站点 %s 结果处理失败：%s", site_id, reason)
        return [], SiteSearchStatus(
            site_id=site_id, site_name=name, count=0, error=reason, elapsed_ms=elapsed()
        )
    return hits, SiteSearchStatus(
        site_id=site_id,
        site_name=name,
        count=len(hits),
        elapsed_ms=elapsed(),
        has_more=True if True in pages_more else None if None in pages_more else False,
    )


async def stream_search_all_sites(
    keyword: str = "",
    categories: list[TorrentCategory] | None = None,
    site_ids: list[str] | None = None,
    label: str | None = None,
    page: int = 1,
    allowed_site_ids: set[str] | None = None,
    exclude_protected: bool = False,
    also_keywords: list[str] | None = None,
) -> AsyncIterator[tuple[str, BaseModel]]:
    """流式跨站搜索：按「站点实际完成的先后」逐个产出事件，供 SSE 端点直接转发。

    事件序列固定为 ``start → site_start × N → (site_result | site_error) × N → done``
    （载荷定义见 schemas.search 的流式事件段）。快的站点先出结果，前端边收边渲染，
    彻底摆脱「最慢站点决定整体等待时间」的木桶效应。

    错误隔离口径与阻塞版完全一致：单站失败降级为 ``site_error`` 事件，绝不中断整个流。
    调用方（客户端断开等）提前关闭生成器时，finally 会取消所有未完成的站点搜索任务，
    不留孤儿请求。

    :param keyword: 关键词（支持 IMDb ID，具体识别由各站实现决定）。**留空 = 浏览模式**：
        改打各站的种子浏览页（``list_torrents``），按分类逛最新发布，事件序列与
        载荷结构和搜索完全一致，前端不需要两套渲染。
    :param categories: 分类组合过滤（tracker 层原生支持多分类）；空/None 表示不限分类。
    :param site_ids: 站点子集；空/None 表示全部可用站点。勾选的站点当前不可用
        （禁用/验证未通过）时直接跳过，不产生错误——口径与「全部站点」一致。
    :param label: 本次搜索的展示名（分类中文名/自定义分类名），原样回显给前端。
    :param page: 页码（各站点独立分页，不做跨站统一分页）。
    :param allowed_site_ids: 成员的可用站点白名单（None=不受限）。这是站点
        可见性的**服务端强制点**：白名单外的站点静默排除（不产生错误事件，
        白名单外的站点名因此不出现在任何响应里），前端勾选也绕不过。
    :param exclude_protected: 排除开了保护开关的站点。**订阅链路专用**
        （缺口搜索/死种换源传 True）——受保护站点不被订阅自动拉种，但用户
        主动搜索照常，见 docs/design/site-protection-ratio-boost.md。
    :param also_keywords: 同搜词（如详情页带上的英文名/原名），每站与主词一起搜、按种子
        合并成该站的一份结果（见 ``_fetch_one``）。经 ``also_keywords_of`` 清洗去重，
        清洗后的结果在 ``start`` 事件里回显；浏览模式忽略。
    """
    also_keywords = also_keywords_of(keyword, also_keywords)
    sites = await _active_sites()
    if exclude_protected:
        sites = [c for c in sites if not c.protected]
    if allowed_site_ids is not None:
        sites = [c for c in sites if c.site_id in allowed_site_ids]
    if site_ids:
        wanted = set(site_ids)
        sites = [c for c in sites if c.site_id in wanted]
    started = time.monotonic()

    yield (
        "start",
        SearchStreamStart(
            keyword=keyword,
            also_keywords=also_keywords or None,
            label=label,
            categories=[c.value for c in categories] if categories else [],
            page=page,
            sites=[
                SearchStreamSite(site_id=c.site_id, site_name=_display_name(c.site_id))
                for c in sites
            ],
        ),
    )

    # 扇出并发：先建齐所有任务再逐个宣告 site_start，各站从此刻起同时在跑
    tasks = [
        asyncio.create_task(
            _fetch_one(
                c,
                keyword=keyword,
                also_keywords=also_keywords,
                categories=categories,
                page=page,
            )
        )
        for c in sites
    ]
    for c in sites:
        yield (
            "site_start",
            SearchStreamSite(site_id=c.site_id, site_name=_display_name(c.site_id)),
        )

    total = 0
    statuses: list[SiteSearchStatus] = []
    try:
        # as_completed：谁先搜完谁先出事件，这正是流式搜索的全部意义
        for fut in asyncio.as_completed(tasks):
            hits, status = await fut
            statuses.append(status)
            elapsed_ms = status.elapsed_ms or 0
            if status.error is not None:
                yield (
                    "site_error",
                    SiteStreamError(
                        site_id=status.site_id,
                        site_name=status.site_name,
                        error=status.error,
                        elapsed_ms=elapsed_ms,
                    ),
                )
            else:
                total += len(hits)
                yield (
                    "site_result",
                    SiteStreamResult(
                        site_id=status.site_id,
                        site_name=status.site_name,
                        count=len(hits),
                        elapsed_ms=elapsed_ms,
                        items=hits,
                    ),
                )
        yield (
            "done",
            SearchStreamDone(
                total=total,
                elapsed_ms=int((time.monotonic() - started) * 1000),
                sites=statuses,
            ),
        )
    finally:
        # 客户端中途断开时生成器被提前关闭：取消尚未完成的站点搜索，不留孤儿请求
        for task in tasks:
            task.cancel()


async def search_all_sites(
    keyword: str = "",
    categories: list[TorrentCategory] | None = None,
    site_ids: list[str] | None = None,
    label: str | None = None,
    page: int = 1,
    allowed_site_ids: set[str] | None = None,
    exclude_protected: bool = False,
    also_keywords: list[str] | None = None,
) -> SearchResponse:
    """并发搜索可用站点并合并结果（阻塞版：等全部站点返回后一次性给出）。

    基于 ``stream_search_all_sites`` 实现——消费整个事件流再组装成 ``SearchResponse``，
    与流式端点共享同一套扇出/隔离逻辑，避免两头维护。参数含义见流式版 docstring。
    """
    items: list[TorrentHit] = []
    statuses: list[SiteSearchStatus] = []
    async for event, payload in stream_search_all_sites(
        keyword=keyword,
        categories=categories,
        site_ids=site_ids,
        label=label,
        page=page,
        allowed_site_ids=allowed_site_ids,
        exclude_protected=exclude_protected,
        also_keywords=also_keywords,
    ):
        if event == "start":
            assert isinstance(payload, SearchStreamStart)
            also_keywords = payload.also_keywords or []
        elif event == "site_result":
            assert isinstance(payload, SiteStreamResult)
            items.extend(payload.items)
        elif event == "done":
            assert isinstance(payload, SearchStreamDone)
            statuses = payload.sites

    return SearchResponse(
        keyword=keyword,
        also_keywords=also_keywords or None,
        label=label,
        categories=[c.value for c in categories] if categories else [],
        total=len(items),
        items=items,
        sites=statuses,
    )
