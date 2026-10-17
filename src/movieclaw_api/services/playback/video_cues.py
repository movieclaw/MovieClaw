"""MKV 精简索引的服务端（docs/design/playback-qoe.md §9.12，App 引擎补丁 P58）。

App 的播放引擎打开 MKV 时要先读完整个 Cues（索引）才能规划分片、定位续播点。
mkvmerge 给每条字幕轨的每个事件都写索引点，字幕轨多的片子 Cues 很大（片库抽样
中位 68 KB、九成在 560 KB 以内、最大 4.2 MB），外网慢时单独下它就要好几秒。引擎
只用得到视频轨的索引点，所以服务端把它们挑出来（数值原样）存成几 KB～几十 KB 的
精简版（``build_matroska_video_cues``），开播放会话时随响应下发，引擎在解复用器
读 Cues 时直接给这份，不再下载原索引。

开销控制（NAS 性能弱，这块不能拖慢服务）：

- **每个文件只算一次**：结果连同片源的大小与修改时间存成缓存文件，片子没变就一直
  用；精简后省不了多少的（字幕轨少，原索引本来就小）记一笔「不值得」，以后也不再算。
- **不在起播路径上算**：开会话只查缓存（读一个小文件 + stat 片源一次）；没有就在
  后台排队、等起播的关键窗口过去再生成，给续播、下一次播放用。顺带把下一集也排上，
  追剧时点开下一集就用得上；查下一集的那条 SQL 也在后台跑，不占开会话的请求。
- **单独进程、低优先级、一次一个**：解析大索引要零点几秒 CPU（62 条字幕轨的 4K 片
  约 0.8 秒），放在服务进程里会抢 GIL、拖慢同时在跑的取流与接口，所以起一个调低
  优先级的子进程去算，排队依次做。
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from sqlmodel import col, select

from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile
from movieclaw_playback.streaming import file_stamp

logger = logging.getLogger("movieclaw_api.playback.video_cues")

#: 缓存格式版本：改了生成规则就加一，旧记录自动作废、下次播放时重算
_VERSION = 1
#: 精简后至少省这么多字节才下发（6 Mbit/s 下约 0.13 秒）；省不了这么多的记为「不值得」
MIN_SAVING_BYTES = 96 * 1024
#: 精简结果超过这么大不下发：会话响应本身就在起播的关键路径上
MAX_DATA_BYTES = 128 * 1024
#: 开会话后等这么久再生成：让开起播的关键窗口（慢线路上从点开到开始播放要十来秒），
#: 结果本来就是给续播、下一次播放和下一集用的
SCHEDULE_DELAY_S = 15.0
#: 后台排队上限：超过就不再接新的（只是优化，丢掉无妨）
_MAX_PENDING = 16
_MATROSKA_SUFFIXES = (".mkv", ".mk3d", ".webm")

# 子进程里跑的代码：只导入解析模块，调低优先级，结果以一行 JSON 写回标准输出
_WORKER_CODE = """
import base64, json, os, sys
try:
    os.nice(10)
except OSError:
    pass
from movieclaw_playback.container_index import build_matroska_video_cues
r = build_matroska_video_cues(sys.argv[1])
print(json.dumps(None if r is None else {
    "offset": r.cues_offset, "original": r.original_bytes, "points": r.points,
    "data": base64.b64encode(r.data).decode("ascii")}))
"""


@dataclass(frozen=True)
class VideoCues:
    """可下发的精简索引。"""

    #: Cues 元素在文件里的绝对位置（SeekHead 登记的）；引擎核对一致才用
    cues_offset: int
    #: 精简后的整个 Cues 元素（含元素头）
    data: bytes
    #: 原 Cues 元素多少字节（诊断用）
    original_bytes: int


def is_matroska(file_path: str) -> bool:
    return file_path.lower().endswith(_MATROSKA_SUFFIXES)


def _cache_path(file_id: int) -> Path:
    return Path(get_settings().playback_cues_cache_dir) / f"{file_id}.bin"


def _stamp(file_path: str) -> tuple[int, int] | None:
    """片源的 (大小, 修改时间)：缓存按它判断片子有没有变。"""
    return file_stamp(file_path)


def _read_record(file_id: int, file_path: str) -> tuple[dict, bytes] | None:
    """读缓存记录；片源已变（大小或修改时间不同）、版本不对、格式坏了都当没有。"""
    try:
        raw = _cache_path(file_id).read_bytes()
    except OSError:
        return None
    head, sep, data = raw.partition(b"\n")
    if not sep:
        return None
    try:
        meta = json.loads(head)
    except ValueError:
        return None
    stamp = _stamp(file_path)
    if (
        not isinstance(meta, dict)
        or meta.get("v") != _VERSION
        or stamp is None
        or (meta.get("size"), meta.get("mtime_ns")) != stamp
    ):
        return None
    return meta, data


def cached(file_id: int, file_path: str) -> VideoCues | None:
    """开会话时查：有、片子没变、值得下发才返回。

    同步 IO（读一个小文件 + stat 片源），调用方放线程里。"""
    record = _read_record(file_id, file_path)
    if record is None:
        return None
    meta, data = record
    if meta.get("skip") or not data:
        return None
    try:
        return VideoCues(
            cues_offset=int(meta["offset"]), data=data, original_bytes=int(meta["original"])
        )
    except (KeyError, TypeError, ValueError):
        return None


def _write_record(file_id: int, meta: dict, data: bytes) -> None:
    path = _cache_path(file_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    staging = path.with_name(f".{path.name}.part")
    staging.write_bytes(json.dumps(meta, ensure_ascii=False).encode() + b"\n" + data)
    os.replace(staging, path)


_pending: set[int] = set()
_running: set[asyncio.Task] = set()
_slot: tuple[asyncio.AbstractEventLoop, asyncio.Semaphore] | None = None


def _get_slot() -> asyncio.Semaphore:
    """一次只跑一个生成子进程。信号量绑定事件循环，按循环惰性创建（测试里每个用例一个新循环）。"""
    global _slot
    loop = asyncio.get_running_loop()
    if _slot is None or _slot[0] is not loop:
        _slot = (loop, asyncio.Semaphore(1))
    return _slot[1]


def schedule(file: LibraryFile, *, delay_s: float = SCHEDULE_DELAY_S) -> None:
    """开会话后在后台排队：这个文件（还没有有效记录时）和同一部剧的下一集。

    不是 MKV、已在排队、队列满都直接返回；没有事件循环时（同步上下文）跳过。
    """
    file_id = file.id
    if file_id is None or not is_matroska(file.file_path):
        return
    if file_id in _pending or len(_pending) >= _MAX_PENDING:
        return
    unit = (file.media_item_id, file.season_number, file.episode_number)
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    _pending.add(file_id)
    task = loop.create_task(_run(file_id, file.file_path, unit, delay_s))
    _running.add(task)
    task.add_done_callback(_running.discard)


async def _run(
    file_id: int, file_path: str, unit: tuple[int | None, int, int], delay_s: float
) -> None:
    try:
        if delay_s > 0:
            await asyncio.sleep(delay_s)
        await _generate(file_id, file_path)
        for next_id, next_path in await _next_episode_files(*unit):
            await _generate(next_id, next_path)
    except Exception:  # noqa: BLE001 — 只是优化，出错只记日志，播放照常走原索引
        logger.warning("MKV 精简索引的后台任务出错（file_id=%s）", file_id, exc_info=True)
    finally:
        _pending.discard(file_id)


async def _generate(file_id: int, file_path: str) -> None:
    """生成一个文件的记录（已有有效记录就跳过）。一次只跑一个子进程。"""
    try:
        async with _get_slot():
            if await asyncio.to_thread(_read_record, file_id, file_path) is not None:
                return  # 已经生成过（或已记为不值得）
            stamp = await asyncio.to_thread(_stamp, file_path)
            if stamp is None:
                return
            result = await _run_worker(file_path)
            meta: dict = {"v": _VERSION, "size": stamp[0], "mtime_ns": stamp[1]}
            data = b""
            if result is None:
                meta["skip"] = True
                note = "不是可用的 MKV 索引，记为不适用"
            else:
                data = base64.b64decode(result["data"])
                original = int(result["original"])
                if original - len(data) < MIN_SAVING_BYTES or len(data) > MAX_DATA_BYTES:
                    meta.update(skip=True, original=original)
                    note = (
                        f"原索引 {original // 1024} KB、精简后 {len(data) // 1024} KB，"
                        "省得不多，不下发"
                    )
                    data = b""
                else:
                    meta.update(
                        offset=int(result["offset"]),
                        original=original,
                        points=int(result["points"]),
                    )
                    note = (
                        f"原索引 {original // 1024} KB → 精简 {len(data) // 1024} KB"
                        f"（{result['points']} 个视频索引点）"
                    )
            await asyncio.to_thread(_write_record, file_id, meta, data)
            logger.info("MKV 精简索引：file_id=%s %s", file_id, note)
    except Exception:  # noqa: BLE001 — 只是优化，出错只记日志，播放照常走原索引
        logger.warning(
            "生成 MKV 精简索引失败（file_id=%s），播放照常下载原索引", file_id, exc_info=True
        )


async def _run_worker(file_path: str) -> dict | None:
    """起一个低优先级子进程解析索引，返回它写出的 JSON（None = 不适用）。

    子进程继承当前的模块搜索路径。"""
    env = dict(os.environ, PYTHONPATH=os.pathsep.join(p for p in sys.path if p))
    proc = await asyncio.create_subprocess_exec(
        sys.executable,
        "-c",
        _WORKER_CODE,
        file_path,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=60)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        raise RuntimeError("解析索引超过 60 秒") from None
    if proc.returncode != 0:
        raise RuntimeError(
            f"解析子进程退出码 {proc.returncode}：{err.decode(errors='replace')[-300:]}"
        )
    return json.loads(out.decode().strip().splitlines()[-1])


async def _next_episode_files(
    media_item_id: int | None, season: int, episode: int
) -> list[tuple[int, str]]:
    """同一部剧紧接着的那一集（同季下一集，没有就下一季第一集）的全部在位版本。

    电影的季号、集号都存 0，直接返回空。"""
    if media_item_id is None or episode <= 0:
        return []
    async with get_database().session() as session:
        rows = await session.execute(
            select(
                LibraryFile.id,
                LibraryFile.file_path,
                LibraryFile.season_number,
                LibraryFile.episode_number,
            )
            .where(LibraryFile.media_item_id == media_item_id)
            .where(LibraryFile.in_place())
            .where(
                (
                    (col(LibraryFile.season_number) == season)
                    & (col(LibraryFile.episode_number) > episode)
                )
                | (col(LibraryFile.season_number) > season)
            )
            .order_by(col(LibraryFile.season_number), col(LibraryFile.episode_number))
            .limit(8)
        )
        candidates = rows.all()
    if not candidates:
        return []
    first = (candidates[0][2], candidates[0][3])
    return [
        (int(file_id), file_path)
        for file_id, file_path, s_no, e_no in candidates
        if (s_no, e_no) == first and file_id is not None and is_matroska(file_path)
    ]
