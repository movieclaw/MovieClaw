"""插件第三方依赖：批准、安装与加载（docs/design/plugin-dependencies.md §2～§4）。

批准页在权限之后列出要装的包：包名、版本、这台服务器上要下载的大小、是否含本机代码、从哪个索引下载。
同意的是「这一份锁文件」（按内容哈希记在安装记录里）：升级时锁文件没变就不再问，变了列出增删改再问。

安装（批准后、挂载前）::

    data/plugins/deps/<锁文件哈希前 16 位>-<平台标签>/   装好的依赖（同一份锁文件的插件版本共用）
    data/plugins/deps/.cache/<sha256>/<轮子文件名>        下载过的轮子（重装、换平台标签时复用）

1. 每个包先挑出这台机器能用的轮子（锁文件 ``#>`` 行）；挑不出直接失败，不联网；
2. 轮子优先取插件包里的 ``wheels/``（离线），其次缓存，最后经统一网络出口（服务 ``pypi``，跟随
   「设置 → 网络」的代理）从包索引下载，逐个核对 sha256；
3. 再用主程序自己的解释器离线安装：``python -m pip install --target <临时目录>
   --require-hashes --only-binary=:all: --no-deps --no-compile --no-index --find-links …
   -c host-constraints.txt -r <锁文件>``，装完改名为正式目录，失败不留半截目录。
   安装过程不执行包里的任何代码（只装轮子）。

加载：进程外运行器用 ``sys.path`` 把依赖目录追加在最后（不经 ``site``，包里的 ``.pth`` 不执行）。
主程序换了 Python 版本（平台标签对不上）时，启动后在后台按原锁文件重装，装好再挂载。
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import logging
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from movieclaw_sdk import deps

logger = logging.getLogger("movieclaw_api.plugin_deps")

DEPS_DIR = "plugins/deps"
CACHE = ".cache"
COMPLETE = ".complete"
SERVICE = "pypi"
DOWNLOAD_TIMEOUT = 120.0
PIP_TIMEOUT = 600.0

INDEX_LABELS = {deps.DEFAULT_INDEX: "PyPI", deps.TSINGHUA_INDEX: "PyPI 清华镜像"}


def index_url() -> str:
    """下载依赖用的包索引：「设置 → 网络」里改，空 = PyPI 官方。"""
    from movieclaw_api.services.network_egress import current_network_setting

    return current_network_setting().pypi_index_url or deps.DEFAULT_INDEX


def index_label(url: str) -> str:
    return INDEX_LABELS.get(url.rstrip("/"), url)


def view(lock: deps.Lock | None, approved: dict[str, Any] | None) -> dict[str, Any] | None:
    """批准页的依赖一节；``approved`` 是当前已安装版本的依赖授权（没有则全部算新增）。"""
    if lock is None:
        return None
    before = {p["name"]: p["version"] for p in (approved or {}).get("packages", [])}
    tags = deps.here_tags()
    rows: list[dict[str, Any]] = []
    for package in lock.packages:
        wheel = package.pick(tags)
        previous = before.get(package.name)
        rows.append(
            {
                "name": package.name,
                "version": package.version,
                "size": wheel.size if wheel else None,
                "native": package.native,
                "available": wheel is not None,
                "change": (
                    "added"
                    if package.name not in before
                    else ("changed" if previous != package.version else None)
                ),
                "previous_version": previous if previous != package.version else None,
            }
        )
    names = {p.name for p in lock.packages}
    url = index_url()
    return {
        "lock_digest": lock.digest,
        "packages": rows,
        "total_size": sum(r["size"] or 0 for r in rows),
        "native": [r["name"] for r in rows if r["native"]],
        "unavailable": [f"{r['name']} {r['version']}" for r in rows if not r["available"]],
        "removed": [f"{name} {version}" for name, version in before.items() if name not in names],
        "index": url,
        "index_label": index_label(url),
        "needs_consent": (approved or {}).get("digest") != lock.digest,
    }


def summary(view: dict[str, Any]) -> str:
    """一行说明：「需要下载并安装 6 个第三方包（共 4.2 MB，来自 PyPI）：…」。"""
    packages = "、".join(
        f"{r['name']} {r['version']}" + ("（含本机代码）" if r["native"] else "")
        for r in view["packages"]
    )
    size = view["total_size"] / 1024 / 1024
    return (
        f"需要下载并安装 {len(view['packages'])} 个第三方包"
        f"（共 {size:.1f} MB，来自 {view['index_label']}）：{packages}"
    )


# ---------------------------------------------------------------------- 安装
class DependencyError(RuntimeError):
    """依赖装不上：原因直接给用户看（网络不通、哈希不对、没有适用于本机平台的轮子……）。"""


@dataclass
class Progress:
    """一个插件的依赖安装进度（批准页 / 插件列表显示「正在安装依赖（3 / 6）」）。"""

    total: int
    done: int = 0
    error: str | None = None
    phase: str = "installing"
    """installing 正在安装 / failed 失败（等重试）。"""
    task: asyncio.Task[Any] | None = field(default=None, repr=False)

    def view(self) -> dict[str, Any]:
        return {"phase": self.phase, "done": self.done, "total": self.total, "error": self.error}


_progress: dict[str, Progress] = {}
_locks: dict[str, asyncio.Lock] = {}


def progress(entry_id: str) -> dict[str, Any] | None:
    found = _progress.get(entry_id)
    return found.view() if found else None


def platform_tag() -> str:
    """这台机器最优先的轮子标签（解释器 + 平台），如 ``cp312-manylinux_2_36_x86_64``。

    主程序换了 Python 版本或架构，标签就变，依赖要按原锁文件重装。
    """
    first = next(iter(deps.here_tags()))
    return f"{first.interpreter}-{first.platform}"


def root(settings: object) -> Path:
    return Path(getattr(settings, "data_dir", "./data")) / DEPS_DIR


def target_dir(settings: object, digest: str) -> Path:
    return root(settings) / f"{digest[:16]}-{platform_tag()}"


def ready_dir(settings: object, digest: str) -> Path | None:
    target = target_dir(settings, digest)
    return target if (target / COMPLETE).is_file() else None


def _here() -> str:
    from movieclaw_api.plugins.packages import current_platform

    return f"{current_platform()}，Python {sys.version_info.major}.{sys.version_info.minor}"


async def install(
    settings: object,
    entry_id: str,
    package_dir: Path,
    lock_name: str,
    *,
    index: str | None = None,
) -> Path:
    """装好一个插件包的依赖并返回依赖目录（已装好的直接返回）。失败抛 ``DependencyError``。"""
    text = (package_dir / lock_name).read_text(encoding="utf-8")
    lock = deps.parse_lock(text)
    target = target_dir(settings, lock.digest)
    lock_guard = _locks.setdefault(target.name, asyncio.Lock())
    async with lock_guard:
        if (target / COMPLETE).is_file():
            return target
        tags = deps.here_tags()
        picks = [(p, p.pick(tags)) for p in lock.packages]
        missing = [f"{p.name} {p.version}" for p, wheel in picks if wheel is None]
        if missing:
            raise DependencyError(
                f"没有适用于这台服务器（{_here()}）的轮子：{'、'.join(missing)}。"
                "插件作者需要换用提供这个平台轮子的版本"
            )
        state = _progress.get(entry_id) or Progress(total=0)
        state.total, state.done, state.phase, state.error = len(picks), 0, "installing", None
        _progress[entry_id] = state
        try:
            files = []
            url = index or index_url()
            async with _client() as client:
                pages: dict[str, list[deps.IndexFile]] = {}
                for package, wheel in picks:
                    assert wheel is not None
                    files.append(
                        await _fetch(settings, client, url, pages, package, wheel, package_dir)
                    )
                    state.done += 1
            await asyncio.to_thread(_pip_install, text, files, target)
        except DependencyError as exc:
            state.phase, state.error = "failed", str(exc)
            raise
        except Exception as exc:  # noqa: BLE001 -- 任何意外都写成原因，不让插件卡在「安装中」
            state.phase, state.error = "failed", f"{type(exc).__name__}: {exc}"
            raise DependencyError(state.error) from exc
        _progress.pop(entry_id, None)
    logger.info("插件 %s 的依赖已装好（%d 个包）：%s", entry_id, len(picks), target.name)
    return target


def _client() -> Any:
    import httpx

    from movieclaw_net import egress_transport

    return httpx.AsyncClient(
        transport=egress_transport(SERVICE),
        timeout=httpx.Timeout(DOWNLOAD_TIMEOUT, connect=15.0),
        follow_redirects=True,
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


async def _fetch(
    settings: object,
    client: Any,
    index: str,
    pages: dict[str, list[deps.IndexFile]],
    package: deps.Locked,
    wheel: deps.Wheel,
    package_dir: Path,
) -> Path:
    """一个轮子的本地文件：插件包里的 ``wheels/`` → 缓存 → 从包索引下载（逐个核对哈希）。"""
    import httpx

    bundled = package_dir / "wheels" / wheel.filename
    if bundled.is_file():
        if await asyncio.to_thread(_sha256, bundled) != wheel.sha256:
            raise DependencyError(
                f"插件包里的 wheels/{wheel.filename} 与锁文件的哈希不一致，插件包可能被改过"
            )
        return bundled
    cached = root(settings) / CACHE / wheel.sha256 / wheel.filename
    if cached.is_file() and await asyncio.to_thread(_sha256, cached) == wheel.sha256:
        return cached
    try:
        if package.name not in pages:
            page = deps.index_page_url(index, package.name)
            reply = await client.get(page, headers={"Accept": deps.INDEX_ACCEPT})
            reply.raise_for_status()
            pages[package.name] = deps.parse_index_page(
                reply.text, reply.headers.get("content-type", ""), str(reply.url)
            )
        found = next((f for f in pages[package.name] if f.filename == wheel.filename), None)
        if found is None:
            raise DependencyError(
                f"包索引 {index} 上找不到 {wheel.filename}（{package.name} {package.version}），"
                "换个包索引（设置 → 网络）后重试"
            )
        cached.parent.mkdir(parents=True, exist_ok=True)
        partial = cached.with_name(f".{wheel.filename}.{os.getpid()}.partial")
        digest = hashlib.sha256()
        try:
            async with client.stream("GET", found.url) as response:
                response.raise_for_status()
                with partial.open("wb") as out:
                    async for chunk in response.aiter_bytes(1 << 16):
                        digest.update(chunk)
                        out.write(chunk)
            if digest.hexdigest() != wheel.sha256:
                raise DependencyError(
                    f"下载的 {wheel.filename} 哈希不对（锁文件 {wheel.sha256[:12]}…，"
                    f"实际 {digest.hexdigest()[:12]}…）：文件可能被替换或镜像出错，已丢弃"
                )
            os.replace(partial, cached)
        finally:
            partial.unlink(missing_ok=True)
            if not cached.exists():
                with contextlib.suppress(OSError):
                    cached.parent.rmdir()
    except httpx.HTTPStatusError as exc:
        raise DependencyError(
            f"下载 {package.name} 失败：包索引返回 {exc.response.status_code}（{exc.request.url}）"
        ) from exc
    except httpx.HTTPError as exc:
        raise DependencyError(
            f"下载 {package.name} 失败：连不上包索引 {index}（{type(exc).__name__}: {exc}）。"
            "检查网络与「设置 → 网络」里的代理、包索引地址后重试"
        ) from exc
    return cached


def _pip_install(lock_text: str, files: list[Path], target: Path) -> None:
    """离线安装到临时目录，校验后改名；失败不留半截目录。"""
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=target.parent) as tmp:
        work = Path(tmp)
        (work / "requirements.lock").write_text(lock_text, encoding="utf-8")
        (work / "host-constraints.txt").write_text(deps.constraints_text(), encoding="utf-8")
        out = work / "site"
        command = [
            sys.executable, "-m", "pip", "install", "--target", str(out),
            "--require-hashes", "--only-binary=:all:", "--no-deps", "--no-compile",
            "--no-index", "--no-cache-dir", "--disable-pip-version-check", "--no-input",
            "--quiet", "-c", str(work / "host-constraints.txt"),
            "-r", str(work / "requirements.lock"),
        ]  # fmt: skip
        for folder in dict.fromkeys(str(f.parent) for f in files):
            command += ["--find-links", folder]
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": tmp,
            "PIP_CONFIG_FILE": os.devnull,
            "PYTHONNOUSERSITE": "1",
            "LANG": "C.UTF-8",
        }
        try:
            proc = subprocess.run(
                command, capture_output=True, text=True, env=env, timeout=PIP_TIMEOUT, check=False
            )
        except subprocess.TimeoutExpired as exc:
            raise DependencyError(f"安装依赖超时（{int(PIP_TIMEOUT)} 秒）") from exc
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout).strip().splitlines()[-6:]
            raise DependencyError("pip 安装失败：" + " / ".join(tail))
        (out / COMPLETE).write_text(lock_text, encoding="utf-8")
        if target.exists():
            shutil.rmtree(target)
        os.replace(out, target)


# ---------------------------------------------------------------------- 清理
def prune(settings: object, packages: dict[str, Any]) -> None:
    """只保留当前版与上一版引用的依赖目录（本平台标签的），缓存里只留它们用到的轮子。"""
    base = root(settings)
    if not base.is_dir():
        return
    from movieclaw_api.plugins import packages as pkg

    keep_dirs: set[str] = set()
    keep_wheels: set[str] = set()
    for record in packages.values():
        for version, record_deps in (
            (record.version, record.dependencies),
            ((record.previous or {}).get("version"), (record.previous or {}).get("dependencies")),
        ):
            if not version or not record_deps:
                continue
            keep_dirs.add(target_dir(settings, record_deps["digest"]).name)
            lock_file = pkg.version_dir(settings, record.id, version) / record_deps["lock"]
            with contextlib.suppress(OSError, deps.LockError):
                lock = deps.parse_lock(lock_file.read_text(encoding="utf-8"))
                keep_wheels |= {w.sha256 for p in lock.packages for w in p.wheels}
    for path in base.iterdir():
        if path.name == CACHE or path.name.startswith(".install-") or not path.is_dir():
            continue
        if path.name not in keep_dirs:
            shutil.rmtree(path, ignore_errors=True)
            logger.info("已清理不再使用的插件依赖目录 %s", path.name)
    cache = base / CACHE
    if cache.is_dir():
        for path in cache.iterdir():
            if path.name not in keep_wheels:
                shutil.rmtree(path, ignore_errors=True)


# ---------------------------------------------------------------------- 启动时补装
def pending_installs(settings: object) -> list[Any]:
    """依赖还没就绪的已安装插件（首次启动、主程序换了 Python 版本、依赖目录被删）。"""
    from movieclaw_api.plugins import packages as pkg

    return [
        p
        for p in pkg.installed(settings).values()
        if p.dependencies and ready_dir(settings, p.dependencies["digest"]) is None
    ]


def resume(kernel: Any, settings: object) -> None:
    """后台按原锁文件补装依赖（授权已给过，不再问），装好就挂载；不卡启动。"""
    for record in pending_installs(settings):
        current = _progress.get(record.id)
        if current is not None and current.task is not None and not current.task.done():
            continue
        task = asyncio.get_running_loop().create_task(
            _resume_one(kernel, settings, record.id), name=f"plugin-deps:{record.id}"
        )
        _progress[record.id] = Progress(total=0, task=task)


async def _resume_one(kernel: Any, settings: object, entry_id: str) -> None:
    from movieclaw_api.plugins import packages as pkg

    record = pkg.installed(settings).get(entry_id)
    if record is None or not record.dependencies:
        _progress.pop(entry_id, None)
        return
    logger.info("插件 %s 的依赖需要重新准备（平台 %s），后台安装中", entry_id, platform_tag())
    try:
        await install(
            settings,
            entry_id,
            pkg.version_dir(settings, entry_id, record.version),
            record.dependencies["lock"],
        )
    except DependencyError as exc:
        logger.warning("插件 %s 的依赖安装失败：%s", entry_id, exc)
        return
    if kernel.fiber(entry_id) is None:
        fiber = await kernel.mount(pkg.entry_for(settings, record))
        logger.info("插件 %s 依赖就绪，已挂载（%s）", entry_id, fiber.state.value)


def forget(entry_id: str) -> None:
    found = _progress.pop(entry_id, None)
    if found is not None and found.task is not None and not found.task.done():
        found.task.cancel()


async def stop() -> None:
    tasks = [p.task for p in _progress.values() if p.task is not None and not p.task.done()]
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    _progress.clear()
