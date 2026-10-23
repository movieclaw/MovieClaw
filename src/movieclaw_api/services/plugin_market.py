"""插件市场：从 movieclaw-plugins 的签名索引浏览、安装插件。

索引格式见该仓库的 index.schema.json（schema 2）。

信任链：

- 索引 ``index.json`` 旁边是 ``index.json.sig``（Ed25519，签原始字节），公钥随应用发布
  （``CATALOG_KEYS``）。没签名、签名不对、密钥不认识一律不加载；只有自建索引可以用
  ``PLUGIN_CATALOG_ALLOW_UNSIGNED`` 放行。
- 插件包、README、依赖锁文件、图标、截图都按索引里的 sha256 与字节数核对，所以下载可以走
  ``UPDATE_DOWNLOAD_MIRROR`` 加速镜像（与应用内更新同一个设置）。
- 只下载索引里登记的地址。核对通过的包交给 ``PackageManager.upload``：之后的批准、依赖、
  宽限期回滚与上传安装完全一样，市场不另开安装通道，也从不跳过批准。

索引在本地持久缓存（cache_entry 表）：30 分钟内直接用；过期就回源，回源失败时 7 天内的旧索引
照用并标出「上次检查失败」。签名过的旧索引不会盖掉更新的（按 generated_at 比较），防回放。
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import json
import logging
import re
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlsplit

import httpx

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins import packages as pkg

logger = logging.getLogger("movieclaw_api.plugin_market")

SCHEMA = 2
#: 索引签名公钥：key_id → base64 的 32 字节 Ed25519 公钥。换密钥时先在这里加新公钥并发版，
#: 插件仓库再换 RELEASE_SIGNING_KEY；旧公钥等不再有人用旧索引后删掉。
CATALOG_KEYS: dict[str, str] = {
    "catalog-1": "APwjAgU0ugHlXrjbkRb7RwgYupgnEtXQvo8gOiEbp7E=",
}
CACHE_NAMESPACE = "plugin_market"
FRESH_SECONDS = 30 * 60
STALE_SECONDS = 7 * 24 * 3600
INDEX_MAX_BYTES = 4 * 1024 * 1024
README_MAX_BYTES = 512 * 1024
LOCK_MAX_BYTES = 1024 * 1024
IMAGE_MAX_BYTES = 256 * 1024
SCREENSHOT_MAX_BYTES = 2 * 1024 * 1024
IMAGE_TYPES = {
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".webp": "image/webp",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
}
_TIMEOUT = httpx.Timeout(30.0, connect=15.0)
_MIRRORED_HOSTS = {"github.com", "raw.githubusercontent.com", "objects.githubusercontent.com"}


class MarketError(Exception):
    """市场操作失败：消息直接给用户看。``status`` 决定接口返回 4xx 还是 503。"""

    def __init__(self, message: str, *, status: int = 400) -> None:
        super().__init__(message)
        self.message = message
        self.status = status


def _transport() -> httpx.AsyncBaseTransport:
    """出口 transport（测试替换成 MockTransport）。"""
    from movieclaw_net import egress_transport

    return egress_transport("github", use_breaker=False)


transport_factory: Callable[[], httpx.AsyncBaseTransport] = _transport


# ---------------------------------------------------------------------- 版本号
def version_key(version: str) -> tuple:
    """semver 优先级（越大越新）：正式版排在同号预发布之后，预发布标识按数字比较。"""
    core, _, pre = version.split("+", 1)[0].partition("-")
    try:
        major, minor, patch = (int(part) for part in core.split("."))
    except ValueError:
        return (0, 0, 0, 0, ())
    if not pre:
        return (major, minor, patch, 1, ())
    idents = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
    return (major, minor, patch, 0, idents)


def is_prerelease(version: str) -> bool:
    return "-" in version.split("+", 1)[0]


# ---------------------------------------------------------------------- 下载
def _mirrored(url: str) -> str:
    mirror = get_settings().update_download_mirror.strip()
    if not mirror or urlsplit(url).hostname not in _MIRRORED_HOSTS:
        return url
    return mirror.rstrip("/") + "/" + url


def _network_error(what: str, exc: Exception) -> MarketError:
    return MarketError(
        f"{what}失败：连不上 GitHub（{exc.__class__.__name__}）。"
        "可以在「设置 → 网络与代理」给 GitHub 配代理，或配置下载加速镜像后重试",
        status=503,
    )


async def _fetch(
    url: str, *, limit: int, what: str, mirror: bool = True, overflow: str | None = None
) -> bytes | None:
    """GET 一个地址，超过 ``limit`` 字节就停（报 ``overflow``）。

    404 返回 None，其余失败抛 MarketError。
    """
    target = _mirrored(url) if mirror else url
    try:
        async with (
            httpx.AsyncClient(
                transport=transport_factory(),
                timeout=_TIMEOUT,
                follow_redirects=True,
                headers={"User-Agent": "MovieClaw plugin market"},
            ) as client,
            client.stream("GET", target) as resp,
        ):
            if resp.status_code == 404:
                return None
            resp.raise_for_status()
            chunks: list[bytes] = []
            total = 0
            async for chunk in resp.aiter_bytes():
                total += len(chunk)
                if total > limit:
                    raise MarketError(overflow or f"{what}超过 {max(limit // 1024, 1)} KB，已放弃")
                chunks.append(chunk)
            return b"".join(chunks)
    except httpx.HTTPStatusError as exc:
        raise MarketError(
            f"{what}失败：GitHub 返回 {exc.response.status_code}", status=503
        ) from exc
    except httpx.HTTPError as exc:
        raise _network_error(what, exc) from exc


async def _fetch_asset(
    asset: dict[str, Any], *, limit: int, what: str, cache: bool = True
) -> bytes:
    """按索引里的 {url, sha256, size} 下载并核对。``cache``：核对过的内容按 sha256 永久缓存
    （README、锁文件、图标；插件包本身不缓存，装上就有一份）。"""
    from movieclaw_db.stores import SqlCacheStore

    sha = str(asset.get("sha256") or "")
    size = asset.get("size")
    if not re.fullmatch(r"[0-9a-f]{64}", sha) or not isinstance(size, int) or size > limit:
        raise MarketError(f"索引里{what}的记录不完整或过大")
    store = SqlCacheStore()
    key = f"asset:{sha}"
    hit = None
    if cache:
        try:
            hit = await store.get(CACHE_NAMESPACE, key)
        except Exception:  # noqa: BLE001 — 缓存坏了就回源，不影响功能
            hit = None
    if hit is not None:
        return base64.b64decode(hit.payload)
    mismatch = f"下载的{what}与索引里的校验值不一致，已丢弃（可能被镜像篡改）"
    data = await _fetch(str(asset["url"]), limit=size, what=f"下载{what}", overflow=mismatch)
    if data is None:
        raise MarketError(f"下载{what}失败：地址已失效（404）", status=503)
    if len(data) != size or hashlib.sha256(data).hexdigest() != sha:
        raise MarketError(mismatch)
    if not cache:
        return data
    try:
        await store.set(CACHE_NAMESPACE, key, base64.b64encode(data).decode())
    except Exception:  # noqa: BLE001
        logger.warning("插件市场：缓存 %s 失败", what, exc_info=True)
    return data


# ---------------------------------------------------------------------- 索引
@dataclass
class Catalog:
    url: str
    document: dict[str, Any]
    fetched_at: datetime
    """这份索引是什么时候取到的（naive UTC）。"""
    error: str | None = None
    """回源失败时用的是旧索引：上次失败的原因。"""

    @property
    def plugins(self) -> list[dict[str, Any]]:
        return [p for p in self.document.get("plugins") or [] if isinstance(p, dict)]

    def plugin(self, plugin_id: str) -> dict[str, Any] | None:
        return next((p for p in self.plugins if p.get("id") == plugin_id), None)


def _verify(raw: bytes, sig: bytes | None) -> dict[str, Any]:
    """解析并验签；不合格抛 MarketError。"""
    try:
        document = json.loads(raw)
    except (UnicodeError, ValueError) as exc:
        raise MarketError("插件索引不是合法的 JSON，已拒绝加载") from exc
    if not isinstance(document, dict):
        raise MarketError("插件索引格式不对，已拒绝加载")
    schema = document.get("schema")
    if schema != SCHEMA:
        raise MarketError(
            f"插件索引是 schema {schema}，这个版本的 MovieClaw 只认 schema {SCHEMA}"
            + ("，请更新 MovieClaw" if isinstance(schema, int) and schema > SCHEMA else "")
        )
    if not document.get("signed"):
        if get_settings().plugin_catalog_allow_unsigned:
            return document
        raise MarketError("插件索引没有签名，已拒绝加载")
    key_id = str(document.get("key_id") or "")
    public = CATALOG_KEYS.get(key_id)
    if public is None:
        raise MarketError(
            f"插件索引用的签名密钥 {key_id or '（未写）'} 本机不认识，请更新 MovieClaw"
        )
    if sig is None:
        raise MarketError("插件索引声明了签名，但没有找到 index.json.sig，已拒绝加载")
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    try:
        Ed25519PublicKey.from_public_bytes(base64.b64decode(public)).verify(
            base64.b64decode(sig.strip()), raw
        )
    except (InvalidSignature, binascii.Error, ValueError) as exc:
        raise MarketError("插件索引的签名校验失败，内容可能被篡改，已拒绝加载") from exc
    return document


def _now() -> datetime:
    return datetime.now(UTC).replace(tzinfo=None)


_lock = asyncio.Lock()
_memory: dict[str, Catalog] = {}


def reset_for_tests() -> None:
    _memory.clear()


async def _download_catalog(url: str) -> tuple[bytes, dict[str, Any]]:
    allow_unsigned = get_settings().plugin_catalog_allow_unsigned
    # 允许未签名时，镜像能同时伪造索引和包：索引只直连
    raw = await _fetch(url, limit=INDEX_MAX_BYTES, what="获取插件索引", mirror=not allow_unsigned)
    if raw is None:
        raise MarketError("插件索引地址不存在（404）", status=503)
    sig = await _fetch(url + ".sig", limit=4096, what="获取插件索引签名", mirror=not allow_unsigned)
    return raw, _verify(raw, sig)


async def load_catalog(*, refresh: bool = False) -> Catalog:
    """当前可用的索引。``refresh`` = 用户点了「检查更新」：不看新鲜期，直接回源。"""
    from movieclaw_db.stores import SqlCacheStore

    url = get_settings().plugin_catalog_url
    key = f"catalog:{url}"
    store = SqlCacheStore()
    async with _lock:
        cached = _memory.get(url)
        if cached is None:
            try:
                hit = await store.get(CACHE_NAMESPACE, key)
            except Exception:  # noqa: BLE001
                hit = None
            if hit is not None:
                try:
                    stored = json.loads(hit.payload)
                    cached = Catalog(url, stored["document"], hit.fetched_at)
                except (ValueError, KeyError, TypeError):
                    cached = None
        age = (_now() - cached.fetched_at).total_seconds() if cached else None
        if cached is not None and not refresh and age is not None and age < FRESH_SECONDS:
            _memory[url] = cached
            return cached
        try:
            _raw, document = await _download_catalog(url)
        except MarketError as exc:
            if cached is not None and age is not None and age < STALE_SECONDS:
                logger.warning(
                    "插件市场：更新索引失败，沿用 %s 的旧索引：%s", cached.fetched_at, exc
                )
                stale = Catalog(url, cached.document, cached.fetched_at, error=exc.message)
                _memory[url] = stale
                return stale
            raise
        if cached is not None and str(document.get("generated_at", "")) < str(
            cached.document.get("generated_at", "")
        ):
            # 拿到的比手里的旧（镜像缓存或回放）：不倒退
            logger.warning("插件市场：取到的索引比已有的旧，忽略")
            document = cached.document
        fresh = Catalog(url, document, _now())
        try:
            await store.set(CACHE_NAMESPACE, key, json.dumps({"document": document}))
        except Exception:  # noqa: BLE001
            logger.warning("插件市场：缓存索引失败", exc_info=True)
        _memory[url] = fresh
        return fresh


# ---------------------------------------------------------------------- 兼容性与状态
def _artifact(version: dict[str, Any]) -> dict[str, Any] | None:
    here = pkg.current_platform()
    artifacts = [a for a in version.get("artifacts") or [] if isinstance(a, dict)]
    return next((a for a in artifacts if a.get("platform") == here), None) or next(
        (a for a in artifacts if a.get("platform") == "any"), None
    )


def incompatibility(version: dict[str, Any], operations: set[str]) -> str | None:
    """这台服务器装不了这个版本的原因；能装返回 None。与 ``pkg.check_compat`` 同一套规则。"""
    from movieclaw_kernel.contracts import Version, check_requires, satisfies
    from movieclaw_sdk import SDK_VERSION

    if version.get("runtime") not in ("process", "inline", "exec"):
        return f"运行方式 {version.get('runtime')} 本机不支持，请更新 MovieClaw"
    try:
        if not satisfies(str(version.get("sdk") or "^1.0"), Version.parse(SDK_VERSION)):
            return f"需要 SDK {version.get('sdk')}，本机是 {SDK_VERSION}"
    except ValueError:
        return f"SDK 版本要求写法不对：{version.get('sdk')}"
    requires = version.get("requires") or {}
    if isinstance(requires, dict):
        reason = check_requires({str(k): str(v) for k, v in requires.items()}, third_party=True)
        if reason:
            return f"需要更新 MovieClaw：{reason}"
    from movieclaw_sdk.agent import PERMISSION_PREFIX

    for op in (version.get("permissions") or {}).get("operations") or []:
        if op.startswith(PERMISSION_PREFIX):
            continue
        known = (
            any(o.startswith(op[:-1]) for o in operations)
            if op.endswith(".*")
            else op in operations
        )
        if not known:
            return f"需要更新 MovieClaw：本机没有宿主操作 {op}"
    if _artifact(version) is None:
        return f"没有适用于这台服务器（{pkg.current_platform()}）的安装包"
    return None


def _installed(plugin_id: str, kernel: Any, settings: object) -> dict[str, Any] | None:
    from movieclaw_api.plugins.bundled import bundled
    from movieclaw_api.services import plugin_switches

    record = pkg.installed(settings).get(plugin_id)
    fiber = kernel.fiber(plugin_id) if kernel is not None else None
    if record is not None:
        return {
            "version": record.version,
            "source": "package",
            "state": fiber.state.value if fiber else "unloaded",
            "previous_version": (record.previous or {}).get("version"),
        }
    package = bundled().get(plugin_id)
    if package is not None and plugin_id not in plugin_switches.read_switches(settings).removed:
        return {
            "version": package.manifest.plugin.version,
            "source": "bundled",
            "state": fiber.state.value if fiber else "unloaded",
            "previous_version": None,
        }
    return None


def _recommended(versions: list[dict[str, Any]], installed: str | None) -> dict[str, Any] | None:
    """该给用户的那一版：能装、没撤回的最新版。装着测试版、或一个正式版都没有时才推测试版。"""
    usable = [v for v in versions if v["compatible"] and not v["yanked"]]
    stable = [v for v in usable if not v["prerelease"]]
    if installed is not None and is_prerelease(installed):
        return usable[0] if usable else None
    return stable[0] if stable else (usable[0] if usable else None)


def _version_view(version: dict[str, Any], operations: set[str]) -> dict[str, Any]:
    artifact = _artifact(version)
    reason = incompatibility(version, operations)
    deps = version.get("dependencies")
    permissions = version.get("permissions") or {}
    return {
        "version": str(version.get("version")),
        "prerelease": bool(version.get("prerelease")),
        "released_at": version.get("released_at"),
        "yanked": (version.get("yanked") or {}).get("reason") if version.get("yanked") else None,
        "notes": str(version.get("notes") or ""),
        "changelog_url": version.get("changelog_url"),
        "source_url": version.get("source_url"),
        "runtime": version.get("runtime"),
        "requires": version.get("requires") or {},
        "permissions": {
            "operations": list(permissions.get("operations") or []),
            "paths": list(permissions.get("paths") or []),
            "network": bool(permissions.get("network")),
            "callbacks": list(permissions.get("callbacks") or []),
            "events": list(permissions.get("events") or []),
        },
        "web": bool(version.get("web")),
        "dependencies": (
            [
                {
                    "name": p.get("name"),
                    "version": p.get("version"),
                    "native": bool(p.get("native")),
                }
                for p in deps.get("packages") or []
            ]
            if isinstance(deps, dict)
            else []
        ),
        "size": artifact.get("size") if artifact else None,
        "compatible": reason is None,
        "incompatible_reason": reason,
    }


def _icon_url(plugin: dict[str, Any]) -> str | None:
    icon = plugin.get("icon")
    if not isinstance(icon, dict) or not icon.get("sha256"):
        return None
    # 带上内容哈希：图标换了地址就变，浏览器可以放心长缓存
    return f"/api/v1/app/plugins/market/{plugin['id']}/icon?v={str(icon['sha256'])[:12]}"


def _download_count(value: Any) -> int | None:
    """累计下载次数。缺、写错、负数都当没有，一条坏数据不拖垮整个市场。"""
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _http_url(value: Any) -> str | None:
    """只要 http(s) 地址。空串、相对路径和 javascript: 不当链接用。"""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    parts = urlsplit(text)
    if parts.scheme not in {"http", "https"} or not parts.netloc:
        return None
    return text


def _image_type(asset: dict[str, Any]) -> str | None:
    suffix = "." + str(asset.get("url", "")).rsplit(".", 1)[-1].lower()
    return IMAGE_TYPES.get(suffix)


def _usable_screenshot(shot: Any) -> dict[str, Any] | None:
    """能代理的截图：有校验值、声明的大小在限额内、格式是图片。"""
    if not isinstance(shot, dict):
        return None
    sha = str(shot.get("sha256") or "")
    size = shot.get("size")
    if (
        isinstance(size, bool)
        or not isinstance(size, int)
        or size <= 0
        or size > SCREENSHOT_MAX_BYTES
        or not re.fullmatch(r"[0-9a-f]{64}", sha)
        or _image_type(shot) is None
    ):
        return None
    return shot


def _screenshot_urls(plugin: dict[str, Any]) -> list[str]:
    """截图走本服务器代理（和标图标同一条核对链）。不合格的不出现在列表里。"""
    shots = plugin.get("screenshots")
    if not isinstance(shots, list):
        return []
    plugin_id = plugin.get("id")
    urls: list[str] = []
    for index, shot in enumerate(shots):
        usable = _usable_screenshot(shot)
        if usable is None:
            continue
        sha = str(usable["sha256"])
        urls.append(f"/api/v1/app/plugins/market/{plugin_id}/screenshots/{index}?v={sha[:12]}")
    return urls


def plugin_view(
    plugin: dict[str, Any],
    *,
    kernel: Any,
    settings: object,
    reserved: set[str],
    operations: set[str],
) -> dict[str, Any]:
    plugin_id = str(plugin["id"])
    versions = sorted(
        (_version_view(v, operations) for v in plugin.get("versions") or [] if isinstance(v, dict)),
        key=lambda v: version_key(v["version"]),
        reverse=True,
    )
    installed = _installed(plugin_id, kernel, settings)
    blocked = (
        "已有同 id 的内置插件或本地插件，不能安装"
        if plugin_id in reserved and installed is None
        else None
    )
    recommended = (
        None if blocked else _recommended(versions, installed["version"] if installed else None)
    )
    update = None
    if (
        installed is not None
        and recommended is not None
        and version_key(recommended["version"]) > version_key(installed["version"])
    ):
        update = recommended["version"]
    if installed is not None:
        mine = next((v for v in versions if v["version"] == installed["version"]), None)
        installed = {**installed, "yanked": mine["yanked"] if mine else None}
    author = plugin.get("author") if isinstance(plugin.get("author"), dict) else {}
    return {
        "id": plugin_id,
        "name": str(plugin.get("name") or plugin_id),
        "summary": str(plugin.get("summary") or ""),
        "description": str(plugin.get("description") or ""),
        "category": str(plugin.get("category") or "tools"),
        "author": {"name": str(author.get("name") or ""), "url": author.get("url")},
        "homepage": plugin.get("homepage"),
        "repository": plugin.get("repository"),
        "feedback_url": _http_url(plugin.get("feedback_url")),
        "downloads": _download_count(plugin.get("downloads")),
        "screenshots": _screenshot_urls(plugin),
        "license": str(plugin.get("license") or ""),
        "icon_url": _icon_url(plugin),
        "deprecated": plugin.get("deprecated"),
        "latest": plugin.get("latest"),
        "recommended": recommended["version"] if recommended else None,
        "installed": installed,
        "update": update,
        "blocked": blocked,
        "versions": versions,
    }


def _context(kernel: Any, settings: object) -> tuple[set[str], set[str]]:
    from movieclaw_api.services.plugin_packages import _operations, _reserved

    return _reserved(kernel, settings), _operations()


def market_view(catalog: Catalog, kernel: Any) -> dict[str, Any]:
    settings = get_settings()
    reserved, operations = _context(kernel, settings)
    plugins = [
        plugin_view(p, kernel=kernel, settings=settings, reserved=reserved, operations=operations)
        for p in catalog.plugins
        if isinstance(p.get("id"), str)
    ]
    document = catalog.document
    return {
        "source": {
            "url": catalog.url,
            "repository": document.get("repository"),
            "generated_at": document.get("generated_at"),
            "signed": bool(document.get("signed")),
            "checked_at": catalog.fetched_at,
            "error": catalog.error,
        },
        "plugins": plugins,
        "updates": sum(1 for p in plugins if p["update"]),
    }


def _find(catalog: Catalog, plugin_id: str) -> dict[str, Any]:
    plugin = catalog.plugin(plugin_id)
    if plugin is None:
        raise MarketError(f"插件市场里没有 {plugin_id}", status=404)
    return plugin


def _raw_version(plugin: dict[str, Any], version: str) -> dict[str, Any]:
    found = next(
        (
            v
            for v in plugin.get("versions") or []
            if isinstance(v, dict) and v.get("version") == version
        ),
        None,
    )
    if found is None:
        raise MarketError(
            f"{plugin.get('name') or plugin.get('id')} 没有 {version} 这个版本", status=404
        )
    return found


async def plugin_detail(
    plugin_id: str, kernel: Any, *, version: str | None = None
) -> dict[str, Any]:
    """详情：列表里的一项，加上所选版本（默认推荐版本）的 README 与这台服务器要下载的依赖。"""
    catalog = await load_catalog()
    plugin = _find(catalog, plugin_id)
    settings = get_settings()
    reserved, operations = _context(kernel, settings)
    view = plugin_view(
        plugin, kernel=kernel, settings=settings, reserved=reserved, operations=operations
    )
    chosen = (
        version
        or view["recommended"]
        or (view["versions"][0]["version"] if view["versions"] else None)
    )
    readme = None
    dependencies = None
    readme_error = None
    if chosen is not None:
        raw = _raw_version(plugin, chosen)
        if isinstance(raw.get("readme"), dict):
            try:
                readme = (
                    await _fetch_asset(raw["readme"], limit=README_MAX_BYTES, what="说明文档")
                ).decode("utf-8", "replace")
            except MarketError as exc:
                readme_error = exc.message
        if isinstance(raw.get("dependencies"), dict) and isinstance(
            raw["dependencies"].get("lock"), dict
        ):
            dependencies = await _dependencies(plugin_id, raw["dependencies"]["lock"], settings)
    return {
        **view,
        "selected": chosen,
        "readme": readme,
        "readme_error": readme_error,
        "dependencies": dependencies,
    }


async def _dependencies(
    plugin_id: str, lock_asset: dict[str, Any], settings: object
) -> dict[str, Any] | None:
    """按这台服务器的平台算出要下载的轮子（与批准页同一份 view）。锁文件取不到时返回 None。"""
    from movieclaw_api.services import plugin_deps
    from movieclaw_sdk import deps

    try:
        text = (await _fetch_asset(lock_asset, limit=LOCK_MAX_BYTES, what="依赖锁文件")).decode(
            "utf-8"
        )
        lock = deps.parse_lock(text)
    except (MarketError, UnicodeError, deps.LockError) as exc:
        logger.warning("插件市场：读 %s 的锁文件失败：%s", plugin_id, exc)
        return None
    current = pkg.installed(settings).get(plugin_id)
    return plugin_deps.view(lock, current.dependencies if current else None)


async def icon(plugin_id: str) -> tuple[bytes, str]:
    catalog = await load_catalog()
    plugin = _find(catalog, plugin_id)
    asset = plugin.get("icon")
    if not isinstance(asset, dict):
        raise MarketError(f"{plugin_id} 没有图标", status=404)
    media = _image_type(asset)
    if media is None:
        raise MarketError("图标格式不支持", status=404)
    return await _fetch_asset(asset, limit=IMAGE_MAX_BYTES, what="图标"), media


async def screenshot(plugin_id: str, index: int) -> tuple[bytes, str]:
    catalog = await load_catalog()
    plugin = _find(catalog, plugin_id)
    shots = plugin.get("screenshots")
    asset = None
    if isinstance(shots, list) and 0 <= index < len(shots):
        asset = _usable_screenshot(shots[index])
    if asset is None:
        raise MarketError(f"{plugin_id} 没有这张截图", status=404)
    media = _image_type(asset)
    assert media is not None  # _usable_screenshot 已检查
    return await _fetch_asset(asset, limit=SCREENSHOT_MAX_BYTES, what="截图"), media


async def download(plugin_id: str, version: str, kernel: Any) -> bytes:
    """下载并核对某一版的插件包；装不了（不兼容、被占用、已撤回）在下载前就拒绝。"""
    catalog = await load_catalog()
    plugin = catalog.plugin(plugin_id)
    if plugin is None or not any(v.get("version") == version for v in plugin.get("versions") or []):
        # 用户可能看的是更新的索引（别的标签页刷新过）：回源一次再找
        catalog = await load_catalog(refresh=True)
        plugin = _find(catalog, plugin_id)
    raw = _raw_version(plugin, version)
    settings = get_settings()
    reserved, operations = _context(kernel, settings)
    view = plugin_view(
        plugin, kernel=kernel, settings=settings, reserved=reserved, operations=operations
    )
    if view["blocked"]:
        raise MarketError(view["blocked"], status=409)
    if (
        view["installed"]
        and view["installed"]["version"] == version
        and view["installed"]["source"] == "package"
    ):
        raise MarketError(f"{view['name']} {version} 已经安装", status=409)
    reason = incompatibility(raw, operations)
    if reason:
        raise MarketError(f"{view['name']} {version} 装不了：{reason}", status=409)
    artifact = _artifact(raw)
    assert artifact is not None  # incompatibility 已检查
    data = await _fetch_asset(
        {
            "url": artifact.get("url"),
            "sha256": artifact.get("sha256"),
            "size": artifact.get("size"),
        },
        limit=pkg.MAX_ARCHIVE_BYTES,
        what="插件包",
        cache=False,
    )
    manifest, _archive = pkg.read_archive(data)
    if manifest.plugin.id != plugin_id or manifest.plugin.version != version:
        raise MarketError(
            f"插件包里是 {manifest.plugin.id} {manifest.plugin.version}，"
            f"与索引的 {plugin_id} {version} 不一致，已丢弃"
        )
    logger.info("插件市场：已下载并核对 %s %s（%d 字节）", plugin_id, version, len(data))
    return data
