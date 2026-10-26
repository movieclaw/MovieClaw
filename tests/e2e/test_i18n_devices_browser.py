"""Real device pairing, credentials, rename, cleanup previews and one-time manual tokens."""

import hashlib
import re
from datetime import timedelta

import pytest

from . import test_smart_subscription_browser as smart
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_subscription_cancel_browser import _run

stack = smart.smart_stack
browser = theme.browser
pytestmark = pytest.mark.integration
FAMILY = {"username": "family", "password": "family-pass-1"}


async def _seed(database_url):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import LoginDevice, utcnow

    database = Database(database_url)
    try:
        async with database.session() as session:
            now = utcnow()
            for index in range(25):
                session.add(
                    LoginDevice(
                        kind="web",
                        name=f"RawBrowser-{index:02}",
                        token_hash=hashlib.sha256(f"fixture-browser-{index}".encode()).hexdigest(),
                        member_id=0,
                        platform="Raw OS · arm64",
                        created_at=now - timedelta(days=20),
                        last_seen_at=now - timedelta(seconds=index + 10)
                        if index < 6
                        else now - timedelta(days=15),
                    )
                )
            for name, kind, owner, age in (
                ("旧机器原名", "cli", 0, 100),
                ("RawOldPhone", "ios", 0, 100),
                ("RawMemberPhone", "ios", 1, 100),
                ("RawRecentWorker", "worker", 0, 0),
            ):
                session.add(
                    LoginDevice(
                        kind=kind,
                        name=name,
                        member_id=owner,
                        scope="transcode" if kind == "worker" else "full",
                        token_hash=hashlib.sha256(f"fixture-{kind}-{owner}".encode()).hexdigest(),
                        platform="Raw OS",
                        client_version="1.2.3",
                        created_at=now - timedelta(days=age),
                        last_seen_at=now - timedelta(days=age),
                    )
                )
            await session.commit()
    finally:
        await database.dispose()


def test_device_list_cleanup_tokens_and_pairing(stack, browser):
    from playwright.sync_api import expect

    base, _, root = stack
    context = browser.new_context(
        locale="en-US",
        viewport={"width": 1280, "height": 1000},
        permissions=["clipboard-read", "clipboard-write"],
    )
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    assert context.request.post(base + "/api/v1/members", data=FAMILY).ok
    _run(_seed(f"sqlite+aiosqlite:///{root / 'data.db'}"))
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/devices"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def english(scope):
        text = scope.inner_text().replace("旧机器原名", "").replace("自定义设备名", "")
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    def devices():
        return api("get", "/auth/devices")

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/devices")
        page.wait_for_function(
            "theme => (document.documentElement.dataset.theme || 'silver') === theme", arg=theme_id
        )
        expect(page.get_by_role("button", name="View all browsers", exact=True)).to_be_visible()
        english(page.locator("main"))
        _snapshot(page, shots / f"{theme_id}-{width}-summary-en.png")
        page.get_by_role("button", name="View all browsers", exact=True).click()
        drawer = page.get_by_role("dialog", name="All devices", exact=True)
        expect(drawer.get_by_text("RawBrowser-00", exact=True)).to_be_visible()
        panel = drawer.get_by_role("tabpanel")
        for _ in range(4):
            panel.evaluate("element => element.scrollTop = element.scrollHeight")
            if drawer.get_by_text("All records shown", exact=True).is_visible():
                break
            page.wait_for_timeout(200)
        expect(drawer.get_by_text("RawBrowser-24", exact=True)).to_be_visible()
        english(drawer)
        _snapshot(page, shots / f"{theme_id}-{width}-drawer-en.png")
        drawer.get_by_role("tab", name="CLI", exact=True).click()
        expect(drawer.get_by_text("旧机器原名", exact=True)).to_be_visible()
        english(drawer)
        drawer.get_by_role("button", name="Done", exact=True).click()
        page.get_by_role("button", name="Clean up…", exact=True).click()
        cleanup = page.get_by_role("dialog", name="Clean up unused devices", exact=True)
        expect(
            cleanup.get_by_role("radio", name="Unused for 30 days", exact=True)
        ).to_have_attribute("aria-checked", "true")
        expect(cleanup.get_by_text("旧机器原名", exact=True)).to_be_visible()
        expect(cleanup.get_by_text("RawMemberPhone", exact=True)).to_have_count(0)
        expect(cleanup.get_by_text("RawRecentWorker", exact=True)).to_have_count(0)
        assert len(devices()) == 29
        cleanup.get_by_role("radio", name="Unused for 7 days", exact=True).click()
        expect(cleanup.get_by_text("RawBrowser-24", exact=True)).to_be_visible()
        english(cleanup)
        _snapshot(page, shots / f"{theme_id}-{width}-cleanup-en.png")
        cleanup.get_by_role("button", name="Cancel", exact=True).click()
        assert len(devices()) == 29  # Preview and cancellation cannot revoke a credential.

        grant = api(
            "post",
            "/auth/device/authorize",
            data={"client_type": "tvos" if width == 320 else "cli", "client_name": "RawPairing"},
        )
        page.goto(base + "/activate?code=" + grant["user_code"])
        expect(page.get_by_role("button", name="Approve sign-in", exact=True)).to_be_visible()
        expect(page.get_by_text(grant["user_code"], exact=True)).to_be_visible()
        english(page.locator("main"))
        page.wait_for_function(
            "getComputedStyle(document.querySelector('.welcome-card-rise')).opacity === '1'"
        )
        _snapshot(page, shots / f"{theme_id}-{width}-pairing-en.png")
        page.get_by_role("button", name="Approve sign-in", exact=True).click()
        expect(page.get_by_role("heading", name="Approved", exact=True)).to_be_visible()
        assert "code=" not in page.url
        token = api("post", "/auth/device/token", data={"device_code": grant["device_code"]})
        with browser.new_context() as paired:
            who = paired.request.get(
                base + "/api/v1/auth/me", headers={"Authorization": "Bearer " + token["token"]}
            )
            assert who.ok and who.json()["data"]["username"] == theme.ADMIN["username"]
        row = next(row for row in devices() if row["name"] == "RawPairing")
        api("delete", "/auth/devices/" + row["id"])

    # Rename and revoke an actual seeded command-line credential through the drawer.
    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/settings/devices")
    page.wait_for_function("(document.documentElement.dataset.theme || 'silver') === 'silver'")
    page.get_by_role(
        "button", name="View all command-line clients and transcoders", exact=True
    ).click()
    drawer = page.get_by_role("dialog", name="All devices", exact=True)
    drawer.get_by_role("button", name="Manage “旧机器原名”", exact=True).click()
    page.get_by_role("menuitem", name="Rename…", exact=True).click()
    rename = page.get_by_role("dialog", name="Rename device", exact=True)
    rename.get_by_role("textbox").fill("自定义设备名")
    rename.get_by_role("button", name="Save", exact=True).click()
    expect(drawer.get_by_text("自定义设备名", exact=True)).to_be_visible()
    row = next(row for row in devices() if row["name"] == "自定义设备名")
    assert row["kind"] == "cli"
    drawer.get_by_role("button", name="Manage “自定义设备名”", exact=True).click()
    page.get_by_role("menuitem", name="Revoke…", exact=True).click()
    confirm = page.get_by_role("dialog", name="Revoke “自定义设备名”?", exact=True)
    expect(confirm.get_by_text("Run mclaw login again", exact=False)).to_be_visible()
    english(confirm)
    confirm.get_by_role("button", name="Cancel", exact=True).click()
    assert any(d["id"] == row["id"] for d in devices())
    drawer.get_by_role("button", name="Manage “自定义设备名”", exact=True).click()
    page.get_by_role("menuitem", name="Revoke…", exact=True).click()
    with page.expect_response(lambda r: r.request.method == "DELETE" and r.url.endswith(row["id"])):
        page.get_by_role("dialog", name="Revoke “自定义设备名”?", exact=True).get_by_role(
            "button", name="Revoke", exact=True
        ).click()
    with browser.new_context() as revoked:
        assert (
            revoked.request.get(
                base + "/api/v1/auth/me",
                headers={"Authorization": "Bearer fixture-cli-0"},
            ).status
            == 401
        )
    drawer.get_by_role("button", name="Done", exact=True).click()

    # All-members preview includes the member; cleanup keeps the current login.
    page.get_by_role("button", name="All members", exact=True).click()
    page.get_by_role("button", name="Clean up…", exact=True).click()
    cleanup = page.get_by_role("dialog", name="Clean up unused devices", exact=True)
    expect(cleanup.get_by_text("RawMemberPhone", exact=True)).to_be_visible()
    cleanup.get_by_role("button", name="Cancel", exact=True).click()
    page.get_by_role("button", name="My devices", exact=True).click()
    page.get_by_role("button", name="Clean up…", exact=True).click()
    cleanup = page.get_by_role("dialog", name="Clean up unused devices", exact=True)
    expect(cleanup.get_by_text("RawOldPhone", exact=True)).to_be_visible()
    cleanup.get_by_role("button", name="Revoke 1 device", exact=True).click()
    expect(cleanup).to_be_hidden()
    assert api("get", "/auth/me")["role"] == "admin"
    assert not any(d["name"] == "RawOldPhone" for d in devices())
    assert any(d["name"] == "RawMemberPhone" for d in api("get", "/auth/devices?all=true"))

    # Manual credentials: full/restricted access and a one-time close guard.
    for scope in ("full", "transcode"):
        page.set_viewport_size({"width": 320 if scope == "transcode" else 1280, "height": 1000})
        page.get_by_role("button", name="Create token", exact=True).click()
        page.get_by_label("Name", exact=True).fill("RawManual-" + scope)
        if scope == "transcode":
            page.locator("label").filter(
                has=page.locator('input[name="manual-token-scope"][value="transcode"]')
            ).click()
        with page.expect_response(
            lambda r: r.request.method == "POST" and r.url.endswith("/auth/tokens")
        ) as made:
            page.get_by_role("button", name="Create token", exact=True).click()
        data = made.value.json()["data"]
        assert data["scope"] == scope
        snippet = page.locator("pre").filter(has_text=data["token"])
        expect(snippet).to_be_visible()
        assert (
            "--nas-url" if scope == "transcode" else "MOVIECLAW_SERVER="
        ) in snippet.inner_text()
        page.get_by_role(
            "button", name="Copy line" if scope == "transcode" else "Copy both lines", exact=True
        ).click()
        expect(page.get_by_role("button", name="Copied", exact=True)).to_be_visible()
        assert page.evaluate("navigator.clipboard.readText()") == snippet.inner_text()
        page.get_by_role("button", name="Copy token only", exact=True).click()
        assert page.evaluate("navigator.clipboard.readText()") == data["token"]
        english(page.locator("main"))
        _snapshot(page, shots / f"manual-{scope}-en.png")
        page.get_by_role("button", name="Saved, close", exact=True).click()
        guard = page.get_by_role("dialog", name="Close this token?", exact=True)
        guard.get_by_role("button", name="Cancel", exact=True).click()
        expect(snippet).to_be_visible()
        page.get_by_role("button", name="Saved, close", exact=True).click()
        page.get_by_role("dialog", name="Close this token?", exact=True).get_by_role(
            "button", name="I have saved it", exact=True
        ).click()
        expect(snippet).to_have_count(0)
        with browser.new_context() as manual:
            response = manual.request.get(
                base + "/api/v1/libraries", headers={"Authorization": "Bearer " + data["token"]}
            )
            assert response.status == (403 if scope == "transcode" else 200)

    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/library")
    page.evaluate("window.deviceLanguageMarker = 821")
    _change_language(page, "zh-Hans")
    assert page.evaluate("window.deviceLanguageMarker") == 821
    page.goto(base + "/settings/devices")
    expect(page.get_by_role("button", name="查看全部浏览器设备", exact=True)).to_be_visible()
    assert "RawRecentWorker" in {d["name"] for d in devices()}
    _snapshot(page, shots / "silver-devices-zh.png")
    assert not errors, errors
    context.close()


def test_pairing_denial_member_permissions_and_transcoder_limit(stack, browser):
    from playwright.sync_api import expect

    base = stack[0]
    admin = browser.new_context(locale="en-US", viewport={"width": 320, "height": 1000})
    bootstrap = admin.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    assert bootstrap.status in (200, 409)
    assert admin.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    created = admin.request.post(base + "/api/v1/members", data=FAMILY)
    assert created.status in (200, 409)
    member = browser.new_context(locale="en-US", viewport={"width": 320, "height": 1000})
    assert member.request.post(base + "/api/v1/auth/login", data=FAMILY).ok
    prefs = member.request.get(base + "/api/v1/ui/preferences").json()["data"]
    prefs.update(language="en")
    assert member.request.put(base + "/api/v1/ui/preferences", data=prefs).ok
    page = member.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))

    def authorize(kind):
        response = admin.request.post(
            base + "/api/v1/auth/device/authorize",
            data={"client_type": kind, "client_name": "RawMemberPairing", "platform": "Raw OS"},
        )
        assert response.ok, response.text()
        return response.json()["data"]

    def redeem(grant):
        return admin.request.post(
            base + "/api/v1/auth/device/token", data={"device_code": grant["device_code"]}
        )

    page.goto(base + "/activate")
    page.get_by_role("textbox", name="Pairing code", exact=True).fill("x")
    page.get_by_role("button", name="Continue", exact=True).click()
    expect(page.get_by_text("Pairing codes look like MCLW-7F3K.", exact=False)).to_be_visible()
    worker = authorize("worker")
    page.goto(base + "/activate?code=" + worker["user_code"])
    expect(
        page.get_by_text("Only an administrator can approve a transcoder", exact=False)
    ).to_be_visible()
    expect(page.get_by_role("button", name="Approve sign-in", exact=True)).to_have_count(0)
    shots = theme.REPO / ".tmp-uidev/i18n/devices"
    shots.mkdir(parents=True, exist_ok=True)
    page.wait_for_function(
        "getComputedStyle(document.querySelector('.welcome-card-rise')).opacity === '1'"
    )
    _snapshot(page, shots / "member-worker-blocked-en.png")
    page.get_by_role("button", name="I did not request this. Deny", exact=True).click()
    expect(page.get_by_role("heading", name="Denied", exact=True)).to_be_visible()
    assert redeem(worker).status == 400
    cli = authorize("cli")
    page.goto(base + "/activate?code=" + cli["user_code"])
    expect(page.get_by_text("Access: The same permissions as you", exact=True)).to_be_visible()
    assert "deleting media files" not in page.locator("main").inner_text()
    page.get_by_role("button", name="Approve sign-in", exact=True).click()
    expect(page.get_by_role("heading", name="Approved", exact=True)).to_be_visible()
    response = redeem(cli)
    assert response.ok and response.json()["data"]["granted_by"] == "family"
    with browser.new_context() as paired:
        who = paired.request.get(
            base + "/api/v1/auth/me",
            headers={"Authorization": "Bearer " + response.json()["data"]["token"]},
        )
        assert who.ok and who.json()["data"]["role"] == "member"
    assert not errors, errors
    member.close()
    admin.close()
