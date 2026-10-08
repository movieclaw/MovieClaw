"""「媒体库有新片」推送（docs/design/cloud-push.md §5）。

入库的路径很多（订阅入库、手动下载、监听目录、扫描库根……），在每个写台账的地方
各挂一次钩子迟早会漏。这里反过来：后台每两分钟看一眼台账里**新出现的行**，从数据上
判断「是不是新片」，所有入库路径一次覆盖。

什么算新片：某部片（或某一集）**第一次**出现在这个库里——同库同单元已经有更早的行，
说明是洗版、多版本或改名，不算。扫描发现的文件在库建好后的头 24 小时内不算：那是
新建媒体库的首次全量扫描，推出去就是几千条；文件本身是一周前就有的老文件也不算（给库
加了个目录、换了挂载点）。图片库不推（同步几百张照片不是「新片」）。

认不出的文件（影视库里挂着临时身份）先不推：推出去只有一个原始文件名。等它被认出来
（重新识别、手动认领）再按正确的片名推，最多等 24 小时。

攒一攒再发：一个库连续 5 分钟没有新行才发，最多等 30 分钟。发的时候只投一个事件给推送事件
中枢（hub.py）：每个人只剩一部要说的，进那部剧的卡（cards.py，安静送达）；不止一部合成一条
汇总。推给打开了这项、并勾选了这个库（或选了「全部」）的人；看不到的库、超出分级的片、静音了
的片不推；已经在这个人剧卡上说过的那几集（自己订阅、手动下载的）不再推。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services.push.events import _lazy_image
from movieclaw_api.services.push.notify import AlertContent, notify
from movieclaw_api.settings.cloud import ArrivalsProgress
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    FileSource,
    FileState,
    Library,
    LibraryFile,
    MediaItem,
    utcnow,
)

logger = logging.getLogger("movieclaw_api.push.arrivals")

TICK_S = 120
#: 一个库安静这么久（没有新行）才发
QUIET = timedelta(minutes=5)
#: 最多攒这么久，持续入库时也按这个节奏发
MAX_WAIT = timedelta(minutes=30)
#: 新建的库头 24 小时扫描出来的不算新片（首次全量扫描）
NEW_LIBRARY_GRACE = timedelta(hours=24)
#: 只看最近这么久新建的台账行：服务停了很久再起来，不补推一天前的「新片」；
#: 也让每一轮的查询量有上限（水位很旧的库不会把查询范围拖回几个月前）
LOOKBACK = timedelta(hours=24)
#: 认不出的文件最多等这么久；记录条数也有上限，防止一个乱七八糟的目录把进度撑爆
HOLD_MAX = timedelta(hours=24)
HOLD_LIMIT = 2000
#: 扫描到的文件修改时间比入账早这么久，就当是早就有的老文件（见 ``_long_existing``）
OLD_FILE = timedelta(days=7)
#: 一条汇总里点名的片数
NAMED_IN_SUMMARY = 3


def watchable(library: Library) -> bool:
    """这个库的内容能看（电影、剧集、其他视频）：图片库不推「媒体库有新片」。"""
    from movieclaw_api.services.library.profile import profile_of

    try:
        return profile_of(library).playable
    except BadRequestException:
        return False


@dataclass
class ItemArrival:
    """一个条目在这一批里新到的单元。"""

    item: MediaItem
    units: list[tuple[int, int]] = field(default_factory=list)


@dataclass
class LibraryBatch:
    library: Library
    items: list[ItemArrival]


@dataclass
class Collected:
    """一轮检查的结果：要发的批次，以及新的进度（发完再存）。"""

    batches: list[LibraryBatch]
    marks: dict[str, datetime]
    held: dict[str, datetime]


async def _progress() -> ArrivalsProgress:
    from movieclaw_api.settings import get_setting_store

    return await get_setting_store().get(ArrivalsProgress)


async def _save(progress: ArrivalsProgress) -> None:
    from movieclaw_api.settings import get_setting_store

    await get_setting_store().set(progress)


async def collect_ready(session: AsyncSession, now: datetime) -> Collected:
    """找出可以发的批次。不写库，调用方发完再存进度。"""
    progress = await _progress()
    started = progress.started_at or now
    floor = max(started, now - LOOKBACK)
    # 水位比查询下限还早的库，下限之后的行对它都是新的：不用再记
    marks = {int(k): v for k, v in progress.marks.items() if v > floor}
    held = {int(k): v for k, v in progress.held.items() if now - v < HOLD_MAX}

    # 先只读三列分组：一天的台账可能有几千行，每两分钟读一次，真要处理的库再取整行
    heads = (
        await session.execute(
            select(LibraryFile.id, LibraryFile.library_id, LibraryFile.created_at).where(  # type: ignore[call-overload]
                LibraryFile.created_at >= floor
            )
        )
    ).all()
    by_library: dict[int, list[tuple[int, datetime]]] = {}
    for row_id, library_id, created_at in heads:
        if library_id is None or row_id in held:
            continue
        if created_at > marks.get(library_id, started):
            by_library.setdefault(library_id, []).append((row_id, created_at))

    batches: list[LibraryBatch] = []
    for library_id, group in by_library.items():
        newest = max(created_at for _, created_at in group)
        oldest = min(created_at for _, created_at in group)
        if newest > now - QUIET and oldest > now - MAX_WAIT:
            continue  # 还在陆续入库，再等等
        marks[library_id] = newest
        library = await session.get(Library, library_id)
        if library is None or not watchable(library):
            continue
        rows = await _rows(session, [row_id for row_id, _ in group])
        items, waiting = await _arrivals(session, library, rows)
        for row in waiting:
            held[row.id or 0] = now
        if items:
            batches.append(LibraryBatch(library=library, items=items))

    # 之前认不出、现在认出来的文件：按新片推（它们的创建时间早已过了安静期）
    if held:
        rows = await _rows(session, list(held))
        present = {row.id for row in rows}
        for row_id in [r for r in held if r not in present]:
            held.pop(row_id)  # 行已经没了（文件删了、清理了），不用再等
        released: dict[int, list[LibraryFile]] = {}
        for row in rows:
            if row.unidentified_code is not None:
                continue  # 还没认出来，接着等
            held.pop(row.id or 0, None)
            if row.library_id is not None:
                released.setdefault(row.library_id, []).append(row)
        for library_id, rows in released.items():
            library = await session.get(Library, library_id)
            if library is None or not watchable(library):
                continue
            items, _ = await _arrivals(session, library, rows)
            if items:
                batches.append(LibraryBatch(library=library, items=items))

    if len(held) > HOLD_LIMIT:
        held = dict(sorted(held.items(), key=lambda kv: kv[1])[-HOLD_LIMIT:])
    return Collected(
        batches=batches,
        marks={str(k): v for k, v in marks.items()},
        held={str(k): v for k, v in held.items()},
    )


async def _rows(session: AsyncSession, ids: list[int]) -> list[LibraryFile]:
    if not ids:
        return []
    return list(
        (
            await session.execute(
                select(LibraryFile)
                .where(LibraryFile.id.in_(ids))  # type: ignore[union-attr]
                .order_by(LibraryFile.id)
            )
        )
        .scalars()
        .all()
    )


async def _arrivals(
    session: AsyncSession, library: Library, rows: list[LibraryFile]
) -> tuple[list[ItemArrival], list[LibraryFile]]:
    """这一批里真正「新」的单元，按条目归并；以及要等它被认出来的行。"""
    found: dict[int, ItemArrival] = {}
    waiting: list[LibraryFile] = []
    for row in rows:
        if row.media_item_id is None or row.state != FileState.IN_PLACE.value:
            continue
        if row.source == FileSource.SCANNED.value and (
            row.created_at - library.created_at < NEW_LIBRARY_GRACE or _long_existing(row)
        ):
            continue  # 新建库的首次全量扫描；给库加了个装着老片的目录
        if row.unidentified_code is not None:
            waiting.append(row)  # 认不出的文件挂着临时身份：等认出来再推
            continue
        unit = (row.season_number, row.episode_number)
        earlier = (
            await session.execute(
                select(LibraryFile.id).where(  # type: ignore[call-overload]
                    LibraryFile.library_id == library.id,
                    LibraryFile.media_item_id == row.media_item_id,
                    LibraryFile.season_number == unit[0],
                    LibraryFile.episode_number == unit[1],
                    LibraryFile.id < row.id,  # type: ignore[operator]
                )
            )
        ).first()
        if earlier is not None:
            continue  # 洗版、多版本、改名：这个单元库里早就有了
        arrival = found.get(row.media_item_id)
        if arrival is None:
            item = await session.get(MediaItem, row.media_item_id)
            if item is None:
                continue
            arrival = found[row.media_item_id] = ItemArrival(item=item)
        if unit not in arrival.units:
            arrival.units.append(unit)
    return list(found.values()), waiting


def _long_existing(row: LibraryFile) -> bool:
    """扫描到的文件本身早就存在（修改时间比入账早一周以上）：多半是给库加了个目录、
    换了挂载点，把老片子扫了进来，不是新到的。下载、导入进来的文件修改时间都是新的。"""
    if row.file_mtime_ns is None:
        return False
    modified = datetime.fromtimestamp(row.file_mtime_ns / 1e9, UTC).replace(tzinfo=None)
    return row.created_at - modified > OLD_FILE


def recipients(library_id: int):  # type: ignore[no-untyped-def]
    """打开了「媒体库有新片」、并关心这个库、也看得到这个库的人。"""

    async def resolve(session: AsyncSession) -> set[int]:
        from movieclaw_api.services.library.access import member_visible_ids
        from movieclaw_api.services.push import preferences
        from movieclaw_db.models import Member

        members = {0} | {
            int(m)
            for m in (
                await session.execute(
                    select(Member.id).where(Member.status == "active")  # type: ignore[call-overload]
                )
            ).scalars()
            if m is not None
        }
        wanting = await preferences.wants(session, members, "library_new")
        selections = await preferences.library_selections(session, wanting)
        result = set()
        for member_id in wanting:
            chosen = selections.get(member_id)
            if chosen is not None and library_id not in chosen:
                continue
            if library_id in await member_visible_ids(session, member_id):
                result.add(member_id)
        return result

    return resolve


def announce_summary(
    library_id: int, member_id: int, items: dict[int, list[tuple[int, int]]]
) -> None:
    """一个人这一批里不止一部：合成「『电影』新增 N 部：A、B、C 等」（安静送达）。

    只剩一部的不走这里，进那部剧的卡（cards.py）。
    """

    async def build(session: AsyncSession, _member_id: int) -> AlertContent | None:
        library = await session.get(Library, library_id)
        found = [item for i in items if (item := await session.get(MediaItem, i)) is not None]
        if library is None or not found:
            return None
        videos = library.kind not in ("movie", "tv")  # 「其他」库：家庭录像、课程这类，不叫「片」
        names = "、".join(item.title for item in found[:NAMED_IN_SUMMARY])
        more = "等" if len(found) > NAMED_IN_SUMMARY else ""
        unit = "个视频" if videos else "部"
        return AlertContent(
            title=f"「{library.name}」新增 {len(found)} {unit}",
            body=f"{names}{more}",
            image=await _lazy_image(_image_url(found[0]))(),
            open=f"/library/{library_id}",
            thread=f"library-{library_id}",
            level="passive",
            relevance=0.3,
        )

    notify("library_new", {member_id}, build)


def _image_url(item: MediaItem) -> str | None:
    from movieclaw_api.services.channel_push import tmdb_push_image_url

    return tmdb_push_image_url(item.backdrop_path, item.poster_path)


async def check_once(now: datetime | None = None) -> int:
    """检查一轮，返回发出的批次数。"""
    from movieclaw_api.services.push import downloads as push_downloads

    now = now or utcnow()
    async with get_database().session() as session:
        # 直接下进库目录的手动下载：入账完了推「入库完成」给点下载的人（这一轮先推它，
        # 同一集「媒体库有新片」就不会再推给他）
        push_downloads.announce(await push_downloads.match_scanned(session, now))
        progress = await _progress()
        if progress.started_at is None:
            # 第一次运行：从现在开始算，不回溯已有的库存
            await _save(ArrivalsProgress(started_at=now))
            return 0
        collected = await collect_ready(session, now)
    from movieclaw_api.services.push.hub import LibraryArrivals, emit

    for batch in collected.batches:
        emit(
            LibraryArrivals(
                library_id=batch.library.id or 0,
                items=tuple((a.item.id or 0, tuple(a.units)) for a in batch.items),
            )
        )
    if collected.marks != progress.marks or collected.held != progress.held:
        await _save(
            ArrivalsProgress(
                started_at=progress.started_at, marks=collected.marks, held=collected.held
            )
        )
    if collected.batches:
        logger.info(
            "媒体库新片：%s",
            "、".join(f"{b.library.name} {len(b.items)} 部" for b in collected.batches),
        )
    return len(collected.batches)


_task: asyncio.Task[None] | None = None


async def _loop() -> None:
    while True:
        try:
            await check_once()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 -- 一轮出错下一轮再来，不能拖垮应用
            logger.exception("检查媒体库新片时出错")
        await asyncio.sleep(TICK_S)


def start() -> None:
    global _task
    if _task is None or _task.done():
        _task = asyncio.get_running_loop().create_task(_loop())


async def stop() -> None:
    global _task
    task, _task = _task, None
    if task is not None and not task.done():
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await task
