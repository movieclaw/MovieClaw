"""媒体库统一名称搜索：索引召回、实时权限、人物反查和有界的浏览会话。

FTS 只减少候选，最终在单个名称上核验。未索引/待更新的名称走相同匹配规则。
会话仅保存候选顺序，不保存权限结论；每一页重新检查库存、分级及名称证据。
"""

from __future__ import annotations

import asyncio
import secrets
import time
from collections import OrderedDict, defaultdict
from dataclasses import dataclass, replace

from sqlalchemy import case, column, exists, func, literal, or_, table
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.schemas.library_search import (
    LibrarySearchHit,
    LibrarySearchMatch,
    LibrarySearchPerson,
    LibrarySearchSuggestion,
    LibrarySearchView,
)
from movieclaw_api.services.library.access import ContentLimit
from movieclaw_api.services.library.bulk import scalar_rows
from movieclaw_api.services.library.items import _aggregate_wall_views, _narrow
from movieclaw_api.services.library.search_index import INDEX_VERSION, source_names
from movieclaw_api.services.library.search_matching import (
    NameMatch,
    compact,
    match_name,
    normalized,
    query_tokens,
)
from movieclaw_api.services.people_images import avatar_url
from movieclaw_db.models import LibraryFile, MediaItem
from movieclaw_db.models.person import MediaItemPerson, Person

_DOC = table(
    "library_search_document", *map(column, ("id", "entity_kind", "entity_id", "index_version"))
)
_NAME = table(
    "library_search_name",
    *map(
        column,
        (
            "id",
            "document_id",
            "source_field",
            "raw_name",
            "normalized",
            "pinyin",
            "initials",
        ),
    ),
)
_FTS = table("library_search_fts", column("rowid"), column("name_tokens"))
_DIRTY = table("library_search_dirty", column("entity_kind"), column("entity_id"))
_LABELS = {
    "text": "名称匹配",
    "pinyin": "拼音匹配",
    "initials": "首字母匹配",
    "mixed": "文字与拼音混合匹配",
    "words": "名称词组匹配",
}
_FIELD_ORDER = {"title": 0, "original_title": 1, "english_title": 2, "alias": 3}
# 演员表前 5 位（TMDB credit order 0～4）或导演算「主创」：人物排序与人物带出的作品排序都用它
_LEAD_BILLING = 5
_SHORT_MATCH_TYPES = (
    "text_exact",
    "pinyin_exact",
    "initials_exact",
    "text_prefix",
    "pinyin_prefix",
    "initials_prefix",
    "text_contains",
    "pinyin_contains",
    "initials_contains",
)


def _billing(department: str, credit_order: int) -> int:
    """此人在一部片里的排位：导演记作最靠前，演员取剧组给的主次顺序。"""
    return 0 if department == "director" else credit_order


@dataclass(frozen=True, slots=True)
class MatchEvidence:
    """游标仅保存轻量证据；当前页和人物入口才创建响应模型，减少并发分配。

    人物全名与头像不参与候选排序，只在展示时读取；人物身份在当前页重新核验。
    """

    type: str
    source_field: str
    matched_name: str
    label: str
    person_id: int | None = None
    department: str | None = None

    def view(self, person_name: str = "") -> LibrarySearchMatch:
        label = self.label
        if self.department is not None:
            label = f"{'导演' if self.department == 'director' else '演员'}：{person_name}"
        return LibrarySearchMatch(
            type=self.type,
            source_field=self.source_field,
            matched_name=self.matched_name,
            label=label,
            person_id=self.person_id,
        )


@dataclass(slots=True)
class Candidate:
    """候选只记录身份和命中证据，海报及库存仅对当前页聚合。"""

    id: int
    order: tuple[int, int, int, int]
    match: MatchEvidence


@dataclass(slots=True)
class BrowseSession:
    binding: tuple
    expires: float
    candidates: list[Candidate]


_sessions: OrderedDict[str, BrowseSession] = OrderedDict()


def _eligible(library_ids: set[int], member_id: int, limit: ContentLimit | None, person_id=None):
    conditions = [
        LibraryFile.library_id.in_(library_ids),
        LibraryFile.state == "in_place",
        LibraryFile.unidentified_code.is_(None),
        *_narrow(None, member_id, library_id=frozenset(library_ids), content_limit=limit),
    ]
    if person_id is not None:
        conditions.append(
            MediaItem.id.in_(
                select(MediaItemPerson.media_item_id).where(
                    MediaItemPerson.person_id == person_id,
                )
            )
        )
    return (
        select(MediaItem.id)
        .join(
            LibraryFile,
            LibraryFile.media_item_id == MediaItem.id,
        )
        .where(*conditions)
        .distinct()
    )


async def _name_candidates(session, query, eligible):
    allowed_people = select(MediaItemPerson.person_id).where(
        MediaItemPerson.media_item_id.in_(eligible),
    )
    # 先用名称索引缩小候选，再按作品主键/人物索引核验可见性；
    # EXISTS 在找到第一份有效库存时即可停止，不为每次输入构建整库人物集合。
    allowed = or_(
        (_DOC.c.entity_kind == "media")
        & exists(eligible.where(MediaItem.id == _DOC.c.entity_id).correlate(_DOC)),
        (_DOC.c.entity_kind == "person")
        & exists(
            select(1)
            .select_from(MediaItemPerson)
            .where(
                MediaItemPerson.person_id == _DOC.c.entity_id,
                exists(
                    eligible.where(MediaItem.id == MediaItemPerson.media_item_id).correlate(
                        MediaItemPerson
                    )
                ),
            )
        ),
    )
    needle = compact(query)
    prefix = or_(
        *[
            (field >= needle) & (field < needle + "\U0010ffff")
            for field in (_NAME.c.normalized, _NAME.c.pinyin, _NAME.c.initials)
        ]
    )
    doc_ids = select(_NAME.c.document_id).where(prefix)
    tokens = query_tokens(query)
    if tokens and (len(needle) > 1 or not needle.isascii()):
        doc_ids = doc_ids.union(select(_FTS.c.rowid).where(_FTS.c.name_tokens.match(tokens)))
    clean = (_DOC.c.index_version == INDEX_VERSION) & ~exists(
        select(1)
        .select_from(_DIRTY)
        .where(
            _DIRTY.c.entity_kind == _DOC.c.entity_kind,
            _DIRTY.c.entity_id == _DOC.c.entity_id,
        )
    )
    name_filter = ()
    if needle.isascii() and len(needle) <= 2 and normalized(query).strip() == needle:
        # 一个连续短缩写不涉及混输/词组，可直接排除同文档中未命中的其它姓名。
        # 长输入仍完整核验原始名称，不能用 LIKE 过滤掉 xingjicy 这样的混拼。
        name_filter = (
            prefix
            if len(needle) == 1
            else or_(
                *[
                    field.contains(needle)
                    for field in (_NAME.c.normalized, _NAME.c.pinyin, _NAME.c.initials)
                ]
            ),
        )
    columns = (
        _DOC.c.entity_kind,
        _DOC.c.entity_id,
        _NAME.c.source_field,
        _NAME.c.raw_name,
        _NAME.c.normalized,
        _NAME.c.pinyin,
        _NAME.c.initials,
    )
    statement = (
        select(*columns)
        .select_from(_DOC.join(_NAME, _NAME.c.document_id == _DOC.c.id))
        .where(allowed, clean, _DOC.c.id.in_(doc_ids), *name_filter)
    )
    if name_filter:
        # 短 ASCII 输入的档位可由索引列完整求值：数据库内选每个实体最佳名称，
        # 避免并发 sqlite3.fetchAll 把同一人的多个姓名/片段反复转换成 Python 字符串。
        # 其它输入仍逐原名核验，不能合并掉混输或词组可能命中的名称。
        variants = (_NAME.c.normalized, _NAME.c.pinyin, _NAME.c.initials)
        tier = case(
            *[(field == needle, i) for i, field in enumerate(variants)],
            *[(field.startswith(needle), 3 + i) for i, field in enumerate(variants)],
            *[(field.contains(needle), 6 + i) for i, field in enumerate(variants)],
        )
        field_order = case(_FIELD_ORDER, value=_NAME.c.source_field, else_=0)
        ranked = statement.add_columns(
            tier.label("match_tier"),
            func.row_number()
            .over(
                partition_by=(_DOC.c.entity_kind, _DOC.c.entity_id),
                order_by=(tier, field_order, func.length(_NAME.c.normalized), _NAME.c.id),
            )
            .label("position"),
        ).subquery()
        statement = select(*list(ranked.c)[:-1]).where(ranked.c.position == 1)
    else:
        statement = statement.add_columns(literal(None).label("match_tier"))
    rows = await scalar_rows(session, statement, pack=bool(name_filter))
    # 先看实际存在的待更新类型。索引干净时不执行整库权限与人物关联的兜底查询。
    # 保留子查询，首次构建的几万条名称也不会撞 SQLite 参数上限。
    pending_kinds = set(
        (
            await session.execute(
                select(_DIRTY.c.entity_kind)
                .distinct()
                .union(select(_DOC.c.entity_kind).where(_DOC.c.index_version != INDEX_VERSION))
            )
        ).scalars()
    )
    pending = False
    for kind, eligible_ids in (("media", eligible), ("person", allowed_people)):
        if kind not in pending_kinds:
            continue
        ids = select(_DIRTY.c.entity_id).where(
            _DIRTY.c.entity_kind == kind,
            _DIRTY.c.entity_id.in_(eligible_ids),
        )
        ids = ids.union(
            select(_DOC.c.entity_id).where(
                _DOC.c.entity_kind == kind,
                _DOC.c.entity_id.in_(eligible_ids),
                _DOC.c.index_version != INDEX_VERSION,
            )
        )
        latest = await source_names(session, kind, ids)
        pending = pending or bool(latest)
        rows.extend(
            (kind, entity_id, field, raw, None, None, None, None)
            for entity_id, names in latest.items()
            for field, raw in names
        )
    return rows, pending


def _match_rows(query, rows):
    result = {"media": {}, "person": {}}
    for kind, entity_id, field, raw, normalized_name, pinyin_name, initials, tier in rows:
        derived = (normalized_name, pinyin_name, initials) if normalized_name is not None else None
        # 连续短输入已在 SQL 中按同一原名完整核验，不在线程里重复计算档位。
        # 混输、词组与待更新原名仍调用共用匹配内核。
        matched = (
            NameMatch(tier, _SHORT_MATCH_TYPES[tier])
            if tier is not None
            else match_name(query, raw, derived)
        )
        if matched is None:
            continue
        order = (
            matched.tier,
            _FIELD_ORDER.get(field, 0),
            len(normalized_name) if derived is not None else len(compact(raw)),
            entity_id,
        )
        previous = result[kind].get(entity_id)
        if previous is not None and previous.order <= order:
            continue
        label = _LABELS.get(matched.kind.split("_")[0], "名称匹配")
        if field == "alias":
            label = "别名匹配" if matched.kind.startswith("text") else f"别名 · {label}"
        candidate = Candidate(
            entity_id,
            order,
            MatchEvidence(
                type=matched.kind,
                source_field=field,
                matched_name=raw,
                label=label,
            ),
        )
        result[kind][entity_id] = candidate
    return result


async def search_candidates(session, query, library_ids, member_id, content_limit, person_id=None):
    eligible = _eligible(library_ids, member_id, content_limit, person_id)
    if not compact(query):
        ids = (await session.execute(eligible.order_by(MediaItem.title, MediaItem.id))).scalars()
        return (
            [
                Candidate(
                    i,
                    (0, 0, 0, i),
                    MatchEvidence(
                        type="person",
                        source_field="person_name",
                        matched_name="",
                        label="人物作品",
                        person_id=person_id,
                    ),
                )
                for i in ids
            ],
            [],
            False,
        )
    rows, pending = await _name_candidates(session, query, eligible)
    matched = await asyncio.to_thread(_match_rows, query, rows)
    people = []
    people_ids = list(matched["person"])
    if people_ids:
        relations = await scalar_rows(
            session,
            select(
                MediaItemPerson.media_item_id,
                MediaItemPerson.person_id,
                MediaItemPerson.department,
                MediaItemPerson.credit_order,
            )
            .where(
                MediaItemPerson.person_id.in_(people_ids),
                exists(
                    eligible.where(MediaItem.id == MediaItemPerson.media_item_id).correlate(
                        MediaItemPerson
                    )
                ),
            )
            .order_by(MediaItemPerson.department.desc()),
            pack=len(people_ids) > 8,
        )
        counts = defaultdict(set)
        leads = defaultdict(set)
        best_billing: dict[int, int] = {}
        for item_id, pid, department, credit_order in relations:
            billing = _billing(department, credit_order)
            counts[pid].add(item_id)
            if billing < _LEAD_BILLING:
                leads[pid].add(item_id)
            best_billing[pid] = min(best_billing.get(pid, billing), billing)
        for item_id, pid, department, credit_order in relations:
            source = matched["person"][pid]
            # 人物准确命中优先于片名的弱包含，但不能压过准确片名（档位 + 3）。
            # 同档内按此人在这部片里的排位：主演、导演的作品排在龙套作品前面。
            order = (3 + source.order[0], 100, _billing(department, credit_order), item_id)
            previous = matched["media"].get(item_id)
            if previous is not None and previous.order <= order:
                continue
            evidence = replace(source.match, person_id=pid, department=department)
            matched["media"][item_id] = Candidate(item_id, order, evidence)
        # 首字母这类短输入常有一批同档人物（lyt：李一桐、刘奕铁、郎月婷……），作品数又多半相同。
        # 同档按「在本库里的分量」排：担任主创的作品数 > 可见作品数 > 最靠前的一次排位。
        # 全部来自本地关系表，不依赖隐藏库存或远端热度。
        top_people = sorted(
            counts,
            key=lambda i: (
                matched["person"][i].order[0],
                -len(leads[i]),
                -len(counts[i]),
                best_billing[i],
                matched["person"][i].order,
            ),
        )[:8]
        people_info = {
            p.id: p
            for p in (
                await session.execute(
                    select(Person.id, Person.name, Person.profile_path).where(
                        Person.id.in_(top_people)
                    )
                )
            ).all()
        }
        for pid in top_people:
            person = people_info.get(pid)
            if person is None:
                continue
            people.append(
                LibrarySearchPerson(
                    id=pid,
                    name=person.name,
                    profile_path=person.profile_path,
                    avatar_url=avatar_url(person.profile_path),
                    item_count=len(counts[pid]),
                    match=matched["person"][pid].match.view(),
                )
            )
    return sorted(matched["media"].values(), key=lambda c: c.order), people, pending


async def search_library(
    session: AsyncSession,
    query: str,
    *,
    library_ids: set[int],
    member_id: int,
    content_limit: ContentLimit | None,
    owner: str,
    limit: int = 24,
    cursor: str | None = None,
    person_id: int | None = None,
) -> LibrarySearchView:
    """当前页实时装配；会话有时限、个数和总候选数上限，避免无限增长。"""
    binding = (
        str(session.bind.url),
        owner,
        query,
        person_id,
        tuple(sorted(library_ids)),
        repr(content_limit),
    )
    now = time.monotonic()
    for key in list(_sessions):
        if _sessions[key].expires <= now:
            del _sessions[key]
    people = []
    pending = False
    if cursor:
        try:
            token, offset_raw = cursor.rsplit(":", 1)
            offset = int(offset_raw)
            browsing = _sessions[token]
        except (ValueError, KeyError) as exc:
            raise BadRequestException("搜索结果已过期，请重新搜索") from exc
        if browsing.binding != binding or not 0 <= offset <= len(browsing.candidates):
            raise BadRequestException("分页游标与当前搜索不匹配，请重新搜索")
        candidates = browsing.candidates
    else:
        candidates, people, pending = await search_candidates(
            session,
            query,
            library_ids,
            member_id,
            content_limit,
            person_id,
        )
        if len(candidates) > 100000:
            raise BadRequestException("搜索结果过多，请补充片名或人物名称")
        offset = 0
        token = secrets.token_urlsafe(24)
    eligible = _eligible(library_ids, member_id, content_limit, person_id)
    libraries: dict[int, list[int]] = defaultdict(list)
    # 分页期间名称/人物关系也可能改变：核验命中证据，不能继续显示旧名称的假命中。
    page = []
    page_matches = {}
    while len(page) < limit and offset < len(candidates):
        chunk = candidates[offset : offset + limit]
        chunk_ids = [c.id for c in chunk]
        # 每页仍实时检查权限与库存，但只查本次候选，不重复聚合整库文件。
        library_rows = (
            await session.execute(
                select(LibraryFile.media_item_id, LibraryFile.library_id)
                .where(
                    LibraryFile.media_item_id.in_(eligible.where(MediaItem.id.in_(chunk_ids))),
                    LibraryFile.library_id.in_(library_ids),
                    LibraryFile.state == "in_place",
                    LibraryFile.unidentified_code.is_(None),
                )
                .distinct()
            )
        ).all()
        for item_id, library_id in library_rows:
            libraries[item_id].append(library_id)
        # 人物命中的作品只需核验人物名称与关系，不必重复读取全部影片别名。
        title_ids = [c.id for c in chunk if c.match.person_id is None]
        latest_media = await source_names(session, "media", title_ids) if compact(query) else {}
        pids = list(
            dict.fromkeys(c.match.person_id for c in chunk if c.match.person_id is not None)
        )
        latest_people = await source_names(session, "person", pids) if compact(query) else {}
        relations = {}
        if pids:
            relation_rows = (
                await session.execute(
                    select(
                        MediaItemPerson.media_item_id,
                        MediaItemPerson.person_id,
                        MediaItemPerson.department,
                    ).where(
                        MediaItemPerson.media_item_id.in_(chunk_ids),
                        MediaItemPerson.person_id.in_(pids),
                    )
                )
            ).all()
            for item_id, pid, department in relation_rows:
                pair = (item_id, pid)
                # 与首次召回一致：兼任演员和导演时优先展示导演身份。
                if pair not in relations or department == "director":
                    relations[pair] = department
        for candidate in chunk:
            offset += 1
            if candidate.id not in libraries:
                continue
            evidence = candidate.match
            names = latest_media.get(candidate.id, [])
            if evidence.person_id is not None:
                pair = (candidate.id, evidence.person_id)
                if pair not in relations:
                    continue
                if evidence.department is not None:
                    evidence = replace(evidence, department=relations[pair])
                names = latest_people.get(evidence.person_id, [])
            if compact(query) and (evidence.source_field, evidence.matched_name) not in names:
                continue
            page.append(candidate)
            person_name = next((raw for field, raw in names if field == "person_name"), "")
            page_matches[candidate.id] = evidence.view(person_name)
            if len(page) == limit:
                break
    ids = [c.id for c in page]
    landing = [(i, min(libraries[i])) for i in ids]
    views = (
        await _aggregate_wall_views(session, None, ids, ids, landing_pairs=landing) if ids else []
    )
    by_id = {view.media_item_id: view for view in views}
    items = [
        LibrarySearchHit(
            item=by_id[c.id],
            library_ids=sorted(libraries[c.id]),
            match=page_matches[c.id],
        )
        for c in page
        if c.id in by_id
    ]
    next_cursor = None
    if offset < len(candidates):
        _sessions[token] = BrowseSession(binding, now + 120, candidates)
        _sessions.move_to_end(token)
        while len(_sessions) > 32 or sum(len(v.candidates) for v in _sessions.values()) > 100000:
            oldest = next(iter(_sessions))
            if oldest == token:
                break
            _sessions.popitem(last=False)
        next_cursor = f"{token}:{offset}"
    else:
        _sessions.pop(token, None)
    suggestions = (
        [
            LibrarySearchSuggestion(
                type="title",
                text=hit.item.title,
                media_item_id=hit.item.media_item_id,
            )
            for hit in items[:5]
        ]
        if not cursor
        else []
    )
    suggestions.extend(
        LibrarySearchSuggestion(type="person", text=p.name, person_id=p.id) for p in people[:3]
    )
    return LibrarySearchView(
        query=query,
        person_id=person_id,
        items=items,
        people=people,
        suggestions=suggestions,
        next_cursor=next_cursor,
        index_pending=pending,
    )
