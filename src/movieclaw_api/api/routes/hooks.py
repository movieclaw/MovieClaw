"""插件回调端点的入口（docs/design/plugin-callbacks.md §4）。

地址：``/api/v1/hooks/<条目 id>/<端点名>/<密钥>``。

公开区：不登录，地址里的密钥就是门票，没登记、已作废的一律 404。不进 OpenAPI——这不是给 mclaw /
AI 助手调的业务接口，而是给外部平台的回调地址；验签、解析请求体都交给插件
（services/plugin_callbacks.py）。
"""

from __future__ import annotations

from fastapi import APIRouter, Request, Response

from movieclaw_api.services import plugin_callbacks

router = APIRouter(prefix="/hooks", include_in_schema=False)

_METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]


async def _hook(request: Request, entry_id: str, name: str, key: str, subpath: str) -> Response:
    service = plugin_callbacks.get_service()
    if service is None:
        return Response("插件回调未启用", status_code=503, media_type="text/plain; charset=utf-8")

    async def read_body(limit: int) -> bytes | None:
        """边读边数，超过上限就停（返回 None）。"""
        chunks: list[bytes] = []
        size = 0
        async for chunk in request.stream():
            size += len(chunk)
            if size > limit:
                return None
            chunks.append(chunk)
        return b"".join(chunks)

    try:
        reply = await service.dispatch(
            entry_id,
            name,
            key,
            method=request.method,
            subpath=subpath,
            query=list(request.query_params.multi_items()),
            headers=list(request.headers.items()),
            read_body=read_body,
        )
    except plugin_callbacks.CallbackError as exc:
        return Response(exc.reason, status_code=exc.status, media_type="text/plain; charset=utf-8")
    return Response(reply.body, status_code=reply.status, headers=reply.headers)


@router.api_route("/{entry_id}/{name}/{key}", methods=_METHODS)
async def hook(request: Request, entry_id: str, name: str, key: str) -> Response:
    return await _hook(request, entry_id, name, key, "")


@router.api_route("/{entry_id}/{name}/{key}/{subpath:path}", methods=_METHODS)
async def hook_subpath(
    request: Request, entry_id: str, name: str, key: str, subpath: str
) -> Response:
    return await _hook(request, entry_id, name, key, subpath)
