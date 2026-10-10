"""插件回调端点 ``PLUGIN_CALLBACKS``（docs/design/plugin-callbacks.md §4）。

外部平台按 ``/api/v1/hooks/<条目 id>/<端点名>/<密钥>[/<子路径>]`` 调进来。宿主只管这几件事：

- 登记：一把密钥一行（只存哈希），记归属（整个插件 / 通道账号 / 实体）；可单独作废、换地址；
- 路由：没登记、已作废、端点名对不上的一律 404；插件没在运行 503；
- 限制：只放行登记的方法，请求体上限（默认 1 MB），每把密钥每分钟的请求数；
- 凭据隔离：剥掉 ``Cookie``——管理员用浏览器打开这个地址时会自动带上登录 Cookie，插件不该拿到；
- 统计：调用次数、失败次数只在内存里记（不落盘）；插件回 401 / 403 记为验证失败，
  连续失败过多发待处理事项，恢复后自动消退。

**不验签、不解析请求体**：请求原样交给插件，插件的答复原样回给平台。
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import secrets
import string
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from sqlmodel import select

from movieclaw_db.models import PluginCallback
from movieclaw_db.models.base import utcnow
from movieclaw_sdk.callbacks import (
    MAX_BODY,
    NAME,
    TIMEOUT,
    CallbackRequest,
    CallbackResponse,
    Issued,
)

logger = logging.getLogger("movieclaw_api.plugin_callbacks")

PREFIX = "/api/v1/hooks"
KEY_LENGTH = 16
_ALPHABET = string.ascii_letters + string.digits
#: 每把密钥每分钟最多处理的请求
RATE_PER_MINUTE = 120
#: 连续这么多次验证失败（插件回 401 / 403）就发待处理事项
FAILURE_NOTICE_AFTER = 10
#: 转给插件前剥掉的请求头（MovieClaw 自己的登录凭据）
_STRIPPED = frozenset({"cookie"})


_service: PluginCallbacks | None = None


def set_service(service: PluginCallbacks | None) -> None:
    global _service
    _service = service


def get_service() -> PluginCallbacks | None:
    """路由与插件包管理器用：插件回调底座关着时为 None。"""
    return _service


class CallbackError(Exception):
    """分发阶段的拒绝：直接回给调用方的状态码与原因。"""

    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = status
        self.reason = reason


@dataclass
class _Endpoint:
    handler: Any
    methods: frozenset[str]
    max_body: int
    timeout: float


@dataclass
class _Stats:
    calls: int = 0
    failures: int = 0
    consecutive: int = 0
    last_called_at: datetime | None = None
    last_status: int | None = None
    hits: deque[float] = field(default_factory=deque)


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


def path_of(entry_id: str, name: str, key: str) -> str:
    return f"{PREFIX}/{entry_id}/{name}/{key}"


def masked_path(entry_id: str, name: str, tail: str) -> str:
    return f"{PREFIX}/{entry_id}/{name}/****{tail}"


def _notice_key(entry_id: str, name: str) -> str:
    return f"plugin:{entry_id}:callback:{name}"


async def _external_url() -> str:
    from movieclaw_api.settings import AppServerSetting, get_setting_store

    try:
        return (await get_setting_store().get(AppServerSetting)).external_url or ""
    except Exception:  # noqa: BLE001 -- 配置读不到时退回只给路径
        return ""


class PluginCallbacks:
    def __init__(self, settings: object, database: Any) -> None:
        self._settings = settings
        self._db = database
        self._endpoints: dict[tuple[str, str], _Endpoint] = {}
        self._stats: dict[int, _Stats] = {}

    # ------------------------------------------------------------------ 插件侧
    def _declared(self, entry_id: str, name: str) -> None:
        """插件包只能用清单里声明过（用户批准过）的端点名；内置与本地插件是受信代码。"""
        from movieclaw_api.plugins import packages as pkg

        record = pkg.installed(self._settings).get(entry_id)
        if record is not None and name not in record.callbacks:
            raise ValueError(
                f"回调端点 {name} 没有在清单 [permissions] callbacks 里声明（用户没有批准开放它）"
            )

    def endpoint(
        self,
        ctx: Any,
        name: str,
        handler: Any,
        *,
        methods: tuple[str, ...] = ("POST",),
        max_body: int = MAX_BODY,
        timeout: float = TIMEOUT,
    ) -> None:
        dispose = self.register(
            ctx.entry_id, name, handler, methods=methods, max_body=max_body, timeout=timeout
        )
        ctx.effect(dispose, label=f"callback:{name}")

    def register(
        self,
        entry_id: str,
        name: str,
        handler: Any,
        *,
        methods: tuple[str, ...] = ("POST",),
        max_body: int = MAX_BODY,
        timeout: float = TIMEOUT,
    ) -> Any:
        """登记端点（宿主内部用，如通道中枢替通道插件登记）；返回撤销函数。"""
        if not NAME.match(name):
            raise ValueError(f"回调端点名 {name} 不合规：小写字母开头，字母、数字、连字符")
        self._declared(entry_id, name)
        key = (entry_id, name)
        if key in self._endpoints:
            raise ValueError(f"回调端点 {name} 重复登记")
        endpoint = _Endpoint(
            handler=handler,
            methods=frozenset(m.upper() for m in methods),
            max_body=max(1, min(int(max_body), MAX_BODY)),
            timeout=float(timeout),
        )
        self._endpoints[key] = endpoint

        def dispose() -> None:
            if self._endpoints.get(key) is endpoint:
                del self._endpoints[key]

        return dispose

    async def issue_for(self, entry_id: str, name: str, scope: str) -> Issued:
        """宿主内部替插件发密钥（如通道绑定时）。"""
        self._declared(entry_id, name)
        return await self._issue(entry_id, name, scope)

    async def active(self, entry_id: str, scope: str) -> list[Issued]:
        """某个归属下还有效的密钥（地址打码）。"""
        rows = [r for r in await self._rows(entry_id=entry_id) if r.scope == scope]
        return [
            Issued(r.id or 0, r.name, r.scope, masked_path(r.entry_id, r.name, r.key_tail), False)
            for r in rows
        ]

    async def issue(self, ctx: Any, name: str, *, scope: str = "plugin") -> Issued:
        if not NAME.match(name):
            raise ValueError(f"回调端点名 {name} 不合规")
        self._declared(ctx.entry_id, name)
        return await self._issue(ctx.entry_id, name, scope)

    async def revoke(self, ctx: Any, key_id: int) -> None:
        await self._revoke(key_id, entry_id=ctx.entry_id)

    async def keys(self, ctx: Any, name: str | None = None) -> list[Issued]:
        rows = await self._rows(entry_id=ctx.entry_id, name=name)
        return [
            Issued(r.id or 0, r.name, r.scope, masked_path(r.entry_id, r.name, r.key_tail), False)
            for r in rows
        ]

    # ------------------------------------------------------------------ 管理（mclaw / 插件页）
    async def overview(self, entry_id: str | None = None) -> list[dict[str, Any]]:
        rows = await self._rows(entry_id=entry_id)
        out = []
        for row in rows:
            stats = self._stats.get(row.id or 0) or _Stats()
            out.append(
                {
                    "id": row.id,
                    "entry_id": row.entry_id,
                    "endpoint": row.name,
                    "scope": row.scope,
                    "url": masked_path(row.entry_id, row.name, row.key_tail),
                    "created_at": row.created_at,
                    "running": (row.entry_id, row.name) in self._endpoints,
                    "calls": stats.calls,
                    "failures": stats.failures,
                    "last_called_at": stats.last_called_at,
                    "last_status": stats.last_status,
                }
            )
        return out

    async def rotate(self, key_id: int) -> Issued:
        """换地址：作废旧密钥、按同样的归属发一把新的。"""
        row = await self._get(key_id)
        if row is None or row.revoked_at is not None:
            raise LookupError(f"没有有效的回调地址 #{key_id}")
        await self._revoke(key_id)
        return await self._issue(row.entry_id, row.name, row.scope)

    async def revoke_id(self, key_id: int) -> None:
        await self._revoke(key_id)

    async def revoke_all(self, entry_id: str, *, scope: str | None = None) -> int:
        """作废一个插件（或它某个归属）的全部密钥：卸载插件、解绑账号时用。"""
        rows = await self._rows(entry_id=entry_id)
        count = 0
        for row in rows:
            if scope is None or row.scope == scope:
                await self._revoke(row.id or 0)
                count += 1
        return count

    # ------------------------------------------------------------------ 分发
    async def dispatch(
        self,
        entry_id: str,
        name: str,
        key: str,
        *,
        method: str,
        subpath: str,
        query: list[tuple[str, str]],
        headers: list[tuple[str, str]],
        read_body: Any,
    ) -> CallbackResponse:
        row = await self._lookup(key)
        if row is None or row.entry_id != entry_id or row.name != name:
            raise CallbackError(404, "地址无效")
        endpoint = self._endpoints.get((entry_id, name))
        if endpoint is None:
            raise CallbackError(503, "插件当前没有运行")
        if method.upper() not in endpoint.methods:
            raise CallbackError(405, "不支持这个请求方法")
        stats = self._stats.setdefault(row.id or 0, _Stats())
        now = time.monotonic()
        while stats.hits and now - stats.hits[0] > 60:
            stats.hits.popleft()
        if len(stats.hits) >= RATE_PER_MINUTE:
            raise CallbackError(429, "请求太频繁")
        stats.hits.append(now)
        body = await read_body(endpoint.max_body)
        if body is None:
            raise CallbackError(413, "请求体太大")
        request = CallbackRequest(
            method=method.upper(),
            endpoint=name,
            subpath=subpath,
            query=tuple(query),
            headers=tuple((k, v) for k, v in headers if k.lower() not in _STRIPPED),
            body=body,
            scope=row.scope,
            key_id=row.id or 0,
        )
        stats.calls += 1
        stats.last_called_at = utcnow()
        try:
            response = await asyncio.wait_for(endpoint.handler(request), endpoint.timeout)
        except TimeoutError:
            stats.last_status = 504
            raise CallbackError(504, "插件处理超时") from None
        except Exception:
            stats.last_status = 500
            logger.exception("插件 %s 的回调端点 %s 处理出错", entry_id, name)
            raise CallbackError(500, "插件处理出错") from None
        if not isinstance(response, CallbackResponse):
            stats.last_status = 500
            logger.error("插件 %s 的回调端点 %s 没有返回 CallbackResponse", entry_id, name)
            raise CallbackError(500, "插件处理出错")
        stats.last_status = response.status
        await self._record(entry_id, name, stats, response.status)
        return response

    async def _record(self, entry_id: str, name: str, stats: _Stats, status: int) -> None:
        from movieclaw_api.services.system_notice import resolve_notices, upsert_notice
        from movieclaw_db.models import NoticeSeverity

        if status in (401, 403):
            stats.failures += 1
            stats.consecutive += 1
            if stats.consecutive == FAILURE_NOTICE_AFTER:
                async with self._db.session() as session:
                    await upsert_notice(
                        session,
                        dedupe_key=_notice_key(entry_id, name),
                        severity=NoticeSeverity.WARNING,
                        source="plugin",
                        title=f"插件 {entry_id} 的回调地址连续验证失败",
                        message=(
                            f"回调端点 {name} 连续 {FAILURE_NOTICE_AFTER} 次没通过插件的验证："
                            "可能是平台后台填的令牌 / 密钥和插件里的不一致，"
                            "也可能有人在试探这个地址。"
                            "必要时在插件页换一个回调地址。"
                        ),
                        payload={"entry_id": entry_id, "endpoint": name},
                    )
            return
        if 200 <= status < 400 and stats.consecutive:
            reached = stats.consecutive >= FAILURE_NOTICE_AFTER
            stats.consecutive = 0
            if reached:
                async with self._db.session() as session:
                    await resolve_notices(session, dedupe_key=_notice_key(entry_id, name))

    # ------------------------------------------------------------------ 存取
    async def _issue(self, entry_id: str, name: str, scope: str) -> Issued:
        key = "".join(secrets.choice(_ALPHABET) for _ in range(KEY_LENGTH))
        row = PluginCallback(
            entry_id=entry_id, name=name, key_hash=hash_key(key), key_tail=key[-4:], scope=scope
        )
        async with self._db.session() as session:
            session.add(row)
            await session.commit()
            await session.refresh(row)
        base = (await _external_url()).rstrip("/")
        path = path_of(entry_id, name, key)
        logger.info("插件 %s 的回调端点 %s 发了一把密钥（%s）", entry_id, name, scope)
        return Issued(row.id or 0, name, scope, f"{base}{path}" if base else path, bool(base))

    async def _revoke(self, key_id: int, *, entry_id: str | None = None) -> None:
        async with self._db.session() as session:
            row = await session.get(PluginCallback, key_id)
            if row is None or (entry_id is not None and row.entry_id != entry_id):
                raise LookupError(f"没有回调地址 #{key_id}")
            if row.revoked_at is None:
                row.revoked_at = utcnow()
                session.add(row)
                await session.commit()
        self._stats.pop(key_id, None)

    async def _get(self, key_id: int) -> PluginCallback | None:
        async with self._db.session() as session:
            return await session.get(PluginCallback, key_id)

    async def _lookup(self, key: str) -> PluginCallback | None:
        async with self._db.session() as session:
            row = (
                await session.execute(
                    select(PluginCallback).where(PluginCallback.key_hash == hash_key(key))
                )
            ).scalar_one_or_none()
        return row if row is not None and row.revoked_at is None else None

    async def _rows(self, *, entry_id: str | None, name: str | None = None) -> list[PluginCallback]:
        query = select(PluginCallback).where(PluginCallback.revoked_at.is_(None))  # type: ignore[union-attr]
        if entry_id is not None:
            query = query.where(PluginCallback.entry_id == entry_id)
        if name is not None:
            query = query.where(PluginCallback.name == name)
        async with self._db.session() as session:
            return list((await session.execute(query.order_by(PluginCallback.id))).scalars().all())
