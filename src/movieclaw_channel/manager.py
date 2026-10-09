"""ChannelManager —— 通道账号的生命周期管理。

每个已绑定账号对应一个后台任务组:adapter 收消息循环 + dispatcher(会话
worker 与发送泵)。manager 负责:

- 启动/停止单个账号(绑定完成后热启动,无需重启进程);
- 收消息循环崩溃后的退避重启(网络抖动自愈);
- 凭据失效(ChannelAuthError)时停账号并回调服务层标记 stale;
- 进程关闭时统一停止全部账号。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from movieclaw_channel.adapter import ChannelAdapter, ChannelContext
from movieclaw_channel.dispatcher import ChannelDispatcher
from movieclaw_channel.types import ChannelAuthError

logger = logging.getLogger("movieclaw_channel.manager")

#: 收消息循环异常退出后的重启退避(秒)
_RESTART_BACKOFF_S = 30.0
#: 停止账号时的优雅退出窗口:先置 stop 让长轮询中断、notifystop 送达,
#: 超时仍未退出才强制取消
_GRACEFUL_STOP_TIMEOUT_S = 5.0


@dataclass(slots=True)
class _AccountRuntime:
    """单账号的运行时句柄。"""

    adapter: ChannelAdapter
    dispatcher: ChannelDispatcher
    stop: asyncio.Event
    task: asyncio.Task[None] | None = None
    #: 最近一次收消息循环错误(中文,供状态接口展示)
    last_error: str | None = None
    stale: bool = field(default=False)


class ChannelManager:
    """进程级单例:管理所有通道账号的后台任务。"""

    def __init__(self) -> None:
        # 键是 (通道, 账号) 元组：第三方通道 id 带插件前缀（含冒号），拼成字符串再拆会拆错
        self._accounts: dict[tuple[str, str], _AccountRuntime] = {}

    @staticmethod
    def _key(channel_id: str, account_id: str) -> tuple[str, str]:
        return (channel_id, account_id)

    def is_running(self, channel_id: str, account_id: str) -> bool:
        rt = self._accounts.get(self._key(channel_id, account_id))
        return rt is not None and rt.task is not None and not rt.task.done()

    def get_dispatcher(self, channel_id: str, account_id: str) -> ChannelDispatcher | None:
        """取运行中账号的 dispatcher(主动推送用);未运行返回 None。"""
        rt = self._accounts.get(self._key(channel_id, account_id))
        if rt is None or rt.task is None or rt.task.done():
            return None
        return rt.dispatcher

    def is_stale(self, channel_id: str, account_id: str) -> bool:
        rt = self._accounts.get(self._key(channel_id, account_id))
        return rt.stale if rt else False

    async def start_account(
        self,
        adapter: ChannelAdapter,
        dispatcher: ChannelDispatcher,
        *,
        account_id: str,
        initial_cursor: str,
        save_cursor: Callable[[str], Awaitable[None]],
        on_auth_error: Callable[[str], Awaitable[None]] | None = None,
    ) -> None:
        """启动一个账号(已在运行则先停旧的再起新的,支持重新绑定热替换)。"""
        key = self._key(adapter.channel_id, account_id)
        if key in self._accounts:
            await self.stop_account(adapter.channel_id, account_id)

        stop = asyncio.Event()
        rt = _AccountRuntime(adapter=adapter, dispatcher=dispatcher, stop=stop)
        ctx = ChannelContext(
            account_id=account_id,
            on_inbound=dispatcher.submit_inbound,
            save_cursor=save_cursor,
            initial_cursor=initial_cursor,
            stop=stop,
        )
        dispatcher.start()
        rt.task = asyncio.create_task(
            self._supervise(rt, ctx, on_auth_error),
            name=f"channel-account-{key[0]}:{key[1]}",
        )
        self._accounts[key] = rt
        logger.info("通道账号已启动 %s:%s", *key)

    async def _supervise(
        self,
        rt: _AccountRuntime,
        ctx: ChannelContext,
        on_auth_error: Callable[[str], Awaitable[None]] | None,
    ) -> None:
        """收消息循环的守护壳:异常退避重启,凭据失效则终止并上报。"""
        while not ctx.stop.is_set():  # type: ignore[union-attr]
            try:
                await rt.adapter.run(ctx)
                return  # 正常退出 = stop 置位
            except asyncio.CancelledError:
                raise
            except ChannelAuthError as exc:
                rt.stale = True
                rt.last_error = str(exc)
                logger.error(
                    "通道凭据已失效,账号停止收发,请重新扫码绑定 account=%s err=%s",
                    ctx.account_id,
                    exc,
                )
                if on_auth_error is not None:
                    try:
                        await on_auth_error(ctx.account_id)
                    except Exception:  # noqa: BLE001
                        logger.exception("stale 状态回调失败 account=%s", ctx.account_id)
                # 收消息循环已终止,发送泵/会话 worker 也一并关掉,避免任务泄漏
                # (账号句柄保留在 _accounts 里,状态接口据此展示 stale)
                await rt.dispatcher.close()
                return
            except Exception as exc:  # noqa: BLE001
                rt.last_error = str(exc)
                logger.exception(
                    "收消息循环异常,%s 秒后重启 account=%s", _RESTART_BACKOFF_S, ctx.account_id
                )
                try:
                    await asyncio.wait_for(ctx.stop.wait(), timeout=_RESTART_BACKOFF_S)  # type: ignore[union-attr]
                    return  # 退避期间被要求停止
                except TimeoutError:
                    continue

    async def stop_account(self, channel_id: str, account_id: str) -> None:
        key = self._key(channel_id, account_id)
        rt = self._accounts.pop(key, None)
        if rt is None:
            return
        rt.stop.set()
        if rt.task is not None and not rt.task.done():
            # 优雅窗口:stop 信号会掐断在飞长轮询,循环自然退出并发 notifystop;
            # 超时兜底强制取消(wait_for 超时时已自动 cancel 并等待任务结束)
            with contextlib.suppress(TimeoutError, asyncio.CancelledError, Exception):
                await asyncio.wait_for(rt.task, timeout=_GRACEFUL_STOP_TIMEOUT_S)
        await rt.dispatcher.close()
        logger.info("通道账号已停止 %s:%s", *key)

    async def close(self) -> None:
        """进程关闭:停止全部账号。"""
        for channel_id, account_id in list(self._accounts):
            await self.stop_account(channel_id, account_id)
