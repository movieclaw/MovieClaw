"""Jellyfin 协议的错误响应形态（设计文档 §1 四形态）。

客户端基本不解析错误 body，但状态码语义必须准确：
401=认证失败/无 token（空 body，对齐认证管道挑战）；403=权限；
400=参数缺失（text/plain）；404=不存在。
"""

from __future__ import annotations

from fastapi import HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse, Response

GENERIC_ERROR_TEXT = "Error processing request."


class JellyfinError(HTTPException):
    """协议层错误：由兼容层自己的异常处理器渲染，不走业务统一处理器。"""

    def __init__(self, status_code: int, *, text: str | None = None, json_body: str | None = None):
        super().__init__(status_code=status_code)
        self.text = text
        self.json_body = json_body


def render_error(exc: JellyfinError) -> Response:
    if exc.json_body is not None:
        # 控制器主动 NotFound("文案") 形态：JSON 字符串 body
        return JSONResponse(exc.json_body, status_code=exc.status_code)
    if exc.text is not None:
        return PlainTextResponse(exc.text, status_code=exc.status_code)
    # 认证管道形态：空 body
    return Response(status_code=exc.status_code)


def unauthorized() -> JellyfinError:
    return JellyfinError(401)


def forbidden() -> JellyfinError:
    return JellyfinError(403)


def bad_request_text(text: str = GENERIC_ERROR_TEXT) -> JellyfinError:
    return JellyfinError(400, text=text)


def not_found() -> JellyfinError:
    return JellyfinError(404)


def not_found_message(message: str) -> JellyfinError:
    return JellyfinError(404, json_body=message)
