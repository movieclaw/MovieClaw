"""插件网页的静态托管（docs/design/plugin-web-pages.md §3）。

``/api/v1/plugins/<插件 id>/web/<子路径>``：主程序 ``/apps/<插件 id>/`` 页面里那个同源 iframe
加载的地址。挂在插件路由前缀下、要求登录；插件自己注册路由时 ``/web`` 这一段保留给这里
（``PluginRoutes.mount``）。
必须先于插件路由的宿主路由器挂载（app.py），同一路径才由这里命中。

- 有文件给文件，目录给其中的 index.html；
- 都没有、且是页面导航请求时回退到 ``web/index.html``（单页应用的前端路由）；脚本、图片照常 404；
- 标准 HTTP 缓存校验：ETag + ``Cache-Control: no-cache``；
- 后端默认的 ``X-Frame-Options: DENY`` 在这里换成同源可嵌。

处理函数刻意写成普通 ``def``：每次请求都要读安装记录、``plugins.yaml`` 和文件状态，放在线程池里跑，
盘慢的时候（NAS）不会卡住事件循环。
"""

from __future__ import annotations

import hashlib
import mimetypes

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import FileResponse, RedirectResponse

from movieclaw_api.api.deps import require_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.services import plugin_web
from movieclaw_api.services.auth import Principal

router = APIRouter(prefix="/plugins", tags=["ui"])

_TYPES = {
    ".webmanifest": "application/manifest+json",
    ".mjs": "text/javascript",
    ".js": "text/javascript",
    ".svg": "image/svg+xml",
    ".wasm": "application/wasm",
}
_FRAME_HEADERS = {
    "Cache-Control": "no-cache",
    "X-Frame-Options": "SAMEORIGIN",
    "Content-Security-Policy": "frame-ancestors 'self'; object-src 'none'",
}
#: 浏览器把 iframe / 顶层页面导航标成这些（Fetch Metadata 标准）
_NAVIGATION_DESTS = {"document", "iframe", "frame"}


def _is_navigation(request: Request) -> bool:
    dest = request.headers.get("sec-fetch-dest")
    if dest is not None:
        return dest in _NAVIGATION_DESTS
    return "text/html" in request.headers.get("accept", "")


def _plugin(request: Request, entry_id: str, principal: Principal) -> plugin_web.WebPlugin:
    found = plugin_web.find(get_settings(), entry_id)
    kernel = getattr(request.app.state, "kernel", None)
    if found is None or not plugin_web.visible_to(found, principal, kernel):
        raise NotFoundException("没有这个插件页面")
    return found


@router.get(
    "/{entry_id}/web",
    summary="插件网页根地址（补上结尾斜杠，相对链接才解析得对）",
    operation_id="ui.apps.root",
    openapi_extra={"x-cli-hidden": True},
)
def plugin_web_root(
    entry_id: str, request: Request, principal: Principal = Depends(require_login)
) -> Response:
    _plugin(request, entry_id, principal)
    query = f"?{request.url.query}" if request.url.query else ""
    # 经 Next 反代时结尾斜杠要原样转过来：见 next.config.ts 的 skipTrailingSlashRedirect
    # 与专门的 rewrite
    return RedirectResponse(f"{plugin_web.base_path(entry_id)}{query}", status_code=308)


@router.get(
    "/{entry_id}/web/{path:path}",
    summary="插件网页的静态文件（授信页面，同源 iframe 加载）",
    operation_id="ui.apps.file",
    openapi_extra={"x-cli-hidden": True},
)
def plugin_web_file(
    entry_id: str, path: str, request: Request, principal: Principal = Depends(require_login)
) -> Response:
    found = _plugin(request, entry_id, principal)
    target = plugin_web.resolve_file(found.root, path)
    if target is None and _is_navigation(request):
        target = plugin_web.resolve_file(found.root, plugin_web.INDEX)
    if target is None:
        raise NotFoundException("文件不存在")
    stat = target.stat()
    etag = (
        '"'
        + hashlib.md5(  # noqa: S324 -- 只做缓存校验，不涉及安全
            f"{target}:{stat.st_mtime_ns}:{stat.st_size}".encode()
        ).hexdigest()
        + '"'
    )
    if etag in request.headers.get("if-none-match", ""):
        return Response(status_code=304, headers={**_FRAME_HEADERS, "ETag": etag})
    media_type = _TYPES.get(target.suffix.lower()) or (
        mimetypes.guess_type(target.name)[0] or "application/octet-stream"
    )
    return FileResponse(
        target, media_type=media_type, headers={**_FRAME_HEADERS, "ETag": etag}, stat_result=stat
    )
