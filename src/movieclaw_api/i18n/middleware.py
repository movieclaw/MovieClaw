from starlette.datastructures import MutableHeaders
from starlette.requests import HTTPConnection
from starlette.types import ASGIApp, Receive, Scope, Send

from movieclaw_api.i18n import current_locale, negotiate, normalize_locale


class LocaleMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return
        connection = HTTPConnection(scope)
        locale = normalize_locale(connection.cookies.get("mc_locale", "")) or negotiate(
            connection.headers.get("accept-language")
        )
        token = current_locale.set(locale)

        async def localized_send(message):
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                headers["Content-Language"] = locale
                headers.add_vary_header("Accept-Language, Cookie")
            await send(message)

        try:
            # WebSocket（远程转码 Worker 等）同样按握手请求的语言说话，只是没有响应头可写
            await self.app(scope, receive, localized_send if scope["type"] == "http" else send)
        finally:
            current_locale.reset(token)
