"""插件与宿主之间的 HTTP/1.1 客户端（movieclaw_sdk.http，plugin-ipc-http.md §4.4）。

对着真实的 uvicorn（Unix 套接字）验证：保活复用、服务端空闲关连接后自动重试、取消即断开（服务端收到
``http.disconnect``）、分块流按行读、查询参数编码、超时。
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
import tempfile

import pytest
import uvicorn

from movieclaw_sdk.http import UnixHttp

seen: dict[str, list] = {"disconnects": [], "peers": []}


async def app(scope, receive, send) -> None:
    if scope["type"] != "http":
        return
    path = scope["path"]
    body = b""
    while True:
        message = await receive()
        body += message.get("body", b"")
        if not message.get("more_body"):
            break
    if path == "/slow":
        # 等调用方：它走了会收到 http.disconnect
        message = await receive()
        seen["disconnects"].append(message["type"])
        return
    if path == "/lines":
        await send({"type": "http.response.start", "status": 200, "headers": []})
        for i in range(3):
            line = json.dumps({"i": i}).encode() + b"\n"
            await send({"type": "http.response.body", "body": line, "more_body": True})
            await asyncio.sleep(0.01)
        await send({"type": "http.response.body", "body": b""})
        return
    payload = {
        "path": path,
        "query": scope["query_string"].decode(),
        "body": body.decode(),
        "auth": dict(scope["headers"]).get(b"authorization", b"").decode(),
    }
    data = json.dumps(payload).encode()
    headers = [(b"content-type", b"application/json")]
    await send({"type": "http.response.start", "status": 201, "headers": headers})
    await send({"type": "http.response.body", "body": data})


@pytest.fixture
async def server():
    path = os.path.join(tempfile.mkdtemp(prefix="mch-"), "s.sock")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(path)
    sock.listen(16)
    # 保活只留 0.2 秒：模拟服务端把空闲连接关掉
    config = uvicorn.Config(app, lifespan="off", log_level="warning", timeout_keep_alive=0.2)
    config.load()
    instance = uvicorn.Server(config)
    task = asyncio.get_running_loop().create_task(instance._serve(sockets=[sock]))
    while not instance.started:
        await asyncio.sleep(0.01)
    seen["disconnects"].clear()
    yield path
    instance.should_exit = True
    await task


async def test_requests_reuse_connections_and_survive_idle_close(server) -> None:
    http = UnixHttp(server, headers={"Authorization": "Bearer t"})
    reply = await http.request("POST", "/echo", params={"a": [1, 2], "b": "x"}, json={"k": "值"})
    assert reply.status_code == 201
    assert reply.json() == {
        "path": "/echo",
        "query": "a=1&a=2&b=x",
        "body": '{"k":"值"}',
        "auth": "Bearer t",
    }
    assert len(http._idle) == 1  # 保活，连接回池
    await asyncio.sleep(0.5)  # 服务端按保活超时关掉了空闲连接
    assert (await http.request("GET", "/again")).json()["path"] == "/again"
    await http.aclose()


async def test_cancelling_a_call_disconnects(server) -> None:
    http = UnixHttp(server)
    call = asyncio.ensure_future(http.request("POST", "/slow", json={}))
    await asyncio.sleep(0.1)
    call.cancel()
    with pytest.raises(asyncio.CancelledError):
        await call
    for _ in range(50):
        if seen["disconnects"]:
            break
        await asyncio.sleep(0.02)
    assert seen["disconnects"] == ["http.disconnect"]
    assert http._idle == []  # 被取消的连接不回池
    await http.aclose()


async def test_timeouts_disconnect_too(server) -> None:
    http = UnixHttp(server)
    with pytest.raises(TimeoutError):
        await http.request("POST", "/slow", json={}, timeout=0.1)
    for _ in range(50):
        if seen["disconnects"]:
            break
        await asyncio.sleep(0.02)
    assert seen["disconnects"] == ["http.disconnect"]
    await http.aclose()


async def test_streams_come_line_by_line(server) -> None:
    http = UnixHttp(server)
    async with http.stream("GET", "/lines") as response:
        assert response.status_code == 200
        lines = [json.loads(line) async for line in response.aiter_lines() if line]
    assert lines == [{"i": 0}, {"i": 1}, {"i": 2}]
    assert len(http._idle) == 1  # 读完了，连接回池
    await http.aclose()
