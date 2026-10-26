"""Self-hosted relay management with real HTTP, encrypted test push and language changes."""

import json
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
import pytest
from tests.api.test_cloud_push import FakeRelay

from movieclaw_api.services.push import crypto

from . import test_i18n_ai_settings_browser as ai
from . import test_i18n_plugin_market_browser as market
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
market_http = market.market_http
stack = market.stack


@pytest.fixture(scope="module")
def relay_http():
    relays = {
        "static": FakeRelay(topics=["io.fixture.app"], mode="static", token="mcpush_ab12_secret"),
        "none": FakeRelay(topics=["io.fixture.app"], mode="none"),
        "issuer": FakeRelay(topics=["io.fixture.app"], mode="issuer"),
        "v2": FakeRelay(topics=["io.fixture.app"], mode="none"),
    }
    unavailable = set()

    class Handler(BaseHTTPRequestHandler):
        def reply(self):
            mode, _, suffix = self.path.lstrip("/").partition("/")
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if mode in unavailable:
                response = httpx.Response(503, json={"message": "Fixture upstream failure"})
            elif mode == "bad":
                response = httpx.Response(200, json={"unexpected": True})
            else:
                request = httpx.Request(
                    self.command,
                    "http://fixture/" + suffix,
                    headers=dict(self.headers),
                    content=raw,
                )
                response = relays[mode].handle(request)
                if mode == "v2":
                    document = response.json()
                    document["protocol"] = 9
                    response = httpx.Response(200, json=document)
                elif response.json().get("quota"):
                    document = response.json()
                    document["quota"]["day"]["reset_at"] = int(time.time()) + 3600
                    response = httpx.Response(response.status_code, json=document)
            encoded = response.content
            self.send_response(response.status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        do_GET = reply
        do_POST = reply

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", relays, unavailable
    finally:
        server.shutdown()
        server.server_close()
        thread.join(5)


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_relay_probe_install_edit_and_delete(stack, browser, relay_http, theme_id, width, request):  # noqa: F811
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
    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    device = browser.new_context(locale="en-US", extra_http_headers={"Accept-Language": "en"})
    login = device.request.post(
        base + "/api/v1/auth/device/login",
        data={
            **theme.ADMIN,
            "client": {
                "kind": "ios",
                "installation_id": f"relay-i18n-{theme_id}-{width}",
                "name": "Fixture iPhone",
            },
        },
    )
    assert login.ok, login.text()
    token = login.json()["data"]["token"]
    headers = {"Authorization": "Bearer " + token, "Cookie": ""}
    key = b"x" * 32
    registered = device.request.put(
        base + "/api/v1/push/me/registration",
        headers=headers,
        data={
            "token": "dd" * 32,
            "topic": "io.fixture.app",
            "environment": "production",
            "types": ["alert"],
            "key_id": "fixture-key",
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
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/app-push")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    shots = REPO / ".tmp-uidev/i18n/app-push"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name):
        expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        if page.get_by_role("dialog").count():
            assert not re.search(r"[\u3400-\u9fff]", page.get_by_role("dialog").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        for button in page.locator('main button:visible,[role="dialog"] button:visible').all():
            box = button.bounding_box()
            assert box["x"] >= -1 and box["x"] + box["width"] <= width + 1
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
            return database.execute(
                "SELECT value_json FROM app_setting WHERE namespace='push.channels'"
            ).fetchone()[0]

    def add_dialog():
        page.get_by_role("button", name="Add your own relay", exact=True).last.click()
        return page.get_by_role("dialog")

    def probe(dialog, mode):
        dialog.get_by_label("Relay address", exact=True).fill(upstream + "/" + mode)
        dialog.get_by_role("button", name="Check", exact=True).click()
        expect(dialog.get_by_role("button", name="Checking…", exact=True)).not_to_be_visible()

    def menu(name, action):
        page.get_by_role("button", name="More actions for " + name, exact=True).click()
        page.get_by_role("menuitem", name=action, exact=True).click()

    expect(
        page.get_by_text(re.compile(r"^1 device uses an app you built yourself"))
    ).to_be_visible()
    shot("uncovered")
    dialog = add_dialog()
    for mode, reason in [
        ("bad", "This is not a MovieClaw push relay"),
        ("v2", "Relay protocol is version 9"),
        ("issuer", "This relay requires an issuer token"),
    ]:
        probe(dialog, mode)
        expect(dialog.get_by_text(re.compile("^" + re.escape(reason)))).to_be_visible()
        expect(dialog.get_by_role("button", name="Save", exact=True)).to_be_disabled()
    shot("blocked-probe")
    probe(dialog, "static")
    expect(dialog.get_by_label("Token", exact=True)).to_be_visible()
    expect(dialog.get_by_role("button", name="Save", exact=True)).to_be_disabled()
    dialog.get_by_label("Relay address", exact=True).fill(upstream + "/none")
    expect(dialog.get_by_text("The address changed. Check it again.", exact=True)).to_be_visible()
    expect(dialog.get_by_role("button", name="Save", exact=True)).to_be_disabled()
    probe(dialog, "static")
    dialog.get_by_label("Token", exact=True).fill("bad-token")
    dialog.get_by_label("Name", exact=True).fill("Fixture relay")
    with page.expect_response(
        lambda r: r.request.method == "POST" and r.url.endswith("/push/relays")
    ) as rejected:
        dialog.get_by_role("button", name="Save", exact=True).click()
    assert rejected.value.status == 400
    assert len(api("get", "/push/channels")["channels"]) == 1
    shot("bad-token")
    dialog.get_by_label("Token", exact=True).fill("mcpush_ab12_secret")
    with page.expect_response(
        lambda r: r.request.method == "POST" and r.url.endswith("/push/relays")
    ) as saved:
        dialog.get_by_role("button", name="Save", exact=True).click()
    assert saved.value.ok
    expect(dialog).not_to_be_visible()
    assert "mcpush_ab12_secret" not in stored()
    result = api("post", "/push/me/test")
    assert result["sent"] == 1
    assert relays["static"].bearers[-1] == "mcpush_ab12_secret"
    payload = json.loads(crypto.open_sealed(relays["static"].messages[-1]["payload"], key=key))
    assert payload["title"] == "Test notification"
    page.reload()
    expect(page.get_by_text("Used 1 / 5,000 notifications today", exact=True)).to_be_visible()
    shot("installed")
    before = stored()
    menu("Fixture relay", "Edit")
    page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
    assert stored() == before
    menu("Fixture relay", "Edit")
    dialog = page.get_by_role("dialog")
    dialog.get_by_label("Name", exact=True).fill("Renamed fixture")
    expect(dialog.get_by_text("Leave blank to keep the current token", exact=True)).to_be_visible()
    with page.expect_response(
        lambda r: r.request.method == "PATCH" and "/push/relays/" in r.url
    ) as edited:
        dialog.get_by_role("button", name="Save", exact=True).click()
    assert edited.value.ok
    expect(dialog).not_to_be_visible()
    toggle = page.get_by_role("switch", name="Enable Renamed fixture", exact=True)
    toggle.click()
    expect(toggle).to_have_attribute("aria-checked", "false")
    expect(
        page.get_by_text(re.compile(r"^1 device uses an app you built yourself"))
    ).to_be_visible()
    shot("disabled")
    toggle.click()
    expect(toggle).to_have_attribute("aria-checked", "true")
    unavailable.add("static")
    menu("Renamed fixture", "Check again")
    expect(page.get_by_text("Relay returned Fixture upstream failure", exact=True)).to_be_visible()
    shot("refresh-error")
    unavailable.clear()
    menu("Renamed fixture", "Check again")
    expect(page.get_by_text("Working", exact=True)).to_be_visible()
    if width == 1280:
        before = stored()
        page.evaluate("window.__relayI18nDocument='kept'")
        for language in ("zh-Hans", "en"):
            english = page.locator("html").get_attribute("lang") == "en"
            page.get_by_role(
                "button", name="Appearance and language" if english else "外观与语言", exact=True
            ).click()
            control = page.get_by_test_id("language-settings")
            control.locator(f'input[value="{language}"]').check()
            expect(page.locator("html")).to_have_attribute("lang", language)
            expect(control).to_be_enabled()
            page.get_by_role(
                "button", name="App push" if language == "en" else "App 推送", exact=True
            ).click()
            expect(page.get_by_text("Renamed fixture", exact=True)).to_be_visible()
            assert stored() == before
            assert page.evaluate("window.__relayI18nDocument") == "kept"
        shot("roundtrip")
    dialog = add_dialog()
    probe(dialog, "none")
    expect(dialog.get_by_label("Token", exact=True)).to_have_count(0)
    dialog.get_by_label("Name", exact=True).fill("No token fixture")
    dialog.get_by_role("button", name="Save", exact=True).click()
    expect(dialog).not_to_be_visible()
    expect(page.get_by_text("No token fixture", exact=True)).to_be_visible()
    before = stored()
    menu("Renamed fixture", "Delete")
    page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
    assert stored() == before
    for name in ("Renamed fixture", "No token fixture"):
        menu(name, "Delete")
        dialog = page.get_by_role("dialog")
        if name == "Renamed fixture":
            shot("delete-confirm")
        dialog.get_by_role("button", name="Delete", exact=True).click()
        expect(dialog).not_to_be_visible()
        expect(page.get_by_text(name, exact=True)).not_to_be_visible()
    assert len(api("get", "/push/channels")["channels"]) == 1
    assert not errors
