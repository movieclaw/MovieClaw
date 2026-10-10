"""插件回调端点（docs/design/plugin-callbacks.md §4）。

真实应用 + 一个本地插件（进程内 / 独立进程两种运行方式）：插件登记端点、经自己的接口发密钥；
模拟外部平台按地址调进来——平台自己追加的查询参数、请求头原样到插件，MovieClaw 的登录 Cookie
被剥掉，插件的答复原样回出去；没登记 / 作废 / 方法不对 / 超限 / 超时各回预期状态码；
验证失败计数、连续失败发待处理事项、换地址与作废。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events, plugin_runtime

PLUGIN = """
import asyncio

from fastapi import APIRouter

from movieclaw_api.plugins.keys import PLUGIN_ROUTES
from movieclaw_sdk import plugin
from movieclaw_sdk.callbacks import PLUGIN_CALLBACKS, CallbackResponse


@plugin("acme-hooks", title="回调示例", inject=(PLUGIN_CALLBACKS, PLUGIN_ROUTES))
async def apply(ctx) -> None:
    callbacks = ctx.use(PLUGIN_CALLBACKS)

    async def on_hook(req):
        if req.param("token") == "bad":
            return CallbackResponse(status=403)
        if req.param("echostr"):
            return CallbackResponse.text(req.param("echostr"))
        if req.param("slow"):
            await asyncio.sleep(5)
        return CallbackResponse.json(
            {
                "method": req.method,
                "subpath": req.subpath,
                "query": [list(p) for p in req.query],
                "cookie": req.header("cookie"),
                "auth": req.header("authorization"),
                "signature": req.header("x-hub-signature-256"),
                "body": req.text(),
                "scope": req.scope,
            },
            status=202,
        )

    callbacks.endpoint(ctx, "hook", on_hook, methods=("GET", "POST"), max_body=64, timeout=1)

    router = APIRouter()

    @router.post("/issue", operation_id="plugins.acme-hooks.issue")
    async def issue(scope: str = "plugin") -> dict:
        issued = await callbacks.issue(ctx, "hook", scope=scope)
        return {"id": issued.id, "url": issued.url, "absolute": issued.absolute}

    @router.get("/keys", operation_id="plugins.acme-hooks.keys")
    async def keys() -> list:
        return [k.url for k in await callbacks.keys(ctx)]

    ctx.use(PLUGIN_ROUTES).mount(ctx, router)
"""


@pytest.fixture
def app_env(tmp_path, monkeypatch, request):
    runtime = request.param
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'hooks.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setattr(plugin_runtime, "BACKOFF_MAX", 0.2)
    from movieclaw_api import spec_state

    monkeypatch.setattr(spec_state, "routes_changed", lambda app: None)
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "acme_hooks.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        f"- id: acme-hooks\n  local: true\n  module: acme_hooks\n  runtime: {runtime}\n",
        encoding="utf-8",
    )
    yield runtime
    durable_events.reset_state()
    get_settings.cache_clear()


def start() -> TestClient:
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    return TestClient(app)


def issue(client: TestClient, scope: str = "plugin") -> dict:
    reply = client.post("/api/v1/plugins/acme-hooks/issue", params={"scope": scope})
    assert reply.status_code == 200, reply.text
    return reply.json()


@pytest.mark.parametrize("app_env", ["inline", "process"], indirect=True)
def test_outside_platform_calls_reach_the_plugin_as_sent(app_env) -> None:
    with start() as client:
        assert client.app.state.kernel.fiber("acme-hooks").state.value == "active"
        issued = issue(client)
        url = issued["url"]
        # 没配外部访问地址：只有路径
        assert not issued["absolute"] and url.startswith("/api/v1/hooks/acme-hooks/hook/")
        key = url.rsplit("/", 1)[1]
        assert len(key) == 16

        # 平台验证地址：自己追加签名参数，插件回 echostr
        reply = client.get(url, params={"msg_signature": "s", "timestamp": "1", "echostr": "ok!"})
        assert (reply.status_code, reply.text) == (200, "ok!")

        # 原样转交：方法、子路径、查询参数、平台的请求头与 Authorization；登录 Cookie 被剥掉
        client.cookies.set("movieclaw_session", "admin-session")
        reply = client.post(
            f"{url}/events/push?x=1&x=2",
            content=b"hello",
            headers={"Authorization": "Bearer platform", "X-Hub-Signature-256": "sha256=ab"},
        )
        client.cookies.clear()
        assert reply.status_code == 202, reply.text
        assert reply.json() == {
            "method": "POST",
            "subpath": "events/push",
            "query": [["x", "1"], ["x", "2"]],
            "cookie": None,
            "auth": "Bearer platform",
            "signature": "sha256=ab",
            "body": "hello",
            "scope": "plugin",
        }

        # 宿主的底线：没登记、对不上、方法不对、超限、超时
        assert client.get(url.replace(key, "A" * 16)).status_code == 404
        assert client.get(url.replace("/hook/", "/other/")).status_code == 404
        assert client.put(url).status_code == 405
        assert client.post(url, content=b"x" * 65).status_code == 413
        assert client.get(url, params={"slow": "1"}).status_code == 504

        # 插件回 403 记为验证失败；管理接口里密钥打码
        assert client.get(url, params={"token": "bad"}).status_code == 403
        listed = client.get("/api/v1/app/plugins/callbacks").json()["data"]
        assert len(listed) == 1
        row = listed[0]
        assert row["url"] == f"/api/v1/hooks/acme-hooks/hook/****{key[-4:]}"
        assert key not in str(listed)
        assert (row["running"], row["failures"]) == (True, 1)
        assert row["calls"] >= 4 and row["last_status"] == 403
        keys = client.get("/api/v1/plugins/acme-hooks/keys").json()
        assert keys == [row["url"]]

        # 换地址：旧的立即失效，新的能用；作废：一律 404
        rotated = client.post(f"/api/v1/app/plugins/callbacks/{row['id']}/rotate")
        assert rotated.status_code == 200, rotated.text
        fresh = rotated.json()["data"]["url"]
        assert client.get(url, params={"echostr": "x"}).status_code == 404
        assert client.get(fresh, params={"echostr": "y"}).text == "y"
        fresh_id = rotated.json()["data"]["id"]
        assert client.delete(f"/api/v1/app/plugins/callbacks/{fresh_id}").status_code == 200
        assert client.get(fresh, params={"echostr": "z"}).status_code == 404


@pytest.mark.parametrize("app_env", ["inline"], indirect=True)
def test_repeated_verification_failures_raise_a_notice_until_it_works_again(app_env) -> None:
    from sqlalchemy import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeStatus, SystemNotice

    async def notice() -> SystemNotice | None:
        async with get_database().session() as session:
            return (
                await session.execute(
                    select(SystemNotice).where(
                        SystemNotice.dedupe_key == "plugin:acme-hooks:callback:hook"
                    )
                )
            ).scalar_one_or_none()

    with start() as client:
        url = issue(client)["url"]
        for _ in range(9):
            assert client.get(url, params={"token": "bad"}).status_code == 403
        assert client.portal.call(notice) is None
        assert client.get(url, params={"token": "bad"}).status_code == 403
        found = client.portal.call(notice)
        assert found is not None and found.status != NoticeStatus.RESOLVED.value
        assert client.get(url, params={"echostr": "ok"}).status_code == 200
        assert client.portal.call(notice).status == NoticeStatus.RESOLVED.value


@pytest.mark.parametrize("app_env", ["inline"], indirect=True)
def test_disabled_plugin_answers_503_and_keeps_its_address(app_env) -> None:
    with start() as client:
        url = issue(client)["url"]
        kernel = client.app.state.kernel
        client.portal.call(kernel.disable, "acme-hooks")
        assert client.get(url, params={"echostr": "x"}).status_code == 503
        client.portal.call(kernel.enable, "acme-hooks")
        assert client.get(url, params={"echostr": "x"}).text == "x"


def test_callback_keys_are_masked_in_logs() -> None:
    import logging

    from movieclaw_api.core.logging import RedactingFormatter

    record = logging.LogRecord(
        "movieclaw_api.access",
        logging.INFO,
        __file__,
        1,
        "method=POST path=/api/v1/hooks/acme-hooks/hook/k7Q2xZp9MfT3aR8w/sub status_code=200",
        None,
        None,
    )
    text = RedactingFormatter("%(message)s").format(record)
    assert "k7Q2xZp9MfT3aR8w" not in text
    assert "/api/v1/hooks/acme-hooks/hook/****/sub" in text


def test_the_hooks_route_stays_out_of_the_api_catalog() -> None:
    from movieclaw_api.app import create_app

    paths = create_app().openapi()["paths"]
    assert not [p for p in paths if p.startswith("/api/v1/hooks")]
