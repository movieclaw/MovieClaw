"""插件路由与签名链接（docs/design/plugin-phase2b.md §8）。

真实应用 + 运行中挂载的插件（以第三方来源挂）：三个区的鉴权由宿主注入、公开区验签、
operationId 前缀约束、卸载即摘除、spec 指纹随之变化并恢复、重载后已签发的链接仍然有效。
"""

from __future__ import annotations

import time

import pytest
from fastapi import APIRouter
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.keys import PLUGIN_ROUTES
from movieclaw_api.services import durable_events
from movieclaw_kernel import Entry, plugin


@pytest.fixture
def no_spec_refresh(monkeypatch):
    """不关心 spec 指纹的用例：跳过后台重算（生成整份 spec 要好几秒，会拖慢同进程的请求）。"""
    from movieclaw_api import spec_state

    monkeypatch.setattr(spec_state, "routes_changed", lambda app: None)


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'pr.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as client:
        yield app, client
    get_settings.cache_clear()
    durable_events.reset_state()


def as_principal(app, kind: str | None) -> None:
    """模拟登录态：``None`` = 未登录（不覆盖，走真实鉴权）。"""
    from movieclaw_api.api.deps import require_login
    from movieclaw_api.services.auth import Principal

    app.dependency_overrides.clear()
    if kind is not None:
        principal = Principal(kind=kind, name=kind, is_admin=kind == "admin")
        app.dependency_overrides[require_login] = lambda: principal


def files_plugin(entry_id: str, *, zone: str = "public", operation_prefix: str | None = None):
    holder: dict = {}
    prefix = operation_prefix if operation_prefix is not None else f"plugins.{entry_id}."

    @plugin(entry_id, title="网盘文件", inject=(PLUGIN_ROUTES,))
    async def apply(ctx) -> None:
        routes = ctx.use(PLUGIN_ROUTES)
        router = APIRouter()

        @router.get("/files/{file_id}", operation_id=f"{prefix}file")
        async def file(file_id: int, quality: str = "raw") -> dict:
            return {"file": file_id, "quality": quality}

        holder["prefix"] = routes.mount(ctx, router, zone=zone)
        holder["ctx"] = ctx
        holder["routes"] = routes

    return apply, holder


def mount(app, client, apply, entry_id: str):
    fiber = client.portal.call(app.state.kernel.mount, Entry(entry_id, apply, source="acme"))
    return fiber


def spec_hash(client) -> str:
    return client.get("/api/v1/health").json()["spec_hash"]


def wait_hash(client, *, not_equal: str | None = None, equal: str | None = None) -> str:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        current = spec_hash(client)
        if (not_equal is not None and current != not_equal) or current == equal:
            return current
        time.sleep(0.05)
    raise AssertionError(f"spec 指纹没有按预期变化：{current}（不等于 {not_equal}，等于 {equal}）")


def test_admin_and_member_zones_get_host_auth(app_client, no_spec_refresh) -> None:
    app, client = app_client
    admin_apply, _ = files_plugin("acme.admin", zone="admin")
    member_apply, _ = files_plugin("acme.member", zone="member")
    assert mount(app, client, admin_apply, "acme.admin").state.value == "active"
    assert mount(app, client, member_apply, "acme.member").state.value == "active"

    as_principal(app, None)
    assert client.get("/api/v1/plugins/acme.admin/files/1").status_code == 401
    assert client.get("/api/v1/plugins/acme.member/files/1").status_code == 401

    as_principal(app, "member")
    assert client.get("/api/v1/plugins/acme.admin/files/1").status_code == 403
    reply = client.get("/api/v1/plugins/acme.member/files/1?quality=hd")
    assert reply.status_code == 200
    assert reply.json() == {"file": 1, "quality": "hd"}

    as_principal(app, "admin")
    assert client.get("/api/v1/plugins/acme.admin/files/1").json() == {"file": 1, "quality": "raw"}


def test_routes_follow_the_plugin_and_move_the_spec_hash(app_client) -> None:
    from movieclaw_api.export_openapi import spec_hash as content_hash

    app, client = app_client
    as_principal(app, "admin")
    before = spec_hash(client)
    # 以现场生成的内容为准（源码目录里可能留着旧的基线导出）
    original = content_hash(app.openapi())
    apply, _ = files_plugin("acme.cloud", zone="admin")
    fiber = mount(app, client, apply, "acme.cloud")
    assert fiber.state.value == "active"

    changed = wait_hash(client, not_equal=before)
    assert changed != original
    spec = client.get("/api/v1/spec").json()
    operation = spec["paths"]["/api/v1/plugins/acme.cloud/files/{file_id}"]["get"]
    assert operation["operationId"] == "plugins.acme.cloud.file"
    assert client.get("/api/v1/spec").headers["ETag"] == f'"{changed}"'
    assert client.get("/api/v1/plugins/acme.cloud/files/3").status_code == 200

    client.portal.call(app.state.kernel.unmount, "acme.cloud")
    assert client.get("/api/v1/plugins/acme.cloud/files/3").status_code == 404
    # 摘除后路由表回到基线，指纹也回到原值（内容哈希，不看来源）
    assert wait_hash(client, equal=original) == original
    assert (
        "/api/v1/plugins/acme.cloud/files/{file_id}"
        not in client.get("/api/v1/spec").json()["paths"]
    )

    # 再挂一次：版本号不回退，路由表与 OpenAPI 缓存都要认出新路由
    fiber = mount(app, client, apply, "acme.cloud")
    assert client.get("/api/v1/plugins/acme.cloud/files/4").status_code == 200
    wait_hash(client, equal=changed)
    client.portal.call(app.state.kernel.unmount, "acme.cloud")


@pytest.mark.parametrize(
    ("entry_id", "operation_prefix", "message"),
    [
        ("acme.sly", "plugins.other.", "operationId 须以 plugins.acme.sly. 开头"),
        ("Acme/Bad", None, "条目 id 不能用作路径"),
    ],
)
def test_mount_rejects_bad_operation_ids_and_paths(
    app_client, no_spec_refresh, entry_id, operation_prefix, message
) -> None:
    app, client = app_client
    apply, _ = files_plugin(entry_id, zone="admin", operation_prefix=operation_prefix)
    fiber = mount(app, client, apply, entry_id)
    assert fiber.state.value == "failed"
    assert message in fiber.error


def test_public_zone_requires_the_plugin_signature(app_client, no_spec_refresh) -> None:
    from movieclaw_api.settings import get_setting_store
    from movieclaw_api.settings.app_server import AppServerSetting

    app, client = app_client
    as_principal(app, None)
    apply, holder = files_plugin("acme.strm")
    assert mount(app, client, apply, "acme.strm").state.value == "active"
    ctx, routes = holder["ctx"], holder["routes"]

    def sign(path: str, **kw) -> str:
        return client.portal.call(lambda: routes.sign(ctx, path, **kw))

    forever = sign("/files/7", params={"quality": "hd"})
    assert forever.startswith("/api/v1/plugins/acme.strm/files/7?")
    assert client.get(forever).json() == {"file": 7, "quality": "hd"}

    # 不带签名、改路径、改参数、换别的插件的签名：一律 404（不暴露路由存在）
    assert client.get("/api/v1/plugins/acme.strm/files/7").status_code == 404
    assert client.get(forever.replace("/files/7", "/files/8")).status_code == 404
    assert client.get(forever.replace("quality=hd", "quality=raw")).status_code == 404
    other_apply, other = files_plugin("acme.other")
    assert mount(app, client, other_apply, "acme.other").state.value == "active"
    foreign = client.portal.call(lambda: other["routes"].sign(other["ctx"], "/files/7"))
    sig = foreign.split("sig=")[1]
    assert client.get(f"/api/v1/plugins/acme.strm/files/7?sig={sig}").status_code == 404

    # 带时限的链接：过期后 404
    short = sign("/files/7", expires_in=60)
    assert client.get(short).status_code == 200
    expired = sign("/files/7", expires_in=-1)
    assert client.get(expired).status_code == 404

    # 完整地址：没配外部访问地址时明确报错；配了就拼上
    with pytest.raises(ValueError, match="外部访问地址"):
        sign("/files/7", absolute=True)
    client.portal.call(
        lambda: get_setting_store().set(AppServerSetting(external_url="https://mc.example.com/"))
    )
    assert sign("/files/7", absolute=True).startswith(
        "https://mc.example.com/api/v1/plugins/acme.strm/files/7?sig="
    )

    # 插件路由服务重载（密钥缓存清空，依赖它的插件随之重挂）后，已写出去的不过期链接仍然有效
    kernel = app.state.kernel
    client.portal.call(kernel.disable, "kernel.plugin-routes")
    assert client.get(forever).status_code == 404
    client.portal.call(kernel.enable, "kernel.plugin-routes")
    assert holder["routes"] is not routes
    assert client.get(forever).json() == {"file": 7, "quality": "hd"}
    # 密钥存在插件自己的数据里，且加密存放
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import PluginData

    async def stored() -> list[PluginData]:
        async with get_database().session() as session:
            return list(
                (
                    await session.execute(
                        select(PluginData).where(PluginData.entry_id == "acme.strm")
                    )
                ).scalars()
            )

    rows = client.portal.call(stored)
    assert [(r.key, r.secret) for r in rows] == [("kernel.link-key", True)]


def test_mounting_routes_does_not_rebuild_the_business_routes(app_client, no_spec_refresh) -> None:
    """宿主路由器挂在应用顶层：插件挂路由只重建插件那一块，业务路由的生效上下文原样复用。

    嵌在 api_router 里时，每挂 / 摘一次都要为全部业务路由重建（本机约 1.5 秒，卡在事件循环上）。
    """
    from fastapi.routing import iter_route_contexts

    def health_context():
        return next(
            c._route_context
            for c in iter_route_contexts(app.routes)
            if c.path_format == "/api/v1/health"
        )

    app, client = app_client
    before = health_context()
    apply, _ = files_plugin("acme.cheap", zone="admin")
    assert mount(app, client, apply, "acme.cheap").state.value == "active"
    assert health_context() is before
    client.portal.call(app.state.kernel.unmount, "acme.cheap")
    assert health_context() is before
