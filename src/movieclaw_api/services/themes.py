"""网页主题目录（docs/design/theme-plugins.md §4.6）。

主题就是带 ``[theme]`` 段与 ``theme/`` 目录的插件包：外观在 ``theme/theme.css``（必需），外框组件在
``theme/index.js``（可选，标准 ES 模块，default export 主题定义）。来源两种：

- 随带插件包（``src/movieclaw_plugins/<目录>/``，如 Netflix 主题）：受信，安全模式照常；
  在插件页卸载了、或被同 id 插件包替换了的不算；
- 已安装的插件包：批准时同意过；安全模式下不算。

插件被停用（插件页开关、``plugins.yaml``）的主题不算。契约 ``ui.theme`` 不兼容的
（主程序升级了主版本）列出来但标「需要更新」，不托管文件——前端拿不到就回落默认主题。

这里只管「有哪些主题、长什么样、文件在哪」；接口在 ``api/routes/themes.py``。
"""

from __future__ import annotations

import hashlib
import logging
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from movieclaw_api.plugins import packages as pkg

logger = logging.getLogger("movieclaw_api.themes")

THEME_DIR = "theme"
CSS_NAME = "theme.css"
JS_NAME = "index.js"
BASE = "/api/v1/ui/themes"


@dataclass(frozen=True)
class Theme:
    id: str
    title: str
    version: str
    source: Literal["bundled", "package"]
    root: Path
    """``theme/`` 目录"""
    meta: Any
    """清单的 ``[theme]`` 段（packages._Theme）"""
    incompatible: str | None
    """契约不兼容的原因；兼容为 None"""

    @property
    def has_js(self) -> bool:
        return (self.root / JS_NAME).is_file()

    @property
    def revision(self) -> str:
        """缓存版本号：清单版本 + 主题文件的修改戳。随带主题开发时改了文件、不升版本也能换新。"""
        parts = [self.version]
        for name in (CSS_NAME, JS_NAME):
            path = self.root / name
            if path.is_file():
                stat = path.stat()
                parts.append(f"{stat.st_mtime_ns}:{stat.st_size}")
        digest = hashlib.sha1("|".join(parts).encode()).hexdigest()[:10]  # noqa: S324 -- 只做缓存键
        return f"{self.version}-{digest}"


#: 已安装包的清单缓存：按文件修改戳，每个静态文件请求都要查一次目录
_manifest_cache: dict[Path, tuple[tuple[int, int], pkg.Manifest | None]] = {}


def _manifest(directory: Path) -> pkg.Manifest | None:
    path = directory / pkg.MANIFEST
    try:
        stat = path.stat()
    except OSError:
        return None
    key = (stat.st_mtime_ns, stat.st_size)
    cached = _manifest_cache.get(path)
    if cached is not None and cached[0] == key:
        return cached[1]
    try:
        manifest: pkg.Manifest | None = pkg.Manifest.model_validate(
            tomllib.loads(path.read_text("utf-8"))
        )
    except Exception:  # noqa: BLE001 -- 装好的包清单坏了：当它不是主题，别让整个目录挂掉
        logger.exception("插件包清单读不出来：%s", path)
        manifest = None
    _manifest_cache[path] = (key, manifest)
    return manifest


def _theme(
    manifest: pkg.Manifest | None, directory: Path, source: Any, version: str
) -> Theme | None:
    from movieclaw_kernel.contracts import check_requires

    if manifest is None or manifest.theme is None:
        return None
    root = directory / THEME_DIR
    if not (root / CSS_NAME).is_file():
        return None
    import movieclaw_sdk.theme  # noqa: F401  # 登记 ui.theme 契约

    return Theme(
        id=manifest.plugin.id,
        title=manifest.plugin.title,
        version=version,
        source=source,
        root=root,
        meta=manifest.theme,
        incompatible=check_requires(manifest.requires, third_party=source == "package"),
    )


def _disabled(entry_id: str, kernel: Any) -> bool:
    from movieclaw_kernel import State

    fiber = kernel.fiber(entry_id) if kernel is not None else None
    return fiber is not None and fiber.state == State.DISABLED


def themes(settings: object, kernel: Any) -> list[Theme]:
    """当前可用的主题（含契约不兼容、待更新的）。每次现读盘：装卸、停用、开发时改文件即时生效。"""
    from movieclaw_api.plugins import safe_mode
    from movieclaw_api.plugins.bundled import bundled, canonical
    from movieclaw_api.services import plugin_switches

    packages = {} if safe_mode.current().active else pkg.installed(settings)
    replaced = {canonical(entry_id) for entry_id in packages}
    removed = plugin_switches.removed_ids(settings)
    found: list[Theme] = []
    for item in bundled().values():
        if item.id in replaced or item.id in removed:
            continue
        theme = _theme(item.manifest, item.path, "bundled", item.manifest.plugin.version)
        if theme is not None:
            found.append(theme)
    for record in packages.values():
        directory = pkg.version_dir(settings, record.id, record.version)
        theme = _theme(_manifest(directory), directory, "package", record.version)
        if theme is not None:
            found.append(theme)
    return [t for t in found if not _disabled(t.id, kernel)]


def find(settings: object, kernel: Any, theme_id: str) -> Theme | None:
    """按 id 找一个主题（与 ``themes`` 同一套取舍）。每个主题文件请求都要查一次，只看这一个，
    不扫整个目录。"""
    from movieclaw_api.plugins import safe_mode
    from movieclaw_api.plugins.bundled import bundled, canonical
    from movieclaw_api.services import plugin_switches

    if _disabled(theme_id, kernel):
        return None
    packages = {} if safe_mode.current().active else pkg.installed(settings)
    record = packages.get(theme_id)
    if record is not None:
        directory = pkg.version_dir(settings, record.id, record.version)
        return _theme(_manifest(directory), directory, "package", record.version)
    item = bundled().get(theme_id)
    if item is None or theme_id in plugin_switches.removed_ids(settings):
        return None
    if theme_id in {canonical(entry_id) for entry_id in packages}:
        return None  # 被旧 id 的同名插件包替换了
    return _theme(item.manifest, item.path, "bundled", item.manifest.plugin.version)


def view(theme: Theme) -> dict[str, Any]:
    """给前端的主题目录项：设置页的选择卡、首帧缓存、加载器都只认这些字段。"""
    meta = theme.meta
    rev = theme.revision
    ok = theme.incompatible is None
    return {
        "id": theme.id,
        "label": meta.label,
        "description": meta.description,
        "preview": {"bg": meta.preview.bg, "accent": meta.preview.accent},
        "theme_color": meta.theme_color,
        "layout": meta.layout,
        "glass": meta.glass,
        "version": theme.version,
        "source": theme.source,
        "status": "ok" if ok else "incompatible",
        "reason": theme.incompatible,
        "css": f"{BASE}/{theme.id}/{CSS_NAME}?v={rev}" if ok else None,
        "script": f"{BASE}/{theme.id}/{JS_NAME}?v={rev}" if ok and theme.has_js else None,
    }


def stylesheet(settings: object, kernel: Any) -> str:
    """聚合样式表：每个可用主题一行 ``@import``（各自的相对 url() 按自己的地址解析，不用改写）。

    所有主题 CSS 都挂在各自的 ``html[data-theme="<id>"]`` 作用域下，一起加载互不影响。
    """
    lines = ["/* MovieClaw 网页主题（docs/design/theme-plugins.md §4.3） */"]
    for theme in themes(settings, kernel):
        if theme.incompatible is None:
            lines.append(f'@import url("{BASE}/{theme.id}/{CSS_NAME}?v={theme.revision}");')
    return "\n".join(lines) + "\n"


def resolve_file(theme: Theme, sub: str) -> Path | None:
    """``theme/`` 下的子路径 → 文件；越界（``..``、软链指出去）返回 None。"""
    parts = [p for p in sub.split("/") if p]
    if not parts or any(p in (".", "..") or "\\" in p or "\x00" in p for p in parts):
        return None
    base = theme.root.resolve()
    target = theme.root.joinpath(*parts).resolve()
    if not target.is_relative_to(base) or not target.is_file():
        return None
    return target
