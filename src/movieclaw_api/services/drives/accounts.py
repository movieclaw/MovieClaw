"""网盘账号：扫码登录、Cookie 导入、设置、删除（docs/design/cloud-storage.md §3.1、§11.5）。

扫码登录是插件维护的流程：宿主开始一次登录后在后台跟着轮询插件（前端不轮询也能完成——扫完码就建账号），
设置页轮询宿主拿二维码与状态。登录会话只在内存里，过期后清掉。

同一网盘用户只有一个账号：重新扫码、浏览器扩展重复推送都更新原账号的凭据，不改用户起的名字。
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from collections.abc import Coroutine
from dataclasses import dataclass
from typing import Any

from movieclaw_api.services.drives import gateway
from movieclaw_api.services.drives.registry import BackendUnavailable
from movieclaw_api.services.drives.registry import backend as get_backend
from movieclaw_db.engine import get_database
from movieclaw_db.models import utcnow
from movieclaw_db.models.drive_account import DriveAccount
from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository
from movieclaw_sdk import drives as dv

logger = logging.getLogger("movieclaw_api.drives")

#: 一次扫码登录最长等多久（二维码一般几分钟就过期，插件会先报 expired）
LOGIN_TTL_S = 10 * 60
#: 结束的登录会话再留多久（设置页最后一次轮询能拿到结果）
LOGIN_LINGER_S = 5 * 60
LOGIN_POLL_S = 1.5


@dataclass(slots=True)
class LoginSession:
    login_id: str
    backend: str
    flow_id: str
    detail: str | None
    status: str = "pending"
    message: str = ""
    qr: str | None = None
    account_id: int | None = None
    created: bool = False
    expires_at: float = 0.0

    @property
    def terminal(self) -> bool:
        return self.status in dv.TERMINAL_LOGIN_STATUSES


_logins: dict[str, LoginSession] = {}
_tasks: set[asyncio.Task[Any]] = set()


def _spawn(coro: Coroutine[Any, Any, None], what: str) -> None:
    task = asyncio.get_running_loop().create_task(coro)
    _tasks.add(task)

    def done(t: asyncio.Task[None]) -> None:
        _tasks.discard(t)
        if not t.cancelled() and t.exception() is not None:
            logger.error("%s 后台任务失败", what, exc_info=t.exception())

    task.add_done_callback(done)


def login_session(login_id: str) -> LoginSession | None:
    item = _logins.get(login_id)
    if item is not None and not item.terminal and time.monotonic() > item.expires_at:
        item.status = "expired"
        item.message = "二维码已过期，请重新扫码"
    return item


def _detail(backend: dv.DriveBackend, options: dict[str, str]) -> str | None:
    """扫码时选的登录端等选项，记成一句给人看的说明（账号卡片上显示）。"""
    parts = []
    for option in backend.login.options:
        value = options.get(option.key, option.default)
        label = next((c.label for c in option.choices if c.value == value), value)
        parts.append(label)
    return " · ".join(parts) or None


async def begin_login(backend_type: str, options: dict[str, str]) -> LoginSession:
    backend = get_backend(backend_type)
    if not backend.login.scan:
        raise ValueError(f"{backend.title}不支持扫码登录")
    allowed = {o.key: {c.value for c in o.choices} for o in backend.login.options}
    picked = {o.key: o.default for o in backend.login.options}
    for key, value in options.items():
        if key not in allowed or value not in allowed[key]:
            raise ValueError(f"登录选项 {key}={value} 不在可选范围内")
        picked[key] = value
    flow = await gateway.call_backend(backend, "begin_login", options=picked)
    item = LoginSession(
        login_id=uuid.uuid4().hex[:16],
        backend=backend_type,
        flow_id=flow.flow_id,
        detail=_detail(backend, picked),
        expires_at=time.monotonic() + LOGIN_TTL_S,
    )
    await _apply(item, flow)
    _logins[item.login_id] = item
    _spawn(_watch(item), "网盘扫码登录")
    return item


async def cancel_login(login_id: str) -> None:
    item = _logins.pop(login_id, None)
    if item is None or item.terminal:
        return
    item.status = "failed"
    item.message = "已取消"
    try:
        await gateway.call_backend(get_backend(item.backend), "cancel_login", flow_id=item.flow_id)
    except Exception:  # noqa: BLE001 -- 取消失败不影响前端
        logger.debug("取消网盘扫码登录失败", exc_info=True)


async def _watch(item: LoginSession) -> None:
    try:
        while not item.terminal and time.monotonic() < item.expires_at:
            await asyncio.sleep(LOGIN_POLL_S)
            if item.terminal:
                break
            try:
                flow = await gateway.call_backend(
                    get_backend(item.backend), "login_state", flow_id=item.flow_id
                )
            except BackendUnavailable as exc:
                item.status, item.message = "failed", str(exc)
                break
            except dv.DriveError as exc:
                logger.warning("读取扫码状态失败：%s", exc.message)
                continue
            await _apply(item, flow)
        if not item.terminal:
            item.status, item.message = "expired", "二维码已过期，请重新扫码"
    finally:
        await asyncio.sleep(LOGIN_LINGER_S)
        _logins.pop(item.login_id, None)


async def _apply(item: LoginSession, flow: dv.LoginFlow) -> None:
    if item.terminal:
        return
    item.qr = flow.qr
    if flow.status == "confirmed":
        if flow.result is None:
            item.status, item.message = "failed", "登录结果缺失，请重新扫码"
            return
        try:
            row, created = await _commit(item.backend, flow.result, "scan", item.detail)
        except Exception as exc:  # noqa: BLE001 -- 落库失败原样告诉用户
            logger.exception("网盘账号落库失败")
            item.status, item.message = "failed", f"添加账号失败：{exc}"
            return
        item.account_id, item.created = row.id, created
        item.status = "confirmed"
        item.message = f"已添加：{row.name}" if created else f"已重新登录：{row.name}"
        return
    item.status = flow.status
    item.message = flow.message


async def import_cookie(backend_type: str, cookie_header: str) -> tuple[DriveAccount, bool]:
    """浏览器扩展推送或用户粘贴的 Cookie：交给插件挑出需要的几项并校验，

    再建账号或更新同一用户的账号。
    """
    backend = get_backend(backend_type)
    if not backend.login.cookie_domains:
        raise ValueError(f"{backend.title}不支持用 Cookie 登录")
    try:
        result = await gateway.call_backend(
            backend, "login_with_cookie", cookie_header=cookie_header
        )
    except dv.AuthExpired as exc:
        raise ValueError(f"没读到 {backend.title}的登录：{exc.message}") from exc
    except dv.DriveError as exc:
        raise ValueError(exc.message) from exc
    return await _commit(backend_type, result, "cookie", "网页端")


async def _commit(
    backend_type: str, result: dv.LoginResult, method: str, detail: str | None
) -> tuple[DriveAccount, bool]:
    async with get_database().session() as session:
        row, created = await DriveAccountRepository(session).upsert_login(
            backend=backend_type,
            remote_user_id=result.user_id,
            display_name=result.display_name,
            credentials=result.credentials,
            login_method=method,
            login_detail=detail,
        )
    assert row.id is not None
    await gateway.clear_notice(row.id)
    logger.info("网盘账号已登录 backend=%s account=%s new=%s", backend_type, row.id, created)
    # 昵称与容量：登录后立刻读一次，失败不影响登录
    try:
        row = await refresh_profile(row.id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("读取网盘账号资料失败：%s", exc)
    return row, created


async def refresh_profile(account_id: int) -> DriveAccount:
    info: dv.AccountInfo = await gateway.call(account_id, "account_info")
    async with get_database().session() as session:
        repo = DriveAccountRepository(session)
        row = await repo.get(account_id)
        if row is None:
            raise dv.NotFound("网盘账号不存在")
        row.vip = info.vip
        row.quota_total = info.quota_total
        row.quota_used = info.quota_used
        row.profile_at = utcnow()
        return await repo.update(row)


async def update_settings(
    account_id: int,
    *,
    name: str | None = None,
    qps: float | None = None,
    daily_budget: int | None = None,
    read_slots: int | None = None,
    reset: frozenset[str] = frozenset(),
) -> DriveAccount:
    """改账号设置。``reset`` 里的字段回到插件默认值（存 NULL）。"""
    async with get_database().session() as session:
        repo = DriveAccountRepository(session)
        row = await repo.get(account_id)
        if row is None:
            raise LookupError("网盘账号不存在")
        if name is not None:
            name = name.strip()
            if not name:
                raise ValueError("账号名不能为空")
            row.name = name[:60]
        if qps is not None:
            if not 0.1 <= qps <= 20:
                raise ValueError("请求速率要在 0.1～20 次 / 秒之间")
            row.qps = qps
        if daily_budget is not None:
            if not 100 <= daily_budget <= 1_000_000:
                raise ValueError("每日预算要在 100～1,000,000 次之间")
            row.daily_budget = daily_budget
        if read_slots is not None:
            if not 1 <= read_slots <= 10:
                raise ValueError("同时播放数要在 1～10 之间")
            row.read_slots = read_slots
        for key in reset & {"qps", "daily_budget", "read_slots"}:
            setattr(row, key, None)
        return await repo.update(row)


async def delete_account(account_id: int) -> bool:
    """移除账号：只删 MovieClaw 里的记录，不动网盘上的任何文件。"""
    async with get_database().session() as session:
        removed = await DriveAccountRepository(session).delete(account_id)
    if removed:
        gateway.forget(account_id)
        await gateway.clear_notice(account_id)
    return removed
