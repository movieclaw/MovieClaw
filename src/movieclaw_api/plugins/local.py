"""本地受信插件（docs/design/plugin-phase2a.md §6）。

用户自己写的 Python 插件放在 ``data/plugins/`` 下，**只有在 ``data/plugins.yaml`` 里写了
``local: true`` 的条目才会加载**——目录里多出来的文件永远不会被执行::

    - id: acme.delete-cascade        # 条目 id = @plugin 的名字
      local: true
      module: delete_cascade         # 可选：plugins/delete_cascade.py 或 delete_cascade/ 包
      config: { enabled: true }      # 交给插件的配置
      grants: [subscriptions.delete, dl.torrent.delete]   # 批准它调用的宿主操作
      act_as: family                 # 可选：以哪个成员的身份调用（缺省超管）

本地插件在进程内运行，拥有与主程序相同的系统权限——「受信」的意思是用户为它负责。它按第三方
对待：只能用非内部契约、贡献 id 自动加前缀、宿主操作只拿「声明 ∩ grants」；永远不是关键插件，
启动失败只影响它自己。第三阶段的进程外运行器会把它们挪出进程，插件代码不用改。
"""

from __future__ import annotations

import dataclasses
import importlib.util
import logging
import sys
import types
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from movieclaw_kernel import Entry, Plugin

logger = logging.getLogger("movieclaw_api.plugins.local")

#: 本地插件代码目录（相对数据目录）
LOCAL_DIR = "plugins"
#: 本地插件模块挂在这个包名下，避免与已安装的包重名
PACKAGE = "movieclaw_local_plugins"
SOURCE = "local"


@dataclass(frozen=True)
class LocalSpec:
    id: str
    module: str
    config: dict[str, Any] = field(default_factory=dict)
    grants: tuple[str, ...] = ()
    act_as: str | None = None
    disabled: bool = False
    runtime: str = "inline"
    """``inline``：主进程里运行；``process``：独立进程（docs/design/plugin-phase3.md §4）。"""


def plugins_dir(settings: object) -> Path:
    return Path(getattr(settings, "data_dir", "./data")) / LOCAL_DIR


def default_module(entry_id: str) -> str:
    return entry_id.rsplit(".", 1)[-1].replace("-", "_")


def local_specs(settings: object) -> list[LocalSpec]:
    """从 ``plugins.yaml`` 读出显式开启的本地插件；格式不对的条目告警跳过。"""
    from movieclaw_api.plugins.manifest import read_patch_items

    specs: list[LocalSpec] = []
    for item in read_patch_items(settings):
        if item.get("local") is not True:
            continue
        entry_id = item["id"]
        module = item.get("module") or default_module(entry_id)
        config = item.get("config") or {}
        grants = item.get("grants") or []
        act_as = item.get("act_as")
        runtime = item.get("runtime") or "inline"
        if (
            runtime not in ("inline", "process")
            or not isinstance(module, str)
            or not module.isidentifier()
            or not isinstance(config, dict)
            or not isinstance(grants, list)
            or not all(isinstance(g, str) for g in grants)
            or not (act_as is None or isinstance(act_as, str))
        ):
            logger.warning(
                "本地插件 %s 的配置不合规（module 须是合法模块名、config 是映射、"
                "grants 是字符串列表、runtime 是 inline 或 process），已跳过",
                entry_id,
            )
            continue
        specs.append(
            LocalSpec(
                id=entry_id,
                module=module,
                config=dict(config),
                grants=tuple(grants),
                act_as=act_as,
                disabled=bool(item.get("disabled", False)),
                runtime=runtime,
            )
        )
    return specs


def _failing(entry_id: str, reason: str) -> Plugin:
    async def apply(ctx: Any) -> None:
        raise RuntimeError(reason)

    return Plugin(
        name=entry_id,
        title=f"本地插件 {entry_id}",
        apply=apply,
        disableable=True,
    )


def _ensure_package(root: Path) -> None:
    package = sys.modules.get(PACKAGE)
    if package is None:
        package = types.ModuleType(PACKAGE)
        package.__path__ = []  # type: ignore[attr-defined]
        sys.modules[PACKAGE] = package
    path = str(root)
    if path not in package.__path__:  # type: ignore[attr-defined]
        package.__path__.append(path)  # type: ignore[attr-defined]


def _import(root: Path, spec: LocalSpec) -> types.ModuleType:
    name = f"{PACKAGE}.{spec.module}"
    if name in sys.modules:
        return sys.modules[name]
    file = root / f"{spec.module}.py"
    package = root / spec.module / "__init__.py"
    if package.is_file():
        module_spec = importlib.util.spec_from_file_location(
            name, package, submodule_search_locations=[str(package.parent)]
        )
    elif file.is_file():
        module_spec = importlib.util.spec_from_file_location(name, file)
    else:
        raise FileNotFoundError(
            f"找不到 {LOCAL_DIR}/{spec.module}.py 或 {LOCAL_DIR}/{spec.module}/__init__.py"
        )
    assert module_spec is not None and module_spec.loader is not None
    _ensure_package(root)
    module = importlib.util.module_from_spec(module_spec)
    sys.modules[name] = module
    try:
        module_spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def _resolve(root: Path, spec: LocalSpec) -> Plugin:
    try:
        module = _import(root, spec)
    except Exception as exc:  # noqa: BLE001 -- 本地代码出什么错都只影响它自己
        logger.warning("本地插件 %s 导入失败：%s", spec.id, exc, exc_info=exc)
        return _failing(spec.id, f"导入失败：{type(exc).__name__}: {exc}")
    found = [
        value
        for value in vars(module).values()
        if isinstance(value, Plugin) and value.name == spec.id
    ]
    if not found:
        return _failing(
            spec.id,
            f"模块 {spec.module} 里没有名为 {spec.id} 的插件"
            "（@plugin 的第一个参数须与条目 id 一致）",
        )
    plugin = found[0]
    # 本地插件永远不是关键插件、永远可以在补丁里关掉：它出问题不能拖垮整个应用
    return dataclasses.replace(
        plugin,
        critical=False,
        disableable=True,
        apply_timeout=plugin.apply_timeout or 30.0,
    )


def load_local_entries(settings: object) -> list[Entry]:
    """按 ``plugins.yaml`` 加载本地插件条目；被补丁关掉的不导入代码，只占一个位置给诊断。"""
    specs = local_specs(settings)
    if not specs:
        return []
    root = plugins_dir(settings)
    entries: list[Entry] = []
    for spec in specs:
        if spec.disabled:
            plugin = _failing(spec.id, "已在 plugins.yaml 中关闭")
        elif spec.runtime == "process":
            plugin = _remote(root, spec)
        else:
            plugin = _resolve(root, spec)
        entries.append(Entry(spec.id, plugin, config=spec.config, source=SOURCE))
    inline = [s.id for s in specs if s.runtime == "inline"]
    process = [s.id for s in specs if s.runtime == "process"]
    if inline:
        logger.warning(
            "已加载 %d 个本地插件（进程内运行，拥有与主程序相同的系统权限）：%s",
            len(inline),
            "、".join(inline),
        )
    if process:
        logger.info("已加载 %d 个独立进程运行的本地插件：%s", len(process), "、".join(process))
    return entries


def _remote(root: Path, spec: LocalSpec) -> Plugin:
    """独立进程运行：主进程不导入插件代码，只登记代理（services/plugin_runtime.py）。"""
    from movieclaw_api.services.plugin_runtime import remote_plugin

    found = (root / f"{spec.module}.py").is_file() or (root / spec.module / "__init__.py").is_file()
    if not found:
        return _failing(
            spec.id, f"找不到 {LOCAL_DIR}/{spec.module}.py 或 {LOCAL_DIR}/{spec.module}/__init__.py"
        )
    return remote_plugin(
        spec.id,
        title=f"本地插件 {spec.id}（独立进程）",
        path=root,
        module=spec.module,
        config=spec.config,
    )


def configure_host_ops(host: Any, settings: object) -> None:
    """把用户在 ``plugins.yaml`` 里的批准（grants、act_as）交给宿主操作服务。"""
    for spec in local_specs(settings):
        host.configure(spec.id, grants=spec.grants, act_as=spec.act_as)
