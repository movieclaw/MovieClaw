"""WebSocket 客户端（RFC 6455 的最小实现）：握手、收发文本帧、控制帧、关闭与超时。

对端是 ``miniserver.FakeWebSocketServer``——只会按脚本发帧的桩，不是真的 NAS。
"""

from __future__ import annotations

import json
import secrets
import time

import pytest
from miniserver import FakeWebSocketServer, close_frame, frame, text_frame
from movieclaw_transcoder import websocket
from movieclaw_transcoder.websocket import (
    HandshakeRejected,
    ServerClosed,
    WebSocketClient,
    rejection_kind,
)


def test_handshake_carries_the_token_in_a_header_not_in_the_url():
    """令牌放 Authorization 头：不进反向代理的访问日志。"""
    with FakeWebSocketServer() as server:
        WebSocketClient(server.url, "secret-token", user_agent="UA/1").close()

    peer = server.peer
    assert peer is not None
    assert peer.request_line == "GET /api/v1/transcode-worker/ws?probe=1 HTTP/1.1"
    assert peer.headers["authorization"] == "Bearer secret-token"
    assert "secret-token" not in peer.request_line
    assert peer.headers["upgrade"] == "websocket"
    assert peer.headers["sec-websocket-version"] == "13"
    assert peer.headers["user-agent"] == "UA/1"
    assert peer.headers["host"] == f"127.0.0.1:{server.port}"


@pytest.mark.parametrize("size", [10, 200, 70_000], ids=["7-bit", "16-bit", "64-bit"])
def test_json_messages_round_trip_with_every_length_encoding(size):
    message = {"type": "x", "text": "好" * size}
    seen: dict[str, object] = {}

    def handler(peer):
        opcode, payload, masked = peer.read_frame()
        seen.update(opcode=opcode, masked=masked, payload=payload)
        peer.send(frame(opcode, payload))

    with FakeWebSocketServer(handler) as server:
        client = WebSocketClient(server.url, "t")
        client.send_json(message)
        assert client.recv_json(5.0) == message
        client.close()

    assert seen["opcode"] == 0x1
    assert seen["masked"] is True  # 客户端发出的帧必须带掩码
    assert json.loads(seen["payload"]) == message  # type: ignore[arg-type]


def test_fragmented_messages_are_reassembled_and_pings_are_answered():
    seen: dict[str, object] = {}

    def handler(peer):
        peer.send(frame(0x1, b'{"a":', fin=False))
        peer.send(frame(0x9, b"ping-data"))  # 控制帧可以夹在分片中间
        peer.send(frame(0x0, b"1}", fin=True))
        seen["pong"] = peer.read_frame()[:2]

    with FakeWebSocketServer(handler) as server:
        client = WebSocketClient(server.url, "t")
        assert client.recv_json(5.0) == {"a": 1}
        client.close()

    assert seen["pong"] == (0xA, b"ping-data")


def test_a_first_frame_glued_to_the_handshake_response_is_not_lost():
    with FakeWebSocketServer(glue=text_frame({"type": "worker.accepted"})) as server:
        client = WebSocketClient(server.url, "t")
        assert client.recv_json(5.0) == {"type": "worker.accepted"}
        client.close()


def test_a_quiet_connection_is_not_a_disconnect():
    """帧边界上的读超时只是暂时没消息：曾经它和对端关闭同路，服务端安静几秒 Worker 就自断重连。"""

    def handler(peer):
        time.sleep(0.4)
        peer.send_json({"n": 1})
        peer.read_frame(timeout=3.0)  # 等客户端收尾

    with FakeWebSocketServer(handler) as server:
        client = WebSocketClient(server.url, "t")
        assert client.recv_json(0.1) is None
        assert client.recv_json(5.0) == {"n": 1}
        client.close()


def test_close_frame_surfaces_the_servers_code_and_reason_and_is_answered():
    reason = "凭证无效或已被吊销，请在网页「设置 → 设备」重新配对"
    seen: dict[str, object] = {}

    def handler(peer):
        peer.send(close_frame(1008, reason))
        seen["reply"] = peer.read_frame()[0]

    with FakeWebSocketServer(handler) as server:
        client = WebSocketClient(server.url, "t")
        with pytest.raises(ServerClosed) as info:
            client.recv_json(5.0)

    assert (info.value.code, info.value.reason) == (1008, reason)
    assert seen["reply"] == 0x8  # RFC 6455：收到关闭帧要回一个再断开


def test_a_close_frame_without_a_status_code_reads_as_1005():
    with FakeWebSocketServer(lambda peer: peer.send(frame(0x8))) as server:
        client = WebSocketClient(server.url, "t")
        with pytest.raises(ServerClosed) as info:
            client.recv_json(5.0)

    assert (info.value.code, info.value.reason) == (1005, "")


def test_a_dropped_connection_is_an_oserror_but_not_a_server_close():
    with FakeWebSocketServer(lambda peer: peer.close()) as server:
        client = WebSocketClient(server.url, "t")
        with pytest.raises(OSError) as info:
            client.recv_json(5.0)

    assert not isinstance(info.value, ServerClosed)


def test_http_status_rejection_at_the_handshake_is_reported_with_the_status():
    with (
        FakeWebSocketServer(reject_status="403 Forbidden") as server,
        pytest.raises(HandshakeRejected) as info,
    ):
        WebSocketClient(server.url, "t")

    assert info.value.status == 403


def test_a_wrong_accept_key_fails_the_handshake():
    with FakeWebSocketServer(bad_accept=True) as server, pytest.raises(OSError) as info:
        WebSocketClient(server.url, "t")

    assert "Sec-WebSocket-Accept" in str(info.value)


def test_a_slow_second_half_of_a_frame_is_given_a_grace_period():
    """大报文（job.start 带整条 ffmpeg 命令）会跨几个 TCP 段；后一段慢半拍不该被当成断线。"""
    full = frame(0x1, json.dumps({"type": "big", "pad": "x" * 300}).encode())

    def handler(peer):
        peer.send(full[:5])
        time.sleep(0.5)
        peer.send(full[5:])
        peer.read_frame(timeout=3.0)

    with FakeWebSocketServer(handler) as server:
        client = WebSocketClient(server.url, "t")
        message = client.recv_json(0.1)  # 读超时比对端的停顿短得多
        client.close()

    assert message is not None and message["type"] == "big"


def test_a_frame_that_never_completes_is_a_disconnect_after_the_grace(monkeypatch):
    monkeypatch.setattr(websocket, "_FRAME_GRACE_S", 0.3)
    full = frame(0x1, json.dumps({"type": "big", "pad": "x" * 300}).encode())

    def handler(peer):
        peer.send(full[:5])
        peer.read_frame(timeout=3.0)

    with FakeWebSocketServer(handler) as server:
        client = WebSocketClient(server.url, "t")
        with pytest.raises(OSError):
            client.recv_json(0.1)
        client.close()


def test_only_websocket_urls_are_accepted():
    with pytest.raises(ValueError):
        WebSocketClient("http://127.0.0.1:1/api/v1/transcode-worker/ws", "t")


@pytest.mark.parametrize(
    ("reason", "kind"),
    [
        ("凭证无效或已被吊销，请在网页「设置 → 设备」重新配对", "auth"),
        (
            "服务端尚未启用远程转码，请在网页「应用 → 远程转码」打开开关并确认地址",
            "remote_disabled",
        ),
        ("Worker 协议版本（2）与服务端（1）不一致，请把 Worker 与服务端更新到同一版本", "other"),
        ("", "other"),
    ],
)
def test_rejection_reasons_fall_into_three_classes(reason, kind):
    assert rejection_kind(reason) == kind


@pytest.mark.parametrize("size", [0, 1, 3, 4, 5, 1000])
def test_xor_mask_matches_the_bytewise_definition(size):
    data, mask = secrets.token_bytes(size), secrets.token_bytes(4)

    expected = bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))

    assert websocket._xor_mask(data, mask) == expected
    assert websocket._xor_mask(expected, mask) == data
