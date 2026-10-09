"""随应用携带的插件包（docs/design/plugin-channels.md §7）。

``src/movieclaw_plugins/<目录>/`` 下每个都是完整的插件包（带清单），与第三方插件包同一套格式。
随应用携带时作为内置插件加载：受信、不走批准、在主进程里运行，按包内的规范模块名导入
（``movieclaw_plugins.<目录>.<入口>``）。

装一个同 id 的插件包即替换随带版本（安装时先卸下内置条目再挂上插件包）；卸载、首装失败撤销后，
随带版本自动回来。安全模式下插件包不加载，随带版本照常运行。
"""

from __future__ import annotations

import importlib
import logging
import tomllib
from dataclasses import dataclass
from functools import cache
from pathlib import Path

from movieclaw_api.plugins.packages import MANIFEST, Manifest
from movieclaw_kernel import Entry, Plugin

logger = logging.getLogger("movieclaw_api.plugins.bundled")

PACKAGE = "movieclaw_plugins"


@dataclass(frozen=True)
class Bundled:
    id: str
    path: Path
    manifest: Manifest

    @property
    def module(self) -> str:
        return f"{PACKAGE}.{self.path.name}.{self.manifest.plugin.entry}"


def root() -> Path:
    import movieclaw_plugins

    return Path(movieclaw_plugins.__file__).resolve().parent


@cache
def bundled() -> dict[str, Bundled]:
    """随带的插件包：条目 id → 包。清单写错是开发期错误，直接抛。"""
    found: dict[str, Bundled] = {}
    for path in sorted(root().iterdir()):
        manifest_file = path / MANIFEST
        if not manifest_file.is_file():
            continue
        manifest = Manifest.model_validate(tomllib.loads(manifest_file.read_text("utf-8")))
        found[manifest.plugin.id] = Bundled(manifest.plugin.id, path, manifest)
    return found


def bundled_ids() -> set[str]:
    return set(bundled())


def entry(package: Bundled) -> Entry:
    module = importlib.import_module(package.module)
    for value in vars(module).values():
        if isinstance(value, Plugin) and value.name == package.id:
            return Entry(package.id, value)
    raise LookupError(f"随带插件包 {package.id} 的入口 {package.module} 里没有这个插件")


def load_bundled_entries(replaced: set[str]) -> list[Entry]:
    """随带插件包的内置条目；``replaced`` 里的（已被同 id 插件包替换的）跳过。"""
    entries = [entry(p) for p in bundled().values() if p.id not in replaced]
    skipped = sorted(bundled_ids() & replaced)
    if skipped:
        logger.info("随带插件包已被同 id 插件包替换：%s", "、".join(skipped))
    return entries
