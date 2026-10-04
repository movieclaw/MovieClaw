"""通用图片代理接口（带本地磁盘缓存）与刮削图片资产直出。"""

import asyncio
from pathlib import Path
from stat import S_ISREG

from fastapi import APIRouter, Depends, Query
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.api.deps import require_login
from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.image_cache import get_image_cache
from movieclaw_api.services.image_variants import (
    ImageVariant,
    get_image_variant_service,
    source_version_of,
)
from movieclaw_db.engine import get_session

router = APIRouter(prefix="/images", tags=["images"])

# 所有出图路由共用的宽度参数（docs/design/image-sizing.md §5）：要多少像素宽，服务端向上
# 取到宽度阶梯；原图不比那一档大就回原图。凡是服务端给的图片地址都可以带它
WIDTH_QUERY = Query(
    default=None,
    ge=1,
    le=10000,
    description="需要的像素宽（显示宽 × 屏幕倍率）；服务端向上取到宽度阶梯，原图更小则回原图",
)


def requested_width(w: object) -> int | None:
    """``w`` 参数的实际值：路由函数被直接调用（分享通道转调、测试）时没传的参数是
    ``Query`` 声明本身而不是 None，一律当作没要宽度。"""
    return w if isinstance(w, int) and w > 0 else None


async def sized_file(
    path: Path,
    *,
    source_key: str,
    w: int | None,
    headers: dict[str, str],
    media_type: str | None = None,
) -> FileResponse:
    """出图路由共用：带 ``w`` 取宽度档派生（原图不比那一档大则回原图），否则原图直出。

    ``source_key`` 是这张图的稳定身份（进派生缓存键）；版本取文件的 mtime + 大小，
    原地换图自动失效。
    """
    w = requested_width(w)
    if not w:
        return FileResponse(path, media_type=media_type, headers=headers)
    stat = await asyncio.to_thread(path.stat)
    cached = await get_image_variant_service().get_or_create(
        path,
        source_key=source_key,
        source_version=source_version_of(stat),
        width=w,
        content_type=media_type,
    )
    return FileResponse(cached.path, media_type=cached.content_type, headers=headers)


@router.get(
    "/proxy",
    response_class=FileResponse,
    summary="代理并缓存远程图片",
    operation_id="images.proxy",
    openapi_extra={"x-cli-hidden": True},
)
async def proxy_image(
    url: str = Query(min_length=1, max_length=2048),
    variant: ImageVariant | None = Query(default=None),
    w: int | None = WIDTH_QUERY,
) -> FileResponse:
    """前端所有远程图片的统一入口：命中读本地缓存，未命中回源抓取后落盘。

    域名安全（SSRF 防护）、类型和体积校验在 ImageProxy 服务层完成。
    图床 URL 对应的内容事实上不可变，浏览器侧直接给一年 immutable 缓存。
    """
    w = requested_width(w)
    if variant is not None or w:
        # 派生图只认 URL：命中就不必先读原图（原图被淘汰后断网也能出图）
        cached = await get_image_variant_service().get_or_create_remote(
            url, variant=variant, width=w
        )
    else:
        cached = await get_image_cache().get_or_fetch(url)
    return FileResponse(
        cached.path,
        media_type=cached.content_type,
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


@router.get(
    "/assets/{path:path}",
    response_class=FileResponse,
    summary="刮削图片资产直出（data/metadata/images 下的本地文件）",
    operation_id="images.asset",
    openapi_extra={"x-cli-hidden": True},
)
async def get_metadata_asset(
    path: str,
    variant: ImageVariant | None = Query(default=None),
    v: str | None = Query(default=None, max_length=32),
    principal: Principal = Depends(require_login),
    session: AsyncSession = Depends(get_session),
    w: int | None = WIDTH_QUERY,
) -> FileResponse:
    """海报/剧照等刮削资产的服务通道（docs/design/metadata.md 6.1）。

    路径限定在资产根目录内（防目录穿越）。force 刷新会原地覆盖同名文件，
    故不给 immutable，一天后重新校验即可。

    资产按条目 id 分目录（``<media_item_id>/poster.jpg``），条目 id 是自增整数
    可猜——所以这里还要按库可见范围判一次：条目落在主体不可浏览的库里就 404，
    否则「看不见库」的成员靠猜 id 也能把库里的海报/抓帧图翻个遍
    （docs/design/library-access.md 2.5）。

    超管会话不做这层校验：超管对全部库都有管理权，「仅管理」只是把库从自己的
    浏览面（首页 / 海报墙 / Jellyfin）摘掉，不是对超管保密。活动页「全部」口径
    本来就给超管看范围外记录的片名，海报同级放行；否则那些行会请求到 404，
    海报位一直空着（实测踩过）。
    """
    from movieclaw_api.services.library.access import assert_item_visible
    from movieclaw_api.services.media_scrape import resolve_asset_path

    # 越权判定（含 resolve）结果按相对路径缓存，见 resolve_asset_path
    target = resolve_asset_path(path)
    if target is None:
        raise NotFoundException("图片资产不存在")
    # 一次 stat 走完「存在吗 + 是文件吗 + 版本戳 + 能不能永久缓存」四问：
    # 这四问原本各 stat 一次，而海报墙一屏就是上百个这样的请求
    try:
        stat = target.stat()
    except OSError:
        raise NotFoundException("图片资产不存在") from None
    if not S_ISREG(stat.st_mode):
        raise NotFoundException("图片资产不存在")
    head = path.split("/", 1)[0]
    if head.isdigit() and principal.kind != "admin":
        await assert_item_visible(session, principal, int(head))
    w = requested_width(w)
    if variant is not None or w:
        cached = await get_image_variant_service().get_or_create(
            target,
            source_key=f"asset:{path}",
            source_version=source_version_of(stat),
            variant=variant,
            width=w,
        )
        # 业务 URL 携带的 v 与当前文件版本一致时才可永久缓存；手写的错误 v
        # 仍给一天缓存，避免同一 URL 在换图后长期停留旧派生图。
        immutable = v == str(int(stat.st_mtime))
        cache_control = (
            "public, max-age=31536000, immutable"
            if immutable
            else "public, max-age=86400"
        )
        return FileResponse(
            cached.path,
            media_type=cached.content_type,
            headers={"Cache-Control": cache_control},
        )
    # 类型按扩展名推断（poster.jpg → image/jpeg、logo.png → image/png），
    # 不写死 JPEG：片名 Logo 是 PNG，严格的客户端按声明类型解码会出错
    return FileResponse(target, headers={"Cache-Control": "public, max-age=86400"})


@router.get(
    "/people/{path:path}",
    response_class=FileResponse,
    summary="演职员头像（本地，按 TMDB 头像路径去重存放）",
    operation_id="images.person",
    openapi_extra={"x-cli-hidden": True},
)
async def get_person_avatar(
    path: str,
    w: int | None = WIDTH_QUERY,
    _principal: Principal = Depends(require_login),
) -> FileResponse:
    """头像文件名就是 TMDB 头像路径（内容不可变，换图即换地址），所以给一年 immutable。

    演职员头像是公开资料，不按媒体库可见范围鉴权，登录即可读。"""
    from movieclaw_api.services.people_images import resolve_avatar_path

    target = await asyncio.to_thread(resolve_avatar_path, path)
    if target is None:
        raise NotFoundException("头像不存在")
    return await sized_file(
        target,
        source_key=f"person:{path}",
        w=w,
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )
