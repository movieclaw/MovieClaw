"""插件网页（docs/design/plugin-web-pages.md）。

插件包 / 本地插件目录里有 ``web/index.html`` 就带网页。网页以**授信模式**运行：主程序在
``/apps/<插件 id>/`` 用同源 iframe 嵌进外框，页面用 ``fetch`` 直接调现有接口、以当前查看者的
身份运行。
用户同意过（插件包在批准时、本地插件单独确认一次）才托管、才出现在侧边栏。

侧边栏入口只认 W3C Web App Manifest 的几个标准字段（``web/manifest.webmanifest``，可选）::

    short_name / name   → 侧边栏文字
    icons               → 图标（purpose 含 monochrome 的按遮罩着色）
    start_url           → 主入口落点
    shortcuts[]         → 侧边栏里的其他项

这里只管「哪些插件有网页、谁看得见、文件在哪、入口长什么样」；托管与列表接口在
``api/routes/plugin_web.py`` 和 ``api/routes/ui.py``。
"""

from __future__ import annotations

import json
import logging
import os
import re
import secrets
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urljoin, urlsplit

logger = logging.getLogger("movieclaw_api.plugin_web")

WEB_DIR = "web"
INDEX = "index.html"
#: 按顺序找 manifest：规范推荐 .webmanifest，.json 是常见写法
MANIFEST_NAMES = ("manifest.webmanifest", "manifest.json")
MAX_MANIFEST_BYTES = 64 * 1024
MAX_SHORTCUTS = 8
#: 本地插件的网页确认记录（插件包的同意记在安装记录里）
LOCAL_CONSENT_FILE = "plugins/web-pages.json"
#: 侧边栏文字上限：超出由前端省略；这里只防脏数据
MAX_LABEL = 40


def base_path(entry_id: str) -> str:
    """iframe 实际加载的地址前缀（manifest 里的相对地址按它解析）。"""
    return f"/api/v1/plugins/{entry_id}/web/"


# ---------------------------------------------------------------------- 同意
@dataclass(frozen=True)
class Consent:
    nav: bool = True
    """加到侧边栏"""
    members: bool = False
    """成员也能看到（管理员总能看到）"""

    def record(self) -> dict[str, Any]:
        return {"nav": self.nav, "members": self.members}

    @classmethod
    def parse(cls, raw: Any) -> Consent | None:
        if not isinstance(raw, dict):
            return None
        return cls(nav=bool(raw.get("nav", True)), members=bool(raw.get("members", False)))


def _consent_path(settings: object) -> Path:
    return Path(getattr(settings, "data_dir", "./data")) / LOCAL_CONSENT_FILE


def read_local_consents(settings: object) -> dict[str, Consent]:
    try:
        data = json.loads(_consent_path(settings).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        logger.exception("本地插件网页的确认记录读不出来，按都没确认处理")
        return {}
    found: dict[str, Consent] = {}
    for entry_id, raw in (data.get("pages") or {}).items() if isinstance(data, dict) else ():
        consent = Consent.parse(raw)
        if consent is not None:
            found[entry_id] = consent
    return found


#: 读改写同意记录要串行：两个同时的「同意」不能互相覆盖掉对方
_consent_lock = threading.Lock()


def write_local_consent(settings: object, entry_id: str, consent: Consent | None) -> None:
    """记下（或撤销，``consent=None``）本地插件网页的确认；原子写入。"""
    path = _consent_path(settings)
    with _consent_lock:
        current = {k: v.record() for k, v in read_local_consents(settings).items()}
        if consent is None:
            current.pop(entry_id, None)
        else:
            current[entry_id] = {**consent.record(), "approved_at": time.time()}
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
        text = json.dumps({"pages": current}, ensure_ascii=False, indent=2)
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)


# ---------------------------------------------------------------------- 插件
@dataclass(frozen=True)
class WebPlugin:
    """一个带网页的插件（不论是否已同意）。"""

    id: str
    title: str
    source: str
    """``package`` / ``local``"""
    root: Path
    """``web/`` 目录"""
    consent: Consent | None


def has_web(directory: Path) -> bool:
    return (directory / WEB_DIR / INDEX).is_file()


#: 本地插件条目（plugins.yaml）的缓存：文件没变就不重新解析。每个静态文件请求都要查一次，
#: 而解析时格式不对会打告警——不缓存的话一个页面几十个资源就是几十条重复告警
_local_cache: dict[str, tuple[tuple[int, int], list[tuple[str, str, bool]]]] = {}


def _local_entries(settings: object) -> list[tuple[str, str, bool]]:
    """``plugins.yaml`` 里开启的本地插件 → ``(条目 id, 目录名, 是否关掉)``。

    不用 ``local_specs``：它会顺带登记插件事件（有副作用），是给启动加载用的。目录名的规则与它一致。
    """
    from movieclaw_api.plugins.local import default_module
    from movieclaw_api.plugins.manifest import patch_file, read_patch_items

    path = patch_file(settings)
    try:
        stat = path.stat()
    except OSError:
        return []
    key = (stat.st_mtime_ns, stat.st_size)
    cached = _local_cache.get(str(path))
    if cached is not None and cached[0] == key:
        return cached[1]
    found: list[tuple[str, str, bool]] = []
    for item in read_patch_items(settings):
        if item.get("local") is not True:
            continue
        module = item.get("module") or default_module(item["id"])
        command = item.get("command")
        if item.get("runtime") == "exec" and isinstance(command, str) and "/" in command:
            module = command.split("/", 1)[0]
        if isinstance(module, str) and module and "/" not in module and module not in (".", ".."):
            found.append((item["id"], module, bool(item.get("disabled", False))))
    _local_cache[str(path)] = (key, found)
    return found


def web_plugins(settings: object) -> list[WebPlugin]:
    """全部带网页的插件包与本地插件（每次现读盘：本地插件改了文件、加了网页不用重启）。"""
    from movieclaw_api.plugins import packages as pkg
    from movieclaw_api.plugins.local import plugins_dir

    found: list[WebPlugin] = []
    for record in pkg.installed(settings).values():
        directory = pkg.version_dir(settings, record.id, record.version)
        if has_web(directory):
            found.append(
                WebPlugin(
                    id=record.id,
                    title=record.title,
                    source=pkg.SOURCE,
                    root=directory / WEB_DIR,
                    consent=Consent.parse(record.web),
                )
            )
    consents = read_local_consents(settings)
    local_root = plugins_dir(settings)
    for entry_id, module, disabled in _local_entries(settings):
        # 只有包形式（目录）的本地插件能带网页；exec 插件的 module 就是它的目录
        directory = local_root / module
        if disabled or not has_web(directory):
            continue
        found.append(
            WebPlugin(
                id=entry_id,
                title=entry_id,
                source="local",
                root=directory / WEB_DIR,
                consent=consents.get(entry_id),
            )
        )
    return found


def find(settings: object, entry_id: str) -> WebPlugin | None:
    return next((p for p in web_plugins(settings) if p.id == entry_id), None)


def _blocked(entry_id: str, kernel: Any) -> bool:
    """安全模式下全部不渲染；被停用（插件页的开关、plugins.yaml）的也不渲染。"""
    from movieclaw_api.plugins import safe_mode
    from movieclaw_kernel import State

    mode = safe_mode.current()
    if mode.active:
        return True
    fiber = kernel.fiber(entry_id) if kernel is not None else None
    return fiber is not None and fiber.state == State.DISABLED


def visible_to(plugin: WebPlugin, principal: Any, kernel: Any) -> bool:
    if plugin.consent is None or _blocked(plugin.id, kernel):
        return False
    return bool(principal.is_admin or plugin.consent.members)


# ---------------------------------------------------------------------- manifest
@dataclass(frozen=True)
class NavEntry:
    label: str
    path: str
    """相对 ``web/`` 的子路径（主入口通常是空串）"""
    icon: str | None = None
    """图标地址（iframe 的托管地址，带登录可取）"""
    monochrome: bool = False


@dataclass(frozen=True)
class AppManifest:
    name: str
    entries: list[NavEntry] = field(default_factory=list)


def _read_manifest(root: Path) -> tuple[dict[str, Any] | None, str | None]:
    for name in MANIFEST_NAMES:
        path = root / name
        if not path.is_file():
            continue
        try:
            if path.stat().st_size > MAX_MANIFEST_BYTES:
                raise ValueError(f"超过 {MAX_MANIFEST_BYTES // 1024} KB")
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            logger.warning("插件网页的 %s 读不出来，按没有 manifest 处理：%s", path, exc)
            return None, name
        return (data if isinstance(data, dict) else None), name
    return None, None


def _in_scope(base: str, manifest_url: str, value: Any) -> str | None:
    """按标准规则（相对 manifest 地址）解析 URL，返回相对 ``web/`` 的子路径；越出范围返回 None。"""
    if not isinstance(value, str):
        return None
    resolved = urlsplit(urljoin(manifest_url, value.strip()))
    if resolved.scheme or resolved.netloc or not resolved.path.startswith(base):
        return None
    sub = resolved.path[len(base) :]
    if resolved.query:
        sub = f"{sub}?{resolved.query}"
    return sub


def _label(raw: dict[str, Any], fallback: str) -> str:
    for key in ("short_name", "name"):
        value = raw.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()[:MAX_LABEL]
    return fallback[:MAX_LABEL]


def _icon(base: str, manifest_url: str, icons: Any) -> tuple[str | None, bool]:
    """挑图标：purpose 含 monochrome 的优先（SVG 再优先），否则用第一个 any 图标。"""
    if not isinstance(icons, list):
        return None, False
    candidates: list[tuple[int, str, bool]] = []
    for icon in icons:
        if not isinstance(icon, dict):
            continue
        sub = _in_scope(base, manifest_url, icon.get("src"))
        if sub is None:
            continue
        purposes = str(icon.get("purpose") or "any").split()
        svg = str(icon.get("type") or "").endswith("svg") or sub.lower().endswith(".svg")
        if "monochrome" in purposes:
            candidates.append((0 if svg else 1, sub, True))
        elif "any" in purposes:
            candidates.append((2 if svg else 3, sub, False))
    if not candidates:
        return None, False
    _, sub, monochrome = min(candidates, key=lambda c: c[0])
    return base + sub, monochrome


def read_manifest(plugin: WebPlugin) -> AppManifest:
    """入口描述：没有 manifest 就是一项主入口（文字用插件名，图标交给前端兜底）。"""
    base = base_path(plugin.id)
    raw, name = _read_manifest(plugin.root)
    if raw is None:
        return AppManifest(name=plugin.title, entries=[NavEntry(label=plugin.title, path="")])
    manifest_url = base + (name or MANIFEST_NAMES[0])
    icon, monochrome = _icon(base, manifest_url, raw.get("icons"))
    start = _in_scope(base, manifest_url, raw.get("start_url", "."))
    title = _label(raw, plugin.title)
    entries = [NavEntry(label=title, path=start or "", icon=icon, monochrome=monochrome)]
    shortcuts = raw.get("shortcuts")
    for item in shortcuts[:MAX_SHORTCUTS] if isinstance(shortcuts, list) else ():
        if not isinstance(item, dict):
            continue
        path = _in_scope(base, manifest_url, item.get("url"))
        if path is None:
            logger.info("插件 %s 的 shortcuts 有一项地址越出 web/，已忽略", plugin.id)
            continue
        own_icon, own_mono = _icon(base, manifest_url, item.get("icons"))
        entries.append(
            NavEntry(
                label=_label(item, title),
                path=path,
                icon=own_icon or icon,
                monochrome=own_mono if own_icon else monochrome,
            )
        )
    name_value = raw.get("name")
    full_name = name_value.strip() if isinstance(name_value, str) and name_value.strip() else title
    return AppManifest(name=full_name[:MAX_LABEL], entries=entries)


def app_view(plugin: WebPlugin) -> dict[str, Any]:
    manifest = read_manifest(plugin)
    consent = plugin.consent or Consent()
    return {
        "id": plugin.id,
        "name": manifest.name,
        "source": plugin.source,
        "nav": consent.nav,
        "members": consent.members,
        "base": base_path(plugin.id),
        "entries": [
            {
                "label": e.label,
                "path": e.path,
                "icon": e.icon,
                "monochrome": e.monochrome,
            }
            for e in manifest.entries
        ],
    }


def visible_apps(settings: object, principal: Any, kernel: Any) -> list[dict[str, Any]]:
    return [app_view(p) for p in web_plugins(settings) if visible_to(p, principal, kernel)]


def pending_preview(directory: Path, entry_id: str, title: str) -> dict[str, Any] | None:
    """待批准的包：给批准页预览入口（图标此时还没托管，SVG 小图直接内嵌成 data URL）。"""
    if not has_web(directory):
        return None
    plugin = WebPlugin(
        id=entry_id, title=title, source="package", root=directory / WEB_DIR, consent=None
    )
    view = app_view(plugin)
    base = base_path(entry_id)
    for entry in view["entries"]:
        icon = entry.pop("icon")
        entry["icon"] = _inline_svg(plugin.root, icon[len(base) :]) if icon else None
    view.pop("nav")
    view.pop("members")
    return view


def _inline_svg(root: Path, sub: str) -> str | None:
    import base64

    path = resolve_file(root, sub.partition("?")[0])
    if path is None or path.suffix.lower() != ".svg" or path.stat().st_size > 32 * 1024:
        return None
    return "data:image/svg+xml;base64," + base64.b64encode(path.read_bytes()).decode("ascii")


# ---------------------------------------------------------------------- 文件
def resolve_file(root: Path, sub: str) -> Path | None:
    """``web/`` 下的子路径 → 文件；目录取其中的 index.html；越界（``..``、软链指出去）返回 None。"""
    parts = [p for p in sub.split("/") if p]
    if any(p in (".", "..") or "\\" in p or "\x00" in p for p in parts):
        return None
    base = root.resolve()
    target = (root.joinpath(*parts) if parts else root).resolve()
    if target.is_dir():
        target = (target / INDEX).resolve()
    if not target.is_relative_to(base) or not target.is_file():
        return None
    return target


# ---------------------------------------------------------------------- 报错
#: 每个插件每分钟最多记这么多条页面报错：页面里写了死循环报错也不能刷爆日志
ERRORS_PER_MINUTE = 20
_error_window: dict[str, tuple[float, int]] = {}


def log_page_error(entry_id: str, who: str, message: str, detail: str) -> bool:
    """记一条插件页面的报错；超出频率上限的丢掉（每个窗口只提示一次）。返回是否记下。"""
    now = time.monotonic()
    start, count = _error_window.get(entry_id, (now, 0))
    if now - start >= 60:
        start, count = now, 0
    count += 1
    _error_window[entry_id] = (start, count)
    if count > ERRORS_PER_MINUTE:
        if count == ERRORS_PER_MINUTE + 1:
            logger.warning("插件 %s 的页面报错太频繁，这一分钟里后面的不再记录", entry_id)
        return False
    # 报错内容来自浏览器（成员也能发）：消息压成一行、出处逐行缩进，不让它在日志里伪造出新的一行
    one_line = _CONTROL.sub(" ", message).strip()
    lines = [f"    {_CONTROL.sub(' ', line)}" for line in detail.splitlines() if line.strip()]
    where = "".join(f"\n{line}" for line in lines)
    logger.warning("插件 %s 的页面报错（%s 打开时）：%s%s", entry_id, who, one_line, where)
    return True


_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
