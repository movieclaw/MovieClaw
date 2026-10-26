"""局域网发现：应答解析、候选地址排序（与 Go CLI ``cli/internal/discover`` 同规则）、
真实 UDP 的一轮广播。"""

from __future__ import annotations

import json
import socket
import threading

from movieclaw_transcoder_app import discovery

NATIVE = {
    "type": "movieclaw.discovery",
    "addresses": ["http://192.168.1.5:3000"],
    "name": "客厅 NAS",
}
JELLYFIN = {"Address": "http://192.168.1.5:8096", "Name": "Jellyfin Server"}


class TestParseReply:
    def test_native_reply(self):
        parsed = discovery.parse_reply(json.dumps(NATIVE).encode())
        assert parsed == (["http://192.168.1.5:3000"], "客厅 NAS", True)

    def test_native_reply_with_empty_address_list_still_parses(self):
        parsed = discovery.parse_reply(
            json.dumps({"type": "movieclaw.discovery", "addresses": [], "name": "x"}).encode()
        )
        assert parsed == ([], "x", True)

    def test_jellyfin_reply(self):
        parsed = discovery.parse_reply(json.dumps(JELLYFIN).encode())
        assert parsed == (["http://192.168.1.5:8096"], "Jellyfin Server", False)

    def test_garbage_is_not_a_reply(self):
        assert discovery.parse_reply(b"not json") is None
        assert discovery.parse_reply(json.dumps({"type": "other"}).encode()) is None
        assert discovery.parse_reply(json.dumps({"Name": "no address"}).encode()) is None
        assert discovery.parse_reply(b"") is None
        assert discovery.parse_reply(json.dumps([1]).encode()) is None


class TestCandidatesFor:
    def test_reply_address_first_then_source_fallbacks(self):
        candidates = discovery.candidates_for(["https://nas.example:8443"], "10.0.0.2")
        assert candidates == [
            "https://nas.example:8443",
            "http://10.0.0.2:8443",
            "http://10.0.0.2:3000",
        ]

    def test_source_port3000_dedupes_with_reply_address(self):
        candidates = discovery.candidates_for(["http://192.168.1.5:3000"], "192.168.1.5")
        assert candidates == ["http://192.168.1.5:3000"]

    def test_invalid_addresses_are_skipped(self):
        candidates = discovery.candidates_for(["ftp://x", "http://", "http://a:1"], "10.0.0.9")
        assert candidates == ["http://a:1", "http://10.0.0.9:1", "http://10.0.0.9:3000"]

    def test_ipv6_source_gets_brackets(self):
        candidates = discovery.candidates_for([], "::1")
        assert candidates == ["http://[::1]:3000"]


class Responder(threading.Thread):
    """按询问应答的 UDP 小服务（对应 Go 测试里的 responder）。"""

    def __init__(self, native: list[str] | None, jellyfin: list[str] | None):
        super().__init__(daemon=True)
        self.native, self.jellyfin = native, jellyfin
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(5)
        self.received: list[str] = []

    def run(self) -> None:
        while True:
            try:
                data, sender = self.sock.recvfrom(4096)
            except OSError:
                return
            probe = data.decode("utf-8", "replace")
            self.received.append(probe)
            reply = None
            if probe.lower() == "who is movieclawserver?":
                reply = NATIVE if self.native is not None else self.jellyfin
            elif probe.lower() == "who is jellyfinserver?":
                reply = JELLYFIN if self.jellyfin is not None else self.native
            if reply is not None:
                self.sock.sendto(json.dumps(reply).encode(), sender)

    def stop(self) -> None:
        self.sock.close()


def test_find_collects_one_server_from_both_probes():
    responder = Responder(NATIVE["addresses"], None)
    responder.start()
    try:
        port = responder.sock.getsockname()[1]
        found = discovery.find(timeout=1.0, port=port, targets=["127.0.0.1"])
    finally:
        responder.stop()
    assert responder.received == list(discovery.PROBES)
    assert [server.address for server in found] == ["http://192.168.1.5:3000"]
    assert found[0].name == "客厅 NAS"


def test_find_works_with_a_jellyfin_only_server():
    """v0.40.0 及更早的服务器只应答 Jellyfin 暗号：照样找得到，名字取自应答。"""
    responder = Responder(None, ["http://192.168.1.5:8096"])
    responder.start()
    try:
        port = responder.sock.getsockname()[1]
        found = discovery.find(timeout=1.0, port=port, targets=["127.0.0.1"])
    finally:
        responder.stop()
    assert [server.address for server in found] == ["http://192.168.1.5:8096"]
    assert found[0].name == "Jellyfin Server"


def test_find_returns_empty_when_nobody_answers():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    assert discovery.find(timeout=0.3, port=port, targets=["127.0.0.1"]) == []
