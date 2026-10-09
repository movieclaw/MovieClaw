"""插件文件接口 ``PLUGIN_FILES``（docs/design/plugin-phase3.md §6.2，C6a）。

::

    files = ctx.use(PLUGIN_FILES).scoped(ctx)
    with await files.open(path, "rb") as src: ...          # 二进制文件对象，读写在线程里做
    await files.rename(tmp, final)
    state = files.path("plugin", "state.json")   # 插件自己目录下的绝对路径（不碰盘）
    return files.response(path)                   # 路由里交出文件（支持 Range）

授权（插件包清单 ``[permissions] paths``、本地插件 ``plugins.yaml`` 的 ``paths``，用户批准后生效）::

    paths = [{ path = "library", mode = "rw" }, { path = "staging", mode = "read" }]

别名：``library``（全部媒体库根目录）、``library:<id>``、``staging``（导入规则的自定义目录）、``plugin``
（``data/plugins/data/<条目 id>/``，总是可读写、只属于它自己）；也可以写绝对路径（例如网盘挂载点）。
每次检查都先 ``realpath`` 再判断落在哪个授权根之下（软链接逃逸无效），别名每次现算
（库根改了立即生效）。

进程外插件经同一接口：``open`` 由宿主检查后打开文件，把文件描述符经专用套接字递过去
（``movieclaw_sdk.runner``）。
"""

from __future__ import annotations

import asyncio
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from starlette.responses import Response

from movieclaw_db.engine import Database

Mode = Literal["read", "rw"]
_WRITE_MODES = frozenset("wax+")
#: 进程外插件的路由交出文件时用的响应头：宿主代理拦下、检查授权后自己发送
SENDFILE_HEADER = "X-MovieClaw-Sendfile"


@dataclass(frozen=True)
class Grant:
    path: str
    mode: Mode = "read"


def parse_grants(raw: Any) -> tuple[Grant, ...]:
    """``[{path, mode}]`` → 授权；格式不对抛 ``ValueError``（原因给用户看）。"""
    if raw is None:
        return ()
    if not isinstance(raw, list):
        raise ValueError("paths 须是列表，如 [{path: library, mode: rw}]")
    grants: list[Grant] = []
    for item in raw:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            raise ValueError("paths 的每一项须是 {path, mode}")
        mode = item.get("mode", "read")
        if mode not in ("read", "rw"):
            raise ValueError(f"路径授权的 mode 只能是 read 或 rw：{mode!r}")
        path = item["path"].strip()
        if not (
            path in ("library", "staging", "plugin")
            or path.startswith("library:")
            or path.startswith("/")
        ):
            raise ValueError(
                f"不认识的路径授权 {path!r}：可用 library、library:<id>、staging、plugin 或绝对路径"
            )
        grants.append(Grant(path, mode))
    return tuple(grants)


class PluginFiles:
    """一个插件条目的文件接口（进程内插件直接用；进程外插件的请求也由宿主经它执行）。"""

    def __init__(self, service: PluginFilesService, entry_id: str) -> None:
        self._service = service
        self.entry_id = entry_id

    # ------------------------------------------------------------------ 授权
    async def roots(self) -> list[tuple[Path, Mode]]:
        return await self._service.roots(self.entry_id)

    async def check(self, path: str | os.PathLike[str], *, write: bool) -> Path:
        """返回检查通过的真实路径；不在授权范围内抛 ``PermissionError``。"""
        real = Path(os.path.realpath(path))
        for root, mode in await self.roots():
            if real == root or real.is_relative_to(root):
                if write and mode != "rw":
                    raise PermissionError(f"插件 {self.entry_id} 对 {root} 只有读权限")
                return real
        raise PermissionError(f"插件 {self.entry_id} 没有获得访问 {path} 的授权")

    def path(self, alias: str, *parts: str) -> str:
        """别名下的绝对路径（目前只支持 ``plugin``：插件自己的目录）。"""
        if alias != "plugin":
            raise ValueError("path() 只支持 plugin 别名")
        target = self._service.private_dir(self.entry_id).joinpath(*parts)
        if not Path(os.path.realpath(target)).is_relative_to(
            self._service.private_dir(self.entry_id)
        ):
            raise PermissionError("路径越出了插件自己的目录")
        return str(target)

    # ------------------------------------------------------------------ 操作
    async def open(self, path: str | os.PathLike[str], mode: str = "rb") -> Any:
        """打开文件（只支持二进制模式），返回文件对象；读写请放进线程（``asyncio.to_thread``）。"""
        if "b" not in mode:
            raise ValueError("只支持二进制模式（rb / wb / ab / r+b）")
        real = await self.check(path, write=bool(_WRITE_MODES & set(mode)))
        return await asyncio.to_thread(open, real, mode)

    async def stat(self, path: str | os.PathLike[str]) -> dict[str, Any] | None:
        real = await self.check(path, write=False)
        try:
            st = await asyncio.to_thread(os.stat, real)
        except FileNotFoundError:
            return None
        return {"size": st.st_size, "mtime": st.st_mtime, "is_dir": os.path.isdir(real)}

    async def exists(self, path: str | os.PathLike[str]) -> bool:
        return await self.stat(path) is not None

    async def listdir(self, path: str | os.PathLike[str]) -> list[str]:
        real = await self.check(path, write=False)
        return sorted(await asyncio.to_thread(os.listdir, real))

    async def makedirs(self, path: str | os.PathLike[str]) -> None:
        real = await self.check(path, write=True)
        await asyncio.to_thread(os.makedirs, real, exist_ok=True)

    async def rename(self, src: str | os.PathLike[str], dst: str | os.PathLike[str]) -> None:
        real_src = await self.check(src, write=True)
        real_dst = await self.check(dst, write=True)
        await asyncio.to_thread(os.replace, real_src, real_dst)

    async def remove(self, path: str | os.PathLike[str]) -> None:
        real = await self.check(path, write=True)
        if await asyncio.to_thread(os.path.isdir, real):
            await asyncio.to_thread(shutil.rmtree, real)
        else:
            await asyncio.to_thread(os.unlink, real)

    def response(self, path: str | os.PathLike[str]) -> Any:
        """路由里交出一个文件（支持 Range）。授权在发送时检查，越权或不存在一律 404。"""
        return _SendfileResponse(self, os.fspath(path))


class PluginFilesService:
    """``PLUGIN_FILES`` 的实现。"""

    def __init__(self, db: Database, data_dir: str | os.PathLike[str]) -> None:
        self._db = db
        self._data_dir = Path(os.path.realpath(data_dir))
        self._grants: dict[str, tuple[Grant, ...]] = {}

    def configure(self, entry_id: str, grants: tuple[Grant, ...]) -> None:
        """登记用户对某个条目批准的路径（本地插件读 plugins.yaml，插件包读安装记录）。"""
        self._grants[entry_id] = grants

    def private_dir(self, entry_id: str) -> Path:
        path = self._data_dir / "plugins" / "data" / entry_id
        path.mkdir(parents=True, exist_ok=True)
        return path

    def scoped(self, ctx: Any) -> PluginFiles:
        return PluginFiles(self, ctx.entry_id)

    def for_entry(self, entry_id: str) -> PluginFiles:
        return PluginFiles(self, entry_id)

    async def roots(self, entry_id: str) -> list[tuple[Path, Mode]]:
        roots: list[tuple[Path, Mode]] = [(self.private_dir(entry_id), "rw")]
        grants = self._grants.get(entry_id, ())
        libraries: list[Any] | None = None
        for grant in grants:
            if grant.path.startswith("/"):
                roots.append((Path(os.path.realpath(grant.path)), grant.mode))
            elif grant.path == "staging":
                for target in await self._staging_dirs():
                    roots.append((Path(os.path.realpath(target)), grant.mode))
            elif grant.path == "library" or grant.path.startswith("library:"):
                if libraries is None:
                    libraries = await self._libraries()
                wanted = None if grant.path == "library" else grant.path.split(":", 1)[1]
                for library in libraries:
                    if wanted is None or str(library.id) == wanted:
                        for root in library.root_paths or []:
                            roots.append((Path(os.path.realpath(root)), grant.mode))
        return roots

    async def _libraries(self) -> list[Any]:
        from sqlmodel import select

        from movieclaw_db.models import Library

        async with self._db.session() as session:
            return list((await session.execute(select(Library))).scalars())

    async def _staging_dirs(self) -> list[str]:
        from sqlmodel import select

        from movieclaw_db.models import ImportWatch

        async with self._db.session() as session:
            rows = await session.execute(
                select(ImportWatch.target_path).where(ImportWatch.target_path.is_not(None))  # type: ignore[union-attr]
            )
            return [row for row in rows.scalars() if row]


class _SendfileResponse(Response):
    """进程内插件路由交出文件：发送时检查授权，再交给 ``FileResponse``（Range 等由它处理）。"""

    def __init__(self, files: PluginFiles, path: str) -> None:
        super().__init__(status_code=200)
        self._files = files
        self._path = path

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        from starlette.responses import JSONResponse

        try:
            response = await _file_response(self._files, self._path)
        except (PermissionError, FileNotFoundError) as exc:
            response = JSONResponse(
                {"success": False, "code": "NOT_FOUND", "message": str(exc), "data": None},
                status_code=404,
            )
        await response(scope, receive, send)


async def _file_response(files: PluginFiles, path: str) -> Any:
    from starlette.responses import FileResponse

    real = await files.check(path, write=False)
    if not await asyncio.to_thread(real.is_file):
        raise FileNotFoundError("文件不存在")
    return FileResponse(real)


async def sendfile(files: PluginFiles, path: str) -> Any:
    """宿主侧交出文件：检查读授权后返回 ``FileResponse``（Range、条件请求由 Starlette 处理）。"""
    from movieclaw_api.exceptions import NotFoundException

    try:
        return await _file_response(files, path)
    except (PermissionError, FileNotFoundError) as exc:
        raise NotFoundException(str(exc)) from exc
