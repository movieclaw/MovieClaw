"""Notification preferences, membership isolation and real encrypted test delivery in Chrome."""

import json
import re
import sqlite3
import time

import pytest

from movieclaw_api.services.push import crypto

from . import test_i18n_app_push_browser as push
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = push.browser
search_provider = push.search_provider
market_http = push.market_http
stack = push.stack
relay_http = push.relay_http


async def _seed_title(database_url, tmdb_id):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import MediaItem

    database = Database(database_url)
    try:
        async with database.session() as session:
            item = MediaItem(
                kind="movie",
                tmdb_id=tmdb_id,
                title="Fixture muted title",
                original_title="Fixture muted title",
                year=2024,
            )
            session.add(item)
            await session.commit()
            await session.refresh(item)
            return item.id
    finally:
        await database.dispose()


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_notifications_preferences_and_delivery(
    stack, browser, relay_http, theme_id, width, request
):  # noqa: F811
    from playwright.sync_api import expect

    upstream, relays, unavailable = relay_http
    unavailable.clear()
    relays["static"].messages.clear()
    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    reply = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not reply.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    for channel in api("get", "/push/channels")["channels"]:
        if channel["kind"] == "custom":
            api("delete", "/push/relays/" + channel["id"])
    for library in api("get", "/libraries"):
        assert context.request.delete(base + f"/api/v1/libraries/{library['id']}").ok
    root = stack["data"] / f"notifications-{theme_id}-{width}"
    root.mkdir(exist_ok=True)
    sentinel = root / "original.txt"
    sentinel.write_bytes(b"Keep original media content unchanged during notification preferences")
    libraries = []
    for label in ("movies", "shows"):
        folder = root / label
        folder.mkdir(exist_ok=True)
        libraries.append(
            api(
                "post",
                "/libraries",
                data={
                    "name": "Fixture " + label,
                    "kind": "video",
                    "root_paths": [str(folder)],
                    "realtime_watch": False,
                },
            )
        )
    item_id = _run(
        _seed_title(stack["database_url"], 990000 + width + (10000 if theme_id == "netflix" else 0))
    )
    api("put", f"/push/me/muted-items/{item_id}")
    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/notifications")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    shots = REPO / ".tmp-uidev/i18n/notifications"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name, receipt=False):
        if not receipt:
            expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
        else:
            for toast in page.locator(".toast-item").all():
                expect(toast).to_have_css("opacity", "1")
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
            return database.execute(
                "SELECT events,library_ids,muted_item_ids,updated_at "
                "FROM push_preference WHERE member_id=0"
            ).fetchone()

    expect(
        page.get_by_text("Phone notifications are not enabled on this server", exact=True)
    ).to_be_visible()
    expect(page.get_by_role("button", name="Send", exact=True)).to_be_disabled()
    shot("not-ready")
    before = stored()
    credentials = {"username": f"nf-{theme_id}-{width}", "password": "fixture-passw0rd"}
    member = api("post", "/members", data={**credentials, "nickname": "Fixture member"})
    member_context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    assert member_context.request.post(base + "/api/v1/auth/login", data=credentials).ok
    member_preferences = member_context.request.get(base + "/api/v1/ui/preferences").json()["data"]
    member_preferences.update(
        theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en"
    )
    assert member_context.request.put(base + "/api/v1/ui/preferences", data=member_preferences).ok
    member_page = member_context.new_page()
    member_page.goto(base + "/settings/notifications")
    if theme_id == "netflix":
        expect(member_page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(
        member_page.get_by_text(
            "The administrator has not enabled phone notifications yet. "
            "These settings will apply as soon as notifications are enabled.",
            exact=True,
        )
    ).to_be_visible()
    expect(member_page.get_by_role("link", name="Enable notifications", exact=True)).to_have_count(
        0
    )
    member_view = member_context.request.get(base + "/api/v1/push/me").json()["data"]
    assert len(member_view["events"]) < len(api("get", "/push/me")["events"])
    first = member_view["events"][0]
    with member_page.expect_response(
        lambda r: r.request.method == "PUT" and r.url.endswith("/push/me/preferences")
    ) as changed:
        member_page.get_by_role(
            "switch", name=first["title"] + " notifications", exact=True
        ).click()
    assert changed.value.ok
    assert stored() == before
    assert not re.search(r"[\u3400-\u9fff]", member_page.locator("main").inner_text())
    _snapshot(member_page, shots / f"{theme_id}-{width}-member.png")
    member_context.close()
    assert context.request.delete(base + f"/api/v1/members/{member['id']}").ok
    view = api("get", "/push/me")
    arrivals = next(event for event in view["events"] if event["key"] == "library.items.arrived")
    control = page.get_by_role("switch", name=arrivals["title"] + " notifications", exact=True)
    if not arrivals["enabled"]:
        with page.expect_response(
            lambda r: r.request.method == "PUT" and r.url.endswith("/push/me/preferences")
        ) as saved:
            control.click()
        assert saved.value.ok
        expect(control).to_have_attribute("aria-checked", "true")
    with page.expect_response(
        lambda r: r.request.method == "PUT" and r.url.endswith("/push/me/preferences")
    ) as saved:
        page.get_by_label("Fixture movies", exact=True).uncheck()
    assert saved.value.ok
    expect(page.get_by_label("Fixture movies", exact=True)).not_to_be_checked()
    assert api("get", "/push/me")["library_ids"] == [libraries[1]["id"]]
    with page.expect_response(
        lambda r: r.request.method == "PUT" and r.url.endswith("/push/me/preferences")
    ) as saved:
        page.get_by_label("Fixture shows", exact=True).click()
    assert saved.value.ok
    expect(control).to_have_attribute("aria-checked", "false")
    assert api("get", "/push/me")["library_ids"] is None
    with page.expect_response(
        lambda r: r.request.method == "PUT" and r.url.endswith("/push/me/preferences")
    ) as saved:
        control.click()
    assert saved.value.ok
    expect(control).to_have_attribute("aria-checked", "true")
    expect(page.get_by_label("Fixture movies", exact=True)).to_be_checked()
    expect(page.get_by_label("Fixture shows", exact=True)).to_be_checked()
    future = root / "future"
    future.mkdir(exist_ok=True)
    api(
        "post",
        "/libraries",
        data={
            "name": "Fixture future",
            "kind": "video",
            "root_paths": [str(future)],
            "realtime_watch": False,
        },
    )
    page.reload()
    expect(page.get_by_label("Fixture future", exact=True)).to_be_checked()
    expect(page.get_by_text("Fixture muted title", exact=False)).to_be_visible()
    with page.expect_response(
        lambda r: r.request.method == "DELETE" and r.url.endswith(f"/muted-items/{item_id}")
    ) as restored:
        page.get_by_role("button", name="Restore", exact=True).click()
    assert restored.value.ok
    expect(page.get_by_text("Fixture muted title", exact=False)).not_to_be_visible()
    assert api("get", "/push/me")["muted_items"] == []
    shot("preferences")
    api(
        "post",
        "/push/relays",
        data={"url": upstream + "/static", "name": "Fixture relay", "token": "mcpush_ab12_secret"},
    )
    device = browser.new_context(locale="en-US", extra_http_headers={"Accept-Language": "en"})
    login = device.request.post(
        base + "/api/v1/auth/device/login",
        data={
            **theme.ADMIN,
            "client": {
                "kind": "ios",
                "installation_id": f"nf-device-{theme_id}-{width}",
                "name": "Fixture iPhone",
            },
        },
    )
    assert login.ok, login.text()
    headers = {"Authorization": "Bearer " + login.json()["data"]["token"], "Cookie": ""}
    key = b"n" * 32
    registered = device.request.put(
        base + "/api/v1/push/me/registration",
        headers=headers,
        data={
            "token": "ee" * 32,
            "topic": "io.fixture.app",
            "environment": "production",
            "types": ["alert"],
            "key_id": crypto.b64url(b"notify01"),
            "key": crypto.b64url(key),
            "permission": "authorized",
        },
    )
    assert registered.ok, registered.text()

    def cleanup():
        assert device.request.delete(base + "/api/v1/push/me/registration", headers=headers).ok
        device.close()
        context.close()

    request.addfinalizer(cleanup)
    page.reload()
    expect(page.get_by_text("Send to 1 device", exact=True)).to_be_visible()
    page.wait_for_timeout(10100)
    with page.expect_response(
        lambda r: r.request.method == "POST" and r.url.endswith("/push/me/test")
    ) as tested:
        page.get_by_role("button", name="Send", exact=True).click()
    assert tested.value.ok
    result = tested.value.json()["data"]
    assert result["sent"] == 1
    assert result["results"][0]["message"] == "Delivered to Apple Push Notification service"
    receipt = page.locator(".toast-item").filter(
        has_text="Test notification sent to 1 device. Check your phone"
    )
    expect(receipt).to_be_visible()
    assert (
        json.loads(crypto.open_sealed(relays["static"].messages[-1]["payload"], key=key))["title"]
        == "Test notification"
    )
    shot("delivered", receipt=True)
    if width == 1280:
        before = stored()
        ids = [(event["key"], event["group_id"]) for event in api("get", "/push/me")["events"]]
        page.evaluate("window.__notificationI18nDocument='kept'")
        for language in ("zh-Hans", "en"):
            english = page.locator("html").get_attribute("lang") == "en"
            page.get_by_role(
                "button", name="Appearance and language" if english else "外观与语言", exact=True
            ).click()
            language_control = page.get_by_test_id("language-settings")
            language_control.locator(f'input[value="{language}"]').check()
            expect(page.locator("html")).to_have_attribute("lang", language)
            expect(language_control).to_be_enabled()
            label = "Notifications" if language == "en" else "通知"
            page.get_by_role("button", name=label, exact=True).filter(has_text=label).click()
            expect(
                page.get_by_role("heading", name="Test" if language == "en" else "测试", exact=True)
            ).to_be_visible()
            assert [
                (event["key"], event["group_id"]) for event in api("get", "/push/me")["events"]
            ] == ids
            assert stored() == before
            assert page.evaluate("window.__notificationI18nDocument") == "kept"
        shot("roundtrip")
    if theme_id == "silver" and width == 1280:
        page.wait_for_timeout(10100)
        unavailable.add("static")
        with page.expect_response(
            lambda r: r.request.method == "POST" and r.url.endswith("/push/me/test")
        ) as queued:
            page.get_by_role("button", name="Send", exact=True).click()
        assert queued.value.ok
        assert (
            queued.value.json()["data"]["results"][0]["message"]
            == "Channel is temporarily unavailable. It will retry automatically"
        )
        expect(
            page.locator(".toast-item").filter(has_text="Channel is temporarily unavailable")
        ).to_be_visible()
        shot("queued", receipt=True)
        unavailable.clear()
        previous = len(relays["static"].messages)
        deadline = time.monotonic() + 45
        while len(relays["static"].messages) == previous and time.monotonic() < deadline:
            time.sleep(0.25)
        assert len(relays["static"].messages) > previous
        while (
            api("get", "/push/channels")["channels"][1]["last_error"] is not None
            and time.monotonic() < deadline
        ):
            time.sleep(0.1)
        assert api("get", "/push/channels")["channels"][1]["last_error"] is None
        assert (
            json.loads(crypto.open_sealed(relays["static"].messages[-1]["payload"], key=key))[
                "title"
            ]
            == "Test notification"
        )
    assert (
        sentinel.read_bytes()
        == b"Keep original media content unchanged during notification preferences"
    )
    assert not errors
