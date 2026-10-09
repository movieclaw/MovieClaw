"""宿主操作：插件以自己的身份调用本进程的 OpenAPI 操作（docs/design/plugin-phase2a.md §3）。

插件不需要另一套宿主 API——CLI、MCP、Agent 共用的那份操作目录就是插件的能力面::

    @plugin("acme.watch", inject=(HOST_OPS,), permissions=("search.titles", "subscriptions.create"))
    async def apply(ctx):
        ops = await ctx.use(HOST_OPS).client(ctx)
        found = await ops.call("search.titles", {"query": "沙丘"})

- **身份**：每个插件条目一枚只在内存里的凭证（激活时签发、释放时作废），请求走与 HTTP 完全相同的
  鉴权、权限与校验；``require_login`` 按匹配到的路由 operationId 校验授权（默认拒绝）。
- **授权**：插件声明 ``permissions``（支持 ``领域.*``）；危险操作必须逐个列出，通配不覆盖。内置插件
  声明即授权；本地受信插件取「声明 ∩ 用户在 ``plugins.yaml`` 里批准的」（``configure``）。
- **代表谁**：缺省为超管；``configure(act_as=成员用户名)`` 后以该成员的形状出现，有效权限 =
  成员权限 ∩ 插件授权。
- 调用经 ``httpx.ASGITransport`` 进本进程应用；每次调用记一行审计日志。
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Iterable
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Any

import httpx

from movieclaw_api.services.auth import PluginGrant, issue_plugin_token, revoke_plugin_token

logger = logging.getLogger("movieclaw_api.host_ops")

_HTTP_METHODS = frozenset({"get", "post", "put", "patch", "delete"})
_BASE_URL = "http://plugin.internal"
DEFAULT_TIMEOUT = 60.0

#: 运行中的应用（lifespan 绑定）。插件内核不认识 FastAPI，宿主操作要靠它才能进 ASGI
_app: Any = None


def bind_app(app: Any) -> None:
    global _app
    _app = app


def unbind_app(app: Any) -> None:
    global _app
    if _app is app:
        _app = None


class OpsError(Exception):
    """宿主操作失败：HTTP 状态、错误码、可读原因与明细（与接口的错误响应同构）。"""

    def __init__(
        self, status: int, code: str, message: str, details: list[dict[str, Any]] | None = None
    ) -> None:
        super().__init__(f"{code}（{status}）：{message}")
        self.status = status
        self.code = code
        self.message = message
        self.details = details or []


@dataclass
class _EntrySettings:
    grants: frozenset[str] | None = None
    """用户批准的授权（本地受信插件）；``None`` = 没有配置。"""
    act_as: str | None = None


@lru_cache(maxsize=1)
def _operation_index() -> dict[str, Any]:
    """操作目录：与 CLI / MCP 同一份基线 spec、同一入选口径（有 operationId、非隐藏、非流式）。

    读构建期导出的基线（部署产物里一定有，且与代码同版），不现场 ``app.openapi()``：
    现算整份 spec 在 NAS 上要好几秒，而插件第一次拿凭证正是在启动过程中。
    """
    from movieclaw_api.services.spec_catalog import load_spec
    from movieclaw_mcp.catalog import _build_operation

    spec = load_spec()
    index: dict[str, Any] = {}
    for path, methods in (spec.get("paths") or {}).items():
        for method, op in methods.items():
            if method not in _HTTP_METHODS or not isinstance(op, dict):
                continue
            operation_id = op.get("operationId") or ""
            if not operation_id or op.get("x-cli-hidden") or op.get("x-cli-stream"):
                continue
            built = _build_operation(spec, path, method, op)
            if built is not None:
                index[operation_id] = built
    return index


def expand_grants(patterns: Iterable[str], index: dict[str, Any]) -> frozenset[str]:
    """把声明展开成具体 operationId：``领域.*`` 只覆盖非危险操作，危险操作必须逐个列出。"""
    exact = {p for p in patterns if not p.endswith(".*")}
    domains = {p[:-2] for p in patterns if p.endswith(".*")}
    allowed: set[str] = set()
    for operation_id, op in index.items():
        if operation_id in exact or (op.domain in domains and not op.dangerous):
            allowed.add(operation_id)
    return frozenset(allowed)


class HostOps:
    """``HOST_OPS`` 的实现。"""

    def __init__(self, app: Any) -> None:
        self._app = app
        self._index: dict[str, Any] | None = None
        self._settings: dict[str, _EntrySettings] = {}

    @property
    def index(self) -> dict[str, Any]:
        if self._index is None:
            self._index = _operation_index()
        return self._index

    def configure(
        self, entry_id: str, *, grants: Iterable[str] | None = None, act_as: str | None = None
    ) -> None:
        """登记用户对某个条目的批准（授权、代表谁）；本地受信插件加载时由宿主调用。"""
        self._settings[entry_id] = _EntrySettings(
            grants=frozenset(grants) if grants is not None else None, act_as=act_as
        )

    def granted(self, ctx: Any) -> frozenset[str]:
        requested = tuple(ctx.permissions)
        if ctx.third_party:
            approved = self._settings.get(ctx.entry_id, _EntrySettings()).grants or frozenset()
            dropped = [p for p in requested if p not in approved]
            if dropped:
                logger.warning(
                    "插件 %s 声明的操作 %s 没有在 plugins.yaml 的 grants 里批准，不授予",
                    ctx.entry_id,
                    "、".join(dropped),
                )
            requested = tuple(p for p in requested if p in approved)
        return expand_grants(requested, self.index)

    async def client(self, ctx: Any, *, timeout: float = DEFAULT_TIMEOUT) -> OpsClient:
        """给插件签一枚凭证并返回调用入口；凭证随插件释放作废。"""
        operations = self.granted(ctx)
        act_as = self._settings.get(ctx.entry_id, _EntrySettings()).act_as
        member_id = await _member_id(act_as) if act_as else None
        token = issue_plugin_token(
            PluginGrant(entry_id=ctx.entry_id, operations=operations), member_id=member_id
        )
        ctx.effect(lambda: revoke_plugin_token(token), label="revoke-plugin-token")
        logger.info(
            "插件 %s 获得 %d 个宿主操作授权（代表%s）",
            ctx.entry_id,
            len(operations),
            f"成员 {act_as}" if act_as else "超管",
        )
        return OpsClient(self._app, token, ctx.entry_id, self.index, operations, timeout)


async def _member_id(username: str) -> int:
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import Member

    async with get_database().session() as session:
        member = (
            await session.execute(select(Member).where(Member.username == username))
        ).scalar_one_or_none()
    if member is None or member.id is None:
        raise LookupError(f"插件配置的 act_as 成员不存在：{username}")
    return member.id


@dataclass
class OpsClient:
    _app: Any
    _token: str
    entry_id: str
    _index: dict[str, Any] = field(repr=False)
    operations: frozenset[str]
    timeout: float = DEFAULT_TIMEOUT

    def allowed(self, operation_id: str) -> bool:
        return operation_id in self.operations

    async def call(
        self,
        operation_id: str,
        arguments: dict[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> Any:
        """调用一个操作，返回响应里的 ``data``；失败抛 ``OpsError``。

        参数是扁平的：路径参数、查询参数、请求体字段放在同一个字典里（与 MCP 工具参数同构）。
        """
        from movieclaw_mcp.dispatch import build_request

        op = self._index.get(operation_id)
        if op is None:
            raise OpsError(404, "UNKNOWN_OPERATION", f"没有这个操作：{operation_id}")
        try:
            path, query, body = build_request(op, arguments or {})
        except ValueError as exc:
            raise OpsError(400, "INVALID_ARGUMENTS", str(exc)) from exc

        async def send() -> httpx.Response:
            transport = httpx.ASGITransport(app=self._app, raise_app_exceptions=False)
            async with httpx.AsyncClient(
                transport=transport, base_url=_BASE_URL, timeout=timeout or self.timeout
            ) as client:
                return await client.request(
                    op.method.upper(),
                    path,
                    params=query or None,
                    json=body,
                    headers={
                        "Authorization": f"Bearer {self._token}",
                        "X-MovieClaw-Client": "plugin",
                    },
                )

        started = time.perf_counter()
        # 放进独立任务：请求处理里设置的上下文变量（发起方等）不回流到插件自己的上下文；
        # 插件被取消时这个任务跟着取消
        response = await asyncio.create_task(send())
        elapsed = (time.perf_counter() - started) * 1000
        logger.info(
            "插件 %s 调用 %s %s %s → %d（%.0f 毫秒）",
            self.entry_id,
            operation_id,
            op.method.upper(),
            path,
            response.status_code,
            elapsed,
        )
        try:
            payload = response.json()
        except ValueError:
            payload = {"message": response.text[:500]}
        if response.status_code >= 400:
            if not isinstance(payload, dict):
                payload = {}
            raise OpsError(
                response.status_code,
                str(payload.get("code") or "HTTP_ERROR"),
                str(payload.get("message") or f"请求失败（HTTP {response.status_code}）"),
                payload.get("details") if isinstance(payload.get("details"), list) else None,
            )
        return payload.get("data") if isinstance(payload, dict) and "data" in payload else payload
