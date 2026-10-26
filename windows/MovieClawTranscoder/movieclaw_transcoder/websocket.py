"""RFC 6455 客户端的最小实现（纯标准库）：只收发文本帧，够远程转码控制面用。

控制面消息都是小 JSON（唯一的大报文是 ``job.start``，带着整条 ffmpeg 命令，也只有几 KB），
所以不做分片发送、不压缩、不支持二进制帧。``wss`` 走系统证书库验证服务端证书。
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import json
import secrets
import socket
import ssl
import struct
import threading
import time
import urllib.parse
from typing import Any

_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

#: 帧读到一半的收尾宽限。主循环的空等超时压得很短（见 ``TranscoderClient``），
#: 大报文会跨几个 TCP 段，后一段慢半拍不该被当成断线。
_FRAME_GRACE_S = 5.0


class ServerClosed(OSError):
    """服务端发来关闭帧。``code`` / ``reason`` 是服务端写好的理由：1008 就是「不接受你」。"""

    def __init__(self, code: int, reason: str) -> None:
        self.code = code
        self.reason = reason
        text = f"服务端关闭了连接（{code}）"
        super().__init__(f"{text}：{reason}" if reason else text)


class HandshakeRejected(OSError):
    """握手阶段就被 HTTP 状态码拒绝（旧版服务端、反向代理）。"""

    def __init__(self, status: int) -> None:
        self.status = status
        super().__init__(f"NAS 拒绝了连接（HTTP {status}）")


class _Idle(Exception):
    """帧边界处读超时：连接没坏，只是暂时没消息。

    不能做成 OSError 的子类：上层把 OSError 一律当断线处理。曾经帧边界超时与对端关闭
    走同一条路，服务端安静几秒（心跳间隔比它长，必然出现）Worker 就自断重连，表现是
    「上线→离线」循环。
    """


def rejection_kind(reason: str) -> str:
    """1008 关闭理由分三类：``auth``（凭证失效）/ ``remote_disabled``（远程转码没开）/ ``other``。

    文字与服务端 ``transcode_worker.py`` 写死的几句一致（macOS 转码器的 ``NASRejection`` 同源）：
    改服务端文案时两边一起看。
    """
    if any(word in reason for word in ("凭证", "吊销", "注销")):
        return "auth"
    if "尚未启用远程转码" in reason:
        return "remote_disabled"
    return "other"


def _xor_mask(data: bytes, mask: bytes) -> bytes:
    if not data:
        return data
    size = len(data)
    key = (mask * (size // 4 + 1))[:size]
    return (int.from_bytes(data, "big") ^ int.from_bytes(key, "big")).to_bytes(size, "big")


class WebSocketClient:
    """一条已握手的 WebSocket 连接。收发线程各一个：``recv_json`` 只在读线程里调。"""

    def __init__(
        self,
        url: str,
        token: str,
        *,
        user_agent: str = "MovieClawTranscoder",
        connect_timeout: float = 10.0,
        handshake_timeout: float = 20.0,
    ) -> None:
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("ws", "wss"):
            raise ValueError(f"不是 WebSocket 地址：{url}")
        host = parts.hostname or "127.0.0.1"
        tls = parts.scheme == "wss"
        port = parts.port or (443 if tls else 80)
        target = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")

        raw = socket.create_connection((host, port), timeout=connect_timeout)
        try:
            self._sock: socket.socket = (
                ssl.create_default_context().wrap_socket(raw, server_hostname=host) if tls else raw
            )
        except OSError:
            raw.close()
            raise
        self._send_lock = threading.Lock()
        self._buf = b""
        self._closed = False
        try:
            self._handshake(host, port, tls, target, token, user_agent, handshake_timeout)
        except BaseException:
            self._sock.close()
            raise

    # -- 握手 ---------------------------------------------------------------

    def _handshake(
        self,
        host: str,
        port: int,
        tls: bool,
        target: str,
        token: str,
        user_agent: str,
        timeout: float,
    ) -> None:
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        default_port = 443 if tls else 80
        host_header = host if port == default_port else f"{host}:{port}"
        # 令牌放 Authorization 头而不是查询参数：不进反向代理的访问日志
        request = (
            f"GET {target} HTTP/1.1\r\n"
            f"Host: {host_header}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Authorization: Bearer {token}\r\n"
            f"User-Agent: {user_agent}\r\n\r\n"
        )
        self._sock.settimeout(timeout)
        self._sock.sendall(request.encode())
        deadline = time.monotonic() + timeout
        response = b""
        while b"\r\n\r\n" not in response:
            if time.monotonic() > deadline:
                raise TimeoutError("WebSocket 握手超时")
            chunk = self._sock.recv(4096)
            if not chunk:
                raise OSError("WebSocket 握手无响应")
            response += chunk
        head, _, rest = response.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        status_parts = lines[0].split(" ", 2)
        status = int(status_parts[1]) if len(status_parts) > 1 and status_parts[1].isdigit() else 0
        if status != 101:
            raise HandshakeRejected(status)
        headers = {
            name.strip().lower(): value.strip()
            for name, _, value in (line.partition(":") for line in lines[1:])
        }
        expected = base64.b64encode(hashlib.sha1(key.encode() + _GUID).digest()).decode()
        if headers.get("sec-websocket-accept") != expected:
            raise OSError("WebSocket 握手校验失败（Sec-WebSocket-Accept 不符）")
        # 握手响应可能与第一条帧挤在同一个 TCP 段里：残留留给读缓冲，不能丢
        self._buf = rest

    # -- 发送 ---------------------------------------------------------------

    def send_json(self, payload: dict[str, Any]) -> None:
        self._send_frame(0x1, json.dumps(payload, ensure_ascii=False).encode("utf-8"))

    def _send_frame(self, opcode: int, data: bytes) -> None:
        length = len(data)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)
        mask = secrets.token_bytes(4)
        with self._send_lock:
            self._sock.sendall(header + mask + _xor_mask(data, mask))

    # -- 接收 ---------------------------------------------------------------

    def recv_json(self, timeout: float) -> dict[str, Any] | None:
        """收一条文本消息；``timeout`` 秒内没有消息返回 None；连接断开抛 ``OSError``。"""
        self._sock.settimeout(timeout)
        try:
            return self._read_message()
        except _Idle:
            return None

    def _read_message(self) -> dict[str, Any] | None:
        fragments: list[bytes] = []
        text_started = False
        while True:
            head = self._take(2, at_boundary=not text_started and not fragments)
            fin = bool(head[0] & 0x80)
            opcode = head[0] & 0x0F
            length = head[1] & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._take(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._take(8))[0]
            mask = self._take(4) if head[1] & 0x80 else None
            payload = self._take(length) if length else b""
            if mask:
                payload = _xor_mask(payload, mask)
            if opcode == 0x8:  # close：载荷 = 2 字节状态码 + UTF-8 理由（都可省略）
                code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else 1005
                reason = payload[2:].decode("utf-8", errors="replace")
                self.close()  # RFC 6455：收到关闭帧要回一个再断开，服务端才好收尾
                raise ServerClosed(code, reason)
            if opcode == 0x9:  # ping → pong
                with contextlib.suppress(OSError):
                    self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:  # pong
                continue
            if opcode in (0x1, 0x0):
                text_started = True
                fragments.append(payload)
                if fin:
                    return json.loads(b"".join(fragments).decode("utf-8"))
                continue
            # 二进制帧等本协议用不上的：读掉丢弃
            fragments.clear()
            text_started = False

    def _take(self, count: int, *, at_boundary: bool = False) -> bytes:
        """从读缓冲取 ``count`` 字节。``at_boundary``：这是一帧的开头，空等超时是正常的。"""
        grace_until: float | None = None
        while len(self._buf) < count:
            try:
                chunk = self._sock.recv(65536)
            except TimeoutError as exc:
                if at_boundary and not self._buf:
                    raise _Idle from exc
                # 帧开了头才超时：多半是跨段报文的后一段慢了半拍。给一段宽限收完本帧，
                # 宽限烧完才按断线上抛
                now = time.monotonic()
                if grace_until is None:
                    grace_until = now + _FRAME_GRACE_S
                    self._sock.settimeout(_FRAME_GRACE_S)
                elif now > grace_until:
                    raise
                continue
            if not chunk:
                raise OSError("连接已关闭")
            self._buf += chunk
        data, self._buf = self._buf[:count], self._buf[count:]
        return data

    # -- 收尾 ---------------------------------------------------------------

    def close(self) -> None:
        # 对端先发来关闭帧时也要走到 socket.close()：只标记不关，fd 会挂到 GC 才放
        if not self._closed:
            self._closed = True
            with contextlib.suppress(OSError):
                self._send_frame(0x8, struct.pack(">H", 1000))
        with contextlib.suppress(OSError):
            self._sock.close()
