"""第三方插件包（docs/design/plugin-phase3.md §2、§3，C5）。

一个插件包是 zip（``.mcplugin``），根目录有 ``movieclaw-plugin.toml``::

    [plugin]
    id = "group-blocklist"          # 全局唯一：小写字母开头，字母、数字、连字符，3～40 位，不含点
    title = "发布组黑名单"
    version = "0.1.0"
    entry = "group_blocklist"       # 模块名：group_blocklist.py 或 group_blocklist/__init__.py
    runtime = "process"             # 默认；"inline" 需要用户单独批准（与主程序同权限）
    sdk = "^1.0"

    [requires]                      # 用到的契约与版本（同内核 requires 语义）
    "subscription.candidates.filter" = "^1.0"

    [permissions]
    operations = ["search.titles"]  # 宿主操作；危险操作必须逐个列出

依赖只能随包携带（``vendor/`` 目录，运行时加入导入路径），安装时不联网、不跑 pip（§9 决策 2）。

目录与状态::

    data/plugins/packages/<条目 id>/<版本>/            已安装的版本（当前版 + 上一版）
    data/plugins/packages/<条目 id>/<版本>.pending/    已上传、等用户批准
    data/plugins/packages/state.json                   安装记录与批准结果

批准结果不写进用户手写的 ``plugins.yaml``，那里只留给本地受信插件。
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import logging
import os
import re
import secrets
import shutil
import stat
import sys
import time
import tomllib
import zipfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from movieclaw_kernel import Entry, Plugin
from movieclaw_kernel.contracts import Version, check_requires, satisfies

logger = logging.getLogger("movieclaw_api.plugins.packages")

MANIFEST = "movieclaw-plugin.toml"
SOURCE = "package"
PACKAGES_DIR = "plugins/packages"
STATE_FILE = "state.json"
MAX_ARCHIVE_BYTES = 50 * 1024 * 1024
MAX_UNPACKED_BYTES = 200 * 1024 * 1024
MAX_FILES = 5000

#: 插件包 id（docs/design/plugin-callbacks.md §3）：不含点。带点的名字留给内核里的内置条目，
#: 两边永不相交
_ID = re.compile(r"^[a-z][a-z0-9-]{1,38}[a-z0-9]$")
#: 旧格式（带命名空间点）：只认已经装上的插件包——代码里写死了这个 id，宿主不能替它改名
_LEGACY_ID = re.compile(r"^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9_-]*)+$")
ID_RULE = "小写字母开头，只用小写字母、数字和连字符，3～40 位，不含点，如 group-blocklist"

_VERSION = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
_MODULE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def is_legacy_id(entry_id: str) -> bool:
    return not _ID.match(entry_id) and bool(_LEGACY_ID.match(entry_id))


class PackageError(ValueError):
    """插件包不合规 / 不兼容 / 状态不对：原因直接给用户看。"""


# ---------------------------------------------------------------------- 清单
class _Plugin(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str = Field(max_length=64)
    title: str = Field(min_length=1, max_length=60)
    version: str
    entry: str
    runtime: Literal["process", "inline"] = "process"
    sdk: str = "^1.0"
    description: str = Field(default="", max_length=500)

    @field_validator("id")
    @classmethod
    def _id(cls, value: str) -> str:
        # 旧格式在这里放行，是否允许由安装流程按「是否已经装过」决定（is_legacy_id）
        if not _ID.match(value) and not _LEGACY_ID.match(value):
            raise ValueError(f"id 须{ID_RULE}")
        return value

    @field_validator("version")
    @classmethod
    def _version(cls, value: str) -> str:
        if not _VERSION.match(value):
            raise ValueError("version 须是 主.次.修订（如 1.2.0）")
        return value

    @field_validator("entry")
    @classmethod
    def _entry(cls, value: str) -> str:
        if not _MODULE.match(value):
            raise ValueError("entry 须是模块名（如 group_blocklist）")
        return value


class _Permissions(BaseModel):
    model_config = ConfigDict(extra="forbid")

    operations: list[str] = Field(default_factory=list)
    paths: list[dict[str, str]] = Field(default_factory=list)
    network: bool = False
    callbacks: list[str] = Field(default_factory=list, max_length=8)
    """要开放的回调端点名（docs/design/plugin-callbacks.md §4.3）：外部平台能直接调进来的地址。"""

    @field_validator("callbacks")
    @classmethod
    def _callbacks(cls, value: list[str]) -> list[str]:
        from movieclaw_sdk.callbacks import NAME

        bad = [name for name in value if not NAME.match(name)]
        if bad:
            names = "、".join(bad)
            raise ValueError(f"回调端点名 {names} 不合规：小写字母开头，字母、数字、连字符")
        if len(set(value)) != len(value):
            raise ValueError("回调端点名重复")
        return value


class Manifest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    plugin: _Plugin
    requires: dict[str, str] = Field(default_factory=dict)
    permissions: _Permissions = Field(default_factory=_Permissions)


# ---------------------------------------------------------------------- 校验
def read_archive(data: bytes) -> tuple[Manifest, zipfile.ZipFile]:
    """校验压缩包本身（大小、路径、软链）并读出清单；不检查兼容性。"""
    if len(data) > MAX_ARCHIVE_BYTES:
        raise PackageError(f"插件包超过 {MAX_ARCHIVE_BYTES // (1024 * 1024)} MB")
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as exc:
        raise PackageError("不是有效的插件包（须是 zip 格式的 .mcplugin）") from exc
    infos = archive.infolist()
    if len(infos) > MAX_FILES:
        raise PackageError(f"插件包里的文件超过 {MAX_FILES} 个")
    total = 0
    for info in infos:
        name = PurePosixPath(info.filename)
        if info.filename.startswith(("/", "\\")) or ".." in name.parts or ":" in info.filename:
            raise PackageError(f"插件包里有不安全的路径：{info.filename}")
        mode = info.external_attr >> 16
        if stat.S_ISLNK(mode):
            raise PackageError(f"插件包里不能有软链接：{info.filename}")
        total += info.file_size
    if total > MAX_UNPACKED_BYTES:
        raise PackageError(f"插件包解压后超过 {MAX_UNPACKED_BYTES // (1024 * 1024)} MB")
    try:
        raw = archive.read(MANIFEST)
    except KeyError as exc:
        raise PackageError(f"插件包根目录缺少 {MANIFEST}") from exc
    try:
        manifest = Manifest.model_validate(tomllib.loads(raw.decode("utf-8")))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as exc:
        raise PackageError(f"{MANIFEST} 不是合法的 TOML：{exc}") from exc
    except ValidationError as exc:
        first = exc.errors()[0]
        where = ".".join(str(p) for p in first["loc"])
        raise PackageError(f"{MANIFEST} 的 {where} 不合规：{first['msg']}") from exc
    entry = manifest.plugin.entry
    names = set(archive.namelist())
    if f"{entry}.py" not in names and f"{entry}/__init__.py" not in names:
        raise PackageError(f"插件包里找不到入口模块 {entry}.py 或 {entry}/__init__.py")
    return manifest, archive


def check_compat(manifest: Manifest, *, reserved: set[str], operations: set[str]) -> None:
    """兼容性与权限声明检查：SDK、契约、条目 id 冲突、宿主操作是否存在。"""
    from movieclaw_sdk import SDK_VERSION

    plugin = manifest.plugin
    if plugin.id in reserved:
        raise PackageError(f"条目 id {plugin.id} 已被内置插件或本地插件占用")
    try:
        sdk_ok = satisfies(plugin.sdk, Version.parse(SDK_VERSION))
    except ValueError as exc:
        raise PackageError(f"sdk 版本要求写法不对：{plugin.sdk}") from exc
    if not sdk_ok:
        raise PackageError(f"插件要求 SDK {plugin.sdk}，当前是 {SDK_VERSION}，请换用兼容的版本")
    reason = check_requires(manifest.requires, third_party=True)
    if reason:
        raise PackageError(f"契约不兼容：{reason}")
    from movieclaw_api.services.plugin_files import parse_grants

    try:
        parse_grants(manifest.permissions.paths)
    except ValueError as exc:
        raise PackageError(f"路径授权不合规：{exc}") from exc
    for pattern in manifest.permissions.operations:
        if pattern.endswith(".*"):
            domain = pattern[:-2] + "."
            if not any(op.startswith(domain) for op in operations):
                raise PackageError(f"宿主操作领域 {pattern} 不存在")
        elif pattern not in operations:
            raise PackageError(f"宿主操作 {pattern} 不存在")


# ---------------------------------------------------------------------- 状态
@dataclass
class Installed:
    id: str
    version: str
    title: str
    entry: str
    runtime: str
    operations: list[str]
    paths: list[dict[str, str]] = field(default_factory=list)
    """批准的路径授权（``PLUGIN_FILES``）。"""
    callbacks: list[str] = field(default_factory=list)
    """批准开放的回调端点名（``PLUGIN_CALLBACKS``）。"""
    previous: dict[str, Any] | None = None
    """上一版的安装记录（version、title、entry、runtime、operations），回滚用。"""
    bad: list[str] = field(default_factory=list)
    """激活失败过的版本：列出来提醒用户，不再自动尝试。"""
    installed_at: float = 0.0

    def snapshot(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "title": self.title,
            "entry": self.entry,
            "runtime": self.runtime,
            "operations": list(self.operations),
            "paths": [dict(p) for p in self.paths],
            "callbacks": list(self.callbacks),
        }


def root(settings: object) -> Path:
    return Path(getattr(settings, "data_dir", "./data")) / PACKAGES_DIR


def _read_state(settings: object) -> dict[str, Any]:
    try:
        data = json.loads((root(settings) / STATE_FILE).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"packages": {}}
    except (OSError, ValueError):
        logger.exception("插件包安装记录读不出来，按没有已安装的包处理")
        return {"packages": {}}
    return data if isinstance(data, dict) else {"packages": {}}


def _write_state(settings: object, data: dict[str, Any]) -> None:
    path = root(settings) / STATE_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def installed(settings: object) -> dict[str, Installed]:
    packages = _read_state(settings).get("packages") or {}
    found: dict[str, Installed] = {}
    for entry_id, item in packages.items():
        with contextlib.suppress(TypeError):
            found[entry_id] = Installed(id=entry_id, **item)
    return found


def save(settings: object, packages: dict[str, Installed]) -> None:
    _write_state(
        settings,
        {
            "packages": {
                p.id: {k: v for k, v in p.__dict__.items() if k != "id"} for p in packages.values()
            }
        },
    )


def version_dir(settings: object, entry_id: str, version: str) -> Path:
    return root(settings) / entry_id / version


def pending_dir(settings: object, entry_id: str, version: str) -> Path:
    return root(settings) / entry_id / f"{version}.pending"


def pending(settings: object) -> list[tuple[Manifest, Path]]:
    """已上传、等批准的包（每个条目最多一个，后传的覆盖先传的）。"""
    found: list[tuple[Manifest, Path]] = []
    base = root(settings)
    if not base.is_dir():
        return found
    for path in sorted(base.glob("*/*.pending")):
        try:
            raw = (path / MANIFEST).read_text(encoding="utf-8")
            found.append((Manifest.model_validate(tomllib.loads(raw)), path))
        except (OSError, ValueError):
            logger.warning("待批准的插件包 %s 读不出来，已忽略", path)
    return found


def extract(archive: zipfile.ZipFile, target: Path) -> None:
    """解到 ``target``（先解到临时目录、校验后改名）；已存在则整个替换。"""
    tmp = target.with_name(f".{target.name}.{secrets.token_hex(4)}.partial")
    tmp.mkdir(parents=True)
    try:
        for info in archive.infolist():
            dest = tmp / info.filename
            if not dest.resolve().is_relative_to(tmp.resolve()):
                raise PackageError(f"插件包里有不安全的路径：{info.filename}")
            if info.is_dir():
                dest.mkdir(parents=True, exist_ok=True)
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as src, dest.open("wb") as out:
                shutil.copyfileobj(src, out)
        if target.exists():
            shutil.rmtree(target)
        os.replace(tmp, target)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


# ---------------------------------------------------------------------- 加载
def _failing(entry_id: str, reason: str) -> Plugin:
    async def apply(ctx: Any) -> None:
        raise RuntimeError(reason)

    return Plugin(name=entry_id, title=f"插件包 {entry_id}", apply=apply, disableable=True)


def _inline(path: Path, package: Installed) -> Plugin:
    """进程内运行（用户单独批准过）：按包目录导入，模块名带条目 id 前缀避免与别的包重名。"""
    import dataclasses

    safe = re.sub(r"[^A-Za-z0-9_]", "_", package.id)
    name = f"movieclaw_packages.{safe}.{package.entry}"
    vendor = path / "vendor"
    if vendor.is_dir() and str(vendor) not in sys.path:
        sys.path.append(str(vendor))
    # 每次挂载都按盘上的代码重新导入：模块名不带版本，沿用缓存会让升级、回滚、重装后的包
    # 照样跑第一次导入的旧代码，直到重启
    for loaded in [m for m in sys.modules if m == name or m.startswith(f"{name}.")]:
        del sys.modules[loaded]
    file = path / f"{package.entry}.py"
    pkg = path / package.entry / "__init__.py"
    spec = (
        importlib.util.spec_from_file_location(
            name, pkg, submodule_search_locations=[str(pkg.parent)]
        )
        if pkg.is_file()
        else importlib.util.spec_from_file_location(name, file)
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    for value in vars(module).values():
        if isinstance(value, Plugin) and value.name == package.id:
            return dataclasses.replace(
                value,
                critical=False,
                disableable=True,
                apply_timeout=value.apply_timeout or 30.0,
            )
    raise PackageError(f"模块 {package.entry} 里没有名为 {package.id} 的插件")


def entry_for(settings: object, package: Installed) -> Entry:
    """一个已安装的包 → 内核条目（独立进程或进程内）。出错只影响它自己。"""
    path = version_dir(settings, package.id, package.version)
    try:
        if package.runtime == "inline":
            plugin = _inline(path, package)
        else:
            from movieclaw_api.services.plugin_runtime import describe, remote_plugin

            declared = describe(path, package.entry, package.id)
            plugin = remote_plugin(
                package.id,
                title=f"{declared['title']}（独立进程）",
                path=path,
                module=package.entry,
                inject=tuple(declared["inject"]),
                permissions=tuple(declared["permissions"]),
                config_description=declared.get("config"),
            )
    except Exception as exc:  # noqa: BLE001 -- 包出什么错都只影响它自己
        logger.warning("插件包 %s v%s 无法加载：%s", package.id, package.version, exc)
        plugin = _failing(package.id, f"{type(exc).__name__}: {exc}")
    return Entry(package.id, plugin, source=SOURCE)


def load_package_entries(settings: object) -> list[Entry]:
    packages = installed(settings)
    if not packages:
        return []
    entries = [entry_for(settings, p) for p in packages.values()]
    logger.info(
        "已加载 %d 个插件包：%s",
        len(entries),
        "、".join(f"{p.id} v{p.version}" for p in packages.values()),
    )
    return entries


def package_ids(settings: object) -> list[str]:
    return list(installed(settings))


def configure_host_ops(host: Any, settings: object) -> None:
    """把用户批准的宿主操作交给宿主操作服务（与本地受信插件同一套机制）。"""
    for package in installed(settings).values():
        host.configure(package.id, grants=package.operations)


def now() -> float:
    return time.time()
