"""插件与宿主之间用的 HTTP/1.1 客户端（Unix 套接字，docs/design/plugin-ipc-http.md §4.4）。

协议就是标准 HTTP/1.1，只是客户端实现精简：保活连接池 + httptools（uvicorn 的 C 解析器，
``uvicorn[standard]`` 已带）解析响应。httpx 每个请求在客户端要花 0.5～0.8 毫秒 CPU，
单个插件进程最多七八百次每秒；这里约 0.05 毫秒，插件调宿主的开销回到原来管道协议的水平。

- 复用的空闲连接可能刚被服务端按保活超时关掉：还没收到任何响应字节就断了，
  说明服务端没开始处理，换新连接重试一次；
- 超时、被取消都关掉这条连接：服务端据此知道调用方走了（取消就是断开）；
- 流式响应（分块传输）逐块产出，``aiter_lines`` 按行切分（ndjson / SSE）。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
from collections.abc import AsyncIterator
from typing import Any
from urllib.parse import urlencode

import httptools

#: 连接池里最多留几条空闲连接
MAX_IDLE = 32
_READ = 65536


class _Parsed:
    """httptools 的回调目标：收响应头与响应体。"""

    __slots__ = ("headers", "chunks", "head_done", "done")

    def __init__(self) -> None:
        self.headers: dict[str, str] = {}
        self.chunks: list[bytes] = []
        self.head_done = False
        self.done = False

    def on_header(self, name: bytes, value: bytes) -> None:
        self.headers[name.decode("latin-1").lower()] = value.decode("latin-1")

    def on_headers_complete(self) -> None:
        self.head_done = True

    def on_body(self, body: bytes) -> None:
        self.chunks.append(body)

    def on_message_complete(self) -> None:
        self.done = True


class Response:
    def __init__(self, status: int, headers: dict[str, str], body: bytes) -> None:
        self.status_code = status
        self.headers = headers
        self.content = body

    @property
    def text(self) -> str:
        return self.content.decode("utf-8", "replace")

    def json(self) -> Any:
        return json.loads(self.content) if self.content else None


class StreamResponse:
    """流式响应：头已收到，响应体边读边产出。"""

    def __init__(self, client: UnixHttp, conn: _Conn, parser: Any, parsed: _Parsed) -> None:
        self._client = client
        self._conn = conn
        self._parser = parser
        self._parsed = parsed
        self.status_code = parser.get_status_code()
        self.headers = parsed.headers

    async def aiter_bytes(self) -> AsyncIterator[bytes]:
        parsed = self._parsed
        while True:
            if parsed.chunks:
                chunks, parsed.chunks = parsed.chunks, []
                for chunk in chunks:
                    yield chunk
            if parsed.done:
                return
            data = await self._conn.reader.read(_READ)
            if not data:
                raise ConnectionError("对端在响应途中关闭了连接")
            self._parser.feed_data(data)

    async def aiter_lines(self) -> AsyncIterator[str]:
        buffer = b""
        async for chunk in self.aiter_bytes():
            buffer += chunk
            *lines, buffer = buffer.split(b"\n")
            for line in lines:
                yield line.rstrip(b"\r").decode("utf-8", "replace")
        if buffer:
            yield buffer.decode("utf-8", "replace")

    async def aread(self) -> bytes:
        return b"".join([chunk async for chunk in self.aiter_bytes()])

    @property
    def text(self) -> str:
        return b"".join(self._parsed.chunks).decode("utf-8", "replace")


class _Conn:
    __slots__ = ("reader", "writer")

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader = reader
        self.writer = writer

    def close(self) -> None:
        with contextlib.suppress(Exception):
            self.writer.close()


class UnixHttp:
    """一个 Unix 套接字上的 HTTP/1.1 客户端（保活连接池）。"""

    def __init__(
        self, path: str, *, headers: dict[str, str] | None = None, timeout: float | None = 60.0
    ) -> None:
        self.path = path
        self.timeout = timeout
        self._headers = {"host": "movieclaw", **{k.lower(): v for k, v in (headers or {}).items()}}
        self._idle: list[_Conn] = []
        self._closed = False

    # ------------------------------------------------------------------ 连接
    async def _connect(self) -> _Conn:
        reader, writer = await asyncio.open_unix_connection(self.path, limit=_READ)
        return _Conn(reader, writer)

    def _release(self, conn: _Conn, parsed: _Parsed) -> None:
        # HTTP/1.1 默认保活，除非对端说了 Connection: close（httptools 的 should_keep_alive()
        # 在整条消息解析完之后恒为假，不能用）
        keep = parsed.headers.get("connection", "").lower() != "close"
        if not self._closed and keep and len(self._idle) < MAX_IDLE:
            self._idle.append(conn)
        else:
            conn.close()

    def _encode(
        self,
        method: str,
        target: str,
        params: dict[str, Any] | None,
        json_body: Any,
        content: bytes | None,
        headers: dict[str, str] | None,
    ) -> bytes:
        if params:
            target = f"{target}?{urlencode(params, doseq=True)}"
        merged = dict(self._headers)
        if headers:
            merged.update({k.lower(): v for k, v in headers.items()})
        body = content or b""
        if json_body is not None:
            body = json.dumps(json_body, ensure_ascii=False, separators=(",", ":")).encode()
            merged["content-type"] = "application/json"
        merged["content-length"] = str(len(body))
        head = f"{method} {target} HTTP/1.1\r\n" + "".join(
            f"{name}: {value}\r\n" for name, value in merged.items()
        )
        return head.encode("latin-1") + b"\r\n" + body

    async def _send(self, payload: bytes) -> tuple[_Conn, Any, _Parsed]:
        """发出请求并读到响应头。复用的连接一个字节都没回就断了，换新连接重试一次。"""
        reused = bool(self._idle)
        conn = self._idle.pop() if reused else await self._connect()
        while True:
            parsed = _Parsed()
            parser = httptools.HttpResponseParser(parsed)
            received = False
            try:
                conn.writer.write(payload)
                while not parsed.head_done:
                    data = await conn.reader.read(_READ)
                    if not data:
                        raise ConnectionResetError("对端关闭了连接")
                    received = True
                    parser.feed_data(data)
                return conn, parser, parsed
            except (ConnectionError, OSError):
                conn.close()
                if not reused or received:
                    raise
                reused = False
                conn = await self._connect()
            except BaseException:
                conn.close()
                raise

    # ------------------------------------------------------------------ 请求
    async def request(
        self,
        method: str,
        target: str,
        *,
        params: dict[str, Any] | None = None,
        json: Any = None,
        content: bytes | None = None,
        headers: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> Response:
        payload = self._encode(method, target, params, json, content, headers)
        limit = timeout if timeout is not None else self.timeout
        async with asyncio.timeout(limit):
            conn, parser, parsed = await self._send(payload)
            try:
                while not parsed.done:
                    data = await conn.reader.read(_READ)
                    if not data:
                        raise ConnectionResetError("对端在响应途中关闭了连接")
                    parser.feed_data(data)
            except BaseException:
                conn.close()
                raise
        self._release(conn, parsed)
        return Response(parser.get_status_code(), parsed.headers, b"".join(parsed.chunks))

    @contextlib.asynccontextmanager
    async def stream(
        self,
        method: str,
        target: str,
        *,
        params: dict[str, Any] | None = None,
        json: Any = None,
        content: bytes | None = None,
        headers: dict[str, str] | None = None,
        connect_timeout: float = 10.0,
    ) -> AsyncIterator[StreamResponse]:
        """流式请求：只给响应头设时限，响应体不限时；退出时没读完就关连接（对端据此知道调用方走了）。"""
        payload = self._encode(method, target, params, json, content, headers)
        async with asyncio.timeout(connect_timeout):
            conn, parser, parsed = await self._send(payload)
        response = StreamResponse(self, conn, parser, parsed)
        try:
            yield response
        except BaseException:
            conn.close()
            raise
        if parsed.done:
            self._release(conn, parsed)
        else:
            conn.close()

    async def aclose(self) -> None:
        self._closed = True
        while self._idle:
            self._idle.pop().close()
