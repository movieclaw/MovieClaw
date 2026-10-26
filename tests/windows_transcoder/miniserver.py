"""测试用的两个小服务：RFC 6455 握手桩（控制连接）与模拟 NAS 的产物端点（回传）。

都只监听 127.0.0.1 的随机端口、跑在测试进程的线程里，不依赖真实的 NAS。
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import http.server
import json
import socket
import struct
import threading
import time
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def accept_key(key: str) -> str:
    return base64.b64encode(hashlib.sha1(key.encode() + _GUID).digest()).decode()


def frame(opcode: int, payload: bytes = b"", *, fin: bool = True) -> bytes:
    """服务端发出的帧（不加掩码）。"""
    head = bytes([(0x80 if fin else 0) | opcode])
    size = len(payload)
    if size < 126:
        head += bytes([size])
    elif size < 65536:
        head += bytes([126]) + struct.pack(">H", size)
    else:
        head += bytes([127]) + struct.pack(">Q", size)
    return head + payload


def text_frame(message: dict[str, Any]) -> bytes:
    return frame(0x1, json.dumps(message, ensure_ascii=False).encode("utf-8"))


def close_frame(code: int, reason: str = "") -> bytes:
    return frame(0x8, struct.pack(">H", code) + reason.encode("utf-8"))


class Peer:
    """服务端视角的一条 WebSocket 连接。"""

    def __init__(self, conn: socket.socket, request: str) -> None:
        self.conn = conn
        self.request = request
        lines = request.split("\r\n")
        self.request_line = lines[0]
        self.headers = {
            name.strip().lower(): value.strip()
            for name, _, value in (line.partition(":") for line in lines[1:] if ":" in line)
        }
        self._buf = b""

    def send(self, data: bytes) -> None:
        self.conn.sendall(data)

    def send_json(self, message: dict[str, Any]) -> None:
        self.send(text_frame(message))

    def _take(self, count: int, timeout: float) -> bytes:
        self.conn.settimeout(timeout)
        while len(self._buf) < count:
            chunk = self.conn.recv(65536)
            if not chunk:
                raise ConnectionError("客户端已断开")
            self._buf += chunk
        data, self._buf = self._buf[:count], self._buf[count:]
        return data

    def read_frame(self, timeout: float = 5.0) -> tuple[int, bytes, bool]:
        """读客户端的一帧：(操作码, 解掩码后的载荷, 是否带掩码)。"""
        head = self._take(2, timeout)
        opcode, masked, length = head[0] & 0x0F, bool(head[1] & 0x80), head[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._take(2, timeout))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._take(8, timeout))[0]
        mask = self._take(4, timeout) if masked else b""
        payload = self._take(length, timeout) if length else b""
        if masked:
            payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
        return opcode, payload, masked

    def read_json(self, timeout: float = 5.0) -> dict[str, Any]:
        """读下一条文本消息（跳过控制帧）。"""
        while True:
            opcode, payload, _ = self.read_frame(timeout)
            if opcode == 0x1:
                return json.loads(payload.decode("utf-8"))

    def close(self) -> None:
        with contextlib.suppress(OSError):
            self.conn.close()


class FakeWebSocketServer:
    """只接一条连接：按要求握手，然后把连接交给 ``handler(peer)``。

    - ``reject_status``：握手阶段直接回这个 HTTP 状态（如 ``"403 Forbidden"``）；
    - ``bad_accept``：握手响应里的 Sec-WebSocket-Accept 故意写错；
    - ``glue``：紧跟在握手响应后、同一次发送里的字节（第一条帧挤在握手响应的 TCP 段里）。

    ``handler`` 里抛的异常在退出 ``with`` 时重新抛出，测试里的断言失败不会被线程吞掉。
    """

    def __init__(
        self,
        handler: Callable[[Peer], None] = lambda _peer: None,
        *,
        reject_status: str | None = None,
        bad_accept: bool = False,
        glue: bytes = b"",
    ) -> None:
        self._handler = handler
        self._reject_status = reject_status
        self._bad_accept = bad_accept
        self._glue = glue
        self._listener = socket.socket()
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(1)
        self.port: int = self._listener.getsockname()[1]
        self.url = f"ws://127.0.0.1:{self.port}/api/v1/transcode-worker/ws?probe=1"
        self.error: BaseException | None = None
        self.peer: Peer | None = None
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> FakeWebSocketServer:
        self._thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self._listener.close()
        self._thread.join(timeout=10)
        if self.peer is not None:
            self.peer.close()
        if self.error is not None and _exc[0] is None:
            raise self.error

    def _serve(self) -> None:
        try:
            conn, _ = self._listener.accept()
        except OSError:
            return
        try:
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                request += chunk
            peer = Peer(conn, request.decode("latin-1"))
            self.peer = peer
            if self._reject_status is not None:
                conn.sendall(
                    f"HTTP/1.1 {self._reject_status}\r\nContent-Length: 0\r\n\r\n".encode()
                )
                return
            accept = accept_key(peer.headers["sec-websocket-key"])
            if self._bad_accept:
                accept = accept_key("not-the-key")
            conn.sendall(
                (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                ).encode()
                + self._glue
            )
            self._handler(peer)
        except (ConnectionError, TimeoutError):
            pass  # 客户端先走了：正常的收尾，不是桩的错
        except BaseException as exc:  # noqa: BLE001 - 交给 __exit__ 重新抛
            self.error = exc


# -- 模拟 NAS 的产物端点 ---------------------------------------------------------


@dataclass
class Upload:
    """NAS 收到的一次 PUT。"""

    name: str
    query: dict[str, str]
    body: bytes
    status: int = 0

    @property
    def part(self) -> int | None:
        return int(self.query["part"]) if "part" in self.query else None

    @property
    def final(self) -> bool:
        return self.query.get("final") == "1"


@dataclass
class _Recorder:
    uploads: list[Upload] = field(default_factory=list)
    connections: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)


class FakeNas:
    """记录每一次 PUT 的产物端点。``respond(upload)`` 决定回什么状态码（缺省全部 201）。"""

    def __init__(self, respond: Callable[[Upload], int] = lambda _upload: 201) -> None:
        recorder = _Recorder()
        self._recorder = recorder

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def setup(self) -> None:
                super().setup()
                with recorder.lock:
                    recorder.connections += 1

            def log_message(self, *_args: object) -> None:
                pass

            def do_PUT(self) -> None:  # noqa: N802 - http.server 的约定名
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                parts = urllib.parse.urlsplit(self.path)
                query = dict(urllib.parse.parse_qsl(parts.query, keep_blank_values=True))
                upload = Upload(parts.path.rsplit("/", 1)[-1], query, body)
                with recorder.lock:
                    upload.status = respond(upload)
                    recorder.uploads.append(upload)
                self.send_response(upload.status)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port: int = self._server.server_address[1]
        #: 形如 ffmpeg 输出参数里的 NAS 产物地址（带签名令牌）
        self.stream_url = (
            f"http://127.0.0.1:{self.port}/api/v1/transcode-worker/sessions/S1/artifacts/"
            "stream.mp4?token=tok"
        )
        self.base_url = (
            f"http://127.0.0.1:{self.port}/api/v1/transcode-worker/sessions/S1/artifacts"
        )
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def __enter__(self) -> FakeNas:
        self._thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=10)

    @property
    def uploads(self) -> list[Upload]:
        with self._recorder.lock:
            return list(self._recorder.uploads)

    @property
    def connections(self) -> int:
        return self._recorder.connections

    def named(self, name: str) -> list[Upload]:
        return [upload for upload in self.uploads if upload.name == name]


def wait_until(condition: Callable[[], object], timeout: float = 10.0, what: str = "条件") -> None:
    """轮询到条件成立；超时抛断言错误（线程里的事不能靠固定 sleep 等）。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.02)
    raise AssertionError(f"等待超时：{what}")
