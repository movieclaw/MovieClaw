"""Android 手机 / 电视客户端的更新检查与安装包代取。

两个客户端在同一仓库单独发版（tag ``android-vX.Y.Z`` / ``androidtv-vX.Y.Z``），
Release 带一份包信息 JSON（versionCode、sha256、签名证书指纹，见
scripts/build-download-manifest.py）。App 不直接访问 GitHub——电视、国内手机
常常连不上——而是问自己的服务器：服务器沿用应用内更新的 GitHub 出口
（「设置 → 网络」的 github 代理、令牌、加速镜像）查发布、代取 APK。
"""

from __future__ import annotations

import logging
import re
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass

import httpx

from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.schemas.app_update import ClientReleaseView
from movieclaw_api.services import app_update
from movieclaw_net import egress_transport, resolve_proxy_url

logger = logging.getLogger("movieclaw_api.client_update")


@dataclass(frozen=True)
class _Product:
    tag_prefix: str
    #: Release 里描述安装包的 JSON 附件
    info_asset: str


PRODUCTS: dict[str, _Product] = {
    "android": _Product("android-v", "MovieClaw-Android-arm64.json"),
    "androidtv": _Product("androidtv-v", "MovieClaw-AndroidTV.json"),
}

#: 检查结果缓存：App 每次启动都会问，GitHub 未认证配额只有 60 次/小时
_CACHE_SECONDS = 30 * 60
_cache: dict[str, tuple[float, ClientReleaseView, str]] = {}


def reset_cache_for_tests() -> None:
    _cache.clear()


def _product(product: str) -> _Product:
    found = PRODUCTS.get(product)
    if found is None:
        raise NotFoundException(
            message_key="errors.clientUpdate.unknown", params={"product": product}
        )
    return found


def _version_key(tag: str, prefix: str) -> tuple[int, ...]:
    return tuple(int(p) for p in tag.removeprefix(prefix).split("."))


async def _latest_release(spec: _Product) -> dict:
    pattern = re.compile(rf"^{re.escape(spec.tag_prefix)}\d+(?:\.\d+)*$")
    release = await app_update._find_release(
        spec.tag_prefix,
        pattern,
        lambda tag: _version_key(tag, spec.tag_prefix),
        app_update.CLIENT_SCOPE,
    )
    if release is None:
        # 反代不认 matching-refs 时退回整页列表
        candidates = [
            r
            for r in await app_update._fetch_releases(app_update.CLIENT_SCOPE)
            if pattern.match(r.get("tag_name") or "")
            and not r.get("draft")
            and not r.get("prerelease")
        ]
        release = max(
            candidates,
            key=lambda r: _version_key(r["tag_name"], spec.tag_prefix),
            default=None,
        )
    if release is None:
        raise BadRequestException(message_key="errors.clientUpdate.noRelease")
    return release


def _asset_url(release: dict, name: str) -> str:
    asset = next((a for a in release.get("assets", []) if a.get("name") == name), None)
    if asset is None:
        raise BadRequestException(
            message_key="errors.clientUpdate.assetMissing",
            params={"tag": release.get("tag_name", "?"), "name": name},
        )
    return str(asset["browser_download_url"])


async def latest(product: str, *, force: bool = False) -> ClientReleaseView:
    """该客户端最新正式版的信息（缓存 30 分钟）。"""
    view, _ = await _latest_with_apk(product, force=force)
    return view


async def _latest_with_apk(product: str, *, force: bool = False) -> tuple[ClientReleaseView, str]:
    spec = _product(product)
    cached = _cache.get(product)
    if cached and not force and time.monotonic() - cached[0] < _CACHE_SECONDS:
        return cached[1], cached[2]
    release = await _latest_release(spec)
    # 包信息 JSON 是 sha256 的信任锚点，同更新清单一样固定直连 GitHub（体积小），
    # 只有大文件 APK 允许走加速镜像
    async with httpx.AsyncClient(
        transport=egress_transport("github", use_breaker=False),
        timeout=app_update._HTTP_TIMEOUT,
        follow_redirects=True,
        headers={"User-Agent": "movieclaw-updater"},
    ) as client:
        try:
            resp = await client.get(_asset_url(release, spec.info_asset))
            resp.raise_for_status()
            info = resp.json()
        except httpx.HTTPError as exc:
            raise BadRequestException(
                **app_update._github_error_reference(exc, app_update.CLIENT_SCOPE)
            ) from exc
    try:
        view = ClientReleaseView(
            product=product,
            version=str(info["version"]),
            build=int(info["build"]),
            size=int(info["size"]),
            sha256=str(info["sha256"]).lower(),
            certificate_sha256=info.get("certificateSha256"),
            minimum_sdk=info.get("minimumSdk"),
            changelog=release.get("body") or "",
            published_at=release.get("published_at"),
            release_url=release.get("html_url") or "",
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise BadRequestException(
            message_key="errors.clientUpdate.metadataInvalid", params={"tag": release["tag_name"]}
        ) from exc
    apk_url = _asset_url(release, str(info["asset"]))
    _cache[product] = (time.monotonic(), view, apk_url)
    return view, apk_url


async def open_apk(product: str) -> tuple[ClientReleaseView, AsyncIterator[bytes]]:
    """代取最新 APK：先连上并确认 200，再把字节流交给路由（连不上时能报清楚的错）。"""
    view, url = await _latest_with_apk(product)
    client = httpx.AsyncClient(
        proxy=resolve_proxy_url("github"),
        trust_env=False,
        timeout=httpx.Timeout(60.0, connect=15.0),
        follow_redirects=True,
        headers={"User-Agent": "movieclaw-updater"},
    )
    try:
        request = client.build_request("GET", app_update._mirror_url(url))
        resp = await client.send(request, stream=True)
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        await client.aclose()
        raise BadRequestException(
            **app_update._github_error_reference(exc, app_update.CLIENT_SCOPE)
        ) from exc

    async def body() -> AsyncIterator[bytes]:
        try:
            async for chunk in resp.aiter_bytes(256 * 1024):
                yield chunk
        finally:
            await resp.aclose()
            await client.aclose()

    return view, body()
