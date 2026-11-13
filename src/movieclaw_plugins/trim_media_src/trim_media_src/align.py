"""库对齐与复用：飞牛库挂进来时，先对齐 MC 已有的识别成果，只做必要的活。

设计（按用户要求的三级匹配 + 兜底待识别）：

    L1  飞牛 trim_id → MC media_item.tmdb_id        复用条目，不重新刮削
    L2  飞牛文件 (size, duration) → MC 台账行        飞牛没 TMDB id 但文件是同一份
    L3  飞牛 标题/原名 + 年份 → MC media_item        没有 TMDB id 时的兜底
    L4  都没命中                                   建临时本地身份 + 待识别标记，
                                                  进 MC 的「待识别」清单由用户认领

两个阶段：

- **只读对齐**（``align(apply=False)``）：盘点飞牛 + 比对 MC，产出报告，不写任何数据；
- **执行复用**（``align(apply=True)``）：只对报告里确认过的行操作——
  搬文件级数据（片头片尾 / 规格 / 章节 / 身份来源）+ 给 L4 建临时身份。

为什么不「边同步边猜」：识别链对每条新路径都要解析文件名 + 搜 TMDB，几千个文件
就是几千次搜索；而这些文件在原始库里**早就识别过**（同一份文件，size 与时长一致）。
先对齐、再决定干什么，能把无用功全部省掉，也能给人一份可核对的清单。
"""

from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass, field
from typing import Any

#: 与主程序 skip_segments.ALGO_VERSION 保持一致
_CURRENT_ALGO = 10
#: 分块提交的条数（和主程序扫描同口径：小事务，别攒大事务）
_CHUNK = 200
#: 未匹配条目的说明（写进台账，用户能在待识别清单里看到）
_UNMATCHED_REASON = "飞牛条目没有 TMDB 标识，MC 里也没找到匹配，请人工认领"


@dataclass
class TrimEntry:
    """从飞牛盘点出来的一条（电影本体 / 分集）。"""

    guid: str
    kind: str  # movie / tv
    title: str
    original_title: str = ""
    year: int | None = None
    tmdb_id: int | None = None
    season: int | None = None
    episode: int | None = None
    duration: int | None = None
    remote_path: str | None = None
    size: int | None = None


@dataclass
class MatchBucket:
    """某一级匹配命中的条目。"""

    #: (飞牛条目, MC media_item_id)
    entries: list[tuple[TrimEntry, int]] = field(default_factory=list)


@dataclass
class AlignReport:
    """一次对齐的结果（可直接序列化成 JSON 给人看）。"""

    library: str
    library_id: int
    trim_entries: int = 0
    #: 各级命中
    l1_tmdb: int = 0
    l2_file: int = 0
    l3_title: int = 0
    unmatched: int = 0
    #: 文件级可复用的行数（片头片尾/规格/章节能直接搬）
    reusable_files: int = 0
    #: 未匹配清单（供用户处理）
    unmatched_titles: list[str] = field(default_factory=list)
    #: 执行阶段的结果
    applied: dict[str, int] = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "library": self.library,
            "library_id": self.library_id,
            "trim_entries": self.trim_entries,
            "match": {
                "l1_tmdb": self.l1_tmdb,
                "l2_file": self.l2_file,
                "l3_title": self.l3_title,
                "unmatched": self.unmatched,
            },
            "reusable_files": self.reusable_files,
            "unmatched_titles": self.unmatched_titles[:50],
            "applied": self.applied,
            "errors": self.errors[:20],
        }


# --------------------------------------------------------------------- 盘点
async def inventory(trim: Any, *, library_guid: str, kind: str, log: Any) -> list[TrimEntry]:
    """从飞牛盘点一个库的全部条目（电影本体 / 分集）。

    只有需要文件级匹配时（没 TMDB id）才去取 size，避免几千次无效请求。
    """
    from .trim_api import TYPE_MOVIE, TYPE_TV

    top = await trim.all_items(library_guid)
    out: list[TrimEntry] = []
    if kind == "movie":
        for item in top:
            if item.type != TYPE_MOVIE or not item.guid:
                continue
            out.append(
                TrimEntry(
                    guid=item.guid,
                    kind="movie",
                    title=str(item.title or ""),
                    original_title=str(item.original_title or ""),
                    year=item.year,
                    tmdb_id=item.tmdb_id,
                    duration=item.duration,
                )
            )
        return out

    tvs = [i for i in top if i.type == TYPE_TV and i.guid]
    for index, tv in enumerate(tvs, start=1):
        try:
            episodes = await trim.tv_episodes(tv.guid)
        except Exception as exc:  # noqa: BLE001 -- 单部剧失败不拖垮盘点
            log.warning("盘点《%s》分集失败：%s", tv.title, exc)
            continue
        for ep in episodes:
            out.append(
                TrimEntry(
                    guid=ep.guid,
                    kind="tv",
                    title=str(ep.tv_title or tv.title or ep.title or ""),
                    original_title=str(tv.original_title or ""),
                    year=ep.year or tv.year,
                    tmdb_id=ep.tmdb_id or tv.tmdb_id,
                    season=ep.season_number,
                    episode=ep.episode_number,
                    duration=ep.duration,
                )
            )
        if index % 20 == 0:
            await _yield()
    return out


async def enrich_file_info(trim: Any, entries: list[TrimEntry], *, log: Any) -> None:
    """给「没有 TMDB id」的条目补文件信息（path/size），用于 L2 文件级匹配。

    只对这类条目调 ``/stream/list``：有 TMDB 的直接 L1 命中，不需要文件信息。
    """
    need = [e for e in entries if e.tmdb_id is None]
    if not need:
        return
    log.info("有 %d 条没有 TMDB 标识，取文件信息做文件级匹配", len(need))
    for index, entry in enumerate(need, start=1):
        try:
            data = await trim._request("GET", f"/stream/list/{entry.guid}")
        except Exception:  # noqa: BLE001 -- 取不到就留给 L3/L4
            continue
        files = (data or {}).get("files") or []
        if not files:
            continue
        f = files[0]
        entry.remote_path = f.get("path")
        entry.size = f.get("size")
        entry.duration = entry.duration or f.get("duration")
        if index % 50 == 0:
            await _yield()


# --------------------------------------------------------------------- 匹配
async def match(
    session: Any, entries: list[TrimEntry], *, library_id: int, path_map: tuple[str, str]
) -> tuple[MatchBucket, MatchBucket, MatchBucket, list[TrimEntry]]:
    """三级匹配，返回 (L1, L2, L3, 未匹配)。只读。"""
    from sqlmodel import select

    from movieclaw_db.models import LibraryFile, MediaItem

    l1, l2, l3 = MatchBucket(), MatchBucket(), MatchBucket()
    unmatched: list[TrimEntry] = []

    # L1：TMDB 直配
    tmdb_ids = sorted({e.tmdb_id for e in entries if e.tmdb_id})
    by_tmdb: dict[int, int] = {}
    for chunk in _chunks(tmdb_ids, 500):
        for row in (
            await session.execute(
                select(MediaItem.tmdb_id, MediaItem.id).where(MediaItem.tmdb_id.in_(chunk))
            )
        ).all():
            if row[0] is not None and row[1] is not None:
                by_tmdb[int(row[0])] = int(row[1])

    rest: list[TrimEntry] = []
    for entry in entries:
        media_id = by_tmdb.get(int(entry.tmdb_id)) if entry.tmdb_id else None
        if media_id is not None:
            l1.entries.append((entry, media_id))
        else:
            rest.append(entry)

    # L2：文件级（size + duration 都对上），只对没有 TMDB id 的条目
    for entry in rest:
        if entry.tmdb_id or not entry.size:
            continue
        local = map_local(entry.remote_path, path_map)
        if not local or not await asyncio.to_thread(os.path.isfile, local):
            continue
        twin = (
            await session.execute(
                select(LibraryFile.media_item_id)
                .where(
                    LibraryFile.size_bytes == int(entry.size),
                    LibraryFile.duration_seconds == int(entry.duration or 0),
                    LibraryFile.library_id != library_id,
                    LibraryFile.media_item_id.is_not(None),
                )
                .limit(1)
            )
        ).first()
        if twin is not None and twin[0] is not None:
            l2.entries.append((entry, int(twin[0])))

    matched_guids = {e.guid for e, _ in l2.entries}

    # L3：标题 + 年份（没有 TMDB id、文件也没对上的兜底）
    for entry in rest:
        if entry.tmdb_id or entry.guid in matched_guids:
            continue
        names = [n for n in (entry.title, entry.original_title) if n]
        if not names:
            unmatched.append(entry)
            continue
        found = (
            await session.execute(
                select(MediaItem.id)
                .where(
                    MediaItem.title.in_(names),
                    *([MediaItem.year == entry.year] if entry.year else []),
                )
                .limit(1)
            )
        ).first()
        if found is not None and found[0] is not None:
            l3.entries.append((entry, int(found[0])))
        else:
            unmatched.append(entry)

    return l1, l2, l3, unmatched


async def count_reusable_files(session: Any, *, library_id: int) -> int:
    """本库台账里，有多少行能从别的库搬来文件级数据（片头片尾/规格/章节）。只读。"""
    from sqlmodel import text

    row = (
        await session.execute(
            text(
                """
                SELECT COUNT(*) FROM library_file tlf
                JOIN library_file olf
                     ON olf.size_bytes = tlf.size_bytes
                    AND olf.file_mtime_ns = tlf.file_mtime_ns
                    AND olf.id != tlf.id
                JOIN library ol ON ol.id = olf.library_id AND ol.source != 'trim'
                WHERE tlf.library_id = :lid
                  AND tlf.state = 'in_place'
                  AND (tlf.resolution IS NULL OR tlf.duration_seconds IS NULL)
                """
            ),
            {"lid": library_id},
        )
    ).first()
    return int(row[0]) if row else 0


# --------------------------------------------------------------------- 执行
async def apply_reuse(session: Any, *, library_id: int, log: Any) -> dict[str, int]:
    """把别的库同文件（size+mtime 一致）的文件级数据搬给本库的台账行。

    搬的是：介质规格、时长、音轨/字幕轨、章节、身份来源、容器。
    片头片尾（media_segment）单独搬——那张表按 library_file_id 记账。
    幂等：本行已有规格就不再覆盖。
    """
    from sqlmodel import text

    stats = {"specs": 0, "segments": 0}

    # 1) 介质规格
    spec_cols = (
        "resolution, video_codec, hdr, bit_depth, duration_seconds, bit_rate, "
        "frame_rate, color_space, audio_streams, subtitle_streams, chapters, "
        "container, media_source, release_group, identity_source"
    )
    rows = (
        await session.execute(
            text(
                f"""
                SELECT tlf.id, {", ".join("o." + c.strip() for c in spec_cols.split(","))}
                FROM library_file tlf
                JOIN library_file o
                     ON o.size_bytes = tlf.size_bytes
                    AND o.file_mtime_ns = tlf.file_mtime_ns
                    AND o.id != tlf.id
                JOIN library ol ON ol.id = o.library_id AND ol.source != 'trim'
                WHERE tlf.library_id = :lid
                  AND tlf.state = 'in_place'
                  AND (tlf.resolution IS NULL OR tlf.duration_seconds IS NULL)
                  AND o.resolution IS NOT NULL
                GROUP BY tlf.id
                """
            ),
            {"lid": library_id},
        )
    ).all()
    for start in range(0, len(rows), _CHUNK):
        for row in rows[start : start + _CHUNK]:
            values = dict(zip([c.strip() for c in spec_cols.split(",")], row[1:], strict=False))
            sets = ", ".join(f"{k} = :{k}" for k in values)
            await session.execute(
                text(f"UPDATE library_file SET {sets} WHERE id = :fid"),
                {**values, "fid": row[0]},
            )
            stats["specs"] += 1
        await session.commit()
        await _yield()
    if stats["specs"]:
        log.info("复用介质规格：%d 行", stats["specs"])

    # 2) 片头片尾（media_segment 按 library_file_id 记账，同文件两行各一份）
    seg_rows = (
        await session.execute(
            text(
                """
                SELECT tlf.id, ms.segments, ms.algo_version, ms.analyzed_at,
                       ms.fingerprinted_at, ms.source_size
                FROM library_file tlf
                JOIN library_file o
                     ON o.size_bytes = tlf.size_bytes
                    AND o.file_mtime_ns = tlf.file_mtime_ns
                    AND o.id != tlf.id
                JOIN library ol ON ol.id = o.library_id AND ol.source != 'trim'
                JOIN media_segment ms ON ms.library_file_id = o.id
                LEFT JOIN media_segment tms ON tms.library_file_id = tlf.id
                WHERE tlf.library_id = :lid
                  AND tlf.state = 'in_place'
                  AND ms.fingerprint_status = 'ok'
                  AND ms.segments IS NOT NULL
                  AND ms.segments != 'null'
                  AND ms.algo_version = :algo
                  AND (tms.analyzed_at IS NULL OR tms.segments IS NULL OR tms.segments = 'null')
                GROUP BY tlf.id
                """
            ),
            {"lid": library_id, "algo": _CURRENT_ALGO},
        )
    ).all()
    for start in range(0, len(seg_rows), _CHUNK):
        for row in seg_rows[start : start + _CHUNK]:
            await session.execute(
                text(
                    """
                    INSERT INTO media_segment
                        (library_file_id, fingerprint_status, segments, algo_version,
                         analyzed_at, fingerprinted_at, source_size, created_at, updated_at)
                    VALUES (:fid, 'ok', :segments, :algo, :analyzed, :fp, :size,
                            datetime('now'), datetime('now'))
                    ON CONFLICT(library_file_id) DO UPDATE SET
                        fingerprint_status = 'ok',
                        segments = excluded.segments,
                        algo_version = excluded.algo_version,
                        analyzed_at = excluded.analyzed_at,
                        fingerprinted_at = excluded.fingerprinted_at,
                        source_size = excluded.source_size,
                        updated_at = excluded.updated_at
                    """
                ),
                {
                    "fid": row[0],
                    "segments": row[1],
                    "algo": row[2],
                    "analyzed": row[3],
                    "fp": row[4],
                    "size": row[5],
                },
            )
            stats["segments"] += 1
        await session.commit()
        await _yield()
    if stats["segments"]:
        log.info("复用片头片尾：%d 行", stats["segments"])
    return stats


async def apply_matched(
    session: Any,
    matched: list[tuple[TrimEntry, int]],
    *,
    library_id: int,
    path_map: tuple[str, str],
    log: Any,
) -> int:
    """L2/L3 命中的条目：给本库建台账行并挂上已有的 ``media_item_id``。

    这一步的价值：主线扫描对每条**不认识的路径**都要跑识别链（解析文件名 → 搜 TMDB）。
    先把台账行写好（带身份锚），扫描到这些路径就是「已知行」直接跳过——
    飞牛里那些没刮到 TMDB、但文件其实是 MC 里已有的片，就不用再猜一次。
    """
    from sqlmodel import select

    from movieclaw_db.models import LibraryFile

    if not matched:
        return 0
    from movieclaw_db.models import MediaItem

    existing_rows = {
        row.file_path: row
        for row in (await session.execute(
            select(LibraryFile).where(LibraryFile.library_id == library_id)
        )).scalars().all()
    }
    written = 0
    for entry, media_item_id in matched:
        local = map_local(entry.remote_path, path_map)
        if not local:
            continue
        if not await asyncio.to_thread(os.path.isfile, local):
            continue
        if local in existing_rows:
            # 行已存在：如果它挂的是「临时本地身份」（扫描认不出时建的那种），
            # 就升级成正式条目 —— 这正是文件级/标题级匹配的价值所在
            row = existing_rows[local]
            if row.media_item_id == media_item_id:
                continue
            current = (
                await session.get(MediaItem, row.media_item_id) if row.media_item_id else None
            )
            if current is None or str(current.source) == "local":
                row.media_item_id = media_item_id
                row.unidentified_code = None
                row.unidentified_reason = None
                row.unidentified_message = None
                row.identity_source = "manual"
                written += 1
                if written % 40 == 0:
                    await session.commit()
                    await _yield()
            continue
        # 同一份文件在别的库可能已有完整规格：顺手带上，省掉一次探测
        twin = (
            await session.execute(
                select(
                    LibraryFile.size_bytes, LibraryFile.file_mtime_ns,
                    LibraryFile.duration_seconds, LibraryFile.container,
                    LibraryFile.resolution, LibraryFile.video_codec,
                    LibraryFile.identity_source,
                )
                .where(
                    LibraryFile.size_bytes == int(entry.size or 0),
                    LibraryFile.media_item_id == media_item_id,
                )
                .limit(1)
            )
        ).first()
        row = LibraryFile(
            library_id=library_id,
            media_item_id=media_item_id,
            season_number=entry.season or 0,
            episode_number=entry.episode or 0,
            file_path=local,
            size_bytes=int(entry.size or 0),
            file_mtime_ns=twin[1] if twin else None,
            duration_seconds=(twin[2] if twin and twin[2] else entry.duration),
            container=(
                (twin[3] if twin else None)
                or (os.path.splitext(local)[1].lstrip(".").lower() or None)
            ),
            resolution=twin[4] if twin else None,
            video_codec=twin[5] if twin else None,
            local_bytes=True,
            state="in_place",
            source="scanned",
            identity_source=twin[6] if twin else None,
        )
        session.add(row)
        existing_rows[local] = row
        written += 1
        if written % 40 == 0:
            await session.commit()
            await _yield()
    await session.commit()
    if written:
        log.info("按已有识别结论补台账：%d 条（扫描将跳过识别链）", written)
    return written


async def apply_unmatched(
    session: Any, entries: list[TrimEntry], *, library_id: int, kind: str,
    path_map: tuple[str, str], log: Any
) -> int:
    """L4：给匹配不到的飞牛条目建临时本地身份 + 待识别标记，进 MC 的「待识别」清单。

    做法与主程序扫描链一致（scan.py 的 ``build_local_identity`` + ``ensure_local_item``）：
    文件立刻可见可播，同时 ``unidentified_code='no_match'`` 让它在待识别清单里，
    用户在界面上认领后就成了正式条目。
    """
    from sqlmodel import select

    from movieclaw_api.services.library.local_identity import LocalIdentity
    from movieclaw_api.services.media_discover import get_tmdb_client
    from movieclaw_api.services.media_library import MediaLibraryService
    from movieclaw_db.models import LibraryFile
    from movieclaw_db.models.library_file import UnidentifiedCode

    if not entries:
        return 0
    service = MediaLibraryService(session, get_tmdb_client(), scrape_library_id=library_id)
    written = 0
    for entry in entries:
        local = map_local(entry.remote_path, path_map)
        if not local:
            continue
        if not await asyncio.to_thread(os.path.isfile, local):
            continue  # 换算出的路径在本机不存在：不建假记录
        existing = (
            await session.execute(
                select(LibraryFile).where(
                    LibraryFile.library_id == library_id, LibraryFile.file_path == local
                )
            )
        ).scalars().first()
        if existing is not None:
            # 行已有（扫描建的临时本地身份），但没打待识别标记 —— 补上，
            # 用户才能在「待识别」清单里看到并认领
            if existing.unidentified_code is None:
                existing.unidentified_code = UnidentifiedCode.NO_MATCH.value
                existing.unidentified_reason = _UNMATCHED_REASON
                existing.unidentified_message = {
                    "message_key": "errors.trimMedia.unmatched",
                    "message_params": {},
                }
                written += 1
                if written % 40 == 0:
                    await session.commit()
                    await _yield()
            continue
        identity = LocalIdentity(
            external_id=f"trim:{entry.guid}",
            title=entry.title or entry.original_title or entry.guid,
            year=entry.year,
            runtime_minutes=(entry.duration // 60) if entry.duration else None,
        )
        item = await service.ensure_local_item(
            __import__("movieclaw_media.models", fromlist=["MediaKind"]).MediaKind(kind),
            identity,
            library_id=library_id,
        )
        row = LibraryFile(
            library_id=library_id,
            media_item_id=item.id,
            season_number=entry.season or 0,
            episode_number=entry.episode or 0,
            file_path=local,
            size_bytes=int(entry.size or 0),
            file_mtime_ns=None,
            duration_seconds=entry.duration,
            container=(os.path.splitext(local)[1].lstrip(".").lower() or None),
            local_bytes=True,
            state="in_place",
            source="scanned",
            unidentified_code=UnidentifiedCode.NO_MATCH.value,
            unidentified_reason=_UNMATCHED_REASON,
            # message 是 i18n 结构（主程序按 dict 取 message_key），纯字符串会把它
            # 的待识别接口整个打 500 —— 实测踩过
            unidentified_message={
                "message_key": "errors.trimMedia.unmatched",
                "message_params": {},
            },
        )
        session.add(row)
        written += 1
        if written % 40 == 0:
            await session.commit()
            await _yield()
    await session.commit()
    if written:
        log.info("未匹配条目已放入待识别清单：%d 条", written)
    return written


# --------------------------------------------------------------------- 工具
def map_local(remote_path: str | None, path_map: tuple[str, str]) -> str | None:
    """飞牛侧路径 → 本机路径（用插件的 path_map 换算）。"""
    if not remote_path:
        return None
    frm, to = path_map
    if not frm or not to:
        return None
    raw = remote_path.strip()
    if not raw.startswith(frm):
        return None
    tail = raw[len(frm):].strip("/")
    return f"{to.rstrip('/')}/{tail}" if tail else to.rstrip("/")


def _chunks(seq: list, size: int) -> list[list]:
    return [seq[i : i + size] for i in range(0, len(seq), size)]


async def _yield() -> None:
    """照主程序的做法：前台有请求在算就让一步。"""
    try:
        from movieclaw_api.services.foreground import yield_to_foreground

        await yield_to_foreground()
    except Exception:  # noqa: BLE001 -- 没有前台压力模块时零开销
        await asyncio.sleep(0)
