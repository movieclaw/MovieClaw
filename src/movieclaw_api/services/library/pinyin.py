"""拼音结果的三级记忆：进程内字典 → 持久缓存表 → 短命子进程现算。

pypinyin 的词组词库导入即常驻约 50MB，是后端导入期最大的单项。而拼音只对**库里
存着的名字**算（海报墙的标题排序键、搜索匹配的逐字读音），从不对用户输入的查询词
算——结果可以按「输入 → 输出」记下来，主进程永远不必导入 pypinyin：

- 进程内：排序键无界（定义域是片名集合，与 sort_key 原来的无界缓存同量级）；
  逐字读音有界，与 search_matching 的 lru_cache 同容量。
- 持久：``cache_entry`` 表（namespace ``pinyin.sort`` / ``pinyin.syllables``）。拼音是
  可随时删、可重建的派生数据，正合那张表的准入边界；被每日清理删掉也只是下次重算。
  只在启动补算（:func:`backfill`，独立后台任务）里写表，请求路径只读。
- 没见过的名字：攒成一批交给 ``pinyin_worker.py`` 子进程算完即退（冷启动约 0.1 秒）。

用法：排序、匹配之前 ``await prepare(...)``，之后的同步读 :func:`sort_pinyin` /
:func:`syllables` 只查字典。漏了 prepare 的同步调用退回进程内现算——结果一致，只是把
词库拉进了内存——并告警一次，方便发现漏掉的调用点。
"""

from __future__ import annotations

import asyncio
import json
import logging
import sys
import time
import weakref
from collections import OrderedDict
from collections.abc import Iterable
from pathlib import Path

from sqlalchemy import text

from movieclaw_api.services.library import pinyin_worker
from movieclaw_db.engine import get_database
from movieclaw_db.repositories.cache_repo import CacheRepository

logger = logging.getLogger(__name__)

SORT_NAMESPACE = "pinyin.sort"
SYLLABLES_NAMESPACE = "pinyin.syllables"
_SYLLABLES_CAPACITY = 65536
_WORKER = Path(pinyin_worker.__file__)
_WORKER_TIMEOUT_S = 300.0

_sort: dict[str, str] = {}
_syllables: OrderedDict[str, tuple[str, ...]] = OrderedDict()
_warned = False
# 同一批名字并发 prepare 时只算一遍（首页一屏会同时排好几面墙）；锁按事件循环各建一把
_locks: weakref.WeakKeyDictionary[asyncio.AbstractEventLoop, asyncio.Lock] = (
    weakref.WeakKeyDictionary()
)


def _fallback(kind: str, text: str):  # type: ignore[no-untyped-def]
    global _warned
    if not _warned:
        _warned = True
        logger.warning(
            "拼音记忆未预热（%s：%r），退回进程内计算，pypinyin 词库会常驻内存", kind, text
        )
    return pinyin_worker.sort_pinyin(text) if kind == "sort" else pinyin_worker.syllables(text)


def sort_pinyin(text: str) -> str:
    """标题排序用的整串拼音（见 pinyin_worker.sort_pinyin）。"""
    value = _sort.get(text)
    if value is None:
        value = _sort[text] = _fallback("sort", text)
    return value


def syllables(text: str) -> tuple[str, ...]:
    """逐字读音（见 pinyin_worker.syllables）。"""
    value = _syllables.get(text)
    if value is None:
        value = tuple(_fallback("syllables", text))
        _remember_syllables({text: value})
    return value


def _remember_syllables(values: dict[str, tuple[str, ...]]) -> None:
    _syllables.update(values)
    while len(_syllables) > _SYLLABLES_CAPACITY:
        _syllables.popitem(last=False)


async def _compute(sort: list[str], syllables_: list[str], *, background: bool = False) -> dict:
    request = json.dumps({"sort": sort, "syllables": syllables_}, ensure_ascii=False).encode()
    try:
        proc = await asyncio.create_subprocess_exec(
            sys.executable,
            # 隔离模式：按文件路径运行时脚本目录会排到 sys.path 最前，同目录的
            # collections.py（合集模块）会盖住标准库的 collections
            "-I",
            str(_WORKER),
            *(["--background"] if background else []),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, err = await asyncio.wait_for(proc.communicate(request), _WORKER_TIMEOUT_S)
        if proc.returncode == 0:
            return json.loads(out)
        logger.warning("拼音子进程失败（exit=%s）：%s", proc.returncode, err.decode()[-500:])
    except (OSError, TimeoutError, ValueError) as exc:
        logger.warning("拼音子进程不可用：%s", exc)
    # 子进程起不来（资源耗尽等）：正确性优先，进程内算
    return await asyncio.to_thread(pinyin_worker.compute, {"sort": sort, "syllables": syllables_})


async def prepare(*, sort: Iterable[str] = (), syllables: Iterable[str] = ()) -> None:
    """确保这些输入的结果已在进程内字典里：先查持久表，剩下的交子进程算。

    这里只读表、不写表：调用方常在自己的写事务里排序（SQLite 同一时刻只有一个写者），
    另开会话写表会被挡到超时。新算出的结果留在进程内，由下次启动的 backfill 落表。
    """
    want_sort = {t for t in sort if t not in _sort}
    want_syllables = {t for t in syllables if t not in _syllables}
    if not want_sort and not want_syllables:
        return
    lock = _locks.setdefault(asyncio.get_running_loop(), asyncio.Lock())
    async with lock:
        want_sort = [t for t in want_sort if t not in _sort]
        want_syllables = [t for t in want_syllables if t not in _syllables]
        async with get_database().session() as session:
            repo = CacheRepository(session)
            stored_sort = await repo.get_many(SORT_NAMESPACE, want_sort)
            stored_syllables = await repo.get_many(SYLLABLES_NAMESPACE, want_syllables)
        _sort.update(stored_sort)
        _remember_syllables({k: tuple(json.loads(v)) for k, v in stored_syllables.items()})
        missing_sort = [t for t in want_sort if t not in stored_sort]
        missing_syllables = [t for t in want_syllables if t not in stored_syllables]
        if not missing_sort and not missing_syllables:
            return
        result = await _compute(missing_sort, missing_syllables)
        new_sort = dict(zip(missing_sort, result["sort"], strict=True))
        new_syllables = {
            k: tuple(v) for k, v in zip(missing_syllables, result["syllables"], strict=True)
        }
        _sort.update(new_sort)
        _remember_syllables(new_syllables)


_BACKFILL_CHUNK = 5000


async def backfill() -> None:
    """启动后台：为库里已有的片名与已建索引的名称补齐持久记忆。

    升级后第一次要算全库（几万个名字，子进程里几秒），之后每次启动只查出零星缺口
    （被每日清理删掉的、或建索引时子进程失败的）。名称读音只写表、不进进程内字典——
    几万条没必要常驻，搜索时按候选从表里取；片名排序键本来就要常驻，顺手放进字典。
    """
    async with get_database().session() as session:
        titles = {
            title.strip()
            for title in (await session.execute(text("SELECT title FROM media_item"))).scalars()
            if title and title.strip()
        }
        have = set(
            (
                await session.execute(
                    text("SELECT cache_key FROM cache_entry WHERE namespace = :ns"),
                    {"ns": SORT_NAMESPACE},
                )
            ).scalars()
        )
        names = list(
            (
                await session.execute(
                    text("""SELECT DISTINCT n.normalized FROM library_search_name n
                    LEFT JOIN cache_entry c ON c.namespace = :ns AND c.cache_key = n.normalized
                    WHERE c.cache_key IS NULL AND n.normalized != ''"""),
                    {"ns": SYLLABLES_NAMESPACE},
                )
            ).scalars()
        )
    missing_titles = sorted(titles - have)
    del have
    if not missing_titles and not names:
        return
    started = time.perf_counter()
    for start in range(0, max(len(missing_titles), len(names)), _BACKFILL_CHUNK):
        sort = missing_titles[start : start + _BACKFILL_CHUNK]
        syllables_ = names[start : start + _BACKFILL_CHUNK]
        result = await _compute(sort, syllables_, background=True)
        new_sort = dict(zip(sort, result["sort"], strict=True))
        _sort.update(new_sort)
        async with get_database().session() as session:
            repo = CacheRepository(session)
            await repo.put_many(SORT_NAMESPACE, new_sort)
            await repo.put_many(
                SYLLABLES_NAMESPACE,
                {
                    k: json.dumps(v, ensure_ascii=False)
                    for k, v in zip(syllables_, result["syllables"], strict=True)
                },
            )
    logger.info(
        "补算拼音记忆：片名 %d 个，名称 %d 个，用时 %.1f 秒",
        len(missing_titles),
        len(names),
        time.perf_counter() - started,
    )
