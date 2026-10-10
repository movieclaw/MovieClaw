"""刷片信息流：从本人可见的电影库、剧集库里随机抽片，一页一页地给 App。

**抽样按「部」不按文件**：一部电影、一部剧各算一个名额（剧集库里《哆啦A梦》一部就有
两千多集，按文件抽会刷成它的专场）。抽到剧固定放最早一季的第二集（``choose_file``）。
一期不看观看状态，看没看过一样抽（docs/design/reels.md）。

**按评分加权洗牌**：高分片更容易排到前面，低分片照样会出现（``weighted_order``）。

**无状态翻页**：第一页由服务端生成随机种子，App 翻页时把 ``seed`` 与 ``offset``
带回来；同一个种子洗出来的顺序固定，服务端不用记会话，同一次刷片里不会重复。

**按需计算 + 凑够就返回**：现成的片段够一页就立刻返回，没算过的这一页跳过、后台照常
算完落盘；不够才并行现算（每个文件零点几秒到两秒），凑满一页就返回，整页最多等
``PAGE_BUDGET_S``（``_segments_within_budget``）。返回一页后顺手在后台把下一页要用的
片段算好——App 翻到下一页时基本都是现成的。

**第一条起得快**：进页面（第一页）时，把前几条里第一个起播字节不大的排到最前
（``_quick_first``），并在后台并行把前两条起播要读的字节从片源盘预读一遍（``_preread``）。
片源在另一台 NAS 上经 NFS 挂载，冷读一段约 300 ms，播放器又是文件头、索引、起点一段一段
串行读的，第一条光等片源盘就要一秒上下；预读把三段并行读进本机页面缓存，播放器来取时
直接命中。

**全池补算**：服务启动后第一次有人刷片时，后台把整个池子（全部电影库 / 剧集库，每部一个
文件）没算过的片段一部一部补齐，只补这一轮（``_fill_pool``）。补齐之后每页都是现成的，
不再有「等满 3 秒」；没人用刷片的部署一点不花。

**「其他」是独立的池，不混进默认**：默认（不传 ``kind``）只从电影库、剧集库抽——刷片
是帮人决定「今晚看什么」，而「其他」库（家庭录像、自录内容）一个文件一个条目，动辄几千个，
按条目均匀抽会把电影、剧集淹没。要刷它得主动选 ``kind=video``。唯一的例外：可见范围里
**没有任何可刷的电影 / 剧集文件**（只建了「其他」库）时，默认回落到「其他」池，否则这类用户
的「全部」永远是空的（``pool_libraries``）。「其他」没有 TMDB 档案，类型 / 地区 / 年代 / 评分 /
片长这几维筛选对它无意义，服务端一律忽略，只认「观看状态」（``watch_only``）。

**筛选**：与媒体库筛选同一套维度与参数（类型、地区、年代、评分、片长、观看状态，
``LibraryFilter``），另加「电影 / 剧集」。收窄只在抽样池上加一条 ``media_item_id IN (…)``，
走媒体库唯一的收窄点 ``_narrow``（观看者的分级约束也在里面）——口径不会与媒体库分叉，
翻页、预热都不用知道筛选的存在。菜单的候选值与计数见 ``reels/facets.py``。

**怎么放和放哪段分开**：``segment`` 永远是原片时间轴上的起止；``play`` 说明这一条
怎么放（一期只有 ``seek``：自研引擎从原片中间起播）。App 用 ``modes`` 声明自己会放
哪几种，服务端只发它会放的——将来加「预剪好的片段文件」（``clip``）时老版本 App
不受影响。
"""

from __future__ import annotations

import asyncio
import logging
import math
import os
import random
import re
import secrets
import time
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library.access import (
    NO_CONTENT_LIMIT,
    ContentLimit,
    content_limit_for,
    visible_library_ids,
)
from movieclaw_api.services.library.items import (
    LibraryFilter,
    _narrow,
    backdrop_facts_many,
    poster_facts_many,
)
from movieclaw_api.services.library.profile import profile_for
from movieclaw_api.services.media_extract import window_format
from movieclaw_api.services.media_scrape import asset_version
from movieclaw_api.services.people_images import avatar_url
from movieclaw_api.services.playback import marks as playback_marks
from movieclaw_api.services.playback.signing import issue_stream_token
from movieclaw_api.services.playback_up_next import _progress_percent, _runtime_ms
from movieclaw_api.services.reels import clips
from movieclaw_api.services.reels.segments import (
    FileRef,
    ReelSegment,
    cached_segment,
    get_segment,
    is_miss,
)
from movieclaw_api.services.reels.tracks import choose_audio, choose_subtitle
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    Library,
    LibraryFile,
    MediaEpisode,
    MediaItem,
    MediaItemPerson,
    MediaMetadata,
    Person,
    ReelEvent,
)
from movieclaw_playback import state as playback_state
from movieclaw_playback.streaming import is_strm

logger = logging.getLogger("movieclaw_api.reels")

#: 一页最多等多久（秒）：超时没算完的这一页先跳过
PAGE_BUDGET_S = 3.0
#: 一页最多往后看多少部（很多部挑不出片段时不至于无限往后翻）
SCAN_FACTOR = 3
#: 剧集太短（片花、预告）不抽。不能定太高：《小猪佩奇》一集只有 5 分钟左右
MIN_EPISODE_SECONDS = 120
#: App 会放的方式：从原片中间起播 / 预切好的片段文件
#: （开了「片段预切」才出，docs/design/reels.md §8）
MODE_SEEK = "seek"
MODE_CLIP = "clip"

_warm_tasks: set[asyncio.Task[Any]] = set()


@dataclass
class ReelCandidate:
    """一页里的一条：选中的文件与算好的片段。"""

    media_item_id: int
    kind: str  # movie / episode / video
    file: LibraryFile
    segment: ReelSegment | None = None


@dataclass
class ReelPage:
    seed: int
    next_offset: int
    has_more: bool
    items: list[dict[str, Any]] = field(default_factory=list)
    #: 片段预切进度（clip 模式才有）
    clips: dict[str, Any] | None = None


# --- 抽样 ------------------------------------------------------------------------


async def _playable_library_kinds(session: AsyncSession, principal: Principal) -> dict[int, str]:
    """本人可见、能播放的库：库 id → 库形态（movie / tv / video）。

    「能播放」读能力位 ``profile.playable``，不列举形态：图片库不可播放自然被挡在外面，
    将来新增可播放的形态也不用回来改这里。
    """
    visible = await visible_library_ids(session, principal)
    if not visible:
        return {}
    rows = await session.execute(
        select(Library.id, Library.kind, Library.source).where(
            Library.id.in_(visible),  # type: ignore[union-attr]
        )
    )
    return {
        int(lid): str(kind)
        for lid, kind, source in rows.all()
        if profile_for(kind, source).playable
    }


def _playable_file_filter(library_ids: Sequence[int]) -> list[Any]:
    return [
        LibraryFile.library_id.in_(list(library_ids)),  # type: ignore[attr-defined]
        LibraryFile.in_place(),
        LibraryFile.media_item_id.is_not(None),  # type: ignore[union-attr]
    ]


def only_kind(libraries: dict[int, str], kind: str | None) -> dict[int, str]:
    """「电影 / 剧集 / 其他」这一维：只留这类库（不传是都留）。"""
    return {lid: k for lid, k in libraries.items() if kind is None or k == kind}


@dataclass(frozen=True)
class ReelPool:
    """这次刷片从哪些库抽。"""

    #: 抽样的库：库 id → 库形态
    libraries: dict[int, str]
    #: 是不是「其他」池（选了 ``kind=video``，或只有「其他」库时的回落）。它没有 TMDB 档案，
    #: 筛选只剩观看状态，App 据此收起类型 / 年代 / 地区 / 评分 / 片长几个菜单
    video: bool
    #: 电影 / 剧集有没有可刷的文件。没有就说明用户只有「其他」，没必要给「电影 / 剧集 / 其他」切换
    film_available: bool


async def pool_libraries(session: AsyncSession, principal: Principal, kind: str | None) -> ReelPool:
    """按 ``kind`` 定这次从哪些库抽。

    - ``video``：只抽「其他」库；
    - ``movie`` / ``tv``：只抽这一类；
    - 不传：抽电影 + 剧集；**电影 / 剧集一个可刷的文件都没有**且有「其他」库时回落到「其他」。
      判据是「有没有可刷的文件」而不是筛选后的结果：带着筛选条件刷空了不能偷偷改推家庭录像，
      也不看「有没有库」——建了个空电影库的人照样该看到自己的录像。
    """
    libraries = await _playable_library_kinds(session, principal)
    other = only_kind(libraries, "video")
    film = {lid: k for lid, k in libraries.items() if k != "video"}
    film_available = (
        bool(film)
        and (
            await session.execute(
                select(LibraryFile.id).where(*_playable_file_filter(list(film))).limit(1)
            )
        ).first()
        is not None
    )
    if kind == "video":
        return ReelPool(other, True, film_available)
    if kind is not None:
        return ReelPool(only_kind(film, kind), False, film_available)
    if film_available or not other:
        return ReelPool(film, False, film_available)
    return ReelPool(other, True, False)


def watch_only(filters: LibraryFilter | None) -> LibraryFilter | None:
    """「其他」池的筛选：只留观看状态。

    类型 / 地区 / 年代 / 评分 / 片长都来自 TMDB 档案，「其他」条目没有——留着只会把它们
    全部筛空；观看状态按人算、与档案无关，家庭录像同样有「只看没看过的」需求。
    """
    return LibraryFilter(watch=filters.watch) if filters and filters.watch else None


def unit_kind(library_kind: str) -> str:
    """库形态 → 抽样单位：tv 是 episode（一部剧放一集），video 是 video（单本，没有 TMDB 档案），
    其余是 movie。挑点区间对 video 沿用单本的口径（``picker.REGION`` 找不到时退回 movie）。"""
    return {"tv": "episode", "video": "video"}.get(library_kind, "movie")


async def _title_pool(
    session: AsyncSession,
    libraries: dict[int, str],
    limit: ContentLimit,
    filters: LibraryFilter | None,
    member_id: int,
) -> list[tuple[int, str]]:
    """可抽的「部」：(条目 id, movie/episode/video)，按条目 id 排好（洗牌前的确定顺序）。"""
    stmt = (
        select(LibraryFile.media_item_id, LibraryFile.library_id)
        .where(
            *_playable_file_filter(list(libraries)),
            *_narrow(filters, member_id, content_limit=limit),
        )
        .distinct()
    )
    kinds: dict[int, str] = {}
    for item_id, library_id in (await session.execute(stmt)).all():
        kinds.setdefault(int(item_id), unit_kind(libraries.get(int(library_id), "movie")))
    return sorted(kinds.items())


#: 评分每高 1 分，排到前面的机会是几倍。NAS 实测片库评分挤在 6.6～8.45（10%～90% 分位），
#: 取 3：8.4 分的片被抽到前面的机会约是 6.6 分的 7 倍，低分片不会被埋没到刷不到
RATING_BOOST = 3.0
#: 评分人数的先验强度（贝叶斯平均）：评分人数少的片，分数按人数往池子均分拉——
#: 片库里评分人数不到 30 的有 151 部、其中 66 部在 8 分以上，多是几个人打出来的虚高分
RATING_PRIOR_VOTES = 50


async def _ratings_of(
    session: AsyncSession, item_ids: Sequence[int]
) -> dict[int, tuple[float | None, int | None]]:
    """条目 → (评分, 评分人数)。"""
    if not item_ids:
        return {}
    rows = await session.execute(
        select(
            MediaMetadata.media_item_id, MediaMetadata.vote_average, MediaMetadata.vote_count
        ).where(MediaMetadata.media_item_id.in_(list(item_ids)))  # type: ignore[union-attr]
    )
    return {int(i): (r, c) for i, r, c in rows.all()}


def weighted_order(
    pool: list[tuple[int, str]],
    ratings: dict[int, tuple[float | None, int | None]],
    seed: int,
) -> list[tuple[int, str]]:
    """按评分加权的随机顺序（Efraimidis–Spirakis 加权无放回抽样）。

    每部片抽一个 ``Exp(1) / 权重`` 的随机键，按键从小到大排：权重大的键往往小、排在前面，
    但谁都有机会。权重 = ``RATING_BOOST ** (校正分 - 池子均分)``；校正分是按评分人数往
    均分拉过的贝叶斯平均（``RATING_PRIOR_VOTES``），没有评分的按均分算。评分人数缺失
    （如 NFO 只写了分数）按先验强度同等信任。

    同一个种子、同一个池子（``pool`` 按条目 id 排好）得到的顺序固定——无状态翻页靠它。
    均分按当前池子算：筛了「8 分以上」时，加权的是池子里的相对高低。
    """
    rated = [r for r, _ in ratings.values() if r]
    mean = sum(rated) / len(rated) if rated else 0.0
    rng = random.Random(seed)
    keyed = []
    for item_id, kind in pool:
        rating, votes = ratings.get(item_id, (None, None))
        score = mean
        if rating:
            n = RATING_PRIOR_VOTES if votes is None else votes
            score = (n * rating + RATING_PRIOR_VOTES * mean) / (n + RATING_PRIOR_VOTES)
        # 1 - random() 落在 (0, 1]，log 不会碰到 0
        key = -math.log(1.0 - rng.random()) / RATING_BOOST ** (score - mean)
        keyed.append((key, item_id, kind))
    keyed.sort()
    return [(item_id, kind) for _, item_id, kind in keyed]


_HEIGHT = re.compile(r"(\d{3,4})")


def _height(resolution: str | None) -> int:
    match = _HEIGHT.search(resolution or "")
    return int(match.group(1)) if match else 0


#: 剧集固定放第几集。依据是 Netflix 2015 年对 25 部剧的统计（「看完这一集的观众七成会追完
#: 第一季」是哪一集）：没有一部是第一集——试播集忙着交代人物设定；最早是第二集（7 部，
#: 《绝命毒师》《行尸走肉》等），平均第四集。刷片要的是一滑过来就有戏、又不剧透，早期集里
#: 第二集最合适。固定一集还让同一部剧每次刷到的都是算好的那一段，不用现算。
REEL_EPISODE = 2


def choose_file(files: Sequence[LibraryFile], kind: str) -> LibraryFile | None:
    """一部片里挑一个文件放。

    剧集：最早的正片季（季号 ≥ 1，没有正片季才用特别季）里取第 ``REEL_EPISODE`` 集；
    没有这一集取离它最近的一集，一样近取后一集（第一集是试播集，尽量不用），太短的不要。
    同一集多个版本、电影多个版本：取 1080p 及以上里体积最小的（竖屏横条 1080p 足够，
    文件小预取快）。
    """
    if kind == "episode":
        episodes = [
            f
            for f in files
            if (f.duration_seconds or 0) == 0 or (f.duration_seconds or 0) >= MIN_EPISODE_SECONDS
        ]
        regular = [f for f in episodes if (f.season_number or 0) >= 1] or episodes
        if not regular:
            return None
        season = min(f.season_number or 0 for f in regular)
        in_season = [f for f in regular if (f.season_number or 0) == season]
        target = min(
            {f.episode_number or 0 for f in in_season},
            key=lambda e: (abs(e - REEL_EPISODE), -e),
        )
        files = [f for f in in_season if (f.episode_number or 0) == target]
    if not files:
        return None
    return min(files, key=lambda f: (_height(f.resolution) < 1080, f.size_bytes or 0))


def _file_ref(file: LibraryFile, kind: str) -> FileRef:
    return FileRef(
        id=int(file.id or 0),
        media_item_id=int(file.media_item_id or 0),
        path=file.file_path,
        kind=kind,
        size_bytes=file.size_bytes,
        mtime_ns=file.file_mtime_ns,
        duration_s=float(file.duration_seconds) if file.duration_seconds else None,
        hdr=file.hdr,
        subtitle_streams=list(file.subtitle_streams or []),
        container=file.container,
        disc_playlist=file.disc_playlist if isinstance(file.disc_playlist, dict) else None,
        chapters=list(file.chapters or []),
    )


async def _files_of(
    session: AsyncSession, item_ids: Sequence[int], library_ids: Sequence[int]
) -> dict[int, list[LibraryFile]]:
    if not item_ids:
        return {}
    rows = await session.execute(
        select(LibraryFile).where(
            LibraryFile.media_item_id.in_(list(item_ids)),  # type: ignore[union-attr]
            *_playable_file_filter(library_ids),
        )
    )
    grouped: dict[int, list[LibraryFile]] = {}
    for file in rows.scalars().all():
        grouped.setdefault(int(file.media_item_id or 0), []).append(file)
    return grouped


async def _choose_candidates(
    session: AsyncSession,
    pool: list[tuple[int, str]],
    library_ids: Sequence[int],
) -> list[ReelCandidate]:
    files = await _files_of(session, [item_id for item_id, _ in pool], library_ids)
    candidates = []
    for item_id, kind in pool:
        chosen = choose_file(files.get(item_id, []), kind)
        if chosen is not None:
            candidates.append(ReelCandidate(item_id, kind, chosen))
    return candidates


# --- 翻页 ------------------------------------------------------------------------


async def build_feed(
    session: AsyncSession,
    principal: Principal,
    *,
    seed: int | None,
    offset: int,
    limit: int,
    modes: set[str],
    filters: LibraryFilter | None = None,
    kind: str | None = None,
) -> ReelPage:
    """组一页。``modes`` 里没有本服务能出的放法时返回空页；``filters`` / ``kind`` 收窄抽样池。"""
    seed = seed if seed is not None else secrets.randbelow(2**31)
    clip_mode = MODE_CLIP in modes and await clips.enabled()
    if MODE_SEEK not in modes and not clip_mode:
        return ReelPage(seed=seed, next_offset=offset, has_more=False)
    reel_pool = await pool_libraries(session, principal, kind)
    libraries = reel_pool.libraries
    if not libraries:
        return ReelPage(seed=seed, next_offset=offset, has_more=False)
    if reel_pool.video:
        filters = watch_only(filters)
    member_id = principal.member_id if principal.member_id is not None else 0
    content_limit = await content_limit_for(session, principal)
    pool = await _title_pool(session, libraries, content_limit, filters, member_id)
    pool = weighted_order(pool, await _ratings_of(session, [i for i, _ in pool]), seed)
    if clip_mode:
        return await _clip_page(session, pool, offset, limit, seed, reel_pool, member_id)

    window = pool[offset : offset + limit * SCAN_FACTOR]
    candidates = await _choose_candidates(session, window, list(libraries))
    ready = await _segments_within_budget(candidates, limit)

    # 下一页从「这一页实际看到哪一部」接着往后
    last_used = ready[-1].media_item_id if ready else None
    consumed = len(window)
    if last_used is not None and len(ready) >= limit:
        consumed = next(i for i, (item_id, _) in enumerate(window) if item_id == last_used) + 1
    next_offset = offset + consumed
    has_more = next_offset < len(pool)

    page = ready[:limit]
    if offset == 0:
        # 进页面的第一页：第一条是冷起播（没有任何预取），挑个起得快的、马上开始预读。
        # 预读排在装配之前，能早一点是一点——客户端拿到列表后一两百毫秒就会来取
        page = _quick_first(page)
        _preread_in_background(page[:PREREAD_ITEMS])
    if has_more:
        _warm_next_page(pool[next_offset : next_offset + limit + 3], list(libraries))
    _fill_pool_in_background(video=reel_pool.video)

    items = await _assemble(session, page, member_id)
    _warm_stills([i["title"]["backdrop_url"] or i["cover_url"] for i in items[:WARM_STILLS]])
    return ReelPage(seed=seed, next_offset=next_offset, has_more=has_more, items=items)


async def _clip_page(
    session: AsyncSession,
    pool: list[tuple[int, str]],
    offset: int,
    limit: int,
    seed: int,
    reel_pool: ReelPool,
    member_id: int,
) -> ReelPage:
    """clip 模式的一页：顺着同一个抽样顺序往后，只挑切好的。

    偏移仍按完整的抽样顺序算（不先把池子筛成「切好的」再分页）：中途又切好了几部，
    排在已经刷过的位置之前的这次就不出，之后的照常出——同一次刷片不会重复、不会跳漏。
    切好的片段一定有挑点缓存，不用现算，也不用预读、预热（小文件本身就快）。
    """
    clips.ensure_planned(video=reel_pool.video)
    progress = clips.progress([item_id for item_id, _ in pool])
    ready = clips.ready_item_ids()
    window, index = [], offset
    while index < len(pool) and len(window) < limit:
        if pool[index][0] in ready:
            window.append(pool[index])
        index += 1
    page: list[ReelCandidate] = []
    infos: dict[int, clips.ClipInfo] = {}
    for candidate in await _choose_candidates(session, window, list(reel_pool.libraries)):
        segment = cached_segment(_file_ref(candidate.file, candidate.kind))
        info = (
            clips.ready_clip(candidate.file, segment)  # type: ignore[arg-type]
            if isinstance(segment, ReelSegment)
            else None
        )
        if info is None:
            # 挑点重算过、换了版本：这一部要重切，这次先不出
            clips.on_file_changed(candidate.media_item_id)
            continue
        candidate.segment = segment  # type: ignore[assignment]
        infos[info.file_id] = info
        page.append(candidate)
    has_more = any(item_id in ready for item_id, _ in pool[index:])
    items = await _assemble(session, page, member_id, clips_by_file=infos)
    _warm_stills([i["title"]["backdrop_url"] or i["cover_url"] for i in items[:WARM_STILLS]])
    return ReelPage(
        seed=seed, next_offset=index, has_more=has_more, items=items, clips=progress
    )


async def _segments_within_budget(
    candidates: list[ReelCandidate], limit: int
) -> list[ReelCandidate]:
    """取片段，按抽样顺序返回挑得出片段的前 limit 条；凑够就返回，最多等 PAGE_BUDGET_S。

    1. 先只查缓存：现成的已够 limit 条就立刻返回。没算过的这一页跳过（与超时跳过同一
       语义），计算照常在后台跑完落盘，以后刷到就是现成的。NAS 实测一页 30 部候选里
       现成的常有十三四条，以前却要把其余十几部现算完或等满 3 秒才返回。
    2. 不够才等现算：等到「抽样顺序前面的每一部都有了结果、其中挑得出的凑满 limit 条」
       为止，不为排在后面的片多等；超时没算完的这一页先跳过。
    """
    if not candidates:
        return []
    refs = [_file_ref(c.file, c.kind) for c in candidates]
    settled = [False] * len(candidates)
    for i, (candidate, ref) in enumerate(zip(candidates, refs, strict=True)):
        cached = cached_segment(ref)
        if not is_miss(cached):
            candidate.segment = cached  # type: ignore[assignment]
            settled[i] = True
    tasks = {
        asyncio.ensure_future(get_segment(refs[i])): i for i, done in enumerate(settled) if not done
    }
    for task in tasks:
        # 提前返回时这些计算还在跑，留住引用免得被回收
        _warm_tasks.add(task)
        task.add_done_callback(_warm_tasks.discard)

    if sum(c.segment is not None for c in candidates) < limit:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + PAGE_BUDGET_S
        pending = set(tasks)
        while pending and not _prefix_ready(candidates, settled, limit):
            left = deadline - loop.time()
            if left <= 0:
                break
            done, pending = await asyncio.wait(
                pending, timeout=left, return_when=asyncio.FIRST_COMPLETED
            )
            for task in done:
                i = tasks[task]
                settled[i] = True
                if not task.cancelled() and task.exception() is None:
                    candidates[i].segment = task.result()
    return [c for c in candidates if c.segment is not None][:limit]


def _prefix_ready(candidates: list[ReelCandidate], settled: list[bool], limit: int) -> bool:
    """抽样顺序前面的每一部都有了结果，且其中挑得出片段的已凑满 limit 条。"""
    ready = 0
    for candidate, done in zip(candidates, settled, strict=True):
        if not done:
            return False
        if candidate.segment is not None:
            ready += 1
            if ready >= limit:
                return True
    return True


#: 第一页里第一条起播要下的字节（文件头 + 索引 + 起点后几秒）不超过它才排到最前。NAS 实测
#: 中位 9.5 MB、90 分位 22.7 MB（4K 原盘起点一段就二十多 MB），12 MB 约六成片子满足，
#: 一页 5 条全不满足的机会约 1%；都不满足就挑最小的。只动第一条，其余照评分加权的顺序
FIRST_ITEM_BYTES = 12 << 20
#: 第一页预读前几条的起播字节
PREREAD_ITEMS = 2
#: 预读一段最多读多少（极少数高码率片起点一段很大，读太多只是白占片源盘）
PREREAD_MAX_BYTES = 32 << 20
_PREREAD_CHUNK = 1 << 20


def _start_bytes(candidate: ReelCandidate) -> int:
    """起播要下的字节：服务端给客户端的预取范围（文件头 + 索引 + 起点后几秒）之和。"""
    if candidate.segment is None:
        return 0
    return sum(r.length for r in candidate.segment.prefetch)


def _quick_first(page: list[ReelCandidate]) -> list[ReelCandidate]:
    """把第一个起播字节不超过 ``FIRST_ITEM_BYTES`` 的挪到最前；都超过就挪最小的。"""
    if len(page) < 2:
        return page
    pick = next((c for c in page if _start_bytes(c) <= FIRST_ITEM_BYTES), None)
    pick = pick or min(page, key=_start_bytes)
    return [pick, *(c for c in page if c is not pick)]


def _preread_range(path: str, offset: int, length: int) -> None:
    """把文件的一段读一遍就丢：只为让它进操作系统的页面缓存，之后取流读同一段直接命中。"""
    fd = os.open(path, os.O_RDONLY)
    try:
        end = offset + min(length, PREREAD_MAX_BYTES)
        while offset < end:
            chunk = os.pread(fd, min(_PREREAD_CHUNK, end - offset), offset)
            if not chunk:
                break
            offset += len(chunk)
    finally:
        os.close(fd)


def _preread_in_background(candidates: list[ReelCandidate]) -> None:
    """后台把这几条起播要读的字节预读进页面缓存：一条之内三段并行，条与条之间按顺序。

    三段并行是关键：片源盘冷读每段约 300 ms，并行后三段一共约 300 ms；第一条读完才读第二条，
    免得第二条和第一条抢片源盘。预读失败（片源盘掉线、文件被挪走）不影响任何请求。
    """
    jobs = [
        (c.file.file_path, [(r.offset, r.length) for r in c.segment.prefetch])
        for c in candidates
        if c.segment is not None and c.segment.prefetch
    ]
    if not jobs:
        return

    async def preread() -> None:
        for path, ranges in jobs:
            started = time.monotonic()
            results = await asyncio.gather(
                *(asyncio.to_thread(_preread_range, path, off, n) for off, n in ranges),
                return_exceptions=True,
            )
            failed = [r for r in results if isinstance(r, BaseException)]
            if failed:
                logger.debug("刷片预读失败：%s（%s）", path, failed[0])
            else:
                logger.debug("刷片预读完成：%s，%.0f ms", path, (time.monotonic() - started) * 1000)

    task = asyncio.create_task(preread())
    _warm_tasks.add(task)
    task.add_done_callback(_warm_tasks.discard)


#: 全池补算各只跑一轮：电影 / 剧集（第一次有人刷片时）与「其他」（第一次有人刷到「其他」池时）
_fill_tasks: dict[bool, asyncio.Task[None]] = {}


def _fill_pool_in_background(*, video: bool = False) -> None:
    """每个进程、每个池只补一轮：第一次有人刷这个池时启动，之后什么都不做。

    「其他」池单独懒启动：它一个文件一个条目，动辄几千个，没人刷它的部署不该为它读盘。

    不定时重查：之后新入库的片刷到时现算（现成的够一页就先跳过它、后台算完落盘），
    下次再刷到就是现成的；服务重启（升级）后第一次刷片再补一轮，那时已算过的只是读一下
    缓存记录（全池一两秒），不会重算。
    """
    if video not in _fill_tasks:
        task = asyncio.create_task(_fill_pool(video=video))
        _fill_tasks[video] = task
        _warm_tasks.add(task)
        task.add_done_callback(_warm_tasks.discard)


async def _fill_pool(*, video: bool = False) -> None:
    """把全部电影库、剧集库（``video=True`` 时是「其他」库）每部一个文件
    （``choose_file`` 选中的那个）没算过的片段补齐。

    片段按文件缓存、与观看者无关，所以不按人算可见性与分级：补的是全集，谁刷都用得上。
    **一部一部串行算**：计算闸 ``_COMPUTE_LIMIT`` 是 3 路，补算最多占 1 路，另外 2 路
    始终留给正在等的那一页（同一文件并发要到时两边共用一次计算）。NAS 实测一部零点几秒到
    两秒，688 部的片库冷启动补齐约十分钟。
    """
    try:
        async with get_database().session() as session:
            rows = await session.execute(
                select(Library.id, Library.kind).where(
                    Library.kind.in_(("video",) if video else ("movie", "tv"))  # type: ignore[attr-defined]
                )
            )
            libraries = {int(lid): str(kind) for lid, kind in rows.all()}
            pool = await _title_pool(session, libraries, NO_CONTENT_LIMIT, None, 0)
            candidates = await _choose_candidates(session, pool, list(libraries))
        refs = [_file_ref(c.file, c.kind) for c in candidates]
        missing = [ref for ref in refs if is_miss(cached_segment(ref))]
        if missing:
            logger.info("刷片：后台补算片段，%d / %d 部还没算过", len(missing), len(refs))
            started = time.monotonic()
            for ref in missing:
                await get_segment(ref)
            logger.info(
                "刷片：后台补算完成，%d 部用时 %.0f 秒", len(missing), time.monotonic() - started
            )
    except Exception:  # noqa: BLE001 —— 补算失败不影响任何请求，没补到的刷到时现算
        logger.warning("刷片：后台补算片段中断，没补到的片刷到时再现算", exc_info=True)


def _warm_next_page(pool: list[tuple[int, str]], library_ids: list[int]) -> None:
    """后台把下一页要用的片段先算好（选文件要查库，用独立会话）。"""

    async def warm() -> None:
        try:
            async with get_database().session() as session:
                candidates = await _choose_candidates(session, pool, library_ids)
            for candidate in candidates:
                await get_segment(_file_ref(candidate.file, candidate.kind))
        except Exception:  # noqa: BLE001 —— 预热失败不影响任何请求
            logger.debug("刷片预热下一页失败", exc_info=True)

    task = asyncio.create_task(warm())
    _warm_tasks.add(task)
    task.add_done_callback(_warm_tasks.discard)


#: 一页返回时在后台先压好前几张剧照：客户端滑到之前就在图片缓存里，之后的由客户端边看边预取下一张
WARM_STILLS = 3


def _warm_stills(urls: list[str | None]) -> None:
    """后台把等画面时垫的剧照压成 ``reel-still`` 小图（与客户端请求同一个缓存键）。

    剧照原图多是 4K，第一次请求现压要 0.15～0.55 秒；接口返回时就开始压，客户端拿到列表、
    再发图片请求时多半已经压好。本地资产与远程图床两种来源分别对应 ``/images/assets`` 与
    ``/images/proxy`` 的缓存键写法。
    """

    async def warm() -> None:
        from movieclaw_api.services.image_variants import (
            ImageVariant,
            get_image_variant_service,
            source_version_of,
        )
        from movieclaw_api.services.media_scrape import resolve_asset_path

        variants = get_image_variant_service()
        for url in urls:
            if not url:
                continue
            try:
                if url.startswith(("http://", "https://")):
                    await variants.get_or_create_remote(url, variant=ImageVariant.REEL_STILL)
                    continue
                rel = url.removeprefix("/images/assets/").split("?", 1)[0]
                target = resolve_asset_path(rel)
                if target is None:
                    continue
                await variants.get_or_create(
                    target,
                    source_key=f"asset:{rel}",
                    source_version=source_version_of(target.stat()),
                    variant=ImageVariant.REEL_STILL,
                )
            except Exception:  # noqa: BLE001 —— 预压失败不影响任何请求，客户端请求时照常现压
                logger.debug("刷片剧照预压失败：%s", url, exc_info=True)

    task = asyncio.create_task(warm())
    _warm_tasks.add(task)
    task.add_done_callback(_warm_tasks.discard)


# --- 装配 ------------------------------------------------------------------------


def reel_id(file_id: int, start_ms: int) -> str:
    """片段标识：同一文件同一起点就是同一段（事件按它归并统计）。"""
    return f"rl_{file_id}_{start_ms}"


def _asset_url(rel: str | None) -> str | None:
    return f"/images/assets/{rel}?v={asset_version(rel)}" if rel else None


async def _assemble(
    session: AsyncSession,
    candidates: list[ReelCandidate],
    member_id: int,
    *,
    clips_by_file: dict[int, clips.ClipInfo] | None = None,
) -> list[dict[str, Any]]:
    """把候选装成接口条目。``clips_by_file`` 里有的文件按 clip 放（预切片段），其余按 seek。"""
    if not candidates:
        return []
    item_ids = sorted({c.media_item_id for c in candidates})
    items = {
        item.id: item
        for item in (
            await session.execute(select(MediaItem).where(MediaItem.id.in_(item_ids)))  # type: ignore[union-attr]
        ).scalars()
    }
    metadata = {
        meta.media_item_id: meta
        for meta in (
            await session.execute(
                select(MediaMetadata).where(MediaMetadata.media_item_id.in_(item_ids))  # type: ignore[union-attr]
            )
        ).scalars()
    }
    posters = await poster_facts_many(session, item_ids)
    backdrops = await backdrop_facts_many(session, item_ids)
    episodes = await _episode_facts(session, candidates)
    directors = await _directors_of(session, item_ids)
    # 续播位置：「已看」按钮在看了一半时画进度圈（电影看整部、剧集看这一集）
    states = await playback_state.get_states(session, item_ids, member_id=member_id)

    out = []
    for c in candidates:
        item, meta, segment, file = (
            items.get(c.media_item_id),
            metadata.get(c.media_item_id),
            c.segment,
            c.file,
        )
        if item is None or segment is None:
            continue
        backdrop = backdrops.get(c.media_item_id)
        poster = posters.get(c.media_item_id)
        episode = None
        runtime = (meta.runtime_minutes if meta else None) or _minutes(file.duration_seconds)
        # 收藏落在整部（电影 / 整剧）上；已看电影看整部、剧集看这一集
        favorite_target = playback_marks.MarkTarget(c.media_item_id, None, None)
        played_target = favorite_target
        unit = (c.media_item_id, 0, 0)
        if c.kind == "episode":
            key = (c.media_item_id, file.season_number or 0, file.episode_number or 0)
            name, overview, minutes = episodes.get(key, ("", None, None))
            episode = {
                "season": key[1],
                "episode": key[2],
                "name": name or None,
                "overview": overview or None,
            }
            runtime = minutes or _minutes(file.duration_seconds)
            played_target = playback_marks.MarkTarget(c.media_item_id, key[1], key[2])
            unit = key
        progress = None
        if (row := states.get(unit)) and not row.played:
            progress = _progress_percent(
                row.position_ms, _runtime_ms(file.duration_seconds, None, runtime)
            )
        favorite = await playback_marks.get_state(session, favorite_target, member_id=member_id)
        played = (
            favorite
            if played_target is favorite_target
            else await playback_marks.get_state(session, played_target, member_id=member_id)
        )
        token = await issue_stream_token(member_id=member_id, file_id=int(file.id or 0))
        clip = (clips_by_file or {}).get(int(file.id or 0))
        disc = disc_delivery(file)
        # 光盘的字幕清单是服务端按整盘探测的，与引擎读到的盘内轨对不上序号；strm 抽不了字幕窗口
        subtitle_ordinal = (
            None if disc or is_strm(file.file_path) else choose_subtitle(file.subtitle_streams)
        )
        subtitle = None
        if subtitle_ordinal is not None:
            stream = (file.subtitle_streams or [])[subtitle_ordinal]
            subtitle = {
                "ordinal": subtitle_ordinal,
                "language": stream.get("language"),
                "title": stream.get("title"),
                "codec": stream.get("codec"),
                **_subtitle_window(file, subtitle_ordinal, segment, token),
            }
        out.append(
            {
                "id": reel_id(segment.file_id, segment.start_ms),
                "title": {
                    "media_item_id": c.media_item_id,
                    "library_id": file.library_id,
                    "kind": {"episode": "tv"}.get(c.kind, c.kind),
                    "name": item.title,
                    "year": item.year,
                    "rating": meta.vote_average if meta else None,
                    "runtime_minutes": runtime,
                    "genres": list(meta.genres or [])[:3] if meta else [],
                    "tagline": (meta.tagline or None) if meta else None,
                    "overview": (meta.overview or None) if meta else None,
                    "favorite": favorite.is_favorite,
                    "played": played.played,
                    "progress_percent": progress,
                    # 电影是导演、剧集是主创；关系表还没有（旧条目没刷新）时退回档案里的姓名
                    "directors": directors.get(c.media_item_id)
                    or [
                        {"name": name, "tmdb_person_id": None, "avatar_url": None}
                        for name in (meta.directors if meta else [])[:MAX_DIRECTORS]
                    ],
                    "poster_url": poster.url if poster else None,
                    "backdrop_url": backdrop,
                    "logo_url": _asset_url(meta.logo_file) if meta and meta.logo_file else None,
                    "episode": episode,
                },
                "cover_url": _asset_url(segment.cover) or backdrop,
                "segment": {
                    "file_id": segment.file_id,
                    "start_ms": segment.start_ms,
                    "end_ms": segment.end_ms,
                    "duration_ms": int(file.duration_seconds * 1000)
                    if file.duration_seconds
                    else None,
                    "method": segment.method,
                },
                "play": {
                    "mode": MODE_CLIP if clip else MODE_SEEK,
                    "stream_url": f"/api/v1/playback/files/{file.id}/stream?token={token}",
                    "clip_url": f"{clip.url_path}?token={token}" if clip else None,
                    "clip_size_bytes": clip.size_bytes if clip else None,
                    "size_bytes": file.size_bytes,
                    "disc": disc,
                    # 镜像的音轨清单服务端读不出盘内结构、不可信：交给引擎按盘上的默认音轨起播
                    "audio_ordinal": None if disc == "image" else choose_audio(file.audio_streams),
                    "subtitle": subtitle,
                    # 小文件不用预取原片字节
                    "prefetch": []
                    if clip
                    else [
                        {"offset": r.offset, "length": r.length, "purpose": r.purpose}
                        for r in segment.prefetch
                    ],
                },
            }
        )
    return out


def disc_delivery(file: LibraryFile) -> str | None:
    """光盘怎么交给 App 引擎（与正片同一套，docs/design/disc-direct-play.md §2.2）：
    镜像给原字节地址（image），原盘目录按目录清单逐个文件取（folder），其余是普通文件（None）。"""
    container = (file.container or "").lower()
    if container == "iso":
        return "image"
    if container in ("bluray", "dvd"):
        return "folder"
    return None


#: 片段字幕窗口：起点前多留几秒（接住起点前开始、还没说完的那句），终点后多留几秒
SUBTITLE_PREROLL_MS = 10_000
SUBTITLE_TAIL_MS = 5_000


def _subtitle_window(
    file: LibraryFile, ordinal: int, segment: ReelSegment, token: str
) -> dict[str, str | None]:
    """这一段的字幕地址：只抽片段前后这一小段（见 ``media_extract`` 的窗口抽取）。

    放转码流时引擎读不到内封轨、全屏片段模式要叠加层画字幕，都靠这份；整轨抽取要 NAS 通读
    整个文件，片段等不起。轨不能原样拷贝（图形字幕、mov_text）就不给，图形字幕仍由转码压制。
    """
    fmt = window_format(file, ordinal)
    if fmt is None:
        return {"url": None, "format": None}
    start = max(0, segment.start_ms - SUBTITLE_PREROLL_MS)
    end = segment.end_ms + SUBTITLE_TAIL_MS
    url = (
        f"/api/v1/playback/files/{file.id}/subtitles?track=embedded:{ordinal}"
        f"&start_ms={start}&end_ms={end}&token={token}"
    )
    return {"url": url, "format": fmt}


#: 每部最多给几位导演（左下角只放得下一两个名字）
MAX_DIRECTORS = 2


async def _directors_of(
    session: AsyncSession, item_ids: Sequence[int]
) -> dict[int, list[dict[str, Any]]]:
    """条目 → 导演（剧集为主创），取自与详情页同一张影人关系表，按署名顺序。"""

    if not item_ids:
        return {}
    rows = await session.execute(
        select(
            MediaItemPerson.media_item_id, Person.name, Person.profile_path, Person.tmdb_person_id
        )
        .join(Person, Person.id == MediaItemPerson.person_id)  # type: ignore[arg-type]
        .where(
            MediaItemPerson.media_item_id.in_(list(item_ids)),  # type: ignore[attr-defined]
            MediaItemPerson.department == "director",
        )
        .order_by(MediaItemPerson.credit_order, MediaItemPerson.id)
    )
    out: dict[int, list[dict[str, Any]]] = {}
    for item_id, name, profile, tmdb_id in rows.all():
        people = out.setdefault(int(item_id), [])
        if len(people) < MAX_DIRECTORS:
            people.append(
                {
                    "name": name,
                    "tmdb_person_id": tmdb_id,
                    "avatar_url": avatar_url(profile),
                }
            )
    return out


def _minutes(seconds: float | int | None) -> int | None:
    return int(round(seconds / 60)) if seconds else None


async def _episode_facts(
    session: AsyncSession, candidates: list[ReelCandidate]
) -> dict[tuple[int, int, int], tuple[str, str | None, int | None]]:
    """(条目, 季, 集) → (集名, 分集简介, 单集时长分钟)。"""
    series = {c.media_item_id for c in candidates if c.kind == "episode"}
    if not series:
        return {}
    rows = await session.execute(
        select(
            MediaEpisode.media_item_id,
            MediaEpisode.season_number,
            MediaEpisode.episode_number,
            MediaEpisode.name,
            MediaEpisode.overview,
            MediaEpisode.runtime_minutes,
        ).where(MediaEpisode.media_item_id.in_(sorted(series)))  # type: ignore[attr-defined]
    )
    return {
        (int(i), int(s), int(e)): (str(n or ""), o or None, r or None)
        for i, s, e, n, o, r in rows.all()
    }


# --- 事件 ------------------------------------------------------------------------

EVENT_KINDS = frozenset(
    {
        "impression",
        "first_frame",
        "leave",
        "complete",
        "continue",
        "open",
        "fullscreen",
        "detail",
        "fail",
    }
)


async def record_events(
    session: AsyncSession, member_id: int, events: Sequence[dict[str, Any]]
) -> int:
    """把 App 攒的一批事件落库，返回落了几条（不认识的事件类型直接丢弃）。"""
    rows = [
        ReelEvent(
            member_id=member_id,
            reel_id=str(e["reel_id"])[:64],
            kind=str(e["kind"]),
            mode=str(e.get("mode") or MODE_SEEK)[:16],
            media_item_id=e.get("media_item_id"),
            file_id=e.get("file_id"),
            position_ms=e.get("position_ms"),
            watched_ms=e.get("watched_ms"),
            wait_ms=e.get("wait_ms"),
            detail=e.get("detail") or None,
        )
        for e in events
        if e.get("kind") in EVENT_KINDS and e.get("reel_id")
    ]
    if rows:
        session.add_all(rows)
        await session.commit()
    return len(rows)
