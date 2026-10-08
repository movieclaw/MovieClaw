"""进程外运行器（宿主侧，docs/design/plugin-phase3.md §4）。

进程外插件在内核里就是一个普通条目：``apply`` 拉起子进程（``movieclaw_sdk.runner``）、握手，
再把插件声明的每个监听器**以代理的形式**登记到真实的内核上下文上。于是事件分发、钩子的超时与熔断、
卸载回收全是内核现成的行为，代理背后只是换成了另一个进程：

- 子进程崩溃：在途调用立刻失败（监听器出错 / 钩子走默认实现），按退避重启；
  10 分钟内崩 5 次就不再重启，错误进诊断；
- 卸载：先请插件自己清理，5 秒后 ``SIGTERM``，再 5 秒 ``SIGKILL``，不留进程；
- 子进程只拿到最小环境：代码路径、语言与时区，不继承主密钥、数据库地址、代理凭据。
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import logging
import os
import sys
import time
from collections import deque
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from movieclaw_kernel import Context, Delivery, Mode, Plugin
from movieclaw_sdk.protocol import MAX_LINE, decode, dump, encode, known_events, load

logger = logging.getLogger("movieclaw_api.plugin_runtime")

HANDSHAKE_TIMEOUT = 30.0
#: 普通事件的单次投递时限（钩子另有内核的时限，更短）
CALL_TIMEOUT = 30.0
STOP_GRACE = 5.0
CRASH_WINDOW = 600.0
CRASH_LIMIT = 5
BACKOFF_MAX = 60.0
#: 子进程能看到的环境变量（其余一律不给）
_ENV_KEEP = ("PATH", "LANG", "LC_ALL", "TZ", "HOME", "TMPDIR")
_UNSET: Any = object()

NextFn = Callable[[Any], Awaitable[Any]]

#: 正在运行的插件进程（诊断与测试用）
sessions: dict[str, Session] = {}


class PluginProcessGone(RuntimeError):
    pass


def _child_env() -> dict[str, str]:
    import movieclaw_sdk

    env = {k: v for k, v in os.environ.items() if k in _ENV_KEEP}
    # 与宿主同一份代码（overlay 部署时是 overlay 里的那份）
    env["PYTHONPATH"] = str(Path(movieclaw_sdk.__file__).resolve().parent.parent)
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


class Session:
    """一个插件进程：拉起、握手、调用、监管、停止。"""

    def __init__(self, entry_id: str, *, path: Path, module: str, config: Any) -> None:
        self.entry_id = entry_id
        self._path = path
        self._module = module
        self._config = config
        self._proc: asyncio.subprocess.Process | None = None
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._nexts: dict[str, NextFn] = {}
        self._ids = itertools.count(1)
        self._readers: list[asyncio.Task[Any]] = []
        self._stopping = False
        self._ready = False
        self._crashes: deque[float] = deque()
        self.declarations: list[dict[str, Any]] = []
        self.title: str | None = None

    @property
    def online(self) -> bool:
        """握手完成、进程还在、没在停：只有这时才接受调用（握手期间进来的调用会打乱协议）。"""
        return (
            self._ready
            and self._proc is not None
            and self._proc.returncode is None
            and not self._stopping
        )

    @property
    def pid(self) -> int | None:
        return self._proc.pid if self._proc is not None else None

    # ------------------------------------------------------------------ 启动
    async def start(self) -> list[dict[str, Any]]:
        """拉起进程并握手，返回插件声明的监听器；插件启动失败抛错（内核据此标 FAILED）。"""
        self._ready = False
        self._proc = await asyncio.create_subprocess_exec(
            sys.executable,
            "-s",
            "-m",
            "movieclaw_sdk.runner",
            "--path",
            str(self._path),
            "--module",
            self._module,
            "--entry",
            self.entry_id,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(self._path),
            env=_child_env(),
            limit=MAX_LINE,
        )
        self._readers = [
            asyncio.get_running_loop().create_task(self._pump_stderr(self._proc)),
        ]
        try:
            declarations = await asyncio.wait_for(self._handshake(self._proc), HANDSHAKE_TIMEOUT)
        except BaseException:
            await self._kill()
            raise
        self._readers.append(asyncio.get_running_loop().create_task(self._pump_stdout(self._proc)))
        self._ready = True
        logger.info(
            "插件 %s 已在独立进程中运行（pid %s，%d 个监听器）",
            self.entry_id,
            self._proc.pid,
            len(declarations),
        )
        return declarations

    async def _handshake(self, proc: asyncio.subprocess.Process) -> list[dict[str, Any]]:
        assert proc.stdout is not None
        hello = await self._read(proc)
        if hello["type"] != "hello":
            raise RuntimeError(f"插件进程握手失败：期望 hello，收到 {hello['type']}")
        await self._send({"type": "init", "entry_id": self.entry_id, "config": self._config})
        declarations: list[dict[str, Any]] = []
        while True:
            message = await self._read(proc)
            kind = message["type"]
            if kind == "on":
                declarations.append(message)
            elif kind == "ready":
                self.title = message.get("title")
                return declarations
            elif kind == "failed":
                raise RuntimeError(message.get("error") or "插件启动失败")
            else:
                raise RuntimeError(f"插件进程握手期间发来意外的消息：{kind}")

    async def _read(self, proc: asyncio.subprocess.Process) -> dict[str, Any]:
        assert proc.stdout is not None
        line = await proc.stdout.readline()
        if not line:
            code = await proc.wait()
            raise PluginProcessGone(f"插件进程启动期间退出（退出码 {code}）")
        return decode(line)

    async def _send(self, message: dict[str, Any]) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None or proc.returncode is not None:
            raise PluginProcessGone("插件进程不在运行")
        proc.stdin.write(encode(message))
        try:
            await proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError) as exc:
            raise PluginProcessGone("插件进程不在运行") from exc

    # ------------------------------------------------------------------ 读取
    async def _pump_stderr(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stderr is not None
        while line := await proc.stderr.readline():
            logger.info("[%s] %s", self.entry_id, line.decode("utf-8", "replace").rstrip())

    async def _pump_stdout(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stdout is not None
        try:
            while line := await proc.stdout.readline():
                message = decode(line)
                kind = message["type"]
                if kind == "reply":
                    future = self._pending.pop(message["id"], None)
                    if future is not None and not future.done():
                        future.set_result(message)
                elif kind == "next":
                    asyncio.get_running_loop().create_task(self._run_next(message))
                elif kind == "disposed":
                    pass
                else:
                    logger.warning("插件 %s 发来意外的消息：%s", self.entry_id, kind)
        except ValueError:
            logger.exception("插件 %s 发来无法解析的消息，断开", self.entry_id)
            await self._kill()
        finally:
            if proc is self._proc:
                self._ready = False
                self._fail_pending(PluginProcessGone("插件进程已退出"))

    async def _run_next(self, message: dict[str, Any]) -> None:
        call_id = message["id"]
        run = self._nexts.pop(call_id, None)
        reply: dict[str, Any] = {"type": "next_result", "id": call_id}
        if run is None:
            reply.update(ok=False, error="这次调用已经结束")
        else:
            try:
                reply.update(ok=True, result=await run(message.get("payload", _UNSET)))
            except Exception as exc:  # noqa: BLE001 -- 下游出错原样告诉插件
                reply.update(ok=False, error=f"{type(exc).__name__}: {exc}")
        with contextlib.suppress(PluginProcessGone):
            await self._send(reply)

    def _fail_pending(self, exc: Exception) -> None:
        for future in self._pending.values():
            if not future.done():
                future.set_exception(exc)
        self._pending.clear()
        self._nexts.clear()

    # ------------------------------------------------------------------ 调用
    async def call(
        self,
        listener: str,
        payload: Any,
        run_next: NextFn | None = None,
        *,
        timeout: float = CALL_TIMEOUT,
    ) -> Any:
        if not self.online:
            raise PluginProcessGone(f"插件 {self.entry_id} 的进程不在运行")
        call_id = str(next(self._ids))
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[call_id] = future
        if run_next is not None:
            self._nexts[call_id] = run_next
        try:
            await self._send(
                {"type": "call", "id": call_id, "listener": listener, "payload": payload}
            )
            reply = await asyncio.wait_for(future, timeout)
        finally:
            self._pending.pop(call_id, None)
            self._nexts.pop(call_id, None)
        if not reply.get("ok"):
            raise RuntimeError(f"插件 {self.entry_id} 处理失败：{reply.get('error')}")
        return reply.get("result")

    # ------------------------------------------------------------------ 监管
    async def supervise(self) -> None:
        """进程意外退出就按退避重启；崩溃太频繁则放弃并抛错（错误进诊断）。"""
        backoff = 1.0
        while True:
            proc = self._proc
            assert proc is not None
            code = await proc.wait()
            if self._stopping:
                return
            now = time.monotonic()
            self._crashes.append(now)
            while self._crashes and now - self._crashes[0] > CRASH_WINDOW:
                self._crashes.popleft()
            if len(self._crashes) >= CRASH_LIMIT:
                raise RuntimeError(
                    f"插件进程 {CRASH_WINDOW / 60:.0f} 分钟内崩溃 {len(self._crashes)} 次"
                    f"（最近一次退出码 {code}），已停止重启；修好后重新启用该插件"
                )
            logger.warning(
                "插件 %s 的进程意外退出（退出码 %s），%.0f 秒后重启", self.entry_id, code, backoff
            )
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, BACKOFF_MAX)
            previous = {(d["event"], d["id"]) for d in self.declarations}
            try:
                declarations = await self.start()
            except Exception:
                logger.exception("插件 %s 重启失败", self.entry_id)
                continue
            if {(d["event"], d["id"]) for d in declarations} != previous:
                logger.error("插件 %s 重启后声明的监听器变了，按崩溃处理", self.entry_id)
                await self._kill()
                continue
            backoff = 1.0

    async def stop(self) -> None:
        self._stopping = True
        proc = self._proc
        if proc is not None and proc.returncode is None:
            with contextlib.suppress(PluginProcessGone, asyncio.TimeoutError):
                await self._send({"type": "dispose"})
                await asyncio.wait_for(proc.wait(), STOP_GRACE)
            if proc.returncode is None:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), STOP_GRACE)
                except TimeoutError:
                    proc.kill()
                    await proc.wait()
        for task in self._readers:
            task.cancel()
        await asyncio.gather(*self._readers, return_exceptions=True)
        self._fail_pending(PluginProcessGone("插件已卸载"))

    async def _kill(self) -> None:
        proc = self._proc
        if proc is not None and proc.returncode is None:
            proc.kill()
            await proc.wait()


def _proxy(session: Session, declaration: dict[str, Any]) -> tuple[Any, Callable[..., Any]]:
    event = known_events().get(declaration["event"])
    if event is None:
        raise ValueError(f"事件 {declaration['event']} 不存在或没有开放给第三方插件")
    if event.delivery is Delivery.DURABLE:
        raise NotImplementedError(f"进程外插件暂不能订阅可靠事件 {event.name}（第三阶段 C3 开放）")
    listener = declaration["id"]

    if event.mode is Mode.WATERFALL:

        async def waterfall(payload: Any, next_: Callable[..., Any]) -> Any:
            async def run_next(data: Any) -> Any:
                value = await (next_() if data is _UNSET else next_(load(event.payload, data)))
                return dump(event.result, value)

            data = await session.call(listener, dump(event.payload, payload), run_next)
            return load(event.result, data)

        return event, waterfall

    async def call(payload: Any) -> Any:
        data = await session.call(listener, dump(event.payload, payload))
        return load(event.result, data) if event.mode is Mode.BAIL else None

    return event, call


def remote_plugin(entry_id: str, *, title: str, path: Path, module: str, config: Any) -> Plugin:
    """进程外运行的插件条目：代码在子进程里，内核里只有代理。"""

    async def apply(ctx: Context) -> None:
        session = Session(entry_id, path=path, module=module, config=config)
        declarations = await session.start()
        session.declarations = declarations
        ctx.effect(session.stop, label="stop-process")
        for declaration in declarations:
            event, handler = _proxy(session, declaration)
            ctx.on(
                event, handler, id=declaration["id"], priority=int(declaration.get("priority", 0))
            )
        ctx.task(session.supervise(), name="supervise")
        sessions[entry_id] = session
        ctx.effect(lambda: sessions.pop(entry_id, None), label="forget-session")

    return Plugin(name=entry_id, title=title, apply=apply, disableable=True, apply_timeout=45.0)
