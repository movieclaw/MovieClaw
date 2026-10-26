from typing import Any

from fastapi.encoders import jsonable_encoder

from movieclaw_api.i18n.stored import stored_message


class AppException(Exception):
    def __init__(
        self,
        *,
        status_code: int,
        code: str,
        message: str = "",
        details: list[dict[str, Any]] | None = None,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        self.message_key = message_key
        self.params = jsonable_encoder(params or {}, custom_encoder={Exception: str})
        if message_key:
            message = stored_message(message, message_key, self.params)
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details


class BadRequestException(AppException):
    def __init__(
        self,
        message: str = "bad request",
        details: list[dict[str, Any]] | None = None,
        *,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            status_code=400,
            code="BAD_REQUEST",
            message=message,
            details=details,
            message_key=message_key,
            params=params,
        )


class UnauthorizedException(AppException):
    def __init__(
        self,
        message: str = "unauthorized",
        details: list[dict[str, Any]] | None = None,
        *,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            status_code=401,
            code="UNAUTHORIZED",
            message=message,
            details=details,
            message_key=message_key,
            params=params,
        )


class ForbiddenException(AppException):
    def __init__(
        self,
        message: str = "forbidden",
        details: list[dict[str, Any]] | None = None,
        *,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            status_code=403,
            code="FORBIDDEN",
            message=message,
            details=details,
            message_key=message_key,
            params=params,
        )


class NotFoundException(AppException):
    def __init__(
        self,
        message: str = "resource not found",
        details: list[dict[str, Any]] | None = None,
        *,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            status_code=404,
            code="RESOURCE_NOT_FOUND",
            message=message,
            details=details,
            message_key=message_key,
            params=params,
        )


class UpstreamServiceException(AppException):
    """上游数据服务（如 TMDB）不可用、未配置或请求失败。"""

    def __init__(
        self,
        message: str = "upstream service error",
        details: list[dict[str, Any]] | None = None,
        *,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            status_code=502,
            code="UPSTREAM_ERROR",
            message=message,
            details=details,
            message_key=message_key,
            params=params,
        )


class UpstreamUnreachableException(AppException):
    """上游服务在网络层面不可达（连接失败/超时/熔断）。

    与 ``UpstreamServiceException``（服务可达但出错）区分：本异常携带结构化的
    service 与 hint，前端据 code=UPSTREAM_UNREACHABLE 渲染引导式错误态
    （说明原因 + 跳转「设置 → 网络」），而不是一句裸的 502。
    """

    def __init__(
        self,
        message: str,
        *,
        service: str,
        hint: str,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            status_code=502,
            code="UPSTREAM_UNREACHABLE",
            message=message,
            details=[{"service": service, "hint": hint}],
            message_key=message_key,
            params=params,
        )


class ConflictException(AppException):
    def __init__(
        self,
        message: str = "conflict",
        details: list[dict[str, Any]] | None = None,
        *,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            status_code=409,
            code="CONFLICT",
            message=message,
            details=details,
            message_key=message_key,
            params=params,
        )


class ServiceUnavailableException(AppException):
    """服务暂时不可用（资源耗尽而非请求有错）。

    网页播放器用它表达「转码位已满」「转码缓存达配额」这类**稍后重试就能好**
    的情况——语义上不是客户端的错（4xx），而是服务端当下没有余量。
    message 面向用户，中文。
    """

    def __init__(
        self,
        message: str = "service unavailable",
        details: list[dict[str, Any]] | None = None,
        *,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            status_code=503,
            code="SERVICE_UNAVAILABLE",
            message=message,
            details=details,
            message_key=message_key,
            params=params,
        )


class InsufficientStorageException(AppException):
    """服务端缓存卷空间或配额不足。"""

    def __init__(
        self,
        message: str = "insufficient storage",
        details: list[dict[str, Any]] | None = None,
        *,
        message_key: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(
            status_code=507,
            code="INSUFFICIENT_STORAGE",
            message=message,
            details=details,
            message_key=message_key,
            params=params,
        )


def exception_fields(error: Exception) -> dict[str, Any]:
    """Preserve a domain/SDK error reference when assigning its HTTP status."""
    return {
        "message": getattr(error, "message", str(error)),
        "message_key": getattr(error, "message_key", None),
        "params": getattr(error, "message_params", getattr(error, "params", None)),
    }
