"""Cloud pairing and disconnect through real loopback HTTP, Next, API, SQLite and Chrome."""

import json
import re
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
import pytest
from tests.api.test_cloud_push import FakeCloud, FakeRelay

from . import test_i18n_ai_settings_browser as ai
from . import test_i18n_plugin_market_browser as market
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
market_http = market.market_http


@pytest.fixture(scope="module")
def cloud_http():
    cloud = FakeCloud()
    relay = FakeRelay(topics=["io.movieclaw.app"], mode="issuer")

    class Handler(BaseHTTPRequestHandler):
        def reply(self):
            if self.path.startswith("/activate"):
                raw = b'<form action="/approve" method="post"><button>Approve</button></form>'
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
            elif self.path == "/approve":
                cloud.approval = "approved"
                raw = b"Approved"
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
            else:
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                request = httpx.Request(
                    self.command, base + self.path, headers=dict(self.headers), content=body
                )
                response = (
                    relay.handle(request) if self.path == "/v1/info" else cloud.handle(request)
                )
                data = response.json()
                if self.path == "/v1/instance/renew" and response.status_code == 200:
                    data["data"]["notices"] = [
                        {
                            "id": "fixture-notice",
                            "level": "info",
                            "message": "Fixture service notice",
                        }
                    ]
                text = (
                    json.dumps(data)
                    .replace("https://cloud.test", base)
                    .replace("https://movieclaw.test", base)
                )
                raw = text.encode()
                self.send_response(response.status_code)
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        do_GET = reply
        do_POST = reply

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    base = f"http://127.0.0.1:{server.server_port}"
    cloud.push_endpoints = [base]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield base, cloud, relay
    finally:
        server.shutdown()
        server.server_close()
        thread.join(5)


@pytest.fixture(scope="module")
def stack(tmp_path_factory, search_provider, market_http, cloud_http):  # noqa: F811
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("MOVIECLAW_CLOUD_URL", cloud_http[0])
        patch.setenv("E2E_MARKET_UPSTREAM", market_http[0])
        patch.setenv("E2E_MARKET_KEYS", json.dumps(market_http[1]))
        yield from ai.stack.__wrapped__(tmp_path_factory, search_provider)


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_cloud_pairing_reporting_and_disconnect(stack, browser, cloud_http, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    base = stack["base"]
    cloud = cloud_http[1]
    cloud.approval, cloud.unbind_down, cloud.revoked, cloud.renew_reply = (
        "pending",
        False,
        False,
        None,
    )
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    reply = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not reply.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    if api("get", "/cloud")["state"] != "disconnected":
        api("post", "/cloud/disconnect", data={"force": True})
    cloud.revoked = False
    api("put", "/cloud/settings", data={"report_stats": True})
    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/cloud")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    shots = REPO / ".tmp-uidev/i18n/cloud"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name):
        expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        for button in page.locator('main button:visible, [role="dialog"] button:visible').all():
            box = button.bounding_box()
            assert box["x"] >= -1 and box["x"] + box["width"] <= width + 1
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
            return database.execute(
                "SELECT value_json FROM app_setting WHERE namespace='cloud'"
            ).fetchone()[0]

    def open_code():
        page.get_by_role("button", name="Connect to a MovieClaw account", exact=True).click()
        dialog = page.get_by_role("dialog")
        dialog.get_by_label("Server name", exact=True).fill("Fixture NAS")
        dialog.get_by_role("button", name="Get pairing code", exact=True).click()
        expect(dialog.get_by_text("WDJB-MJHT", exact=True)).to_be_visible()
        return dialog

    expect(page.get_by_text("Not connected yet", exact=True)).to_be_visible()
    assert (
        page.get_by_role("link", name="What information is sent to MovieClaw Cloud?")
        .get_attribute("href")
        .endswith("/en/privacy#server-reports")
    )
    shot("disconnected")
    dialog = open_code()
    shot("pending")
    dialog.get_by_role("button", name="Close", exact=True).last.click()
    expect(page.get_by_role("button", name="View pairing code", exact=True)).to_be_visible()
    assert api("get", "/cloud")["pairing"]["status"] == "pending"
    page.get_by_role("button", name="View pairing code", exact=True).click()
    page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
    expect(page.get_by_text("Not connected yet", exact=True)).to_be_visible()
    assert api("get", "/cloud")["pairing"] is None
    dialog = open_code()
    cloud.approval = "denied"
    expect(
        dialog.get_by_text("This connection was denied on movieclaw.io", exact=True)
    ).to_be_visible()
    shot("denied")
    cloud.approval = "pending"
    dialog.get_by_role("button", name="Get a new pairing code", exact=True).click()
    expect(dialog.get_by_text("WDJB-MJHT", exact=True)).to_be_visible()
    with page.expect_popup() as popup:
        dialog.get_by_role("link", name=re.compile(r"^Open 127\.0\.0\.1:.* to approve")).click()
    approval = popup.value
    approval.get_by_role("button", name="Approve", exact=True).click()
    expect(approval.get_by_text("Approved", exact=True)).to_be_visible()
    approval.close()
    expect(
        page.get_by_role("heading", name="Permissions and capabilities", exact=True)
    ).to_be_visible()
    expect(page.get_by_role("dialog")).not_to_be_visible(timeout=15000)
    expect(page.get_by_text("Fixture service notice", exact=True)).to_be_visible()
    assert page.get_by_text("Fixture NAS", exact=True).evaluate(
        "element => element.scrollWidth <= element.clientWidth"
    )
    assert (
        page.get_by_text(re.compile("^Sends notifications to phones")).bounding_box()["width"] > 160
    )
    assert cloud.reports
    before = stored()
    assert cloud.secret not in before and "jwt-" not in before
    shot("connected")
    page.get_by_role("button", name="Dismiss this notice", exact=True).click()
    expect(page.get_by_text("Fixture service notice", exact=True)).not_to_be_visible()
    with page.expect_response(
        lambda r: r.request.method == "PUT" and r.url.endswith("/cloud/settings")
    ) as saved:
        page.get_by_role("switch", name="Report statistics", exact=True).click()
    assert saved.value.ok
    assert api("get", "/cloud")["report_stats"] is False
    api("post", "/cloud/renew")
    assert set(cloud.reports[-1]) == {"instance_version", "runtime_version", "os", "arch"}
    cloud.renew_reply = (503, {})
    api("post", "/cloud/renew")
    page.reload()
    expect(page.get_by_role("button", name="Sync now", exact=True)).to_be_visible()
    expect(
        page.get_by_text(
            re.compile("The last sync failed: MovieClaw Cloud is temporarily unavailable")
        )
    ).to_be_visible()
    shot("health")
    cloud.renew_reply = None
    with page.expect_response(
        lambda r: r.request.method == "POST" and r.url.endswith("/cloud/renew")
    ) as synced:
        page.get_by_role("button", name="Sync now", exact=True).click()
    assert synced.value.ok
    expect(page.get_by_role("button", name="Sync now", exact=True)).not_to_be_visible()
    if width == 1280:
        before = stored()
        page.evaluate("window.__cloudI18nDocument = 'kept'")
        for language in ("zh-Hans", "en"):
            english = page.locator("html").get_attribute("lang") == "en"
            page.get_by_role(
                "button", name="Appearance and language" if english else "外观与语言", exact=True
            ).click()
            control = page.get_by_test_id("language-settings")
            control.locator(f'input[value="{language}"]').check()
            expect(page.locator("html")).to_have_attribute("lang", language)
            expect(control).to_be_enabled()
            page.get_by_role("button", name="MovieClaw Cloud", exact=True).click()
            expect(
                page.get_by_role(
                    "heading",
                    name="Permissions and capabilities" if language == "en" else "权限与能力",
                    exact=True,
                )
            ).to_be_visible()
            assert stored() == before
            assert page.evaluate("window.__cloudI18nDocument") == "kept"
        shot("roundtrip")
    before = stored()
    page.get_by_role("button", name="Disconnect", exact=True).click()
    dialog = page.get_by_role("dialog")
    dialog.get_by_role("button", name="Cancel", exact=True).click()
    assert stored() == before
    cloud.unbind_down = True
    page.get_by_role("button", name="Disconnect", exact=True).click()
    page.get_by_role("dialog").get_by_role("button", name="Disconnect", exact=True).click()
    expect(
        page.get_by_role("heading", name="Cloud is unreachable. Disconnect anyway?", exact=True)
    ).to_be_visible()
    shot("force-disconnect")
    page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
    assert stored() == before
    page.get_by_role("button", name="Disconnect", exact=True).click()
    page.get_by_role("dialog").get_by_role("button", name="Disconnect", exact=True).click()
    page.get_by_role("dialog").get_by_role("button", name="Disconnect anyway", exact=True).click()
    expect(page.get_by_text("Not connected yet", exact=True)).to_be_visible()
    assert not json.loads(stored())["instance_secret"]
    assert api("get", "/cloud")["state"] == "disconnected"
    assert not cloud.revoked
    assert not errors
    context.close()


def test_normal_cloud_disconnect_reaches_upstream(stack, browser, cloud_http):  # noqa: F811
    from playwright.sync_api import expect

    base = stack["base"]
    cloud = cloud_http[1]
    cloud.approval, cloud.unbind_down, cloud.revoked, cloud.renew_reply = (
        "pending",
        False,
        False,
        None,
    )
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    reply = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not reply.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    prefs = context.request.get(base + "/api/v1/ui/preferences").json()["data"]
    prefs.update(theme="silver", theme_desktop="silver", language="en")
    assert context.request.put(base + "/api/v1/ui/preferences", data=prefs).ok
    page = context.new_page()
    page.set_default_timeout(25000)
    page.goto(base + "/settings/cloud")
    page.get_by_role("button", name="Connect to a MovieClaw account", exact=True).click()
    dialog = page.get_by_role("dialog")
    dialog.get_by_label("Server name", exact=True).fill("Normal disconnect fixture")
    dialog.get_by_role("button", name="Get pairing code", exact=True).click()
    with page.expect_popup() as popup:
        dialog.get_by_role("link", name=re.compile(r"^Open 127\.0\.0\.1:.* to approve")).click()
    approval = popup.value
    approval.get_by_role("button", name="Approve", exact=True).click()
    expect(approval.get_by_text("Approved", exact=True)).to_be_visible()
    approval.close()
    expect(
        page.get_by_role("heading", name="Permissions and capabilities", exact=True)
    ).to_be_visible()
    expect(dialog).not_to_be_visible(timeout=15000)
    page.get_by_role("button", name="Disconnect", exact=True).click()
    with page.expect_response(
        lambda r: r.request.method == "POST" and r.url.endswith("/cloud/disconnect")
    ) as disconnected:
        page.get_by_role("dialog").get_by_role("button", name="Disconnect", exact=True).click()
    assert disconnected.value.ok
    assert cloud.revoked
    expect(page.get_by_text("Not connected yet", exact=True)).to_be_visible()
    with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
        stored = json.loads(
            database.execute(
                "SELECT value_json FROM app_setting WHERE namespace='cloud'"
            ).fetchone()[0]
        )
    assert not stored["instance_secret"] and not stored["access_token"]
    expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
    shots = REPO / ".tmp-uidev/i18n/cloud"
    shots.mkdir(parents=True, exist_ok=True)
    _snapshot(page, shots / "normal-disconnect.png")
    context.close()
