from httpx import ASGITransport, AsyncClient

from movieclaw_api import __version__
from movieclaw_api.app import create_app


async def test_healthcheck() -> None:
    app = create_app()

    async with AsyncClient(
        transport=ASGITransport(app=app, raise_app_exceptions=False),
        base_url="http://testserver",
    ) as client:
        response = await client.get("/api/v1/health")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    # 未登录即可读到版本：App 登录前靠它做版本兼容检查
    assert response.json()["version"] == __version__
