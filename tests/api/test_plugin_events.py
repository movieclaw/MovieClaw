"""插件自己的事件与通知（docs/design/domain-events.md §7）。

声明（清单）→ 批准（会通知普通成员的要单独确认）→ 插件登记、发出 → 进系统事件目录（别的订阅方、
Webhook 能订）、通知开关出现在「账号 → 通知」→ 卸载时一并撤下。敏感事件（谁在什么时候看了什么）
插件包要声明、经批准才能订。推到手机的全链路见
test_cloud_push.py::test_plugin_notifications_go_where_they_were_approved。
"""

from __future__ import annotations

import textwrap

import pytest
from tests.api.test_plugin_packages import (  # noqa: F401 -- data_dir 是夹具
    approve,
    data_dir,
    installed,
    package,
    start,
    upload,
    wait_for,
)

from movieclaw_api.services import plugin_events

PLUGIN = """
from pydantic import BaseModel, ConfigDict
from fastapi import APIRouter

from movieclaw_api.plugins.keys import PLUGIN_ROUTES
from movieclaw_sdk import plugin
from movieclaw_sdk.events import PLUGIN_EVENTS, plugin_event


class QuotaExceeded(BaseModel):
    model_config = ConfigDict(frozen=True)
    site: str
    remaining_gb: float
    member_id: int = 0


EXCEEDED = plugin_event("acme-pkg.quota.exceeded", QuotaExceeded, title="站点配额超限")


@plugin("acme-pkg", title="配额提醒", inject=(PLUGIN_EVENTS, PLUGIN_ROUTES))
async def apply(ctx) -> None:
    events = await ctx.use(PLUGIN_EVENTS).register(ctx, EXCEEDED)
    router = APIRouter()

    @router.post("/fire", operation_id="plugins.acme-pkg.fire")
    async def fire() -> dict:
        await events.publish(EXCEEDED, QuotaExceeded(site="mteam", remaining_gb=2.5, member_id=1))
        return {"ok": True}

    ctx.use(PLUGIN_ROUTES).mount(ctx, router, zone="admin")
"""

MANIFEST = """
[plugin]
id = "acme-pkg"
title = "配额提醒"
version = "{version}.0.0"
entry = "acme_pkg"
runtime = "process"
sdk = "^1.0"

[permissions]
operations = []
{permissions}

[[events]]
name = "acme-pkg.quota.exceeded"
title = "站点配额超限"

[[notifications]]
event = "acme-pkg.quota.exceeded"
title = "{{site}} 配额只剩 {{remaining_gb}} GB"
audience = "{audience}"
"""


def events_package(*, audience: str = "member:member_id", permissions: str = "") -> bytes:
    return package(
        manifest=MANIFEST.format(version=1, audience=audience, permissions=permissions),
        source=textwrap.dedent(PLUGIN),
    )


# ---------------------------------------------------------------------- 声明校验
@pytest.mark.parametrize(
    ("events", "notifications", "message"),
    [
        ([{"name": "other.x", "title": "x"}], [], "须以插件 id 开头"),
        ([{"name": "acme.x", "title": "x"}, {"name": "acme.x"}], [], "重复声明"),
        ([], [{"event": "acme.x", "title": "t"}], "没在 events 里声明"),
        (
            [{"name": "acme.x", "title": "x"}],
            [{"event": "acme.x", "title": "t", "audience": "everyone"}],
            "收件人",
        ),
        (
            [{"name": "acme.x", "title": "x"}],
            [{"event": "acme.x", "title": "t", "level": "time-sensitive"}],
            "打扰级别",
        ),
        (
            [{"name": "acme.x", "title": "x"}],
            [{"event": "acme.x", "title": "t", "image": "x.png"}],
            "不认识的字段",
        ),
    ],
)
def test_declarations_are_checked(events, notifications, message) -> None:
    with pytest.raises(plugin_events.DeclarationError, match=message):
        plugin_events.parse("acme", "示例", events=events, notifications=notifications)


def test_sensitive_permissions_must_name_sensitive_events() -> None:
    _, _, sensitive = plugin_events.parse("acme", "示例", sensitive=["playback.*"])
    assert sensitive == ("playback.*",)
    with pytest.raises(plugin_events.DeclarationError, match="不是需要单独授权"):
        plugin_events.parse("acme", "示例", sensitive=["subscription.fulfilled"])


def test_templates_only_fill_fields() -> None:
    from movieclaw_sdk.events import MediaRef, SubscriptionIdentitySkipped

    payload = SubscriptionIdentitySkipped(
        subscription_id=3, media=MediaRef(id=1, kind="movie", title="奥德赛")
    )
    filled = plugin_events.fill("《{media.title}》#{subscription_id}{missing}", payload)
    assert filled == "《奥德赛》#3"
    assert plugin_events.fill("剩 {gb} GB", {"gb": 2.0}) == "剩 2 GB"


def test_remote_payload_follows_the_declared_schema() -> None:
    event = plugin_events.remote_event(
        {
            "name": "acme.x",
            "title": "x",
            "schema": {
                "type": "object",
                "properties": {"site": {"type": "string"}},
                "required": ["site"],
            },
        }
    )
    assert plugin_events.remote_payload(event, {"site": "mteam"}).site == "mteam"
    with pytest.raises(ValueError, match="不合 Schema"):
        plugin_events.remote_payload(event, {"site": 3})


# ---------------------------------------------------------------------- 插件包全链路
def test_package_events_and_notifications_from_install_to_uninstall(data_dir) -> None:  # noqa: F811
    app, client = start()
    with client:
        assert upload(client, events_package()).status_code == 200
        pending = client.get("/api/v1/app/plugins/packages").json()["data"]["pending"][0]
        # 批准页如实告诉用户：会发什么事件、通知谁、通知什么
        assert pending["events"] == [{"name": "acme-pkg.quota.exceeded", "title": "站点配额超限"}]
        [notice] = pending["notifications"]
        assert notice["audience_label"] == "事件里的那个成员" and notice["reaches_members"]
        assert pending["notifies_members"] is True
        # 会通知到普通成员：不单独确认不给装
        refused = approve(client, "1.0.0", operations=())
        assert refused.status_code == 400 and "普通成员" in refused.text
        assert approve(client, "1.0.0", operations=(), allow_member_notifications=True).json()[
            "data"
        ]["status"] == "active"
        wait_for(lambda: "acme-pkg.quota.exceeded" in plugin_events.catalog())

        # 进系统事件目录：Webhook 能勾、通知开关出现在「账号 → 通知」的插件分组里
        catalog = client.get("/api/v1/webhook").json()["data"]["catalog"]
        assert "acme-pkg.quota.exceeded" in {c["event"] for c in catalog}
        prefs = client.get("/api/v1/push/me").json()["data"]["events"]
        [mine] = [e for e in prefs if e["key"] == "acme-pkg.quota.exceeded"]
        assert mine["title"] == "站点配额超限" and mine["group"] == "插件 · 配额提醒"
        # 插件详情页说清它会发什么事件、会给谁发通知
        detail = client.get("/api/v1/app/plugins/acme-pkg")
        assert detail.status_code == 200, detail.text
        adds = {(a["kind"], a["title"], a["detail"]) for a in detail.json()["data"]["adds"]}
        assert ("event", "会发出「站点配额超限」", "别的插件、Webhook 能订") in adds
        assert ("notification", "会发通知：站点配额超限", "发给事件里的那个成员") in adds

        # 插件发出：宿主订阅方收到同一份载荷（按声明的 Schema 校验过）
        heard: list = []
        from movieclaw_kernel import Entry, plugin

        @plugin("test.listener", title="听插件事件")
        async def listener(ctx) -> None:
            ctx.on(plugin_events.catalog()["acme-pkg.quota.exceeded"], heard.append, id="x")

        client.portal.call(app.state.kernel.mount, Entry("test.listener", listener))
        assert client.post("/api/v1/plugins/acme-pkg/fire").status_code == 200
        wait_for(lambda: heard)
        assert (heard[0].site, heard[0].remaining_gb) == ("mteam", 2.5)

        # 卸载：目录、通知开关一并撤下
        client.portal.call(app.state.kernel.unmount, "test.listener")
        assert client.delete("/api/v1/app/plugins/packages/acme-pkg").status_code == 200
        assert "acme-pkg.quota.exceeded" not in plugin_events.catalog()
        prefs = client.get("/api/v1/push/me").json()["data"]["events"]
        assert "acme-pkg.quota.exceeded" not in {e["key"] for e in prefs}


SENSITIVE = """
from movieclaw_sdk import plugin
from movieclaw_sdk.events import PLAYBACK_STARTED


@plugin("acme-pkg", title="观看记录")
async def apply(ctx) -> None:
    ctx.on(PLAYBACK_STARTED, lambda event: None, id="play")
"""

SENSITIVE_MANIFEST = """
[plugin]
id = "acme-pkg"
title = "观看记录"
version = "{version}.0.0"
entry = "acme_pkg"
runtime = "process"
sdk = "^1.0"

[requires]
"playback.started" = "^2.0"

[permissions]
operations = []
{permissions}
"""


def test_sensitive_events_need_a_declaration(data_dir) -> None:  # noqa: F811
    _, client = start()
    with client:
        data = package(
            manifest=SENSITIVE_MANIFEST.format(version=1, permissions=""),
            source=textwrap.dedent(SENSITIVE),
        )
        assert upload(client, data).status_code == 200
        result = approve(client, "1.0.0", operations=()).json()["data"]
        # 没声明就订「谁在什么时候看了什么」：起不来，说清楚为什么
        assert result["status"] == "rolled_back"
        assert "playback.started" in result["error"] and "[permissions] events" in result["error"]

        data = package(
            manifest=SENSITIVE_MANIFEST.format(
                version=2, permissions='events = ["playback.*"]'
            ),
            source=textwrap.dedent(SENSITIVE),
        )
        assert upload(client, data).status_code == 200
        pending = client.get("/api/v1/app/plugins/packages").json()["data"]["pending"][0]
        assert pending["sensitive_events"] == ["playback.*"]
        assert approve(client, "2.0.0", operations=()).json()["data"]["status"] == "active"
        assert installed(client)["acme-pkg"]["state"] == "active"
