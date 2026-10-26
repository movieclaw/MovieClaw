"""插件与宿主之间的通用调用（docs/design/plugin-ipc-http.md §3）。

契约的方法签名就是协议：服务端按它校验参数、编码返回值，客户端按它生成代理。这里用内存里的 ASGI 应用
往返验证普通调用、流式调用与错误还原，并守护宿主导出的实现与契约签名一致。
"""

from __future__ import annotations

import inspect
import os
from collections.abc import AsyncIterator
from typing import Any, Protocol

import pytest
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

from movieclaw_sdk import rpc
from movieclaw_sdk.http import UnixHttp
from movieclaw_sdk.services import SERVICES


class Point(BaseModel):
    x: int
    y: int = 0


class DemoApi(Protocol):
    async def add(self, a: int, b: int = 1) -> int: ...

    async def shift(self, point: Point, by: int) -> Point: ...

    async def nothing(self) -> None: ...

    async def deny(self) -> None: ...

    async def count(self, upto: int, fail_at: int | None = None) -> AsyncIterator[Point]: ...


class Demo:
    async def add(self, a: int, b: int = 1) -> int:
        return a + b

    async def shift(self, point: Point, by: int) -> Point:
        return Point(x=point.x + by, y=point.y + by)

    async def nothing(self) -> None:
        return None

    async def deny(self) -> None:
        raise PermissionError("不许")

    async def count(self, upto: int, fail_at: int | None = None) -> AsyncIterator[Point]:
        for i in range(upto):
            if i == fail_at:
                raise ValueError(f"第 {i} 个坏了")
            yield Point(x=i)


def make_app() -> FastAPI:
    app = FastAPI()
    target = Demo()

    @app.post("/rpc/demo/{method}")
    async def call(method: str, request: Request) -> Any:
        spec = rpc.methods(DemoApi)[method]
        data = await request.json()
        if spec.stream:
            return StreamingResponse(rpc.ndjson(spec, target, data), media_type=rpc.NDJSON)
        try:
            return JSONResponse(await rpc.invoke(spec, target, data))
        except Exception as exc:  # noqa: BLE001
            status, body = rpc.error_of(exc)
            return JSONResponse(body, status_code=status)

    return app


@pytest.fixture
async def proxy():
    """真实的 uvicorn 监听 Unix 套接字，客户端是 SDK 自己的 HTTP/1.1 客户端。"""
    import asyncio
    import socket
    import tempfile

    import uvicorn

    path = os.path.join(tempfile.mkdtemp(prefix="mcr-"), "s.sock")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(path)
    sock.listen(16)
    config = uvicorn.Config(make_app(), lifespan="off", log_level="warning")
    config.load()
    server = uvicorn.Server(config)
    task = asyncio.get_running_loop().create_task(server._serve(sockets=[sock]))
    while not server.started:
        await asyncio.sleep(0.01)
    client = rpc.RpcClient(UnixHttp(path), "/rpc")
    yield rpc.ServiceProxy(client, "demo", DemoApi)
    await client.aclose()
    server.should_exit = True
    await task


def test_specs_come_from_the_signature() -> None:
    specs = rpc.methods(DemoApi)
    assert set(specs) == {"add", "shift", "nothing", "deny", "count"}
    add = specs["add"]
    assert [p.name for p in add.params] == ["a", "b"]
    assert add.params[0].required and not add.params[1].required
    assert specs["nothing"].returns is None
    assert specs["count"].stream and not add.stream
    with pytest.raises(ValueError, match="缺少参数 a"):
        add.decode_args({})
    with pytest.raises(ValueError, match="没有参数 c"):
        add.decode_args({"a": 1, "c": 2})


async def test_calls_round_trip_with_validation(proxy) -> None:
    assert await proxy.add(a=2) == 3
    assert await proxy.add(a=2, b=5) == 7
    assert await proxy.shift(point=Point(x=1, y=2), by=3) == Point(x=4, y=5)
    assert await proxy.nothing() is None
    with pytest.raises(PermissionError, match="不许"):
        await proxy.deny()
    with pytest.raises(ValueError):
        await proxy.add(a="不是数字")


async def test_streams_yield_items_and_carry_errors(proxy) -> None:
    assert [p.x async for p in proxy.count(upto=3)] == [0, 1, 2]
    got = []
    with pytest.raises(ValueError, match="第 2 个坏了"):
        async for point in proxy.count(upto=5, fail_at=2):
            got.append(point.x)
    assert got == [0, 1]


def test_host_exports_match_the_contracts() -> None:
    """宿主导出的实现与契约逐个方法比对：参数名、默认值一致，契约里的方法一个不少。"""
    from movieclaw_api.services.plugin_runtime import EXPORTS

    assert set(EXPORTS) == set(SERVICES)
    for name, contract in SERVICES.items():
        impl = EXPORTS[name]
        for method, spec in rpc.methods(contract).items():
            fn = getattr(impl, method, None)
            assert fn is not None, f"{name}.{method} 没有实现"
            params = list(inspect.signature(fn).parameters.values())[1:]
            assert [(p.name, p.default) for p in params] == [
                (p.name, p.default) for p in spec.params
            ], f"{name}.{method} 的签名与契约不一致"
