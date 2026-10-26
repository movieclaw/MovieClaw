"""Real local HTTP deliveries, HMAC rotation, settings persistence and reader language."""

import hashlib
import hmac
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from . import test_i18n_storage_browser as storage
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot

stack = storage.stack
browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture
def receiver():
    class Handler(BaseHTTPRequestHandler):
        received = []
        status = 204

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            self.received.append((body, dict(self.headers)))
            self.send_response(self.status)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/events", Handler
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


def test_webhook_editor_deliveries_rotation_and_language(stack, browser, receiver):
    from playwright.sync_api import expect

    target, handler = receiver
    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    context.grant_permissions(["clipboard-read", "clipboard-write"])
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/webhook"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def english():
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    def menu(label):
        page.get_by_role("button", name="More actions for Automation raw endpoint").click()
        page.get_by_role("menuitem", name=label, exact=True).click()

    def secret():
        code = page.get_by_role("status").filter(has_text="Signing secret for").locator("code")
        expect(code).to_have_count(1)
        value = code.inner_text()
        assert value.startswith("mcwh_") and "*" not in value
        page.get_by_role("button", name="Copy", exact=True).click()
        assert page.evaluate("navigator.clipboard.readText()") == value
        page.get_by_role("button", name="Saved, close", exact=True).click()
        expect(code).to_have_count(0)
        return value

    def send_and_verify(key, status=204):
        handler.status = status
        before = len(handler.received)
        menu("Send test")
        expect(page.locator(".toast-item").last).to_contain_text(
            "Test event delivered" if status == 204 else f"Destination returned HTTP {status}"
        )
        assert len(handler.received) == before + 1
        body, headers = handler.received[-1]
        assert (
            headers["X-MovieClaw-Signature"]
            == "sha256=" + hmac.new(key.encode(), body, hashlib.sha256).hexdigest()
        )
        assert json.loads(body)["type"] == "webhook.test"

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        api("put", "/webhook", data={"enabled": False, "endpoints": []})
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/webhook")
        expect(page.get_by_text("No endpoints yet", exact=True)).to_be_visible()
        page.get_by_role("switch", name="Enable event delivery", exact=True).click()
        expect(page.get_by_role("switch", name="Enable event delivery", exact=True)).to_be_checked()
        page.get_by_role("button", name="Add endpoint", exact=True).click()
        page.get_by_role("button", name="Save", exact=True).click()
        expect(page.get_by_text("Enter a destination URL", exact=True)).to_be_visible()
        page.get_by_label("Display name", exact=True).fill("Automation raw endpoint")
        page.get_by_label("Destination URL", exact=True).fill(target)
        expect(
            page.get_by_role("checkbox", name="Playback started playback.started", exact=True)
        ).to_be_checked()
        english()
        _snapshot(page, shots / f"{theme_id}-{width}-editor-en.png")
        page.get_by_role("button", name="Save", exact=True).click()
        key = secret()
        endpoint = api("get", "/webhook")["endpoints"][0]
        assert endpoint["secret"] is None and endpoint["secret_masked"].endswith("****")
        assert endpoint["url"] == target and endpoint["name"] == "Automation raw endpoint"
        enabled = page.get_by_role("switch", name="Enable Automation raw endpoint", exact=True)
        enabled.click()
        expect(enabled).not_to_be_checked()
        assert not api("get", "/webhook")["endpoints"][0]["enabled"]
        enabled.click()
        expect(enabled).to_be_checked()
        assert api("get", "/webhook")["endpoints"][0]["enabled"]
        menu("Deliveries")
        expect(
            page.get_by_text(
                "No deliveries yet. Records are cleared when the server restarts.", exact=True
            )
        ).to_be_visible()
        menu("Hide deliveries")
        send_and_verify(key)
        send_and_verify(key, 503)
        menu("Deliveries")
        failure = page.locator("main").get_by_text("Destination returned HTTP 503", exact=True)
        expect(failure).to_be_visible()
        assert failure.evaluate(
            "node => node.scrollWidth <= node.clientWidth "
            "&& getComputedStyle(node).textOverflow !== 'ellipsis'"
        )
        english()

        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(n => n.click())")
        _snapshot(page, shots / f"{theme_id}-{width}-deliveries-en.png")
        page.get_by_role("button", name="Edit", exact=True).click()
        page.get_by_role("button", name="Rotate secret", exact=True).click()
        dialog = page.get_by_role("dialog")
        expect(dialog).to_contain_text("Rotate signing secret?")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        assert api("get", "/webhook")["endpoints"][0]["secret_masked"] == endpoint["secret_masked"]
        page.get_by_role("button", name="Rotate secret", exact=True).click()
        page.get_by_role("dialog").get_by_role("button", name="Rotate", exact=True).click()
        rotated = secret()
        assert rotated != key
        page.get_by_role("button", name="Cancel", exact=True).click()
        send_and_verify(rotated)
        body, headers = handler.received[-1]
        assert (
            headers["X-MovieClaw-Signature"]
            != "sha256=" + hmac.new(key.encode(), body, hashlib.sha256).hexdigest()
        )
        # The translated labels do not change event names or outgoing format selection.
        page.get_by_role("button", name="Edit", exact=True).click()
        page.get_by_role("button", name="Jellyfin compatible (template)", exact=True).click()
        template = page.get_by_label(re.compile("^Handlebars template"))
        template.fill('{"event":"{{NotificationType}}","title":{{json_encode Name}}}')
        page.get_by_label(re.compile("^Additional headers")).fill("X-Raw: raw value")
        expect(
            page.get_by_role(
                "checkbox", name="Update available system.update.available", exact=True
            )
        ).to_be_disabled()
        english()
        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(n => n.click())")
        _snapshot(page, shots / f"{theme_id}-{width}-jellyfin-en.png")
        page.get_by_role("button", name="Cancel", exact=True).click()
        assert api("get", "/webhook")["endpoints"][0]["format"] == "movieclaw"
        page.get_by_role("button", name="Edit", exact=True).click()
        page.get_by_role("button", name="Jellyfin compatible (template)", exact=True).click()
        page.get_by_label(re.compile("^Handlebars template")).fill(
            '{"event":"{{NotificationType}}","title":{{json_encode Name}}}'
        )
        page.get_by_label(re.compile("^Additional headers")).fill("X-Raw: raw value")
        page.get_by_role("button", name="Save", exact=True).click()
        expect(page.get_by_text("Jellyfin compatible", exact=True)).to_be_visible()
        jellyfin = api("get", "/webhook")["endpoints"][0]
        assert jellyfin["format"] == "jellyfin" and jellyfin["headers"] == {"X-Raw": "raw value"}
        assert "system.update.available" not in jellyfin["events"]
        handler.status = 204
        before = len(handler.received)
        menu("Send test")
        expect(page.locator(".toast-item").last).to_contain_text("Test event delivered")
        assert len(handler.received) == before + 1
        body, headers = handler.received[-1]
        assert json.loads(body)["event"] == "PlaybackStop"
        assert headers["X-Raw"] == "raw value" and "X-MovieClaw-Signature" not in headers
        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(n => n.click())")
        # Delete cancellation never removes the persisted endpoint.
        menu("Delete")
        expect(page.get_by_role("dialog")).to_contain_text('Delete "Automation raw endpoint"?')
        page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
        assert len(api("get", "/webhook")["endpoints"]) == 1
        menu("Delete")
        page.get_by_role("dialog").get_by_role("button", name="Delete", exact=True).click()
        expect(page.get_by_text("No endpoints yet", exact=True)).to_be_visible()
        assert api("get", "/webhook")["endpoints"] == []

    # Changing language inside the same document rereads the catalog without writing config.
    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/library")
    page.evaluate("window.__webhookDocument = 'kept'")
    _change_language(page, "zh-Hans")
    assert page.evaluate("window.__webhookDocument") == "kept"
    page.goto(base + "/settings/webhook")
    expect(page.get_by_role("button", name="新增 Endpoint", exact=True)).to_be_visible()
    page.get_by_role("button", name="新增 Endpoint", exact=True).click()
    expect(
        page.get_by_role("checkbox", name="开始播放 playback.started", exact=True)
    ).to_be_checked()
    page.goto(base + "/library")
    _change_language(page, "en")
    page.goto(base + "/settings/webhook")
    expect(page.get_by_role("button", name="Add endpoint", exact=True)).to_be_visible()
    assert api("get", "/webhook")["endpoints"] == []
    assert not errors, errors
    context.close()
