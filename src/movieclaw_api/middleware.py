"""全局 HTTP 中间件：安全响应头、spec 指纹头、访问日志与访问地址记录。

都以**纯 ASGI 中间件**实现，而不是 ``@app.middleware("http")``
（``BaseHTTPMiddleware``）。原因是 2026-08 NAS 现场事故：

- ``BaseHTTPMiddleware`` 会把响应体的每一块经 anyio 内存流再转发一跳，
  视频取流/整文件下载按块计费的 CPU 开销直接翻倍；
- 更要命的是它的 ``receive`` 包装会让 Starlette 1.x 的
  ``Request.is_disconnected()`` 永远返回 False（预取消的 CancelScope 在到达
  服务器 receive 前就被中间件内部的检查点取消），任何依赖它停读盘的响应都会
  在客户端断开后把文件读到底。

纯 ASGI 中间件只包一层 ``send``，不碰 ``receive``、不复制 body，对流式响应
零开销。
"""

import hashlib
import logging
import time

from fastapi import FastAPI
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from movieclaw_api.core.config import Settings
from movieclaw_api.services import foreground
from movieclaw_api.services.lan_discovery import lan_origins
from movieclaw_api.services.network_side import current_route, parse_route
from movieclaw_api.services.server_addresses import AUTHENTICATED_SCOPE_KEY, address_book
from movieclaw_api.spec_state import SPEC_HASH_HEADER, get_spec_hash

logger = logging.getLogger("movieclaw_api.access")


#: 后端响应统一附加的安全头。取值针对「API 与文件直出」这一形态，
#: 页面侧的同类头由 Next 在 apps/web/next.config.ts 里设置（两处都要有：
#: 容器内 nginx 把 /api/v1 与 Jellyfin 命名空间直接转给后端，不经过 Next）。
_SECURITY_HEADERS: tuple[tuple[bytes, bytes], ...] = (
    # 关掉 MIME 嗅探。对图片代理尤其重要：它把远端字节落盘后直出，虽然回源时
    # 已校验过 Content-Type 是 image/*，但浏览器一旦按嗅探结果改判成 HTML，
    # 就等于把第三方图床的内容当同源文档执行。
    (b"x-content-type-options", b"nosniff"),
    # 后端响应（JSON / 视频 / 字幕 / 图片）没有任何被 iframe 嵌套的正当理由。
    # 页面侧用 SAMEORIGIN（应用自身有同源弹窗与播放器），这里可以更严。
    (b"x-frame-options", b"DENY"),
    (b"content-security-policy", b"frame-ancestors 'none'; object-src 'none'; base-uri 'none'"),
    # 取流 URL 的查询参数里带签名 token，绝不能跟着 Referer 漏到外站去。
    (b"referrer-policy", b"no-referrer"),
)


class SecurityHeadersMiddleware:
    """给所有后端响应补齐安全头（纯 ASGI，只包 send，不碰 body）。

    只在响应头里**缺失**该字段时才补，不覆盖路由自己显式设置的值——
    个别端点若有特殊需要（例如将来要开放某个可嵌入的公开页），在路由层
    自行设置即可，中间件不会把它改回去。
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_security_headers(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                present = {name.lower() for name, _ in headers}
                headers.extend(
                    (name, value) for name, value in _SECURITY_HEADERS if name not in present
                )
                message = {**message, "headers": headers}
            await send(message)

        await self.app(scope, receive, send_with_security_headers)


class SpecHashHeaderMiddleware:
    """所有 API 响应携带 spec 指纹头，CLI 借此零成本发现版本偏斜。"""

    def __init__(self, app: ASGIApp, *, api_prefix: str) -> None:
        self.app = app
        self.api_prefix = api_prefix

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or not scope.get("path", "").startswith(self.api_prefix):
            await self.app(scope, receive, send)
            return

        async def send_with_header(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                spec_hash = get_spec_hash(scope["app"])
                headers.append(
                    (SPEC_HASH_HEADER.lower().encode("latin-1"), spec_hash.encode("latin-1"))
                )
                message = {**message, "headers": headers}
            await send(message)

        await self.app(scope, receive, send_with_header)


class AccessLogMiddleware:
    """访问日志：响应头发出时记一条（含耗时），异常记 500。

    对流式响应（取流/SSE）与 BaseHTTPMiddleware 时代语义一致：在响应头就绪时
    记录，不等 body 传完。
    """

    def __init__(self, app: ASGIApp, *, enabled: bool) -> None:
        self.app = app
        self.enabled = enabled

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or not self.enabled:
            await self.app(scope, receive, send)
            return
        method = scope.get("method", "")
        path = scope.get("path", "")
        started_at = time.perf_counter()

        async def send_logged(message: Message) -> None:
            if message["type"] == "http.response.start":
                status_code = message["status"]
                duration_ms = (time.perf_counter() - started_at) * 1000
                log = logger.info
                if status_code >= 500:
                    log = logger.error
                elif status_code >= 400:
                    log = logger.warning
                log(
                    "method=%s path=%s status_code=%s duration_ms=%.2f message=%s",
                    method,
                    path,
                    status_code,
                    duration_ms,
                    "request completed",
                )
            await send(message)

        try:
            await self.app(scope, receive, send_logged)
        except Exception:
            duration_ms = (time.perf_counter() - started_at) * 1000
            logger.error(
                "method=%s path=%s status_code=%s duration_ms=%.2f message=%s",
                method,
                path,
                500,
                duration_ms,
                "request failed",
            )
            raise


class AccessAddressMiddleware:
    """记下客户端走的是哪个入口，并取出自家 App 声明的路线。

    - 用局域网 IP 访问时的地址（Host 头）供局域网自动发现应答：Docker 桥接部署下容器不知道宿主
      IP 与映射端口，浏览器地址栏里那一串就是答案（见 services/lan_discovery.py）；
    - 已登录、成功的请求进的入口记进访问地址簿，App 据此在内外网地址之间自动选
      （services/server_addresses.py）；
    - ``X-MovieClaw-Route`` 放进 ``current_route``，签发取流 token 时写进去
      （services/network_side.py）。

    同一个 Host 连续出现时只比较一次字节串；只包一层 send 看响应状态。
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return
        host = forwarded_host = forwarded_proto = route = None
        for name, value in scope.get("headers", ()):
            if name == b"host":
                host = value
            elif name == b"x-forwarded-host":
                forwarded_host = value
            elif name == b"x-forwarded-proto":
                forwarded_proto = value
            elif name == b"x-movieclaw-route":
                route = value
        if host is not None:
            lan_origins.observe(host, forwarded_host, forwarded_proto)
        token = current_route.set(parse_route(route))
        try:
            if scope["type"] != "http" or host is None:
                await self.app(scope, receive, send)
                return

            async def send_observed(message: Message) -> None:
                if (
                    message["type"] == "http.response.start"
                    and message.get("status", 500) < 400
                    and scope.get(AUTHENTICATED_SCOPE_KEY)
                ):
                    address_book.observe(host, forwarded_host, forwarded_proto)
                await send(message)

            await self.app(scope, receive, send_observed)
        finally:
            current_route.reset(token)


class ForegroundPressureMiddleware:
    """维护「在途且还没开始响应」的 API 请求数——后台重任务让路的压力信号。

    响应头一发出就减掉：取流 / SSE 的 body 会流几分钟，但它们的重活在头之前就
    算完了，不该把后台饿死。健康探针不计（容器每 30 秒探一次）。计数在
    ``finally`` 里兜底：客户端在响应头之前断开、处理器抛异常，都不能留下一个
    永远减不掉的 1——那会让后台从此永远在等一个不存在的前台。
    """

    HEALTH_PATH_SUFFIX = "/health"

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope.get("path", "").endswith(self.HEALTH_PATH_SUFFIX):
            await self.app(scope, receive, send)
            return
        foreground.request_started()
        responding = False

        async def send_counted(message: Message) -> None:
            nonlocal responding
            if message["type"] == "http.response.start" and not responding:
                responding = True
                foreground.request_responding()
            await send(message)

        try:
            await self.app(scope, receive, send_counted)
        finally:
            if not responding:
                foreground.request_responding()


class JsonEtagMiddleware:
    """/api/v1 JSON GET 响应的 ETag 协商缓存（纯 ASGI，只包 send，不碰 receive）。

    解决的问题：App 每次回前台都整库刷新，库没变也要把几百 KB 的 JSON 重传、
    客户端重解析一遍。启用后内容未变的 GET 从 200+全量 降为 304+空体——
    内容与服务端**当面**比对过，逐字节相同才 304，不存在陈旧风险。

    接管条件（全部满足才缓冲计算）：

    - GET 且路径在 API 前缀内；
    - 响应 200、``application/json``、带 ``content-length`` 且 ≤ 4MB；
      FastAPI 的 JSONResponse 本来就整块生成、一次 send，这里只是收齐再转发，
      不增加内存峰值；流式响应（SSE/取流/大导出）没有 content-length，天然直通；
    - 响应没带自己的 ETag（自带协商的路由不接管）。

    ETag = 响应体 md5（内容指纹，内容变即变）。304 时保留原响应头
    （去掉 content-length/content-type），补 ``Cache-Control: private, no-cache``
    防共享缓存把用户数据错发给别人。客户端不带 If-None-Match 时照常返回
    200 + ETag，让客户端下次有能力协商。
    """

    MAX_BODY_BYTES = 4 * 1024 * 1024

    def __init__(self, app: ASGIApp, *, api_prefix: str) -> None:
        self.app = app
        self.api_prefix = api_prefix

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if (
            scope["type"] != "http"
            or scope.get("method") != "GET"
            or not scope.get("path", "").startswith(self.api_prefix)
        ):
            await self.app(scope, receive, send)
            return
        if_none_match = _parse_if_none_match(scope.get("headers", ()))

        started: Message | None = None
        chunks: list[bytes] = []

        async def send_with_etag(message: Message) -> None:
            nonlocal started, chunks
            if message["type"] == "http.response.start":
                if not self._is_etaggable(message.get("status", 200), message.get("headers", [])):
                    await send(message)
                    return
                started = message
                chunks = []
                return
            if message["type"] == "http.response.body" and started is not None:
                body = message.get("body", b"")
                if body:
                    chunks.append(body)
                if message.get("more_body", False):
                    return
                await self._finish(send, started, b"".join(chunks), if_none_match)
                return
            await send(message)

        await self.app(scope, receive, send_with_etag)

    async def _finish(
        self,
        send: Send,
        started: Message,
        body: bytes,
        if_none_match: frozenset[bytes] | None,
    ) -> None:
        etag = b'"' + hashlib.md5(body).hexdigest().encode("ascii") + b'"'
        original: list = list(started.get("headers", []))
        if if_none_match is not None and (b"*" in if_none_match or etag in if_none_match):
            headers = [
                (name, value)
                for name, value in original
                if name.lower() not in (b"content-length", b"content-type")
            ]
            headers.append((b"etag", etag))
            if not any(name.lower() == b"cache-control" for name, _ in headers):
                headers.append((b"cache-control", b"private, no-cache"))
            await send({**started, "status": 304, "headers": headers})
            await send({"type": "http.response.body", "body": b"", "more_body": False})
            return
        headers = original + [(b"etag", etag)]
        if not any(name.lower() == b"cache-control" for name, _ in headers):
            headers.append((b"cache-control", b"private, no-cache"))
        await send({**started, "headers": headers})
        await send({"type": "http.response.body", "body": body, "more_body": False})

    def _is_etaggable(self, status: int, raw_headers) -> bool:
        if status != 200:
            return False
        content_type: bytes | None = None
        content_length: bytes | None = None
        for name, value in raw_headers:
            lower = name.lower()
            if lower == b"content-type":
                content_type = value
            elif lower == b"content-length":
                content_length = value
            elif lower == b"etag":
                return False
        if content_type is None or not content_type.startswith(b"application/json"):
            return False
        if content_length is None:
            return False
        try:
            return int(content_length) <= self.MAX_BODY_BYTES
        except ValueError:
            return False


def _parse_if_none_match(headers) -> frozenset[bytes] | None:
    """请求头里的 If-None-Match：逗号拆分、去弱校验前缀（``W/``）；``*`` 单独成集合。

    没带该头返回 None（不协商）；弱比较按 RFC 9110（GET 的 If-None-Match 忽略 W/）。
    """
    raw: bytes | None = None
    for name, value in headers:
        if name == b"if-none-match":
            raw = value
            break
    if raw is None:
        return None
    entries: set[bytes] = set()
    for part in raw.split(b","):
        part = part.strip()
        if not part:
            continue
        if part == b"*":
            return frozenset({b"*"})
        if part[:2].lower() == b"w/":
            part = part[2:].strip()
        entries.add(part)
    return frozenset(entries)


def register_middlewares(app: FastAPI, settings: Settings) -> None:
    # add_middleware 后注册者在外层：访问日志最外层，与原 @app.middleware 顺序一致。
    # 安全头挂在最内层：它只补自己那几个字段，与另外两层互不干扰；放最内可以
    # 覆盖到经由异常处理器产出的响应。
    from movieclaw_api.i18n.middleware import LocaleMiddleware

    app.add_middleware(LocaleMiddleware)
    app.add_middleware(SecurityHeadersMiddleware)
    app.add_middleware(AccessAddressMiddleware)
    # ETag 协商缓存：在 SpecHash/访问日志内层——外层照常给 304 补 spec 头、记 304 状态
    app.add_middleware(JsonEtagMiddleware, api_prefix=settings.api_v1_prefix)
    app.add_middleware(SpecHashHeaderMiddleware, api_prefix=settings.api_v1_prefix)
    app.add_middleware(AccessLogMiddleware, enabled=settings.access_log_enabled)
    # 最外层：从请求进门到响应头出门都算在途，不受访问日志开关影响
    app.add_middleware(ForegroundPressureMiddleware)
