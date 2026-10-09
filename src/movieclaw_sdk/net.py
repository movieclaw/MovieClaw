"""插件的网络出口：按用户在「设置 → 网络」里的代理设置连外网（docs/design/plugin-channels.md §7）。

::

    from movieclaw_sdk import net

    client = httpx.AsyncClient(transport=net.http_transport("telegram"))
    proxy = await net.proxy_url("discord")   # 给 websockets 这类不吃 httpx transport 的库

- 主进程里运行（随应用携带的插件包、本地插件）：直接用主程序的出口层，配置改了即时生效；
- 独立进程里运行：向宿主询问代理地址（约每 30 秒复查一次）。代理地址可能带账号密码，宿主只
  回答插件「自己的」服务名——条目 id 本身（``wecom-channel``；旧格式带点的 id 用最后一段，
  ``channel.telegram`` → ``telegram``），问别的服务一律直连。
"""

from __future__ import annotations

import time
from collections.abc import Awaitable, Callable

import httpx

#: 进程外运行时由运行器装上：服务名 → 代理地址（None = 直连）
_resolver: Callable[[str], Awaitable[str | None]] | None = None

#: 进程外复查代理设置的间隔（秒）
REFRESH_S = 30.0


async def proxy_url(service: str) -> str | None:
    if _resolver is not None:
        return await _resolver(service)
    from movieclaw_net import resolve_proxy_url

    return resolve_proxy_url(service)


def http_transport(service: str) -> httpx.AsyncBaseTransport:
    """某服务的 httpx transport：构造客户端时传 ``transport=``。"""
    if _resolver is None:
        from movieclaw_net import egress_transport

        return egress_transport(service)
    return _RemoteTransport(service)


class _RemoteTransport(httpx.AsyncBaseTransport):
    """进程外：按宿主告知的代理建连接，代理设置变了就换一条（旧连接随本 transport 一起关）。"""

    def __init__(self, service: str) -> None:
        self._service = service
        self._inner: httpx.AsyncHTTPTransport | None = None
        self._proxy: str | None = None
        self._checked = 0.0
        self._retired: list[httpx.AsyncHTTPTransport] = []

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        now = time.monotonic()
        if self._inner is None or now - self._checked > REFRESH_S:
            proxy = await proxy_url(self._service)
            self._checked = now
            if self._inner is None or proxy != self._proxy:
                if self._inner is not None:
                    self._retired.append(self._inner)
                self._inner = httpx.AsyncHTTPTransport(proxy=proxy)
                self._proxy = proxy
        return await self._inner.handle_async_request(request)

    async def aclose(self) -> None:
        for transport in self._retired:
            await transport.aclose()
        self._retired.clear()
        if self._inner is not None:
            await self._inner.aclose()
            self._inner = None
