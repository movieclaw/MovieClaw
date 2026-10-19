"""对网盘后端的每次调用都经这里（docs/design/cloud-storage.md §8、§11.3、§11.4）。

- **按请求限速**：网盘按 HTTP 请求计频率，一次调用里可能翻几十页。调用本身先领一个名额，
  之后插件经 SDK 网络出口（``movieclaw_sdk.net``）每多发一个请求再领一个；按账号排队，
  **播放优先**（优先级高的先拿到下一个名额）；
- **超时**：按「多久没有进展」算，插件卡死拖不住宿主；排队等名额不算没进展，大目录慢慢翻不会被掐断；
- **每日预算**：已用次数按请求计、只记在内存里（计量不碰盘，重启后从零算起）。后台用到预算的
  70% 就停，余量留给播放；播放与用户操作不受预算拦截；
- **错误归类**：只有 ``AuthExpired`` 让账号进「要重新登录」；限流、风控期间后台与用户操作
  直接拒绝（翻到一半的也停下）、播放照常尝试；接口改版标「接口异常」；其余按临时错误交还调用方；
- **凭据**：插件在调用里换了凭据（刷新令牌、Cookie 换新），先落库再把结果交给调用方。
"""

from __future__ import annotations

import asyncio
import contextlib
import heapq
import itertools
import logging
import math
from dataclasses import dataclass, field
from datetime import date, timedelta
from enum import IntEnum
from typing import Any

from movieclaw_api.services.drives.registry import backend as get_backend
from movieclaw_api.services.system_notice import resolve_notices, upsert_notice
from movieclaw_db.engine import get_database
from movieclaw_db.models import NoticeSeverity, utcnow
from movieclaw_db.models.drive_account import (
    DRIVE_STATUS_API_BROKEN,
    DRIVE_STATUS_AUTH_EXPIRED,
    DRIVE_STATUS_DISABLED,
    DRIVE_STATUS_OK,
    DRIVE_STATUS_RATE_LIMITED,
    DriveAccount,
)
from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository
from movieclaw_sdk import drives as dv
from movieclaw_sdk import net

logger = logging.getLogger("movieclaw_api.drives")


class Priority(IntEnum):
    """调用的优先级：数字小的先拿到限速名额。"""

    PLAYBACK = 0  # 取直链、起播探测
    USER = 1  # 用户在界面上点的操作（登录、刷新、删除、移动、手动同步）
    BACKGROUND = 2  # 纳管、上传、规格补探、动态拉取、对账


#: 后台用量到每日预算的这个比例就停，余量留给播放
BACKGROUND_SHARE = 0.7
#: 各方法的超时（秒）：多久没有进展（插件没再领到名额、也没返回）就放弃；没列出的用默认值
TIMEOUTS: dict[str, float] = {
    "begin_login": 15.0,
    "login_state": 15.0,
    "cancel_login": 10.0,
    "login_with_cookie": 20.0,
    "login_with_form": 20.0,
    "account_info": 30.0,
    "list_dir": 30.0,
    "list_tree": 120.0,
    "changes": 30.0,
    "ensure_dir": 30.0,
    "begin_upload": 60.0,
    # 一片最大几十 MB：按上行几 MB/s 估，给足
    "upload_part": 600.0,
    "finish_upload": 120.0,
    "delete": 60.0,
    "stat": 20.0,
    "direct_link": 8.0,
}
DEFAULT_TIMEOUT = 30.0
#: 插件没说要等多久时，限流、风控各暂停后台多久（秒）
RATE_LIMIT_PAUSE = 600.0
RISK_CONTROL_PAUSE = 3600.0
#: 这些方法一定要请求网盘：调完一个请求都没经过 SDK 网络出口，说明插件绕过了限速
_NETWORK_METHODS = frozenset({"account_info", "list_dir", "list_tree", "changes"})
#: 已经提醒过绕过出口的后端类型（每种只记一次日志）
_unpaced_warned: set[str] = set()


def _notice_key(account_id: int) -> str:
    return f"drive:{account_id}"


class _Limiter:
    """按账号的速率排队：每隔 1/qps 秒放行一个调用，等待中的按优先级先后放行。

    优先级高的调用（播放）后到也排在前面；同优先级先到先得。等待中被取消的调用退出队列。
    """

    def __init__(self) -> None:
        self.loop = asyncio.get_running_loop()
        self._cond = asyncio.Condition()
        self._queue: list[tuple[int, int]] = []
        self._next = 0.0
        self._seq = itertools.count()

    async def acquire(self, qps: float, priority: Priority) -> None:
        interval = 1.0 / qps if qps > 0 else 0.0
        loop = asyncio.get_running_loop()
        ticket = (int(priority), next(self._seq))
        async with self._cond:
            heapq.heappush(self._queue, ticket)
            try:
                while True:
                    if self._queue[0] == ticket:
                        now = loop.time()
                        wait = self._next - now
                        if wait <= 0:
                            heapq.heappop(self._queue)
                            self._next = max(now, self._next) + interval
                            self._cond.notify_all()
                            return
                        # 等到点；期间来了更高优先级的调用会被唤醒、让给它
                        with contextlib.suppress(TimeoutError):
                            await asyncio.wait_for(self._cond.wait(), wait)
                    else:
                        await self._cond.wait()
            except BaseException:
                if ticket in self._queue:
                    self._queue.remove(ticket)
                    heapq.heapify(self._queue)
                    self._cond.notify_all()
                raise


@dataclass(slots=True)
class _Usage:
    day: date = field(default_factory=date.today)
    used: int = 0


_limiters: dict[int, _Limiter] = {}
_usage: dict[int, _Usage] = {}


def usage_today(account_id: int) -> int:
    """这个账号今天已用的调用次数（内存里的计数）。"""
    item = _usage.get(account_id)
    if item is None or item.day != date.today():
        return 0
    return item.used


def _count(account_id: int) -> None:
    item = _usage.get(account_id)
    today = date.today()
    if item is None or item.day != today:
        item = _usage[account_id] = _Usage(day=today)
    item.used += 1


def reset_state() -> None:
    """清掉内存里的排队与计数（测试换库时用）。"""
    _limiters.clear()
    _usage.clear()
    _unpaced_warned.clear()


def forget(account_id: int) -> None:
    """账号删了：丢掉它的限速与计数。"""
    _limiters.pop(account_id, None)
    _usage.pop(account_id, None)


def effective(row: DriveAccount, backend: dv.DriveBackend | None) -> tuple[float, int, int]:
    """（请求速率, 每日预算, 同时播放数）：用户设过用用户的，否则用插件声明的默认值。"""
    caps = backend.capabilities if backend is not None else dv.Capabilities()
    return (
        row.qps if row.qps is not None else caps.default_qps,
        row.daily_budget if row.daily_budget is not None else caps.default_daily_budget,
        row.read_slots if row.read_slots is not None else caps.default_read_slots,
    )


def _seconds_to_midnight() -> float:
    from datetime import datetime

    now = datetime.now()
    tomorrow = datetime.combine(now.date() + timedelta(days=1), datetime.min.time())
    return (tomorrow - now).total_seconds()


class _Meter:
    """一次调用的限速记账：调用本身领一个名额，插件经网络出口每多发一个请求再领一个。

    插件的第一个请求用调用本身的名额；不走 SDK 出口的插件至少还按调用限速。
    """

    def __init__(
        self, account_id: int, name: str, qps: float, budget: int, priority: Priority
    ) -> None:
        self.account_id = account_id
        self.name = name
        self.qps = qps
        self.budget = budget
        self.priority = priority
        #: 经出口发出的请求数
        self.requests = 0
        #: 是限速器叫停了这次调用（限流、额度用完）：不是网盘报的错，不改账号状态
        self.stopped = False
        #: 正在排队等名额（不算没进展）
        self.waiting = False
        #: 最近一次有进展的时刻（事件循环时间）
        self.progress = 0.0

    async def acquire(self) -> None:
        if (
            self.priority is Priority.BACKGROUND
            and usage_today(self.account_id) >= self.budget * BACKGROUND_SHARE
        ):
            raise dv.RateLimited(
                f"「{self.name}」今天的后台调用额度已用到 {int(BACKGROUND_SHARE * 100)}%，"
                "余量留给播放，明天继续",
                _seconds_to_midnight(),
            )
        limiter = _limiters.get(self.account_id)
        if limiter is None or limiter.loop is not asyncio.get_running_loop():
            # 应用在同一进程里重启（插件内核重载、测试）后事件循环换了，旧的排队对象不能再用
            limiter = _limiters[self.account_id] = _Limiter()
        await limiter.acquire(self.qps, self.priority)
        _count(self.account_id)

    async def pace(self) -> None:
        """出口发请求前调：领名额；账号这期间被限流了就叫停（翻到一半的列举不再接着打）。"""
        self.requests += 1
        if self.requests == 1:
            return
        self.waiting = True
        try:
            async with get_database().session() as session:
                row = await DriveAccountRepository(session).get(self.account_id)
            if row is None:
                raise dv.NotFound("网盘账号不存在")
            _check_status(row.status, row.status_until, self.priority, self.name)
            await self.acquire()
        except dv.DriveError:
            self.stopped = True
            raise
        finally:
            self.waiting = False
            self.progress = asyncio.get_running_loop().time()


async def _run(job: Any, meter: _Meter, timeout: float) -> Any:
    """跑一次后端调用；``timeout`` 秒没有进展（领到名额或返回）就取消，抛 ``TimeoutError``。"""
    loop = asyncio.get_running_loop()
    task = asyncio.ensure_future(job)
    meter.progress = loop.time()
    try:
        while True:
            left = timeout if meter.waiting else meter.progress + timeout - loop.time()
            done, _ = await asyncio.wait({task}, timeout=max(left, 0.0))
            if done:
                return task.result()
            if not meter.waiting and loop.time() - meter.progress >= timeout:
                raise TimeoutError
    finally:
        if not task.done():
            task.cancel()
            # 取消后的结果没人等了：取走异常，免得「从未取回」的告警
            task.add_done_callback(lambda t: t.cancelled() or t.exception())


async def call(
    account_id: int,
    method: str,
    *,
    priority: Priority = Priority.USER,
    **args: Any,
) -> Any:
    """以某个账号的身份调后端的一个方法。

    失败抛 ``DriveError`` 的子类（或 ``BackendUnavailable``）。
    """
    async with get_database().session() as session:
        row = await DriveAccountRepository(session).get(account_id)
        if row is None:
            raise dv.NotFound("网盘账号不存在")
        credentials = DriveAccountRepository.credentials(row)
        status, status_until, backend_type = row.status, row.status_until, row.backend
        name = row.name
    backend = get_backend(backend_type)
    _check_status(status, status_until, priority, name)
    qps, budget, _slots = effective(row, backend)
    meter = _Meter(account_id, name, qps, budget, priority)
    await meter.acquire()

    account = dv.DriveAccount(user_id=row.remote_user_id, credentials=dict(credentials))
    # 进程内的插件由出口直接读到它；进程外的带着调用号回来，宿主在这次调用的上下文里读到它
    token = net.pacer.set(meter.pace)
    try:
        value = await _run(
            getattr(backend, method)(account, **args),
            meter,
            TIMEOUTS.get(method, DEFAULT_TIMEOUT),
        )
    except TimeoutError:
        await _persist_credentials(account_id, credentials, account.credentials)
        raise dv.Transient(f"「{name}」响应超时") from None
    except dv.DriveError as exc:
        await _persist_credentials(account_id, credentials, account.credentials)
        if not meter.stopped:
            await _record_failure(account_id, name, exc)
        raise
    finally:
        net.pacer.reset(token)
    await _persist_credentials(account_id, credentials, account.credentials)
    if meter.requests == 0 and method in _NETWORK_METHODS and backend_type not in _unpaced_warned:
        _unpaced_warned.add(backend_type)
        logger.warning(
            "网盘后端 %s 的 %s 没经 SDK 网络出口发请求（movieclaw_sdk.net.http_transport）："
            "翻页等多次请求不受限速，用户配的代理也不生效",
            backend_type,
            method,
        )
    if status != DRIVE_STATUS_OK:
        await _record_recovery(account_id, status)
    return value


async def call_backend(backend: dv.DriveBackend, method: str, **args: Any) -> Any:
    """不带账号的调用（登录流程）：只有超时与错误归一，不限速、不计预算。"""
    try:
        return await asyncio.wait_for(
            getattr(backend, method)(**args), TIMEOUTS.get(method, DEFAULT_TIMEOUT)
        )
    except TimeoutError:
        raise dv.Transient(f"{backend.title}响应超时") from None


def _check_status(status: str, until: Any, priority: Priority, name: str) -> None:
    if status == DRIVE_STATUS_AUTH_EXPIRED:
        raise dv.AuthExpired(f"「{name}」的登录已失效，需要重新登录")
    if status == DRIVE_STATUS_DISABLED:
        raise dv.AuthExpired(f"「{name}」已停用")
    if status == DRIVE_STATUS_API_BROKEN and priority is Priority.BACKGROUND:
        raise dv.ApiChanged(f"「{name}」的接口有变化，插件暂时不认识，请更新插件")
    if (
        status == DRIVE_STATUS_RATE_LIMITED
        and priority is not Priority.PLAYBACK
        and until is not None
        and until > utcnow()
    ):
        # 用户操作也不打出去：每多一次被拒，网盘的冷却就往后推
        left = (until - utcnow()).total_seconds()
        raise dv.RateLimited(
            f"「{name}」被网盘限流，约 {max(1, math.ceil(left / 60))} 分钟后恢复", left
        )


async def _persist_credentials(
    account_id: int, before: dict[str, str], after: dict[str, str]
) -> None:
    """插件换了凭据：先落库（滚动刷新的令牌用一次就作废，丢了就得重新登录）。"""
    if after == before:
        return
    async with get_database().session() as session:
        await DriveAccountRepository(session).save_credentials(account_id, after)


async def _record_failure(account_id: int, name: str, exc: dv.DriveError) -> None:
    status: str | None = None
    until = None
    if isinstance(exc, dv.AuthExpired):
        status = DRIVE_STATUS_AUTH_EXPIRED
    elif isinstance(exc, dv.ApiChanged):
        status = DRIVE_STATUS_API_BROKEN
    elif isinstance(exc, dv.RiskControl):
        status = DRIVE_STATUS_RATE_LIMITED
        until = utcnow() + timedelta(seconds=RISK_CONTROL_PAUSE)
    elif isinstance(exc, dv.RateLimited):
        status = DRIVE_STATUS_RATE_LIMITED
        until = utcnow() + timedelta(seconds=exc.retry_after or RATE_LIMIT_PAUSE)
    if status is None:
        return
    logger.warning("网盘账号 %s（%s）：%s", account_id, status, exc.message)
    async with get_database().session() as session:
        await DriveAccountRepository(session).set_status(account_id, status, exc.message, until)
        if status in (DRIVE_STATUS_AUTH_EXPIRED, DRIVE_STATUS_API_BROKEN):
            title = (
                f"网盘「{name}」需要重新登录"
                if status == DRIVE_STATUS_AUTH_EXPIRED
                else f"网盘「{name}」的接口有变化"
            )
            await upsert_notice(
                session,
                dedupe_key=_notice_key(account_id),
                severity=NoticeSeverity.WARNING,
                source="drive",
                title=title,
                message=exc.message,
                payload={"account_id": account_id, "status": status},
            )


async def _record_recovery(account_id: int, previous: str) -> None:
    """调用成功了：限流、接口异常这类自动恢复的状态复位（要重新登录的不会走到这里）。"""
    async with get_database().session() as session:
        await DriveAccountRepository(session).set_status(account_id, DRIVE_STATUS_OK)
        if previous == DRIVE_STATUS_API_BROKEN:
            await resolve_notices(session, dedupe_key=_notice_key(account_id))


async def clear_notice(account_id: int) -> None:
    """重新登录、删除账号后：待处理事项消退。出错只记日志。"""
    try:
        async with get_database().session() as session:
            await resolve_notices(session, dedupe_key=_notice_key(account_id))
    except Exception:  # noqa: BLE001 -- 消退失败不影响登录
        logger.warning("消退网盘账号提醒失败", exc_info=True)
