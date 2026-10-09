"""插件路由与签名链接 ``PLUGIN_ROUTES``（docs/design/plugin-phase2b.md §8）。

::

    routes = ctx.use(PLUGIN_ROUTES)
    router = APIRouter()

    @router.get("/files/{file_id}", operation_id=f"plugins.{ctx.entry_id}.file")
    async def file(file_id: int): ...

    routes.mount(ctx, router, zone="public")      # → /api/v1/plugins/<条目 id>/files/{file_id}
    url = await routes.sign(ctx, "/files/7", absolute=True)   # 写进 .strm 的不过期链接

三个区：``admin``（管理员）、``member``（登录成员）、``public``（不登录，但必须带本插件签发的签名；
没签名或签名不对一律 404）。鉴权由宿主在挂载时注入，插件自己的路由不用、也绕不开。
operationId 必须以 ``plugins.<条目 id>.`` 开头；插件卸载时路由一并摘除。

签名密钥每个插件一把，存在它自己的插件数据里（加密）；不与登录会话的密钥共用，改密码、
轮换会话密钥不会让已经写出去的 ``.strm`` 失效。
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import re
import secrets
import time
from typing import Any, Literal
from urllib.parse import quote, urlencode

from fastapi import APIRouter, Depends, Request
from fastapi.routing import APIRoute

from movieclaw_api.exceptions import NotFoundException

Zone = Literal["admin", "member", "public"]

#: 宿主路由器：挂在 /api/v1 下（api/router.py），插件路由按条目 id 加前缀挂到它上面
host_router = APIRouter(prefix="/plugins")

_ENTRY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
_KEY_NAME = "kernel.link-key"


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _canonical(path: str, params: list[tuple[str, str]]) -> bytes:
    query = "&".join(f"{k}={v}" for k, v in sorted(params) if k != "sig")
    return f"{path}?{query}".encode()


class PluginRoutes:
    def __init__(self, app: Any, store_for: Any) -> None:
        self._app = app
        self._store_for = store_for
        self._keys: dict[str, bytes] = {}
        self._key_lock = asyncio.Lock()

    # ------------------------------------------------------------------ 路由
    def mount(self, ctx: Any, router: APIRouter, *, zone: Zone = "admin") -> str:
        """把插件的路由器挂到 ``/api/v1/plugins/<条目 id>``，返回这个前缀；插件卸载时自动摘除。"""
        from movieclaw_api.api.deps import require_admin, require_login

        entry_id = ctx.entry_id
        if not _ENTRY_ID.match(entry_id):
            raise ValueError(f"条目 id 不能用作路径：{entry_id!r}（小写字母、数字、. _ -）")
        if zone not in ("admin", "member", "public"):
            raise ValueError(f"未知的区：{zone!r}（admin / member / public）")
        prefix = f"plugins.{entry_id}."
        for route in router.routes:
            if not isinstance(route, APIRoute):
                raise ValueError(f"插件路由只支持普通 HTTP 接口：{route!r}")
            if not (route.operation_id or "").startswith(prefix):
                raise ValueError(
                    f"{route.path} 的 operationId 须以 {prefix} 开头（当前 {route.operation_id!r}）"
                )
        if zone == "admin":
            guard = require_admin
        elif zone == "member":
            guard = require_login
        else:
            guard = self._verifier(entry_id)
        before = list(host_router.routes)
        host_router.include_router(
            router,
            prefix=f"/{entry_id}",
            tags=[f"plugin:{entry_id}"],
            dependencies=[Depends(guard)],
        )
        added = [r for r in host_router.routes if r not in before]
        self._changed()

        def unmount() -> None:
            for item in added:
                if item in host_router.routes:
                    host_router.routes.remove(item)
            # FastAPI 的路由版本是「自身版本 + 子路由器版本之和」，摘掉子路由器会让总和回退，
            # 可能撞上旧值而命中旧的路由表 / OpenAPI 缓存；这里把自身版本补到比摘除前更大
            removed = sum(
                item.original_router._get_routes_version()
                for item in added
                if hasattr(item, "original_router")
            )
            host_router._routes_version += removed
            host_router._mark_routes_changed()
            self._changed()

        ctx.effect(unmount, label="unmount-routes")
        return f"/api/v1/plugins/{entry_id}"

    def _changed(self) -> None:
        from movieclaw_api.spec_state import routes_changed

        self._app.openapi_schema = None
        routes_changed(self._app)

    # ------------------------------------------------------------------ 签名
    async def _key(self, entry_id: str) -> bytes:
        key = self._keys.get(entry_id)
        if key is not None:
            return key
        # 加锁：首次签发与首次验签并发时不能各生成一把、互相覆盖
        async with self._key_lock:
            if entry_id not in self._keys:
                store = self._store_for(entry_id)
                text = await store.get(_KEY_NAME)
                if text is None:
                    text = _b64(secrets.token_bytes(32))
                    await store.set(_KEY_NAME, text, secret=True)
                self._keys[entry_id] = text.encode("ascii")
            return self._keys[entry_id]

    async def sign(
        self,
        ctx: Any,
        path: str,
        *,
        params: dict[str, str] | None = None,
        expires_in: int | None = None,
        absolute: bool = False,
    ) -> str:
        """签发本插件公开区某个路径的链接。``expires_in`` 秒后失效；不传则不过期（写进 .strm）。

        ``absolute=True`` 拼上「外部访问地址」，没配置时报错（媒体播放器需要完整地址）。
        """
        if not path.startswith("/"):
            raise ValueError("path 须以 / 开头（相对本插件的前缀）")
        full = f"/api/v1/plugins/{ctx.entry_id}{path}"
        items = [(k, str(v)) for k, v in (params or {}).items()]
        if expires_in is not None:
            items.append(("exp", str(int(time.time()) + expires_in)))
        digest = hmac.new(await self._key(ctx.entry_id), _canonical(full, items), hashlib.sha256)
        items.append(("sig", _b64(digest.digest())))
        url = f"{quote(full)}?{urlencode(items)}"
        if not absolute:
            return url
        from movieclaw_api.settings import get_setting_store
        from movieclaw_api.settings.app_server import AppServerSetting

        base = (await get_setting_store().get(AppServerSetting)).external_url.strip().rstrip("/")
        if not base:
            raise ValueError("没有配置外部访问地址（设置 → 应用），无法生成完整链接")
        return f"{base}{url}"

    def _verifier(self, entry_id: str):
        async def verify_plugin_signature(request: Request) -> None:
            items = request.query_params.multi_items()
            given = dict(items).get("sig", "")
            exp = dict(items).get("exp")
            key = await self._key(entry_id)
            digest = hmac.new(key, _canonical(request.url.path, items), hashlib.sha256)
            if not hmac.compare_digest(given, _b64(digest.digest())):
                raise NotFoundException("链接无效")
            if exp is not None and (not exp.isdigit() or int(exp) < time.time()):
                raise NotFoundException("链接已过期")

        return verify_plugin_signature
