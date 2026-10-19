"""OpenAPI spec 运行时刷新端点（docs/design/cli.md §2.1 辅通道）。

CLI 的主 spec 通道是构建期内置基线；本端点只服务「远程安装的 CLI 与服务器
版本偏斜」这一场景：CLI 发现响应头里的 spec_hash 与内置基线不一致时，来
这里拉取当前服务器的完整 spec 并缓存。

与「生产环境关闭 openapi.json」的安全立场不冲突：本端点在受保护区
（须登录 / 令牌），匿名可见面零增加。ETag 用 spec 内容指纹，命中时 304。
"""

from __future__ import annotations

from fastapi import APIRouter, Header, Request, Response

from movieclaw_api.spec_state import get_spec_hash, spec_body

router = APIRouter(prefix="/spec", tags=["system"])


@router.get(
    "",
    summary="当前服务器的完整 OpenAPI spec（CLI 版本偏斜时的刷新数据源）",
    operation_id="system.spec",
    openapi_extra={"x-cli-hidden": True},
)
async def get_spec(
    request: Request,
    if_none_match: str | None = Header(default=None),
) -> Response:
    etag = f'"{get_spec_hash(request.app)}"'
    if if_none_match == etag:
        return Response(status_code=304, headers={"ETag": etag})
    return Response(spec_body(request.app), media_type="application/json", headers={"ETag": etag})
