"""媒体库条目详情页的「相似推荐」：只在观看者自己看得见的库里挑。

刻意做轻：不联网、不用模型、不看个人口味，只拿库里已经刮好的元数据
（系列、导演、主演番位、类型、国家、语言、分级、制片/播出方、年代、单集时长）
给候选打分。片库是几百到几千部的量级，一次请求读几列元数据、在内存里算完。

两条硬约束先于打分：动画与真人、纪录片与剧情片、真人秀/脱口秀/新闻与正剧
互不推荐——看完动画片冒出一部限制级恐怖片，比「不够准」伤得多。

候选口径与首页跨库墙同一套：观看者可见的库、在架、正式条目、内容分级收窄
（``_wall_scope`` + ``_narrow``），儿童档案看不到的片这里同样出不来。
"""

from __future__ import annotations

import math
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass, replace

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.schemas.library import LibraryItemView
from movieclaw_api.services.library.access import ContentLimit
from movieclaw_api.services.library.content_rating import rating_age
from movieclaw_api.services.library.items import (
    LibraryScope,
    _aggregate_wall_views,
    _narrow,
    _wall_scope,
    favorite_item_ids,
)
from movieclaw_db.models import LibraryFile, MediaItem, MediaItemPerson, MediaMetadata

#: 只看演员表前 10 位：龙套同框不说明两部片相像
_TOP_CAST = 10
#: 前 3 位算主角。「同一个人主演的片」最像——主角对主角与同导演同分；
#: 一边是主角一边是配角（《三个老枪手》的摩根·弗里曼 vs 《黑暗骑士》第 7 位）只算一点
_LEAD_CAST = 3

#: 互不跨越的类型边界（TMDB genre id）：16 动画、99 纪录片；
#: 10763 新闻 / 10764 真人秀 / 10767 脱口秀 归为一档「非虚构节目」
_ANIMATION = 16
_DOCUMENTARY = 99
_UNSCRIPTED = frozenset({10763, 10764, 10767})

# 各信号的分量。拍脑袋的初值，上线后按真实片库调——改这里不影响别的
_W_SERIES = 4.0
_W_DIRECTOR = 2.5
_W_LEAD_PAIR = 2.5
_MAX_LEAD_PAIRS = 2
_W_LEAD_SUPPORT = 0.8
_W_SUPPORT_PAIR = 0.3
_MAX_OTHER_CAST = 3
_W_GENRE = 3.0
# 国家、语言只在类型对得上时才加（按类型重合度打折）：同是国产片不等于像，
# 否则《流浪地球》会被同国家同语言的剧情片顶到科幻片前面
_W_COUNTRY = 0.8
_W_LANGUAGE = 0.4
# 厂牌按库内稀有度：华纳、爱奇艺几乎不说明问题，Blumhouse、梦工厂动画、JTBC 本身就是一种风格
_W_STUDIO = 1.5
_W_YEAR = 0.6
_YEAR_SPAN = 20
# 分级档位（受众/调性）：同档加一点；合家欢对成人片扣分
_W_SAME_AUDIENCE = 0.5
_W_FAMILY_ADULT = -2.0
# 剧集形态：二十来分钟一集（情景喜剧、动画）与一小时一集的正剧不是一种看法
_SHORT_EPISODE = 35
_W_SAME_FORMAT = 0.3
_W_OTHER_FORMAT = -1.0


@dataclass(frozen=True, slots=True)
class SimilarProfile:
    """一部片参与相似度计算的全部特征。"""

    genres: frozenset[int] = frozenset()
    countries: frozenset[str] = frozenset()
    language: str | None = None
    studios: frozenset[str] = frozenset()
    series_key: str | None = None
    year: int | None = None
    directors: frozenset[int] = frozenset()
    #: 演员表前 10 位（含主角）
    cast: frozenset[int] = frozenset()
    #: 前 3 位主角
    leads: frozenset[int] = frozenset()
    #: 分级档位：0 合家欢（≤8 岁）、1 青少年（9~14）、2 成人（15+）；认不出的分级为 None
    audience: int | None = None
    #: 单集时长（只有剧集填，电影的片长不参与）
    episode_minutes: int | None = None


def audience_of(content_rating: str | None) -> int | None:
    age = rating_age(content_rating)
    if age is None:
        return None
    return 0 if age <= 8 else 1 if age <= 14 else 2


def _cast_score(target: SimilarProfile, other: SimilarProfile) -> float:
    """主演重合按番位分档：主角对主角最重，最多算两位；其余重合的演员最多算三位。"""
    lead_pairs = target.leads & other.leads
    score = _W_LEAD_PAIR * min(len(lead_pairs), _MAX_LEAD_PAIRS)
    others = sorted(
        (
            _W_LEAD_SUPPORT if person in target.leads or person in other.leads else _W_SUPPORT_PAIR
            for person in (target.cast & other.cast) - lead_pairs
        ),
        reverse=True,
    )
    return score + sum(others[:_MAX_OTHER_CAST])


def _studio_score(
    target: SimilarProfile, other: SimilarProfile, idf: dict, idf_max: float
) -> float:
    """共同的厂牌里最少见的那一家说了算（多数片挂着五六家公司，取并集比例会把信号稀释掉）。"""
    shared = target.studios & other.studios
    if not shared or idf_max <= 0:
        return 0.0
    return _W_STUDIO * max(idf.get(studio, 0.0) for studio in shared) / idf_max


def _boundary(genres: frozenset[int]) -> tuple[bool, bool, bool]:
    return (_ANIMATION in genres, _DOCUMENTARY in genres, not genres.isdisjoint(_UNSCRIPTED))


def _idf_jaccard(a: Iterable, b: Iterable, idf: dict) -> float:
    """按稀有度加权的重合度：越少见的特征重合越说明问题（「剧情」几乎人人都有）。"""
    a, b = set(a), set(b)
    union = a | b
    if not union:
        return 0.0
    total = sum(idf.get(x, 0.0) for x in union)
    return sum(idf.get(x, 0.0) for x in a & b) / total if total else 0.0


def _idf_table(profiles: Iterable[SimilarProfile], attr: str) -> dict:
    counts: Counter = Counter()
    n = 0
    for profile in profiles:
        n += 1
        counts.update(getattr(profile, attr))
    return {key: math.log(1 + n / df) for key, df in counts.items()}


def rank_similar(
    target: SimilarProfile, candidates: dict[int, SimilarProfile], limit: int
) -> list[int]:
    """给候选打分，返回最像的 ``limit`` 个条目 id（不含无共同点的）。"""
    genre_idf = _idf_table([target, *candidates.values()], "genres")
    studio_idf = _idf_table([target, *candidates.values()], "studios")
    # 只出现在一部片上的厂牌就是最稀有的那一档
    studio_idf_max = math.log(1 + len(candidates) + 1)
    boundary = _boundary(target.genres)

    scored: list[tuple[float, int, int]] = []
    for item_id, other in candidates.items():
        if _boundary(other.genres) != boundary:
            continue
        # 没有系列的片 series_key 是空串，不是 NULL：空对空不算同系列
        same_series = bool(target.series_key) and other.series_key == target.series_key
        directors = len(target.directors & other.directors)
        shares_cast = not target.cast.isdisjoint(other.cast)
        genre = _idf_jaccard(target.genres, other.genres, genre_idf)
        # 没有任何实质共同点（同系列、同主创、同类型）的不推——只靠同年代同语言凑不成「相似」
        if not (same_series or directors or shares_cast or genre):
            continue
        locale = _W_COUNTRY * bool(target.countries & other.countries) + _W_LANGUAGE * (
            target.language is not None and target.language == other.language
        )
        score = (
            _W_SERIES * same_series
            + _W_DIRECTOR * directors
            + _cast_score(target, other)
            + _W_GENRE * genre
            + locale * genre
            + _studio_score(target, other, studio_idf, studio_idf_max)
        )
        if target.audience is not None and other.audience is not None:
            spread = abs(target.audience - other.audience)
            score += _W_SAME_AUDIENCE if spread == 0 else _W_FAMILY_ADULT if spread == 2 else 0.0
        if target.episode_minutes and other.episode_minutes:
            same_format = (target.episode_minutes <= _SHORT_EPISODE) == (
                other.episode_minutes <= _SHORT_EPISODE
            )
            score += _W_SAME_FORMAT if same_format else _W_OTHER_FORMAT
        gap = (
            abs(target.year - other.year)
            if target.year is not None and other.year is not None
            else _YEAR_SPAN
        )
        score += _W_YEAR * max(0.0, 1 - gap / _YEAR_SPAN)
        scored.append((-score, gap, item_id))
    scored.sort()
    return [item_id for _, _, item_id in scored[:limit]]


async def similar_item_ids(
    session: AsyncSession,
    media_item_id: int,
    *,
    library_ids: LibraryScope,
    member_id: int,
    content_limit: ContentLimit | None,
    limit: int,
) -> list[int]:
    """在 ``library_ids`` 范围内找与该条目最像的片（同类型：电影找电影、剧找剧）。"""
    item = await session.get(MediaItem, media_item_id)
    if item is None:
        return []
    candidate_ids = (
        select(LibraryFile.media_item_id)
        .join(MediaItem, MediaItem.id == LibraryFile.media_item_id)  # type: ignore[arg-type]
        .where(
            *_wall_scope(library_ids),
            *_narrow(None, member_id, library_id=library_ids, content_limit=content_limit),
            MediaItem.kind == item.kind,
            LibraryFile.media_item_id != media_item_id,
        )
        .distinct()
    )
    rows = (
        await session.execute(
            select(
                MediaMetadata.media_item_id,
                MediaMetadata.genre_ids,
                MediaMetadata.origin_countries,
                MediaMetadata.original_language,
                MediaMetadata.studios,
                MediaMetadata.series_key,
                MediaMetadata.content_rating,
                MediaMetadata.runtime_minutes,
                MediaItem.year,
            )
            .join(MediaItem, MediaItem.id == MediaMetadata.media_item_id)  # type: ignore[arg-type]
            .where(
                (MediaMetadata.media_item_id == media_item_id)
                | MediaMetadata.media_item_id.in_(candidate_ids)  # type: ignore[attr-defined]
            )
        )
    ).all()
    profiles = {
        row[0]: SimilarProfile(
            genres=frozenset(int(g) for g in row[1] or [] if str(g).lstrip("-").isdigit()),
            countries=frozenset(row[2] or []),
            language=row[3],
            studios=frozenset(row[4] or []),
            series_key=row[5],
            audience=audience_of(row[6]),
            episode_minutes=row[7] if item.kind == "tv" else None,
            year=row[8],
        )
        for row in rows
    }
    target = profiles.pop(media_item_id, None)
    if target is None or not profiles:
        # 没刮到档案的条目无从比较：宁可不出这一行，也不拿片名瞎猜
        return []

    # 人只查与目标片共有的那几位：导演全收，演员只收前 10 位（记下谁是前 3 位的主角）
    links = (
        await session.execute(
            select(
                MediaItemPerson.media_item_id,
                MediaItemPerson.person_id,
                MediaItemPerson.department,
                MediaItemPerson.credit_order,
            ).where(MediaItemPerson.media_item_id == media_item_id)
        )
    ).all()
    target_directors = frozenset(p for _, p, dept, _ in links if dept == "director")
    target_cast = frozenset(
        p for _, p, dept, order in links if dept == "cast" and order < _TOP_CAST
    )
    target_leads = frozenset(
        p for _, p, dept, order in links if dept == "cast" and order < _LEAD_CAST
    )
    shared: dict[int, tuple[set[int], set[int], set[int]]] = {}
    if target_directors or target_cast:
        for other_id, person_id, dept, order in (
            await session.execute(
                select(
                    MediaItemPerson.media_item_id,
                    MediaItemPerson.person_id,
                    MediaItemPerson.department,
                    MediaItemPerson.credit_order,
                ).where(
                    MediaItemPerson.person_id.in_(target_directors | target_cast),  # type: ignore[attr-defined]
                    MediaItemPerson.media_item_id.in_(candidate_ids),  # type: ignore[attr-defined]
                )
            )
        ).all():
            directors, cast, leads = shared.setdefault(other_id, (set(), set(), set()))
            if dept == "director":
                directors.add(person_id)
            elif order < _TOP_CAST:
                cast.add(person_id)
                if order < _LEAD_CAST:
                    leads.add(person_id)

    target = replace(target, directors=target_directors, cast=target_cast, leads=target_leads)
    for other_id, (directors, cast, leads) in shared.items():
        if other_id in profiles:
            profiles[other_id] = replace(
                profiles[other_id],
                directors=frozenset(directors),
                cast=frozenset(cast),
                leads=frozenset(leads),
            )
    return rank_similar(target, profiles, limit)


async def build_similar_wall(
    session: AsyncSession,
    media_item_id: int,
    *,
    library_ids: frozenset[int],
    member_id: int,
    content_limit: ContentLimit | None,
    limit: int,
) -> list[LibraryItemView]:
    """相似推荐那一行的海报卡：与首页跨库墙同一份聚合，卡片长得一模一样。"""
    if not library_ids:
        return []
    ids = await similar_item_ids(
        session,
        media_item_id,
        library_ids=library_ids,
        member_id=member_id,
        content_limit=content_limit,
        limit=limit,
    )
    if not ids:
        return []
    views = await _aggregate_wall_views(session, None, ids, ids, library_ids=set(library_ids))
    favorites = await favorite_item_ids(session, ids, member_id=member_id)
    for view in views:
        view.is_favorite = view.media_item_id in favorites
    return views
