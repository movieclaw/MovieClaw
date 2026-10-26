from typing import Any, Generic, TypeVar

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel

T = TypeVar("T")


class ApiResponse(BaseModel, Generic[T]):
    success: bool = True
    code: str = "OK"
    message: str = "success"
    data: T


class ErrorResponse(BaseModel):
    success: bool = False
    code: str
    message: str
    details: list[dict[str, Any]] | None = Field(default=None)
    message_key: str | None = None
    params: dict[str, Any] | None = None


def ok(data: T, message: str = "success", code: str = "OK") -> ApiResponse[T]:
    return ApiResponse[T](success=True, code=code, message=message, data=data)
