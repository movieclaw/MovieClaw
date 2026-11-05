"""直链跨源跳转时去掉厂商令牌头。

httpx 自己跟跳转只会剥掉 ``Authorization`` / ``Cookie``，认不出插件放在
``DirectLink.headers`` 里的 ``X-Emby-Token``、``X-Plex-Token``。转发、按区间读、
交给 ffmpeg 之前都走这里：下一跳换了源（协议、主机或端口）就先去掉这些头。
同源跳转原样带着。
"""

from __future__ import annotations

import time
from collections.abc import Mapping

import httpx

#: 实际读字节最多跟这么多跳（httpx 默认 20）。探测给 ffmpeg 的地址也用这个上限，
#: 整段探测另有 5 秒超时。
MAX_HOPS = 20
_PROBE_TIMEOUT = 5.0
_CACHE_TTL_S = 60.0
_CACHE_MAX = 256
_EXACT_TOKEN_HEADERS = frozenset({"authorization", "proxy-authorization", "cookie"})
_API_KEY_HEADERS = frozenset({"x-api-key", "api-key"})

_cache: dict[tuple, tuple[float, str, tuple[tuple[str, str], ...]]] = {}


def is_vendor_token_header(name: str) -> bool:
    """这个头带着凭据，不能跟到另一个源。``User-Agent`` / ``Referer`` 不是。"""
    folded = name.lower()
    if folded in _EXACT_TOKEN_HEADERS:
        return True
    if folded.replace("_", "-") in _API_KEY_HEADERS:
        return True
    return "token" in folded


def same_origin(a: httpx.URL, b: httpx.URL) -> bool:
    return (
        a.scheme.lower(),
        (a.host or "").lower().rstrip("."),
        a.port,
    ) == (
        b.scheme.lower(),
        (b.host or "").lower().rstrip("."),
        b.port,
    )


def headers_for_hop(
    headers: Mapping[str, str], current: httpx.URL, nxt: httpx.URL
) -> dict[str, str]:
    """下一跳还在同一个源就原样带上，否则去掉厂商令牌。"""
    if same_origin(current, nxt):
        return dict(headers)
    return {name: value for name, value in headers.items() if not is_vendor_token_header(name)}


def next_http_url(current: httpx.URL, location: str | None) -> httpx.URL | None:
    if not location:
        return None
    try:
        nxt = current.join(location)
    except (httpx.InvalidURL, ValueError):
        return None
    if nxt.scheme not in {"http", "https"} or not nxt.host:
        return None
    return nxt


def resolve_ffmpeg_input(url: str, headers: Mapping[str, str]) -> tuple[str, dict[str, str]]:
    """ffmpeg 会把 ``-headers`` 原样跟到每一跳。有厂商令牌时先自己跟一遍。

    全程同源：仍把原始地址和头交给 ffmpeg（它自己跟，令牌只发给这个源）。
    中途换了源：交给它的是最终地址，以及已经去掉令牌的头，这样它不会再把令牌发出去。
    没有令牌头时什么都不探。探不到、又还没换源：保持原样，不把一次网络抖动变成播不了。
    """
    sent = dict(headers)
    if not any(is_vendor_token_header(name) for name in sent):
        return url, sent
    key = (url, tuple(sorted(sent.items())))
    cached = _cache.get(key)
    if cached is not None and cached[0] > time.monotonic():
        return cached[1], dict(cached[2])
    current = httpx.URL(url)
    crossed = False
    try:
        with httpx.Client(follow_redirects=False, timeout=_PROBE_TIMEOUT) as client:
            for _ in range(MAX_HOPS):
                with client.stream(
                    "GET", current, headers={**sent, "Range": "bytes=0-0"}
                ) as response:
                    if not response.is_redirect:
                        break
                    nxt = next_http_url(current, response.headers.get("location"))
                if nxt is None:
                    break
                if not same_origin(current, nxt):
                    crossed = True
                sent = headers_for_hop(sent, current, nxt)
                current = nxt
            else:
                if crossed:
                    return str(current), sent
                return url, dict(headers)
    except httpx.HTTPError:
        if crossed:
            return str(current), sent
        return url, dict(headers)
    result = (url, dict(headers)) if not crossed else (str(current), sent)
    if len(_cache) >= _CACHE_MAX:
        _cache.clear()
    _cache[key] = (time.monotonic() + _CACHE_TTL_S, result[0], tuple(result[1].items()))
    return result


def final_status(url: str, headers: Mapping[str, str], *, timeout: float = 5.0) -> int | None:
    """跟跳转后的 HTTP 状态码。跨源时令牌头不往下带。连不上返回 None。"""
    current = httpx.URL(url)
    sent = dict(headers)
    try:
        with httpx.Client(follow_redirects=False, timeout=timeout) as client:
            for _ in range(MAX_HOPS):
                with client.stream("GET", current, headers=sent) as response:
                    if not response.is_redirect:
                        return response.status_code
                    nxt = next_http_url(current, response.headers.get("location"))
                if nxt is None:
                    return None
                sent = headers_for_hop(sent, current, nxt)
                current = nxt
    except httpx.HTTPError:
        return None
    return None


async def open_followed_stream(
    client: httpx.AsyncClient, url: str, headers: Mapping[str, str]
) -> httpx.Response:
    """GET 并自己跟跳转，返回最终那一跳的流。调用方负责关闭。

    客户端须 ``follow_redirects=False``。跨源跳转先去掉厂商令牌头。
    """
    current = httpx.URL(url)
    sent = dict(headers)
    for _ in range(MAX_HOPS):
        response = await client.send(
            client.build_request("GET", current, headers=sent),
            stream=True,
            follow_redirects=False,
        )
        if not response.is_redirect:
            return response
        nxt = next_http_url(current, response.headers.get("location"))
        await response.aclose()
        if nxt is None:
            raise httpx.RemoteProtocolError("redirect has no usable location")
        sent = headers_for_hop(sent, current, nxt)
        current = nxt
    raise httpx.RemoteProtocolError("too many redirects")
