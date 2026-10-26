"""在局域网里找 movieclaw：往 UDP 7359 广播一句询问，收集应答。

协议与服务端 ``services/lan_discovery.py``、Go CLI ``cli/internal/discover`` 一致：
自家的 ``who is MovieClawServer?``（应答一组按可信度排好的地址）与 Jellyfin 的
``who is JellyfinServer?``（旧版服务器只认这一句，应答一个 Address）。同一来源 IP
的应答合并成一台服务器。

只发受限广播 ``255.255.255.255``：跨网段、VPN、Docker 桥接这边都出不去——找不到
不是错误，界面回落到「直接填地址」（Go CLI 还会逐网卡发定向广播，这里没做）。
"""

from __future__ import annotations

import contextlib
import json
import socket
from dataclasses import dataclass, field
from urllib.parse import urlsplit

#: 服务端认的两句暗号（大小写不敏感），自家的在前
PROBES = ("who is MovieClawServer?", "who is JellyfinServer?")

#: docker-compose 默认映射的对外端口，与服务端 lan_discovery 一致
DEFAULT_PORT = 3000


@dataclass
class DiscoveredServer:
    """一台应答了发现请求的服务器；``address`` 是最可信的候选。"""

    name: str
    address: str
    candidates: list[str] = field(default_factory=list)


def parse_reply(data: bytes) -> tuple[list[str], str, bool] | None:
    """解析一条应答。返回 (地址列表, 名字, 是否自家协议)；不是发现应答返回 None。"""
    try:
        raw = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(raw, dict):
        return None
    if raw.get("type") == "movieclaw.discovery":
        addresses = [item for item in raw.get("addresses") or [] if isinstance(item, str) and item]
        name = raw.get("name") if isinstance(raw.get("name"), str) else ""
        return addresses, name, True
    address = raw.get("Address")
    if not isinstance(address, str) or not address:
        return None
    name = raw.get("Name") if isinstance(raw.get("Name"), str) else ""
    return [address], name, False


def candidates_for(addresses: list[str], source: str) -> list[str]:
    """由一台服务器的全部应答地址与来源 IP 拼候选地址（去重、保序）：

    应答里的地址 → 来源 IP + 应答里出现过的端口 → 来源 IP + 3000。桥接部署下服务端
    报的地址未必连得上，调用方应逐个确认。
    """
    ordered: list[str] = []
    ports: list[int] = []

    def add(value: str) -> None:
        if value not in ordered:
            ordered.append(value)

    for address in addresses:
        parts = urlsplit(address)
        if parts.scheme not in ("http", "https") or not parts.netloc:
            continue
        add(f"{parts.scheme}://{parts.netloc}")
        with contextlib.suppress(ValueError):
            ports.append(parts.port or 0)
    for port in [*ports, DEFAULT_PORT]:
        host = f"[{source}]" if ":" in source else source
        add(f"http://{host}:{port}")
    return ordered


def find(
    timeout: float = 1.5,
    *,
    port: int = DEFAULT_PORT,
    targets: list[str] | None = None,
) -> list[DiscoveredServer]:
    """广播一次并收集 timeout 内的全部应答。找不到返回空列表，不是错误。"""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for target in targets or ["255.255.255.255"]:
            for probe in PROBES:
                try:
                    sock.sendto(probe.encode("ascii"), (target, port))
                except OSError:
                    continue
        sock.settimeout(timeout)
        sources: list[str] = []
        replies: dict[str, list[tuple[list[str], str, bool]]] = {}
        while True:
            try:
                data, sender = sock.recvfrom(4096)
            except TimeoutError:
                break
            except OSError:
                break
            parsed = parse_reply(data)
            if parsed is None:
                continue
            source = sender[0]
            if source not in replies:
                sources.append(source)
                replies[source] = []
            replies[source].append(parsed)
    found: list[DiscoveredServer] = []
    for source in sources:
        # 自家应答的地址与名字在前
        addresses: list[str] = []
        name = ""
        for native in (True, False):
            for reply_addresses, reply_name, reply_native in replies[source]:
                if reply_native is not native:
                    continue
                addresses.extend(reply_addresses)
                if not name:
                    name = reply_name
        candidates = candidates_for(addresses, source)
        if candidates:
            found.append(DiscoveredServer(name=name, address=candidates[0], candidates=candidates))
    return found
