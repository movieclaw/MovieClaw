"""演示下载器：公开演示站专用的离线下载器（docs/design/demo-site.md §10）。

不连接任何下载软件、不产生任何 BT 流量，只按时间推进进度：

- 提交时解析 .torrent，记下任务（状态存成 JSON，进程重启与每日还原都靠它）；
- 下载按固定速度推进，完成的那一刻把种子目录（``MOVIECLAW_DEMO_SEED_DIR``）里同名的
  文件夹复制到任务的保存目录——之后的自动入库、落盘核对都是真实流程；
- 种子目录里没有实体数据的任务（刷流免费种）只模拟做种：上传量按时间增长，从不落盘。

所以它只能「下载」演示资源站收录的开放授权影片。
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import threading
import time
from pathlib import Path

from movieclaw_downloader.base import BaseDownloader
from movieclaw_downloader.exceptions import DownloaderSubmitError
from movieclaw_downloader.models import (
    DownloaderInfo,
    DownloaderLimits,
    DownloaderType,
    DownloadRequest,
    SubmitResult,
    TorrentBrief,
    TorrentFile,
    TorrentStatus,
)

#: 模拟下载速度与时长区间：几百 MB 的演示片约一分钟下完，审核员能看到进度在走
DOWNLOAD_SPEED = 8 * 1024 * 1024
MIN_SECONDS = 20.0
MAX_SECONDS = 120.0
#: 做种上传速度（刷流在池与已完成的任务）
UPLOAD_SPEED = 2 * 1024 * 1024

_lock = threading.Lock()


def _state_path() -> Path:
    return Path(
        os.environ.get("MOVIECLAW_DEMO_DOWNLOADER_STATE")
        or Path(os.environ.get("MOVIECLAW_DATA_DIR", "./data")) / "demo-downloader.json"
    )


def _seed_dir() -> Path:
    return Path(os.environ.get("MOVIECLAW_DEMO_SEED_DIR", "/media/_资源站"))


def _default_save_path() -> str:
    return os.environ.get("MOVIECLAW_DEMO_DOWNLOAD_DIR", "/workspace/downloads")


def _load() -> dict:
    try:
        return json.loads(_state_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"torrents": {}, "limits": {}}


def _save(state: dict) -> None:
    path = _state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# 最小 bencode 解码（只为读出 info 里的名字与文件清单）
# ---------------------------------------------------------------------------


def _decode(data: bytes, pos: int = 0) -> tuple[object, int]:
    token = data[pos : pos + 1]
    if token == b"i":
        end = data.index(b"e", pos)
        return int(data[pos + 1 : end]), end + 1
    if token == b"l":
        pos += 1
        items = []
        while data[pos : pos + 1] != b"e":
            item, pos = _decode(data, pos)
            items.append(item)
        return items, pos + 1
    if token == b"d":
        pos += 1
        result: dict[bytes, object] = {}
        while data[pos : pos + 1] != b"e":
            key, pos = _decode(data, pos)
            value, pos = _decode(data, pos)
            result[key] = value  # type: ignore[index]
        return result, pos + 1
    colon = data.index(b":", pos)
    length = int(data[pos:colon])
    start = colon + 1
    return data[start : start + length], start + length


def _layout(torrent: bytes) -> tuple[str, list[dict]]:
    """种子名与文件清单（路径带种子名作根目录，与 qBittorrent 的口径一致）。"""
    meta, _ = _decode(torrent)
    info = meta[b"info"]  # type: ignore[index]
    name = info[b"name"].decode()
    if b"files" in info:
        files = [
            {
                "path": "/".join([name, *(part.decode() for part in item[b"path"])]),
                "size": item[b"length"],
            }
            for item in info[b"files"]
        ]
    else:
        files = [{"path": name, "size": info[b"length"]}]
    return name, files


# ---------------------------------------------------------------------------
# 进度推进
# ---------------------------------------------------------------------------


def _duration(size: int) -> float:
    return min(MAX_SECONDS, max(MIN_SECONDS, size / DOWNLOAD_SPEED))


def _progress(record: dict, now: float) -> float:
    """暂停中的任务停在暂停那一刻；从未开始（以暂停态添加）的是 0。"""
    if record.get("seed_only"):
        return 1.0
    started = record.get("started_at")
    if started is None:
        return 0.0
    elapsed = record.get("elapsed", 0.0)
    if not record.get("paused"):
        elapsed += now - started
    return min(1.0, elapsed / _duration(record["size"]))


def _uploaded(record: dict, now: float) -> int:
    since = record.get("completed_at") or (record["added_at"] if record.get("seed_only") else None)
    if since is None:
        return 0
    return int(max(0.0, now - since) * UPLOAD_SPEED * record.get("upload_factor", 1.0))


def _materialize(record: dict) -> None:
    """下载完成：把种子目录里的同名数据复制到保存目录（先写临时名，再原子改名）。"""
    source = _seed_dir() / record["name"]
    if not source.exists():
        return
    target = Path(record["save_path"]) / record["name"]
    if target.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.parent / f".{record['name']}.part"
    if staging.exists():
        shutil.rmtree(staging) if staging.is_dir() else staging.unlink()
    if source.is_dir():
        shutil.copytree(source, staging, ignore=shutil.ignore_patterns("release.json"))
    else:
        shutil.copy2(source, staging)
    os.replace(staging, target)


class DemoDownloader(BaseDownloader):
    """演示下载器：状态在本地 JSON 里，按时间推进，完成时从种子目录取数据。"""

    def _advance(self) -> tuple[dict, list[dict]]:
        """读状态、推进完成标记；返回 (状态, 本次刚完成需要落盘的任务)。"""
        now = time.time()
        with _lock:
            state = _load()
            finished = []
            for record in state["torrents"].values():
                if record.get("completed_at") is None and _progress(record, now) >= 1.0:
                    record["completed_at"] = now
                    finished.append(dict(record))
            if finished:
                _save(state)
        return state, finished

    async def _snapshot(self) -> dict:
        state, finished = self._advance()
        for record in finished:
            await asyncio.to_thread(_materialize, record)
        return state

    def _status(self, record: dict, *, include_files: bool, now: float) -> TorrentStatus:
        progress = _progress(record, now)
        done = progress >= 1.0
        size = record["size"]
        completed = int(size * progress)
        downloading = not done and not record.get("paused") and record.get("started_at")
        files = []
        if include_files:
            for index, item in enumerate(record["files"]):
                files.append(
                    TorrentFile(
                        index=index,
                        path=item["path"],
                        size_bytes=item["size"],
                        completed_bytes=item["size"] if done else int(item["size"] * progress),
                        selected=index in record.get("selected", range(len(record["files"]))),
                    )
                )
        return TorrentStatus(
            info_hash=record["info_hash"],
            name=record["name"],
            progress=progress,
            completed_bytes=completed,
            downloaded_bytes=completed,
            completed=done,
            save_path=record["save_path"],
            files=files,
            tags=record.get("tags", []),
            size_bytes=size,
            dlspeed_bytes=DOWNLOAD_SPEED if downloading else 0,
            eta_seconds=int((size - completed) / DOWNLOAD_SPEED) if downloading else None,
            state=self._state_word(record, done),
        )

    @staticmethod
    def _state_word(record: dict, done: bool) -> str:
        if done:
            return "completed"
        if record.get("paused") or record.get("started_at") is None:
            return "paused"
        return "downloading"

    # -- BaseDownloader ----------------------------------------------------

    async def submit(self, request: DownloadRequest) -> SubmitResult:
        if request.torrent_bytes is None:
            raise DownloaderSubmitError("演示下载器只接受演示资源站的种子文件")
        info_hash = self._resolve_info_hash(request)
        assert info_hash is not None
        try:
            name, files = _layout(request.torrent_bytes)
        except (KeyError, ValueError, IndexError) as exc:
            raise DownloaderSubmitError(f"种子文件无法解析：{exc}") from exc
        now = time.time()
        with _lock:
            state = _load()
            if info_hash in state["torrents"]:
                return SubmitResult(info_hash=info_hash, name=name, already_exists=True)
            has_data = (_seed_dir() / name).exists()
            state["torrents"][info_hash] = {
                "info_hash": info_hash,
                "name": name,
                "files": files,
                "size": sum(item["size"] for item in files),
                "save_path": request.save_path or _default_save_path(),
                "category": request.category,
                "tags": list(request.tags),
                "paused": request.paused,
                "added_at": now,
                "started_at": None if request.paused else now,
                "elapsed": 0.0,
                # 没有实体数据的种子（刷流免费种）：直接进入做种，不落盘
                "seed_only": not has_data,
                "completed_at": None if has_data else now,
                "upload_factor": 0.6 + (int(info_hash[:2], 16) % 8) / 10,
            }
            _save(state)
        return SubmitResult(info_hash=info_hash, name=name)

    async def get_torrent(
        self, info_hash: str, *, include_files: bool = True
    ) -> TorrentStatus | None:
        state = await self._snapshot()
        record = state["torrents"].get(info_hash.lower())
        if record is None:
            return None
        return self._status(record, include_files=include_files, now=time.time())

    async def list_torrents(self) -> list[TorrentBrief]:
        state = await self._snapshot()
        now = time.time()
        briefs = []
        for record in state["torrents"].values():
            status = self._status(record, include_files=False, now=now)
            uploaded = _uploaded(record, now)
            seeding = status.completed
            briefs.append(
                TorrentBrief(
                    name=record["name"],
                    content_name=record["name"],
                    completed=status.completed,
                    info_hash=record["info_hash"],
                    progress=status.progress,
                    completed_bytes=status.completed_bytes,
                    size_bytes=record["size"],
                    dlspeed_bytes=status.dlspeed_bytes,
                    upspeed_bytes=int(UPLOAD_SPEED * record.get("upload_factor", 1.0))
                    if seeding
                    else 0,
                    uploaded_bytes=uploaded,
                    downloaded_bytes=status.downloaded_bytes,
                    ratio=round(uploaded / record["size"], 3) if record["size"] else None,
                    swarm_seeders=4,
                    swarm_leechers=6 if seeding else 2,
                    eta_seconds=status.eta_seconds,
                    state=status.state,
                )
            )
        return briefs

    async def delete_torrent(self, info_hash: str, *, delete_files: bool = False) -> None:
        with _lock:
            state = _load()
            record = state["torrents"].pop(info_hash.lower(), None)
            _save(state)
        if record is not None and delete_files:
            target = Path(record["save_path"]) / record["name"]
            if target.is_dir():
                await asyncio.to_thread(shutil.rmtree, target, True)
            elif target.exists():
                target.unlink()

    async def set_location(self, info_hash: str, save_path: str) -> None:
        with _lock:
            state = _load()
            record = state["torrents"].get(info_hash.lower())
            if record is None:
                return
            old = Path(record["save_path"]) / record["name"]
            record["save_path"] = save_path
            _save(state)
        if old.exists():
            Path(save_path).mkdir(parents=True, exist_ok=True)
            await asyncio.to_thread(shutil.move, str(old), str(Path(save_path) / record["name"]))

    async def set_file_selection(self, info_hash: str, selected_indices: list[int]) -> None:
        with _lock:
            state = _load()
            record = state["torrents"].get(info_hash.lower())
            if record is not None:
                record["selected"] = list(selected_indices)
                _save(state)

    async def resume(self, info_hash: str) -> None:
        with _lock:
            state = _load()
            record = state["torrents"].get(info_hash.lower())
            if record is None or not record.get("paused"):
                return
            record["paused"] = False
            record["started_at"] = time.time()
            _save(state)

    async def get_limits(self) -> DownloaderLimits:
        return DownloaderLimits(**_load().get("limits", {}))

    async def set_limits(self, limits: DownloaderLimits) -> None:
        with _lock:
            state = _load()
            state["limits"] = limits.model_dump()
            _save(state)

    async def transfer_speeds(self) -> tuple[int, int]:
        briefs = await self.list_torrents()
        return (
            sum(brief.upspeed_bytes or 0 for brief in briefs),
            sum(brief.dlspeed_bytes or 0 for brief in briefs),
        )

    async def set_download_limits(self, info_hashes: list[str], limit_bytes: int | None) -> None:
        return None

    async def set_upload_limits(self, info_hashes: list[str], limit_bytes: int | None) -> None:
        return None

    async def test_connection(self) -> DownloaderInfo:
        return DownloaderInfo(type=DownloaderType.DEMO, version="演示下载器 1.0")

    async def close(self) -> None:
        return None
