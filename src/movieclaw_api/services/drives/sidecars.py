"""视频传到网盘后，旁车文件跟着传（docs/design/cloud-storage.md §5.5）。

旁车文件：海报 / fanart / Logo 等图片、NFO、分集剧照、外挂字幕。挑法只看文件，不看是谁写的：

- 视频所在目录，以及往上直到库根（不含）的每一级目录（剧集目录、季目录）里的旁车文件；
- 视频直接放在库根下时，库根里只认带视频文件名主干前缀的（``<主干>.nfo``、``<主干>-poster.jpg``、
  ``<主干>.zh.srt``），不碰库根自己的图；
- 图片、NFO 跟随库的「写入图片 / NFO」开关（``effective_mirror_flags``），关了就不传；
  外挂字幕总是传。

本地文件的（大小, 修改时间）和台账（``library_cloud_sidecar``）对不上就算待传：新写出的、
刮削换了海报、重新生成了字幕，都在下一轮上传巡检里补上。
"""

from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass
from pathlib import Path, PurePath

from movieclaw_api.services.library.artwork import ART_EXTS
from movieclaw_api.services.library.layout import SUBTITLE_EXTS
from movieclaw_db.engine import get_database
from movieclaw_db.models.library import Library
from movieclaw_db.models.library_cloud_folder import LibraryCloudFolder
from movieclaw_db.models.library_cloud_sidecar import LibraryCloudSidecar
from movieclaw_db.repositories.library_cloud_repo import LibraryCloudRepository

#: 旁车文件最大多少（整份读进内存再传）；更大的不是旁车，不传
MAX_SIDECAR_BYTES = 64 * 1024 * 1024


@dataclass(frozen=True, slots=True)
class Pending:
    """一个待传的旁车文件与看到它时的（大小, 修改时间）。"""

    path: Path
    size: int
    mtime_ns: int


def _wanted(name: str, *, images: bool, nfo: bool) -> bool:
    suffix = PurePath(name).suffix.lower()
    if suffix in SUBTITLE_EXTS:
        return True
    if suffix == ".nfo":
        return nfo
    if suffix in ART_EXTS:
        return images
    return False


def sidecar_files(roots: list[str], video: Path, *, images: bool, nfo: bool) -> list[Path]:
    """（阻塞）一个视频的旁车文件。视频不在任何库根下就没有。"""
    root = next(
        (Path(r) for r in roots if Path(r) == video.parent or Path(r) in video.parents), None
    )
    if root is None:
        return []
    found: list[Path] = []
    directory = video.parent
    while True:
        at_root = directory == root
        try:
            entries = list(os.scandir(directory))
        except OSError:
            entries = []
        for entry in entries:
            name = entry.name
            if at_root and not name.startswith((video.stem + ".", video.stem + "-")):
                continue
            if _wanted(name, images=images, nfo=nfo) and entry.is_file():
                found.append(Path(entry.path))
        directory = directory.parent
        if at_root or directory == root:
            return found


def _changed(
    videos: list[str],
    roots: list[str],
    ledger: dict[str, LibraryCloudSidecar],
    *,
    images: bool,
    nfo: bool,
) -> list[Pending]:
    """（阻塞）这些视频的旁车文件里，和台账对不上的。"""
    seen: set[Path] = set()
    pending: list[Pending] = []
    for video in videos:
        for path in sidecar_files(roots, Path(video), images=images, nfo=nfo):
            if path in seen:
                continue
            seen.add(path)
            try:
                st = path.stat()
            except OSError:
                continue
            if st.st_size > MAX_SIDECAR_BYTES:
                continue
            row = ledger.get(str(path))
            if row is not None and (row.size_bytes, row.file_mtime_ns) == (
                st.st_size,
                st.st_mtime_ns,
            ):
                continue
            pending.append(Pending(path, st.st_size, st.st_mtime_ns))
    return pending


async def find_pending(
    library: Library, folder: LibraryCloudFolder
) -> tuple[list[Pending], dict[str, LibraryCloudSidecar]]:
    """传到这个文件夹的视频，有哪些旁车文件还没传或本地变了。连同台账一起返回。"""
    from movieclaw_api.services.scrape_config import effective_mirror_flags

    assert library.id is not None and folder.id is not None
    async with get_database().session() as session:
        repo = LibraryCloudRepository(session)
        videos = await repo.uploaded_paths(library.id, folder.id)
        ledger = await repo.sidecars(folder.id)
    if not videos:
        return [], ledger
    images, nfo, _ = effective_mirror_flags(library)
    pending = await asyncio.to_thread(
        _changed, videos, list(library.root_paths), ledger, images=images, nfo=nfo
    )
    return pending, ledger
