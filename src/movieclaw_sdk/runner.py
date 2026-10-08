"""进程外运行器（插件侧，docs/design/plugin-phase3.md §4）。

宿主以 ``python -s -m movieclaw_sdk.runner --path <插件目录> --module <模块> --entry <条目 id>``
拉起本进程，经标准输入输出交换协议消息。插件代码照常写 ``@plugin`` 和 ``ctx.on(...)``，拿到的是
``RemoteContext``：声明经协议告诉宿主，宿主在真实的内核上下文里登记代理；事件、钩子调用再经协议
送回这里执行。

插件自己的 ``print`` 会被改到标准错误（宿主按行收进日志），标准输出只留给协议。
"""

from __future__ import annotations

import argparse
import asyncio
import importlib
import logging
import os
import sys
import traceback
from collections.abc import Callable, Coroutine
from typing import Any

from movieclaw_kernel import Event, Mode, Plugin, ServiceKey
from movieclaw_sdk import SDK_VERSION
from movieclaw_sdk.protocol import MAX_LINE, decode, dump, encode, known_events, load

logger = logging.getLogger("movieclaw_sdk.runner")

_UNSET: Any = object()


class RemoteContext:
    """进程外插件拿到的上下文：与内核 ``Context`` 同名同签名。

    目前支持事件与钩子、后台任务、清理；服务与注册表贡献随第三阶段后续 PR 开放。
    """

    def __init__(self, runner: Runner, entry_id: str, title: str, config: Any) -> None:
        self._runner = runner
        self.entry_id = entry_id
        self.title = title
        self.config = config
        self.third_party = True
        self.logger = logging.getLogger(f"movieclaw_plugin.{entry_id}")
        self._handlers: dict[str, tuple[Event[Any, Any], Callable[..., Any]]] = {}
        self._tasks: set[asyncio.Task[Any]] = set()
        self._effects: list[Callable[[], Any]] = []

    def on(
        self,
        event: Event[Any, Any],
        handler: Callable[..., Any],
        *,
        id: str | None = None,
        priority: int = 0,
    ) -> None:
        if known_events().get(event.name) is not event:
            raise ValueError(f"事件 {event.name} 没有开放给第三方插件")
        key = id or f"{event.name}#{len(self._handlers)}"
        if key in self._handlers:
            raise ValueError(f"监听器 id 重复：{key}")
        self._handlers[key] = (event, handler)
        self._runner.send({"type": "on", "event": event.name, "id": key, "priority": priority})

    def task(self, coro: Coroutine[Any, Any, Any], *, name: str) -> asyncio.Task[Any]:
        task = asyncio.get_running_loop().create_task(coro, name=f"plugin:{self.entry_id}:{name}")
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    def effect(self, disposer: Callable[[], Any], *, label: str = "effect") -> None:
        self._effects.append(disposer)

    def use(self, key: ServiceKey[Any]) -> Any:
        raise NotImplementedError(f"进程外插件暂不能使用服务 {key.name}（第三阶段 C3 起逐步开放）")

    def contribute(self, *args: Any, **kwargs: Any) -> None:
        raise NotImplementedError("进程外插件暂不能往注册表贡献（第三阶段 C4 起开放）")

    async def dispose(self) -> None:
        for task in list(self._tasks):
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
        for disposer in reversed(self._effects):
            try:
                result = disposer()
                if asyncio.iscoroutine(result):
                    await result
            except Exception:  # noqa: BLE001 -- 清理出错不影响其余清理
                logger.exception("插件清理函数出错")


class Runner:
    def __init__(self, writer: Any) -> None:
        self._writer = writer
        self._nexts: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._calls: set[asyncio.Task[Any]] = set()
        self.ctx: RemoteContext | None = None

    def send(self, message: dict[str, Any]) -> None:
        self._writer.write(encode(message))
        self._writer.flush()

    # ------------------------------------------------------------------ 调用
    async def _handle_call(self, message: dict[str, Any]) -> None:
        call_id = message["id"]
        try:
            assert self.ctx is not None
            event, handler = self.ctx._handlers[message["listener"]]
            payload = load(event.payload, message["payload"])
            if event.mode is Mode.WATERFALL:
                result = await _maybe_await(handler(payload, self._next_for(call_id, event)))
            else:
                result = await _maybe_await(handler(payload))
            data = dump(event.result, result) if event.mode is not Mode.EMIT else None
            self.send({"type": "reply", "id": call_id, "ok": True, "result": data})
        except Exception as exc:  # noqa: BLE001 -- 监听器出错原样报给宿主，由宿主按内核规则处理
            self.send(
                {
                    "type": "reply",
                    "id": call_id,
                    "ok": False,
                    "error": f"{type(exc).__name__}: {exc}",
                    "traceback": traceback.format_exc(limit=8),
                }
            )

    def _next_for(self, call_id: str, event: Event[Any, Any]) -> Callable[..., Any]:
        async def next_(new_value: Any = _UNSET) -> Any:
            future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
            self._nexts[call_id] = future
            message: dict[str, Any] = {"type": "next", "id": call_id}
            if new_value is not _UNSET:
                message["payload"] = dump(event.payload, new_value)
            self.send(message)
            reply = await future
            if not reply.get("ok"):
                raise RuntimeError(reply.get("error") or "下游处理失败")
            return load(event.result, reply.get("result"))

        return next_

    # ------------------------------------------------------------------ 主循环
    async def serve(self, reader: asyncio.StreamReader) -> int:
        while True:
            line = await reader.readline()
            if not line:
                return 0  # 宿主关了管道：宿主没了，跟着退出
            message = decode(line)
            kind = message["type"]
            if kind == "call":
                task = asyncio.get_running_loop().create_task(self._handle_call(message))
                self._calls.add(task)
                task.add_done_callback(self._calls.discard)
            elif kind == "next_result":
                future = self._nexts.pop(message["id"], None)
                if future is not None and not future.done():
                    future.set_result(message)
            elif kind == "dispose":
                if self.ctx is not None:
                    await self.ctx.dispose()
                self.send({"type": "disposed"})
                return 0


async def _maybe_await(value: Any) -> Any:
    if asyncio.iscoroutine(value):
        return await value
    return value


def _find_plugin(module_name: str, entry_id: str) -> Plugin:
    module = importlib.import_module(module_name)
    for value in vars(module).values():
        if isinstance(value, Plugin) and value.name == entry_id:
            return value
    raise LookupError(f"模块 {module_name} 里没有名为 {entry_id} 的插件")


async def run(args: argparse.Namespace) -> int:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=MAX_LINE)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    runner = Runner(_PROTOCOL_OUT)
    runner.send({"type": "hello", "sdk": SDK_VERSION, "pid": os.getpid()})
    init = decode(await reader.readline())
    try:
        found = _find_plugin(args.module, args.entry)
        config = init.get("config")
        if found.config is not None:
            config = found.config.model_validate(config or {})
        runner.ctx = RemoteContext(runner, args.entry, init.get("title") or found.title, config)
        await found.apply(runner.ctx)
    except Exception as exc:  # noqa: BLE001 -- 启动失败报给宿主，由内核标 FAILED
        runner.send({"type": "failed", "error": f"{type(exc).__name__}: {exc}"})
        traceback.print_exc()
        return 1
    runner.send({"type": "ready", "title": found.title})
    return await runner.serve(reader)


_PROTOCOL_OUT: Any = None


def main(argv: list[str] | None = None) -> int:
    global _PROTOCOL_OUT
    parser = argparse.ArgumentParser(description="MovieClaw 进程外插件运行器")
    parser.add_argument("--path", required=True, help="插件代码所在目录（加入 sys.path）")
    parser.add_argument("--module", required=True)
    parser.add_argument("--entry", required=True, help="条目 id（@plugin 的名字）")
    args = parser.parse_args(argv)
    # 标准输出只留给协议：插件的 print 改到标准错误
    _PROTOCOL_OUT = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    sys.stdout = sys.stderr
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(levelname)s %(message)s")
    sys.path.insert(0, args.path)
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())
