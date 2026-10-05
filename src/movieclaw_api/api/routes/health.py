from fastapi import APIRouter, Request

from movieclaw_api import __version__
from movieclaw_api.core.config import get_settings
from movieclaw_api.schemas.base import BaseModel
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
    )
