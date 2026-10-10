"""获取领域给入库用的下载器信息（docs/design/library-boundary.md §10，入库桥块 A、B）。

入库要知道「这个条目是不是还在下载、哪些文件已经写完、是不是 MovieClaw 投递的还没到」；
这些都是下载器与投递台账的事，媒体库经 ``services/library/acquisition.py`` 的接口来问，
答案只用媒体库的概念（条目路径、本机文件路径、写完没有）。
"""

from __future__ import annotations

import logging
import os
import re
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path, PurePosixPath

from sqlalchemy import or_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.services.acquisition_origin import (
    OriginContext,
    load_origin_context,
    manual_download_origin,
    subscription_origin,
)
from movieclaw_api.services.download_sources import record_source
from movieclaw_api.services.library.acquisition import (
    AfterIngest,
    IdentityHint,
    IngestedFacts,
    TaskFile,
    TaskFiles,
)
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    DownloaderClient,
    LibraryFile,
    ManualDownloadIntent,
    MediaItem,
    SubscriptionDownloadAttempt,
    utcnow,
)
from movieclaw_db.models.manual_download_intent import MANUAL_DOWNLOAD_INTENT_TTL
from movieclaw_matcher import QualitySnapshot, RuleSetSpec

logger = logging.getLogger("movieclaw_api.library_ingest")

# 下载器种子概览的缓存：一轮事件风暴中的多个目录巡检共享一次 API 调用
_BRIEFS_TTL_SECONDS = 15.0
# 下载器种子概览缓存：(取样时刻, 概览列表或 None=不可用)
_briefs_cache: tuple[float, list | None] = (float("-inf"), None)


def invalidate_downloader_briefs() -> None:
    """刚向下载器提交了种子：丢掉概览缓存。

    否则提交前取到的概览（还没有这颗种子）会在 15 秒内被复用——秒完成 / 已存在 / 辅种
    这类提交后立刻落盘的条目会被投递台账判成「还在下载」，挂起一整轮轮询（5 分钟）。
    """
    global _briefs_cache
    _briefs_cache = (float("-inf"), None)


async def downloader_briefs() -> list | None:
    """全部可用下载器的种子概览（带短缓存）。

    ``[]`` 表示没有配置下载器或可达下载器确实没有任务；``None`` 只表示
    配置过下载器但本轮全部不可达。后者必须 fail closed，不能拿静默窗口
    猜完成——API 短暂失联正是未完成文件被提前入库的根因。
    """
    global _briefs_cache
    now = time.monotonic()
    cached_at, cached = _briefs_cache
    if now - cached_at < _BRIEFS_TTL_SECONDS:
        return cached
    # 局部导入：复用订阅管线的"可用下载器"口径，避免模块加载期的重依赖
    from movieclaw_api.services.download_progress import _usable_downloaders
    from movieclaw_downloader import create_downloader

    db = get_database()
    async with db.session() as session:
        enabled_exists = (
            await session.execute(
                select(DownloaderClient.id).where(DownloaderClient.enabled.is_(True))  # type: ignore[union-attr]
            )
        ).first() is not None
        downloaders = await _usable_downloaders(session)
    if not downloaders:
        # 没有启用任何下载器才表示“确实没有权威状态源”。启用中的配置若仍在
        # pending/verifying/failed，则只是当前不可用，必须和连接异常一样
        # fail closed；否则服务启动的验证窗口会把预分配文件误当成已完成。
        result = None if enabled_exists else []
        _briefs_cache = (now, result)
        return result
    briefs: list = []
    all_ok = True
    for row, config in downloaders:
        adapter = create_downloader(config)
        try:
            briefs.extend(await adapter.list_torrents())
        except Exception as exc:  # noqa: BLE001 -- 继续关闭/检查其余连接后整体降级
            all_ok = False
            logger.warning("列出下载器「%s」的种子失败：%s", row.name, exc)
        finally:
            await adapter.close()
    # 任一台缺席时，这份列表都不能证明“某目录不属于下载任务”。宁可让所有
    # 未决条目暂等，也不能用另一台的成功响应替失联下载器作否定判断。
    result = briefs if all_ok else None
    _briefs_cache = (now, result)
    return result


def _claim_path_matches(entry: Path, save_path: str | None) -> bool:
    """持久化投递路径是否覆盖当前监听条目；旧行无路径时按真实名称认领。"""
    if not save_path:
        return True
    expected = Path(os.path.normpath(save_path))
    actual = Path(os.path.normpath(str(entry)))
    return expected in {actual, actual.parent}


def download_name_matches(entry_name: str, recorded_name: str | None) -> bool:
    """兼容站点标题与下载器内容名的轻微差异，不做宽松片名猜测。"""
    if not recorded_name:
        return False
    if entry_name == recorded_name:
        return True
    compact_entry = re.sub(r"[^a-z0-9]+", "", entry_name.lower())
    compact_recorded = re.sub(r"[^a-z0-9]+", "", recorded_name.lower())
    if compact_entry == compact_recorded:
        return True
    if min(len(compact_entry), len(compact_recorded)) < 20:
        return False
    years_entry = set(re.findall(r"(?:19|20)\d{2}", compact_entry))
    years_recorded = set(re.findall(r"(?:19|20)\d{2}", compact_recorded))
    if years_entry and years_recorded and not years_entry.intersection(years_recorded):
        return False
    return SequenceMatcher(None, compact_entry, compact_recorded).ratio() >= 0.90


async def has_managed_download_claim(session, entry: Path) -> bool:
    """条目是否仍由 MovieClaw 投递台账管理，即使下载器概览暂时漏掉它。"""
    from movieclaw_db.models import (
        DownloadAttemptStatus,
        SiteTorrent,
        SubscriptionDownloadAttempt,
    )

    manual = list(
        (
            await session.execute(
                select(ManualDownloadIntent, SiteTorrent.title)
                .outerjoin(
                    SiteTorrent,
                    (SiteTorrent.site_id == ManualDownloadIntent.site_id)
                    & (SiteTorrent.torrent_id == ManualDownloadIntent.torrent_id),
                )
                .where(
                    ManualDownloadIntent.created_at >= utcnow() - MANUAL_DOWNLOAD_INTENT_TTL,  # type: ignore[arg-type]
                    or_(
                        ManualDownloadIntent.download_name == entry.name,
                        ManualDownloadIntent.download_name.is_(None),  # type: ignore[union-attr]
                        ManualDownloadIntent.download_name == "",
                    ),
                )
            )
        ).all()
    )
    if any(
        _claim_path_matches(entry, intent.save_path)
        and (
            download_name_matches(entry.name, intent.download_name)
            or download_name_matches(entry.name, site_title)
        )
        for intent, site_title in manual
    ):
        return True

    active = (
        DownloadAttemptStatus.ACTIVE,
        DownloadAttemptStatus.REPLACEMENT_PENDING,
        DownloadAttemptStatus.TRIAL,
        DownloadAttemptStatus.CLEANUP_PENDING,
        DownloadAttemptStatus.COMPLETED,
    )
    attempts = list(
        (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.status.in_(active),  # type: ignore[union-attr]
                    or_(
                        SubscriptionDownloadAttempt.download_name == entry.name,
                        SubscriptionDownloadAttempt.download_name.is_(None),  # type: ignore[union-attr]
                        SubscriptionDownloadAttempt.download_name == "",
                    ),
                )
            )
        )
        .scalars()
        .all()
    )
    return any(
        _claim_path_matches(entry, row.save_path)
        and (
            download_name_matches(entry.name, row.download_name)
            or download_name_matches(entry.name, row.torrent_title)
        )
        for row in attempts
    )


async def redelivered_since(
    session: AsyncSession, entry_name: str, since: datetime, info_hashes: list[str]
) -> bool:
    """台账下结论之后，订阅又把同一颗种子重新投递、且投递仍在途：旧结论已过时。

    台账按「条目路径 + 指纹」幂等：已入库/已跳过且指纹没变就不再处理。但结论所
    依据的现实会变——用户把入库的文件删了、作品随之被清掉，之后重新订阅，仍在
    下载器里做种的同一颗种子被原样再投递一次。指纹没变，旧台账于是永远短路，新
    工单停在「已投递」、投递停在「已完成」，谁也不报警（NAS 实测《恶人传》）。

    判据刻意只认「晚于台账结论的在途投递」：重跑会刷新 ``attempted_at``，同一次
    投递不会反复触发；正常流程里投递总是先于入库结论，也不会误触发。
    """
    from movieclaw_db.models import DownloadAttemptStatus, SubscriptionDownloadAttempt

    if not info_hashes:
        return False
    hashes = sorted({h for value in info_hashes if value for h in (value, value.lower())})
    attempt_id = (
        await session.execute(
            select(SubscriptionDownloadAttempt.id)
            .where(
                SubscriptionDownloadAttempt.info_hash.in_(hashes),  # type: ignore[union-attr]
                SubscriptionDownloadAttempt.status.in_(  # type: ignore[attr-defined]
                    (
                        DownloadAttemptStatus.ACTIVE,
                        DownloadAttemptStatus.REPLACEMENT_PENDING,
                        DownloadAttemptStatus.TRIAL,
                        DownloadAttemptStatus.COMPLETED,
                    )
                ),
                SubscriptionDownloadAttempt.created_at > since,  # type: ignore[operator]
            )
            .limit(1)
        )
    ).scalar_one_or_none()
    if attempt_id is None:
        return False
    logger.info(
        "「%s」在上次入库结论之后又被订阅投递（投递 #%s），旧结论已过时，重新入库",
        entry_name,
        attempt_id,
    )
    return True


async def _matched_torrent_statuses(matches: list) -> list[tuple[object, object]] | None:
    """补查同名种子的文件状态；任一详情缺失时返回 None，调用方保守等待。"""
    from movieclaw_api.services.download_progress import _query_torrent, _usable_downloaders

    if any(not brief.info_hash for brief in matches):
        return None  # 没有 hash 的轻量记录无法形成可复核的文件证据
    hashes = sorted({str(brief.info_hash).lower() for brief in matches if brief.info_hash})
    if len(hashes) != len(matches):
        return None  # 重复 hash 的概览不应产生互相矛盾的文件写入证据
    db = get_database()
    async with db.session() as session:
        downloaders = await _usable_downloaders(session)
    if not downloaders:
        return None
    details: list[tuple[object, object]] = []
    for info_hash in hashes:
        found = await _query_torrent(info_hash, downloaders)
        if found is None:
            return None
        details.append(found)
    return details


def _torrent_file_source(downloader, status, torrent_file) -> Path | None:  # noqa: ANN001
    """把下载器文件路径翻译到 MovieClaw 视角；异常相对路径直接拒绝。"""
    from movieclaw_api.services.torrent_submit import translate_to_local

    local_dir = translate_to_local(status.save_path, downloader.path_mappings)
    if not local_dir:
        return None
    relative = PurePosixPath(str(torrent_file.path).replace("\\", "/"))
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        return None
    return Path(local_dir).joinpath(*relative.parts)


def _torrent_file_completed(status, torrent_file) -> bool:  # noqa: ANN001
    """只认下载器完成字节；旧适配器缺字段时仅整种完成可兜底。"""
    if status.completed:
        return True
    completed_bytes = torrent_file.completed_bytes
    return completed_bytes is not None and completed_bytes >= torrent_file.size_bytes


async def task_files(matches: list) -> list[TaskFiles] | None:
    """同名下载任务的文件清单（路径已翻译到本机）；任一详情缺失时返回 None，调用方保守等待。"""
    details = await _matched_torrent_statuses(matches)
    if details is None:
        return None
    out: list[TaskFiles] = []
    for downloader, status in details:
        out.append(
            TaskFiles(
                info_hash=str(status.info_hash).lower(),
                completed=bool(status.completed),
                files=tuple(
                    TaskFile(
                        source=_torrent_file_source(downloader, status, torrent_file),
                        selected=bool(torrent_file.selected),
                        size_bytes=int(torrent_file.size_bytes),
                        completed=_torrent_file_completed(status, torrent_file),
                    )
                    for torrent_file in status.files or ()
                ),
            )
        )
    return out


async def wanted_identity(
    session: AsyncSession, info_hashes: list[str]
) -> tuple[MediaItem | None, int | None]:
    """按 info_hash 反查订阅工单，继承投递时锚定的精确身份。

    返回 (条目, 订阅定格的 library_id)——auto 规则用后者沿用订阅的入库目标
    （粘性：不对认领内容重新路由）；查不到返回 (None, None)。
    """
    if not info_hashes:
        return None, None
    from movieclaw_db.models import Subscription, SubscriptionDownloadAttempt, WantedItem

    result = await session.execute(
        select(MediaItem, Subscription.library_id)
        .join(Subscription, MediaItem.id == Subscription.media_item_id)  # type: ignore[arg-type]
        .join(WantedItem, WantedItem.subscription_id == Subscription.id)  # type: ignore[arg-type]
        .where(WantedItem.info_hash.in_(info_hashes))  # type: ignore[union-attr]
    )
    row = result.first()
    if row is None:
        # 自动换源后 wanted 只指向新主源；旧源可能因 H&R/用户所有权被保留，
        # 它之后若自行完成仍应继承原订阅身份，而不是退回模糊的文件名识别。
        result = await session.execute(
            select(MediaItem, Subscription.library_id)
            .join(Subscription, MediaItem.id == Subscription.media_item_id)  # type: ignore[arg-type]
            .join(
                SubscriptionDownloadAttempt,
                SubscriptionDownloadAttempt.subscription_id == Subscription.id,  # type: ignore[arg-type]
            )
            .where(SubscriptionDownloadAttempt.info_hash.in_(info_hashes))  # type: ignore[union-attr]
        )
        row = result.first()
    if row is None:
        return None, None
    item, library_id = row
    logger.info("条目按 info_hash 认领了订阅身份：《%s》", item.title)
    return item, library_id


async def manual_download_identity(
    session: AsyncSession, info_hashes: list[str]
) -> tuple[MediaItem | None, int | None, ManualDownloadIntent | None]:
    """按 info_hash 反查手动下载在提交时确认的身份与目标库。

    监听目录常被多个库复用，文件名不足以重新识别时，这颗锚把「搜索结果
    已确认的 TMDB 身份 → 收藏范围选库 → 实际投递目录」完整接到完成后的
    整理流程。订阅工单优先级更高，调用方只会在它未命中时走这里。
    """
    if not info_hashes:
        return None, None, None
    result = await session.execute(
        select(MediaItem, ManualDownloadIntent)
        .join(
            ManualDownloadIntent,
            MediaItem.id == ManualDownloadIntent.media_item_id,  # type: ignore[arg-type]
        )
        .where(ManualDownloadIntent.info_hash.in_(info_hashes))  # type: ignore[union-attr]
    )
    row = result.first()
    if row is None:
        return None, None, None
    item, intent = row
    logger.info("条目按 info_hash 认领了手动下载身份：《%s》", item.title)
    return item, intent.library_id, intent


@dataclass(frozen=True)
class _DeliveryProvenance:
    """监听条目内**逐文件**解析订阅投递的来源戳 (site, torrent)。

    不能按条目只取一个来源：逐集发布的单集种子（CMCTV 这类）在下载器里共用
    同一个内容目录名，一个监听条目于是同时匹配多颗种子。旧实现对
    ``info_hash IN (...)`` 不排序取第一条，把整批文件记到同一次投递名下（NAS
    实测 5 部剧 31 个文件记错，《交锋》E12 被记成 E10 的种子），洗版验证
    ``_file_from_attempt`` 精确比对失败，洗版任务永远停在「已完成」。

    判定顺序。原则是宁可不记、不可记错：缺戳时洗版验证还能退化到时间关联
    兜底，记错了连兜底都用不上。

    1. 有下载器文件清单时，候选只留**真正写入该文件**的种子；清单在手却没有
       任何种子写它 → 不是投递来的（外部种子或手工放入），不记；
    2. 候选中投递单元声明了该集的优先，同一集投递过多次取最新一次；
    3. 下载器确认写入、但没有投递声明该集（季包里的附带集）→ 取最新候选；
    4. 没有文件证据时，候选只剩一个来源才记，多个来源无从区分 → 不记。
    """

    attempts: tuple[SubscriptionDownloadAttempt, ...]  # 条目匹配到的、带站点来源的投递
    file_hashes: dict[str, frozenset[str]]  # 条目内相对路径 → 下载器确认写入它的 hash

    @property
    def confidence(self) -> str | None:
        """条目级身份证据强度：全部投递都是外部 ID 精确命中才算 exact，否则按猜测记。"""
        if self.attempts and all(a.identity_confidence == "exact_id" for a in self.attempts):
            return "exact_id"
        return None

    def stamp(
        self, path: str | None, unit: tuple[int, int] | None
    ) -> tuple[str | None, str | None]:
        """单个入库文件的来源戳；path 为 None（原盘目录）时不看文件证据。"""
        attempt = self.attempt_for(path, unit)
        return (attempt.site_id, attempt.torrent_id) if attempt is not None else (None, None)

    def attempt_for(
        self, path: str | None, unit: tuple[int, int] | None
    ) -> SubscriptionDownloadAttempt | None:
        """单个入库文件对应的投递记录（来源戳与去重阶梯都从它取）；判不出返回 None。"""
        candidates = list(self.attempts)
        writers: frozenset[str] | None = None
        if path is not None and self.file_hashes:
            writers = self.file_hashes.get(path, frozenset())
            candidates = [a for a in candidates if a.info_hash.lower() in writers]
        if unit is not None:
            claiming = [
                a
                for a in candidates
                if unit
                in {(int(u[0]), int(u[1])) for u in a.units if isinstance(u, list) and len(u) == 2}
            ]
            if claiming:
                return max(claiming, key=lambda a: a.id or 0)
        if writers and candidates:
            return max(candidates, key=lambda a: a.id or 0)
        sources = {(a.site_id, a.torrent_id) for a in candidates}
        if len(sources) != 1:
            return None
        return max(candidates, key=lambda a: a.id or 0)


async def load_delivery_provenance(
    session: AsyncSession,
    info_hashes: list[str],
    file_writers: Callable[[], Awaitable[dict[str, frozenset[str]]]],
) -> _DeliveryProvenance:
    """按条目匹配到的 hash 载入投递记录；确有投递时再向下载器取文件清单作逐文件证据。"""
    hashes = sorted({h for value in info_hashes if value for h in (value, value.lower())})
    rows = (
        await session.execute(
            select(SubscriptionDownloadAttempt).where(
                SubscriptionDownloadAttempt.info_hash.in_(hashes)  # type: ignore[union-attr]
            )
        )
    ).scalars()
    attempts = tuple(attempt for attempt in rows if attempt.site_id)
    file_hashes = await file_writers() if attempts else {}
    return _DeliveryProvenance(attempts=attempts, file_hashes=file_hashes)


class _Delivery:
    """条目来历（``EntryDelivery`` 的实现）：订阅投递按文件定位到那次投递，手动下载按条目。"""

    def __init__(
        self,
        *,
        provenance: _DeliveryProvenance | None,
        manual: ManualDownloadIntent | None,
        origin_ctx: OriginContext,
        specs: dict[int, RuleSetSpec | None],
        item_title: str,
        strategy: str,
    ) -> None:
        self._provenance = provenance
        self._manual = manual
        self._origin_ctx = origin_ctx
        self._specs = specs
        self._item_title = item_title
        self._strategy = strategy

    @property
    def confidence(self) -> str | None:
        return self._provenance.confidence if self._provenance is not None else None

    def _attempt(
        self, path: str | None, unit: tuple[int, int] | None
    ) -> SubscriptionDownloadAttempt | None:
        if self._provenance is None:
            return None
        return self._provenance.attempt_for(path, unit)

    def stamp(
        self, path: str | None, unit: tuple[int, int] | None
    ) -> tuple[str | None, str | None]:
        # 来源戳：洗版验证据此精确匹配「文件 ↔ 投递」。订阅投递按文件解析
        # （同名目录可能挂着多颗种子），手动下载的身份锚本就钉在单颗种子上，沿用条目级
        if self._provenance is not None:
            return self._provenance.stamp(path, unit)
        if self._manual is not None:
            return self._manual.site_id, self._manual.torrent_id
        return None, None

    def task_of(
        self, path: str | None, unit: tuple[int, int] | None
    ) -> tuple[str | None, int | None]:
        # 与来源戳同源：删片顺手删种子时按它定位下载器任务（plugin-phase2a.md §5.1）
        if self._manual is not None:
            return self._manual.info_hash.lower(), self._manual.downloader_id
        attempt = self._attempt(path, unit)
        if attempt is None:
            return None, None
        return attempt.info_hash.lower(), attempt.downloader_id

    def origin(self, path: str | None, unit: tuple[int, int] | None) -> dict | None:
        # 来源快照（docs/design/library-duplicate-files.md §2）：文案在落账现场一次成型
        attempt = self._attempt(path, unit)
        if attempt is not None:
            return subscription_origin(
                attempt,
                item_title=self._item_title,
                downloader_name=self._origin_ctx.downloader(attempt.downloader_id),
                strategy=self._strategy,
            )
        if self._manual is not None:
            return manual_download_origin(
                self._manual,
                torrent_title=self._origin_ctx.manual_torrent_title,
                downloader_name=self._origin_ctx.downloader(self._manual.downloader_id),
                strategy=self._strategy,
            )
        return None

    def name_quality(
        self, path: str | None, unit: tuple[int, int] | None
    ) -> QualitySnapshot | None:
        # 投递时定格的种子名解析，与洗版验证端的取值一致
        attempt = self._attempt(path, unit)
        if attempt is not None and attempt.quality:
            return QualitySnapshot.model_validate(attempt.quality)
        return None

    def rule_spec(self, path: str | None, unit: tuple[int, int] | None) -> RuleSetSpec | None:
        # 订阅投递按来源投递所属规则组的偏好序判「同档或更高」（issue #381）
        attempt = self._attempt(path, unit)
        return self._specs.get(attempt.subscription_id) if attempt is not None else None

    async def file_recorded(
        self,
        session: AsyncSession,
        file_id: int,
        path: str | None,
        unit: tuple[int, int] | None,
    ) -> None:
        site_id, torrent_id = self.stamp(path, unit)
        info_hash, downloader_id = self.task_of(path, unit)
        await record_source(
            session,
            file_id,
            info_hash=info_hash,
            downloader_id=downloader_id,
            site_id=site_id,
            torrent_id=torrent_id,
        )


async def identity_hint(session: AsyncSession, info_hashes: list[str]) -> IdentityHint | None:
    """订阅工单优先，其次手动下载的身份锚。"""
    item, library_id = await wanted_identity(session, info_hashes)
    if item is not None:
        return IdentityHint(item=item, library_id=library_id, source="subscription")
    item, library_id, intent = await manual_download_identity(session, info_hashes)
    if item is not None:
        return IdentityHint(item=item, library_id=library_id, source="manual", token=intent)
    return None


async def entry_delivery(
    session: AsyncSession,
    info_hashes: list[str],
    hint: IdentityHint | None,
    *,
    item_title: str,
    strategy: str,
    file_writers: Callable[[], Awaitable[dict[str, frozenset[str]]]],
) -> _Delivery:
    from movieclaw_api.services.subscription.upgrade import _specs_for_subscriptions

    manual = hint.token if hint is not None and hint.source == "manual" else None
    assert manual is None or isinstance(manual, ManualDownloadIntent)
    provenance: _DeliveryProvenance | None = None
    if manual is None and info_hashes:
        provenance = await load_delivery_provenance(session, info_hashes, file_writers)
    origin_ctx = await load_origin_context(
        session, provenance.attempts if provenance is not None else (), manual
    )
    specs: dict[int, RuleSetSpec | None] = {}
    if provenance is not None and provenance.attempts:
        specs = await _specs_for_subscriptions(
            session, {a.subscription_id for a in provenance.attempts}
        )
    return _Delivery(
        provenance=provenance,
        manual=manual,
        origin_ctx=origin_ctx,
        specs=specs,
        item_title=item_title,
        strategy=strategy,
    )


async def delivered_quality(
    session: AsyncSession, rows: list[LibraryFile]
) -> dict[int, QualitySnapshot]:
    """带来源戳 (site, torrent) 的在库文件取对应投递定格的种子名解析。

    同一颗种子多次投递取最新一次。

    否则在位文件只能从改名后的文件名重新解析——``… - 2160p.mkv`` 里没有 Remux 字样，
    同一份 Remux 再次投递时来件被判成「严格更优」放行，整份重复入库（线上实测）。
    """
    delivered: dict[tuple[str, str], QualitySnapshot] = {}
    torrent_ids = {row.torrent_id for row in rows if row.site_id and row.torrent_id}
    if torrent_ids:
        attempts = (
            await session.execute(
                select(SubscriptionDownloadAttempt)
                .where(SubscriptionDownloadAttempt.torrent_id.in_(torrent_ids))  # type: ignore[union-attr]
                .order_by(SubscriptionDownloadAttempt.id)  # type: ignore[arg-type]
            )
        ).scalars()
        for attempt in attempts:
            if attempt.site_id and attempt.torrent_id and attempt.quality:
                delivered[(attempt.site_id, attempt.torrent_id)] = QualitySnapshot.model_validate(
                    attempt.quality
                )
    out: dict[int, QualitySnapshot] = {}
    for row in rows:
        if row.id is not None and row.site_id and row.torrent_id:
            snapshot = delivered.get((row.site_id, row.torrent_id))
            if snapshot is not None:
                out[row.id] = snapshot
    return out


async def ingested(session: AsyncSession, facts: IngestedFacts) -> AfterIngest:
    """入库成功的收尾：消费手动下载的身份锚、对照推送对象（随入库结论同一次提交）。"""
    owner: str | None = None
    if facts.item_id is not None:
        # 手动下载的身份锚随成功入库一起删除。依据是本次条目匹配到的全部 hash + 最终媒体身份，
        # 不能只删「身份识别实际选中的那一行」：同一 hash 若先被订阅工单认领，
        # 手动锚虽然没有参与识别，也已经随同一批文件完成了使命
        source_hashes = facts.matched if facts.consumable is None else facts.consumable
        hashes = sorted({value.lower() for value in source_hashes or [] if value})
        if hashes:
            intents = list(
                (
                    await session.execute(
                        select(ManualDownloadIntent).where(
                            ManualDownloadIntent.info_hash.in_(hashes),  # type: ignore[union-attr]
                            ManualDownloadIntent.media_item_id == facts.item_id,
                        )
                    )
                )
                .scalars()
                .all()
            )
            for intent in intents:
                owner = owner or intent.owner
                await session.delete(intent)
                logger.info("手动下载身份锚已随成功入库消费：hash=%s", intent.info_hash)
    # 手动下载的人等的就是这一刻：按种子对上是谁点的，入库结论提交之后推「入库完成」
    # （docs/design/cloud-push.md §5）。推送这边出任何错都不能影响入库
    if not facts.library_id:
        return AfterIngest(owner=owner)
    from movieclaw_api.services.push import downloads as push_downloads

    finished = []
    try:
        complete = facts.matched if facts.consumable is None else facts.consumable
        finished = await push_downloads.ingested(
            session,
            hashes=[*facts.matched, *(facts.consumable or [])],
            complete=list(complete or []),
            batch_id=facts.batch_id,
            imported=facts.imported,
            library_id=facts.library_id,
            item_id=facts.item_id,
        )
    except Exception:  # noqa: BLE001
        logger.exception("对照手动下载的推送对象失败（已忽略）")
    if not finished:
        return AfterIngest(owner=owner)
    return AfterIngest(owner=owner, announce=lambda: push_downloads.announce(finished))
