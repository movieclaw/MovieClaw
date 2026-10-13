from fastapi import APIRouter, Request

from movieclaw_api import __version__
from movieclaw_api.core.config import get_settings
from movieclaw_api.schemas.base import BaseModel
from movieclaw_api.settings.schemas import get_jellyfin_compat
from movieclaw_api.spec_state import get_spec_hash

router = APIRouter()


class HealthResponse(BaseModel):
    status: str
    service: str
    environment: str
    # CLI 版本偏斜检测（docs/design/cli.md §2.1）：与 CLI 内置基线 spec 的
    # 指纹比对，不一致说明两端接口面不同版
    spec_hash: str
    # 服务器应用版本：客户端（iOS / Apple TV）登录前据此判断版本是否兼容，
    # 太旧时直接告诉用户「服务器是 vX，需要升级到 vY」，而不是登录失败后让人猜。
    # 本身总会输出；声明为可空是给生成的客户端类型看的——v0.30.0 及更早的
    # 服务器没有这个字段，客户端必须能把「缺失」当成「旧版本」正常解码。
    version: str | None = None
    # 这台服务器的实例号（docs/design/offline-download.md §9）：与 Jellyfin 兼容层的
    # server_id 同一个值，首次读取时生成、永不重置。App 用它认「是不是我家那台」——
    # 离线下载的归属与连通性探测都按它，不按地址（局域网 IP 与域名是同一台）
    instance_id: str | None = None


@router.get(
    "/health",
    response_model=HealthResponse,
    summary="Health check",
    operation_id="health.check",
)
async def healthcheck(request: Request) -> HealthResponse:
    settings = get_settings()
    return HealthResponse(
        status="ok",
        service=settings.app_name,
        environment=settings.app_env,
        spec_hash=get_spec_hash(request.app),
        version=__version__,
        # 配置存储自带内存缓存：只有第一次读库
        instance_id=(await get_jellyfin_compat()).server_id,
    )

