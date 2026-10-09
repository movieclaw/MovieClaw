"""插件主体与宿主操作（docs/design/plugin-phase2a.md §3）。

真实应用、真实鉴权（不覆盖 require_login）：运行中挂载一个声明了 permissions 的插件，
它拿到的凭证经 ASGI 调本进程接口，授权由 require_login 按 operationId 执行。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.keys import HOST_OPS
from movieclaw_api.services import durable_events
from movieclaw_api.services.host_ops import OpsError, expand_grants
from movieclaw_db.engine import get_database
from movieclaw_kernel import Entry, plugin


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'ops.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "0" * 32)
    get_settings.cache_clear()
    durable_events.reset_state()
    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as client:
        yield app, client
    get_settings.cache_clear()
    durable_events.reset_state()


def mount_caller(app, client, entry_id: str, permissions: tuple[str, ...], *, source="builtin"):
    """挂一个只拿宿主操作入口的插件，返回它的 OpsClient。"""
    holder: dict = {}

    @plugin(entry_id, title=entry_id, inject=(HOST_OPS,), permissions=permissions)
    async def caller(ctx) -> None:
        holder["ops"] = await ctx.use(HOST_OPS).client(ctx)

    fiber = client.portal.call(app.state.kernel.mount, Entry(entry_id, caller, source=source))
    assert fiber.state.value == "active", fiber.error
    return holder["ops"]


def call(client, ops, operation_id, arguments=None):
    return client.portal.call(lambda: ops.call(operation_id, arguments))


def test_wildcards_never_cover_dangerous_operations(app_client) -> None:
    app, _ = app_client
    host = app.state.kernel.service(HOST_OPS)
    granted = expand_grants(["subscriptions.*"], host.index)
    assert "subscriptions.list" in granted
    assert "subscriptions.delete" not in granted  # x-cli-dangerous
    assert "subscriptions.delete" in expand_grants(["subscriptions.delete"], host.index)
    assert all(op.startswith("subscriptions.") for op in granted)


def test_granted_operations_pass_and_everything_else_is_denied(app_client) -> None:
    app, client = app_client
    ops = mount_caller(app, client, "test.caller", ("app.plugins.list", "subscriptions.*"))
    body = call(client, ops, "app.plugins.list")
    assert any(p["id"] == "test.caller" for p in body["plugins"])
    by_id = {p["id"]: p for p in body["plugins"]}
    assert by_id["test.caller"]["permissions"] == ["app.plugins.list", "subscriptions.*"]
    assert call(client, ops, "subscriptions.list") is not None

    with pytest.raises(OpsError) as denied:
        call(client, ops, "library.list")
    assert denied.value.status == 403 and denied.value.code == "PLUGIN_OPERATION_DENIED"
    with pytest.raises(OpsError) as dangerous:
        call(client, ops, "subscriptions.delete", {"subscription_id": 1})
    assert dangerous.value.code == "PLUGIN_OPERATION_DENIED"
    with pytest.raises(OpsError) as unknown:
        call(client, ops, "no.such-op")
    assert unknown.value.code == "UNKNOWN_OPERATION"
    with pytest.raises(OpsError) as bad_args:
        call(client, ops, "app.plugins.list", {"nope": 1})
    assert bad_args.value.code == "INVALID_ARGUMENTS"


def test_plugin_cannot_issue_credentials(app_client) -> None:
    """签发凭证只能是人在网页或 App 里的动作：两层都挡住插件。"""
    from movieclaw_api.services.auth import PluginGrant, Principal

    app, client = app_client
    # 一、这些操作是隐藏操作，不在插件能调用的目录里
    ops = mount_caller(app, client, "test.minter", ("auth.tokens.create",))
    assert ops.operations == frozenset()
    with pytest.raises(OpsError) as hidden:
        call(client, ops, "auth.tokens.create", {"name": "x"})
    assert hidden.value.code == "UNKNOWN_OPERATION"
    # 二、就算绕过目录直接带凭证请求，插件主体也不是「交互式」的
    grant = PluginGrant(entry_id="test.minter", operations=frozenset({"auth.tokens.create"}))
    assert not Principal(kind="admin", name="plugin:test.minter", plugin=grant).interactive
    resp = client.post(
        "/api/v1/auth/tokens",
        json={"name": "x"},
        headers={"Authorization": f"Bearer {ops._token}"},
    )
    assert resp.status_code == 403


def test_credential_dies_with_the_plugin(app_client) -> None:
    app, client = app_client
    ops = mount_caller(app, client, "test.ephemeral", ("app.plugins.list",))
    assert call(client, ops, "app.plugins.list")
    client.portal.call(app.state.kernel.unmount, "test.ephemeral")
    with pytest.raises(OpsError) as gone:
        call(client, ops, "app.plugins.list")
    assert gone.value.status == 401


def test_third_party_plugins_only_get_what_the_user_approved(app_client) -> None:
    app, client = app_client
    host = app.state.kernel.service(HOST_OPS)
    host.configure("acme.partial", grants=["app.plugins.list"])
    ops = mount_caller(
        app, client, "acme.partial", ("app.plugins.list", "subscriptions.*"), source="local"
    )
    assert ops.operations == {"app.plugins.list"}
    with pytest.raises(OpsError):
        call(client, ops, "subscriptions.list")
    unapproved = mount_caller(app, client, "acme.none", ("app.plugins.list",), source="local")
    assert unapproved.operations == frozenset()


def test_acting_as_member_intersects_member_rights(app_client) -> None:
    from movieclaw_db.models import Member

    app, client = app_client

    async def add_member() -> None:
        async with get_database().session() as session:
            session.add(Member(username="family", password_hash="x"))
            await session.commit()

    client.portal.call(add_member)
    host = app.state.kernel.service(HOST_OPS)
    host.configure("test.family", act_as="family")
    ops = mount_caller(app, client, "test.family", ("app.plugins.list", "subscriptions.*"))
    # 授权了也没用：这个操作要管理员，而插件代表的是成员
    with pytest.raises(OpsError) as denied:
        call(client, ops, "app.plugins.list")
    assert denied.value.status == 403 and denied.value.code == "FORBIDDEN"
    assert call(client, ops, "subscriptions.list") is not None


def test_events_caused_by_a_plugin_call_carry_the_plugin_origin(app_client) -> None:
    from movieclaw_api import domain_events
    from movieclaw_db.models import (
        DomainEvent,
        EventConsumer,
        MediaItem,
        RuleSet,
        Subscription,
    )

    app, client = app_client

    async def seed() -> int:
        async with get_database().session() as session:
            item = MediaItem(kind="movie", tmdb_id=9, title="甲", original_title="A")
            rules = RuleSet(name="默认", spec={})
            session.add_all([item, rules])
            await session.flush()
            sub = Subscription(media_item_id=item.id, kind="movie", rule_set_id=rules.id)
            session.add(sub)
            session.add(
                EventConsumer(
                    consumer_id="test:status",
                    event_name=domain_events.SUBSCRIPTION_STATUS_CHANGED.name,
                )
            )
            await session.commit()
            return sub.id

    sub_id = client.portal.call(seed)
    durable_events.reset_subscribed()
    ops = mount_caller(app, client, "test.pauser", ("subscriptions.*",))
    call(
        client,
        ops,
        "subscriptions.set-tracking-state",
        {"subscription_id": sub_id, "state": "paused"},
    )

    async def events() -> list[DomainEvent]:
        async with get_database().session() as session:
            return list((await session.execute(select(DomainEvent))).scalars())

    [event] = client.portal.call(events)
    assert (event.origin_kind, event.origin_id) == ("plugin", "test.pauser")
    assert event.payload["status"] == "paused"


def test_job_created_by_a_plugin_is_attributed_to_it(app_client, tmp_path) -> None:
    from movieclaw_db.models import Job
    from movieclaw_db.repositories.library_repo import LibraryRepository

    app, client = app_client
    root = tmp_path / "lib"
    root.mkdir()

    async def seed() -> int:
        async with get_database().session() as session:
            library = await LibraryRepository(session).create(
                name="电影库", kind="movie", root_paths=[str(root)]
            )
            return library.id

    library_id = client.portal.call(seed)
    ops = mount_caller(app, client, "test.scanner", ("library.scan.start",))
    call(client, ops, "library.scan.start", {"library_id": library_id})

    async def jobs() -> list[Job]:
        async with get_database().session() as session:
            return list((await session.execute(select(Job))).scalars())

    origins = {job.origin for job in client.portal.call(jobs) if job.job_type == "library.scan"}
    assert origins == {"plugin"}
