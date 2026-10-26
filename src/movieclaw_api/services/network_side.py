"""这次请求的客户端在家还是在外面（docs/design/server-addresses.md §5）。

不再按对端 IP 猜：反代、隧道、Docker NAT 都会把它抹成一个私网地址（#947）。依据按顺序取：

1. **自家 App 声明的路线**：请求头 ``X-MovieClaw-Route: lan | vpn | wan``。播放引擎发的取流请求
   带不了自定义头，路线在签发取流 token 时写进 token（``current_route``）。``lan`` 算在家，
   ``vpn`` / ``wan`` 算在外面——VPN 回家时人在外面，流量走的是家里上行。
2. **转发链里有公网地址**：``X-Forwarded-For`` 里出现公网 IP，说明请求是从外面经反代进来的。
3. **入口地址**：``X-Forwarded-Host``（没有再取 ``Host``）是内网地址（或管理员手动标成内网的
   域名）算在家，其余算在外面。家里设备用外网域名访问（NAT 回环）会被判为在外面——这个方向的
   错误很便宜：上传多让一会儿，网盘直连时出口 IP 与家里相同。
4. 以上都没有：``unknown``，各用处按自己的代价选保守的一边。

伪造这些只会害自己（在外面装在家：走家里转发更慢；在家装在外面：多让一次上传）。所以结论只用于
内外网判定，不用于审计、限流和权限。
"""

from __future__ import annotations

import ipaddress
from contextvars import ContextVar
from typing import Literal

from starlette.requests import HTTPConnection

from movieclaw_api.services.server_addresses import address_book, host_kind, split_host

Side = Literal["home", "outside", "unknown"]
Route = Literal["lan", "vpn", "wan"]

ROUTE_HEADER = "x-movieclaw-route"
_ROUTES: frozenset[str] = frozenset(("lan", "vpn", "wan"))

#: 这次请求声明的路线（中间件从请求头取）：签发取流 token 时据此写进 token
current_route: ContextVar[Route | None] = ContextVar("movieclaw_route", default=None)


def parse_route(raw: str | bytes | None) -> Route | None:
    if raw is None:
        return None
    text = (raw.decode("latin-1") if isinstance(raw, bytes) else raw).strip().lower()
    return text if text in _ROUTES else None  # type: ignore[return-value]


def _public_hops(connection: HTTPConnection) -> list[str]:
    """``X-Forwarded-For`` 里的公网 IP（按原顺序）。"""
    hops: list[str] = []
    for header in connection.headers.getlist("x-forwarded-for"):
        for part in header.split(","):
            text = part.strip()
            if text.startswith("[") or text.count(":") == 1:
                text = split_host(text)
            try:
                ipaddress.ip_address(text)
            except ValueError:
                continue
            if host_kind(text) == "wan":
                hops.append(text)
    return hops


def request_side(connection: HTTPConnection, *, route: str | None = None) -> Side:
    """``route`` 是取流 token 里记的路线（请求头里没有时用它）。"""
    declared = parse_route(connection.headers.get(ROUTE_HEADER)) or parse_route(route)
    if declared is not None:
        return "home" if declared == "lan" else "outside"
    if _public_hops(connection):
        return "outside"
    netloc = connection.headers.get("x-forwarded-host") or connection.headers.get("host")
    if not netloc:
        return "unknown"
    hostname = split_host(netloc.split(",")[0])
    kind = address_book.manual_kind(hostname) or host_kind(hostname)
    return "home" if kind == "lan" else "outside"


__all__ = [
    "ROUTE_HEADER",
    "Route",
    "Side",
    "current_route",
    "parse_route",
    "request_side",
]
