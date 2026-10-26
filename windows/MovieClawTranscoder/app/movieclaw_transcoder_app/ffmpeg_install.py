"""从 Jellyfin 官方下载 jellyfin-ffmpeg（Windows x64），下载完校验 SHA256 再解压。

上游 ffmpeg 缺 ``scale_cuda(format)`` 与 ``tonemapx``，所以只认 jellyfin 构建；与 macOS
转码器同一套做法：运行时查 jellyfin-ffmpeg 的最新 GitHub Release，取 ``portable_win64``
资产（GitHub API 的 ``digest`` 字段校验完整性），装到 ``<数据目录>/ffmpeg/versions/<版本>/``，
装新清旧。访问 GitHub 走系统代理设置（urllib 默认行为）；连不上不是致命的——用户也可以
自己装 jellyfin-ffmpeg 后手动指路。

测试可注入 ``fetch_json`` / ``open_stream``，不触网。
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import urllib.request
import zipfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

RELEASE_API_URL = "https://api.github.com/repos/jellyfin/jellyfin-ffmpeg/releases/latest"

#: 只认 Windows x64 的官方便携包（winarm64 与各 Linux 发行版都不匹配）
_ASSET_RE = re.compile(r"^jellyfin-ffmpeg_(.+)_portable_win64-clang-gpl\.zip$")

#: 解压完成后在版本目录里写的标记，与 macOS 转码器同名同结构
MARKER_NAME = ".movieclaw-install.json"

#: 下载分块 1 MiB：进度条粒度够细，也不至于频繁回调
_CHUNK = 1024 * 1024


class FfmpegInstallError(Exception):
    """下载或校验没成；文案给人看。"""


@dataclass(frozen=True)
class FFmpegRelease:
    version: str
    url: str
    digest: str
    size: int


def latest_release(
    *, fetch_json: Callable[[str], object] | None = None
) -> FFmpegRelease:
    """查最新 Release 里 ``portable_win64`` 资产的下载地址与 SHA256。"""
    fetch = fetch_json or _fetch_json_default
    view = fetch(RELEASE_API_URL)
    if not isinstance(view, dict) or not isinstance(view.get("assets"), list):
        raise FfmpegInstallError("Jellyfin 官方发布的格式不对，稍后再试")
    for asset in view["assets"]:
        if not isinstance(asset, dict):
            continue
        name = asset.get("name")
        match = _ASSET_RE.match(name) if isinstance(name, str) else None
        if match is None:
            continue
        digest = str(asset.get("digest") or "")
        if not digest.startswith("sha256:"):
            raise FfmpegInstallError("发布页没有提供校验值，无法安全下载，稍后再试")
        return FFmpegRelease(
            version=match.group(1),
            url=str(asset.get("browser_download_url") or ""),
            digest=digest.removeprefix("sha256:"),
            size=int(asset.get("size") or 0),
        )
    raise FfmpegInstallError("最新发布里没有 Windows 版的 jellyfin-ffmpeg")


def _fetch_json_default(url: str) -> object:
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def install(
    release: FFmpegRelease,
    versions_root: Path,
    *,
    progress: Callable[[int, int], None] = lambda _done, _total: None,
    open_stream: Callable[[str], object] | None = None,
) -> Path:
    """下载、校验、解压到 ``versions_root/<版本>/``，返回 ffmpeg.exe 的路径。

    同版本已装好（标记里的 SHA256 一致）就直接返回，不重复下载。
    """
    target = versions_root / release.version
    existing = _validated_ffmpeg(target, release.digest)
    if existing is not None:
        return existing

    versions_root.mkdir(parents=True, exist_ok=True)
    archive = versions_root / f".{release.version}.zip"
    opener = open_stream or (lambda url: urllib.request.urlopen(url, timeout=60))
    try:
        with opener(release.url) as source, archive.open("wb") as sink:
            total = release.size or 0
            digest = hashlib.sha256()
            done = 0
            while True:
                chunk = source.read(_CHUNK)
                if not chunk:
                    break
                digest.update(chunk)
                sink.write(chunk)
                done += len(chunk)
                progress(done, total)
        if digest.hexdigest() != release.digest:
            raise FfmpegInstallError(
                "下载的 ffmpeg 校验不上（SHA256 与发布页不符），已丢弃；稍后再试"
            )
        target.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(target)  # zipfile 会滤掉路径里的 .. 与盘符
    finally:
        archive.unlink(missing_ok=True)

    ffmpeg = _ffmpeg_exe(target)
    if ffmpeg is None:
        shutil.rmtree(target, ignore_errors=True)
        raise FfmpegInstallError("下载的压缩包里没有 ffmpeg.exe，稍后再试")
    (target / MARKER_NAME).write_text(
        json.dumps({"version": release.version, "digest": release.digest}), encoding="utf-8"
    )
    _cleanup_old(versions_root, keep=release.version)
    return ffmpeg


def _validated_ffmpeg(target: Path, digest: str) -> Path | None:
    """已装且标记里的 SHA256 一致时返回 ffmpeg.exe 路径，否则 None。"""
    try:
        marker = json.loads((target / MARKER_NAME).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if marker.get("digest") != digest:
        return None
    return _ffmpeg_exe(target)


def _ffmpeg_exe(target: Path) -> Path | None:
    for candidate in (target / "ffmpeg.exe", *target.glob("*/ffmpeg.exe")):
        if candidate.is_file():
            return candidate
    return None


def installed(versions_root: Path) -> Path | None:
    """之前装过的 ffmpeg（按修改时间取最新的一份）；没有返回 None。"""
    candidates = [
        path
        for version_dir in _version_dirs(versions_root)
        if (path := _ffmpeg_exe(version_dir)) is not None and (version_dir / MARKER_NAME).is_file()
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def _version_dirs(versions_root: Path) -> list[Path]:
    try:
        return [child for child in versions_root.iterdir() if child.is_dir()]
    except OSError:
        return []


def _cleanup_old(versions_root: Path, *, keep: str) -> None:
    for version_dir in _version_dirs(versions_root):
        if version_dir.name != keep and (version_dir / MARKER_NAME).is_file():
            shutil.rmtree(version_dir, ignore_errors=True)
