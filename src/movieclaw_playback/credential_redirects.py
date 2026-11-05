"""直链跨源跳转时去掉厂商令牌头。

httpx 自己跟跳转只会剥掉 ``Authorization`` / ``Cookie``，认不出插件放在
``DirectLink.headers`` 里的 ``X-Emby-Token``、``X-Plex-Token``。转发、按区间读、
交给 ffmpeg 之前都走这里：下一跳换了源（协议、主机或端口）就先去掉这些头。
同源跳转原样带着。
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Mapping

import httpx

MAX_HOPS = 20
_REDIRECT_TIMEOUT = 5.0
_ffmpeg_relay: Callable[[str, dict[str, str]], str] | None = None
_EXACT_TOKEN_HEADERS = frozenset({"authorization", "proxy-authorization", "cookie"})
_API_KEY_HEADERS = frozenset({"x-api-key", "api-key"})


def bind_ffmpeg_relay(resolve: Callable[[str, dict[str, str]], str]) -> None:
    """宿主提供支持 Range 的取流转发地址；装配输入不访问网络。"""
    global _ffmpeg_relay
    _ffmpeg_relay = resolve


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
    """带凭据的输入始终由宿主取流，不能把凭据交给会自行跳转的 ffmpeg。"""
    sent = dict(headers)
    if not any(is_vendor_token_header(name) for name in sent):
        return url, sent
    if _ffmpeg_relay is None:
        raise RuntimeError("credentialed ffmpeg input requires the host stream relay")
    return _ffmpeg_relay(url, sent), {}


def final_status(url: str, headers: Mapping[str, str], *, timeout: float = 5.0) -> int | None:
    """（阻塞，须在线程中调用）整条跳转链共享超时预算。"""

    async def check() -> int:
        async with httpx.AsyncClient(follow_redirects=False, timeout=timeout) as client:
            response = await open_followed_stream(client, url, headers, timeout=timeout)
            try:
                return response.status_code
            finally:
                await response.aclose()

    try:
        return asyncio.run(check())
    except httpx.HTTPError:
        return None


async def open_followed_stream(
    client: httpx.AsyncClient,
    url: str,
    headers: Mapping[str, str],
    *,
    timeout: float = _REDIRECT_TIMEOUT,
) -> httpx.Response:
    """GET 并自己跟跳转，返回最终那一跳的流。调用方负责关闭。

    客户端须 ``follow_redirects=False``。跨源跳转先去掉厂商令牌头。
    """
    try:
        async with asyncio.timeout(timeout):
            return await _open_followed_stream(client, url, headers)
    except TimeoutError as exc:
        raise httpx.ReadTimeout("redirect chain deadline exceeded") from exc


async def _open_followed_stream(
    client: httpx.AsyncClient, url: str, headers: Mapping[str, str]
) -> httpx.Response:
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
