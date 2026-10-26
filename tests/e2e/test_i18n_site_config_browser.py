"""Site setup and extension synchronization through real services and official HTTP adapters."""

import json
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_i18n_downloader_config_browser as downloaders
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
downloader_http = downloaders.downloader_http


@pytest.fixture(scope="module")
def site_http():
    class Handler(BaseHTTPRequestHandler):
        requests = []
        unknown = []
        sync_mode = "success"

        def reply(self, data, status=200, headers=None):
            raw = isinstance(data, str)
            body = (data if raw else json.dumps(data)).encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html" if raw else "application/json")
            self.send_header("Content-Length", str(len(body)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlsplit(self.path).path
            self.requests.append(("GET", path, self.headers.get("Cookie", "")))
            if path == "/ttg/login.php":
                self.reply(
                    '<form action="takelogin.php" method="post">'
                    '<input name="username"><input name="password" type="password"></form>'
                )
            elif path in {"/ttg/", "/ttg/rules.php"}:
                if "fixture-session" not in self.headers.get("Cookie", ""):
                    self.reply('<form action="login.php"></form>')
                    return
                fonts = ["0", "0", "0", "2.5", "0", "2 TB", "0", "1 TB", "0", "5", "0", "0"]
                self.reply(
                    '<a href="/logout.php">Sign out</a>'
                    '<a href="/userdetails.php?id=42" class="PowerUser">Fixture TTG User</a>'
                    + "".join(f"<font>{value}</font>" for value in fonts)
                )
            elif path.endswith("/favicon.ico"):
                self.reply("", status=404)
            else:
                self.unknown.append(("GET", path))
                self.reply("", status=404)

        def do_POST(self):
            path = urlsplit(self.path).path
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.requests.append(("POST", path, body))
            if path == "/ttg/takelogin.php":
                fields = parse_qs(body.decode())
                valid = fields.get("username") == ["fixture"] and fields.get("password") == [
                    "fixture-pass"
                ]
                self.reply(
                    '<a href="/logout.php">Sign out</a>' if valid else '<td class="text"></td>',
                    headers={"Set-Cookie": "fixture-session=good; Path=/ttg"} if valid else {},
                )
                return
            if path.startswith("/mteam/api/"):
                if self.headers.get("x-api-key") != "fixture-good-key":
                    self.reply({"message": "invalid api key", "code": 401})
                    return
                if path.endswith("/torrent/search"):
                    if self.sync_mode == "network":
                        self.reply({"error": "Fixture temporarily unavailable"}, status=503)
                        return
                    if self.sync_mode == "auth":
                        self.reply({"message": "invalid api key", "code": 401})
                        return
                    data = {"data": [], "total": 0, "pageNumber": 1, "totalPages": 1}
                elif path.endswith("/member/profile"):
                    data = {
                        "id": "42",
                        "username": "Fixture Owner",
                        "role": "Power User",
                        "memberCount": {
                            "uploaded": str(2 * 1024**4),
                            "downloaded": str(1024**4),
                            "shareRate": "2.0",
                            "bonus": "12345.6",
                        },
                    }
                elif path.endswith("/tracker/myPeerStatus"):
                    data = {"seeder": 35, "leecher": 2}
                else:
                    self.unknown.append(("POST", path))
                    self.reply({}, status=404)
                    return
                self.reply({"message": "SUCCESS", "data": data})
                return
            self.unknown.append(("POST", path))
            self.reply({}, status=404)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", Handler
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


@pytest.fixture(scope="module")
def stack(tmp_path_factory, search_provider, site_http, downloader_http):
    # Keep loopback services alive until the API has shut down.
    yield from ai.stack.__wrapped__(tmp_path_factory, search_provider)


def test_site_configuration_and_extension_token(stack, browser, site_http, downloader_http):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(
        locale="en-US",
        viewport={"width": 1280, "height": 1000},
        permissions=["clipboard-read", "clipboard-write"],
    )
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    response = context.request.post(
        base + "/api/v1/__lab/sites/upstream",
        data={
            "mteam": site_http[0] + "/mteam",
            "ttg": site_http[0].replace("127.0.0.1", "localhost") + "/ttg",
        },
    )
    assert response.ok, response.text()
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/site-config"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def lab_sync():
        response = context.request.post(base + "/api/v1/__lab/sites/sync/mteam")
        assert response.ok, response.text()

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return db.execute(
                "SELECT last_error,last_error_ref,api_key FROM site_credential "
                "WHERE site_id='mteam'"
            ).fetchone()

    def language(value):
        width = page.viewport_size["width"]
        page.set_viewport_size({"width": 1280, "height": 1000})
        current = page.locator("html").get_attribute("lang")
        page.get_by_role(
            "button",
            name="Appearance and language" if current == "en" else "外观与语言",
            exact=True,
        ).click()
        page.get_by_test_id("language-settings").locator(f'input[value="{value}"]').check()
        expect(page.locator("html")).to_have_attribute("lang", value)
        page.get_by_role(
            "button", name="Trackers" if value == "en" else "资源站点", exact=True
        ).click()
        page.set_viewport_size({"width": width, "height": 1000})

    def shot(name):
        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(node => node.click())")
        # The original catalog name and its fallback avatar are preserved metadata.
        text = page.locator("main").inner_text().replace("听听歌", "").replace("\n听\n", "\n")
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        assert page.locator("main button").evaluate_all(
            "buttons => buttons.every(button => { const r = button.getBoundingClientRect(); "
            "return !r.width || !r.height || (r.left >= -0.5 && r.right <= innerWidth + 0.5); })"
        ), "A settings action is clipped at the viewport edge"
        _snapshot(page, shots / name)

    def menu(action, name="M-Team"):
        page.get_by_role("button", name=f"More actions for “{name}”", exact=True).click()
        if action in {
            "Enable protection",
            "Disable protection",
            "Enable site",
            "Disable site",
            "Pause boosting",
            "Resume boosting",
            "Verify again",
        }:
            with page.expect_response(
                lambda response: (
                    f"/api/v1/sites/{'mteam' if name == 'M-Team' else 'ttg'}/" in response.url
                    and response.request.method in {"PATCH", "POST"}
                )
            ) as updated:
                page.get_by_role("menuitem", name=action, exact=True).click()
            assert updated.value.ok, updated.value.text()
        else:
            page.get_by_role("menuitem", name=action, exact=True).click()

    def submit(form, label):
        with page.expect_response(
            lambda response: (
                response.request.method in {"POST", "PUT"}
                and re.search(r"/api/v1/sites(?:/mteam|/ttg)?$", response.url)
            )
        ) as saved:
            form.get_by_role("button", name=label, exact=True).click()
        assert saved.value.ok, saved.value.text()
        expect(form).not_to_be_visible()

    def verify_state(status="Verified", count=1):
        expect(page.get_by_text(status, exact=True)).to_have_count(count, timeout=25000)

    for name in ["Default downloader", "Boost downloader"]:
        api(
            "post",
            "/downloaders",
            data={
                "name": name,
                "client_type": "qbittorrent",
                "url": downloader_http[0],
                "username": "fixture",
                "password": "fixture-pass",
            },
        )
    for _ in range(200):
        clients = api("get", "/downloaders")
        if all(client["status"] == "active" for client in clients):
            break
        time.sleep(0.1)
    assert all(client["status"] == "active" for client in clients)

    for theme_id, width in [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]:
        for row in api("get", "/sites"):
            api("delete", "/sites/" + row["site_id"])
        api("delete", "/extension/token")
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/sites")
        expect(page.get_by_text("No sites configured", exact=True)).to_be_visible()
        shot(f"{theme_id}-{width}-empty.png")
        page.get_by_role("button", name="Add site", exact=True).click()
        form = page.get_by_role("dialog", name="Add site", exact=True)
        form.get_by_placeholder("Search by site name or address").fill("no-matching-fixture")
        expect(
            form.get_by_text("No sites match “no-matching-fixture”.", exact=True)
        ).to_be_visible()
        form.get_by_placeholder("Search by site name or address").fill("mteam")
        form.get_by_role("button", name=re.compile("M-Team")).click()
        expect(form.get_by_role("button", name="Save and verify", exact=True)).to_be_disabled()
        form.locator('input[type="password"]').fill("fixture-bad-key")
        shot(f"{theme_id}-{width}-authentication.png")
        submit(form, "Save and verify")
        verify_state("Verification failed")
        expect(page.get_by_text("1 site connected, 1 needs attention", exact=True)).to_be_attached()
        expect(
            page.get_by_text(
                "Authentication failed: M-Team returned an error: invalid api key", exact=True
            )
        ).to_be_visible()
        original = stored()
        assert "M-Team 接口返回错误" in original[0]
        assert original[2].startswith("enc::") and "fixture-bad-key" not in original[2]
        page.evaluate("window.__i18nSiteDocument = 'retained'")
        language("zh-Hans")
        expect(page.get_by_text(original[0], exact=True)).to_be_visible()
        language("en")
        assert page.evaluate("window.__i18nSiteDocument") == "retained"
        assert stored() == original
        menu("Edit authentication")
        form = page.get_by_role("dialog", name="Edit authentication for “M-Team”", exact=True)
        form.get_by_placeholder("Re-enter for security").fill("fixture-good-key")
        submit(form, "Save and verify again")
        verify_state()
        assert stored()[0] is None and json.loads(stored()[1]) is None
        expect(page.get_by_text("1 site connected, working normally", exact=True)).to_be_attached()
        page.locator('[role="button"][aria-expanded]').filter(
            has=page.get_by_role("link", name="M-Team", exact=True)
        ).click()
        expect(page.get_by_text("Fixture Owner", exact=True)).to_be_visible()
        if width >= 640:
            assert page.get_by_text("Authentication", exact=True).evaluate(
                "label => label.getBoundingClientRect().right <= "
                "label.nextElementSibling.getBoundingClientRect().left"
            )
        shot(f"{theme_id}-{width}-profile.png")
        menu("Enable protection")
        expect(page.get_by_label("Site protected", exact=True)).to_be_visible()
        assert api("get", "/sites/mteam")["protected"]
        menu("Disable protection")
        menu("Disable site")
        expect(page.get_by_text("Disabled", exact=True)).to_be_visible()
        assert not api("get", "/sites/mteam")["usable"]
        menu("Enable site")
        menu("Enable boosting…")
        boost = page.get_by_role("dialog", name="Enable automatic ratio boosting", exact=True)
        boost.locator('input[type="number"]').nth(0).fill("0")
        boost.get_by_role("button", name="Enable boosting", exact=True).click()
        expect(
            boost.get_by_text(
                "The boosting budget must be a whole number of at least 1 GiB", exact=True
            )
        ).to_be_visible()
        boost.locator('input[type="number"]').nth(0).fill("64")
        boost.locator('input[type="number"]').nth(1).fill("31")
        boost.get_by_role("button", name="Enable boosting", exact=True).click()
        expect(
            boost.get_by_text(
                "The retention period must be a whole number from 0 to 30 days", exact=True
            )
        ).to_be_visible()
        boost.locator('input[type="number"]').nth(1).fill("3")
        boost.get_by_role("button", name=re.compile("Default downloader")).click()
        page.get_by_role("menuitemradio", name="Boost downloader", exact=True).click()
        shot(f"{theme_id}-{width}-boost.png")
        boost.get_by_role("button", name="Enable boosting", exact=True).click()
        expect(boost).not_to_be_visible()
        configured = api("get", "/sites/mteam")
        assert configured["boost_enabled"] and configured["boost_budget_bytes"] == 64 * 1024**3
        assert configured["boost_downloader_id"] == clients[1]["id"]
        menu("Pause boosting")
        assert api("get", "/sites/mteam")["boost_paused"]
        menu("Resume boosting")
        menu("Boost settings…")
        boost = page.get_by_role("dialog", name="Boost settings", exact=True)
        boost.locator('input[type="number"]').nth(0).fill("32")
        boost.get_by_role("button", name="Save", exact=True).click()
        confirm = page.get_by_role("dialog").filter(
            has=page.get_by_role("button", name="Confirm reduction", exact=True)
        )
        confirm.get_by_role("button", name="Cancel", exact=True).click()
        assert api("get", "/sites/mteam")["boost_budget_bytes"] == 64 * 1024**3
        boost.get_by_role("button", name="Save", exact=True).click()
        page.get_by_role("button", name="Confirm reduction", exact=True).click()
        expect(boost).not_to_be_visible()
        assert api("get", "/sites/mteam")["boost_budget_bytes"] == 32 * 1024**3
        menu("Disable boosting…")
        with page.expect_response(
            lambda response: (
                "/api/v1/sites/mteam/" in response.url and response.request.method == "PATCH"
            )
        ) as disabled:
            page.get_by_role("dialog").get_by_role(
                "button", name="Disable boosting", exact=True
            ).click()
        assert disabled.value.ok, disabled.value.text()
        assert not api("get", "/sites/mteam")["boost_enabled"]

        page.get_by_role("button", name="Install extension", exact=True).click()
        install = page.get_by_role("dialog", name="Install browser extension", exact=True)
        expect(install.get_by_text("chrome-mv3", exact=True)).to_be_visible()
        assert install.get_by_role("link", name="Download package", exact=True).get_attribute(
            "href"
        )
        assert install.get_by_role("link", name="Firefox package", exact=True).get_attribute("href")
        shot(f"{theme_id}-{width}-extension-guide.png")
        install.get_by_text(
            "xpinstall.signatures.required", exact=True
        ).scroll_into_view_if_needed()
        expect(install.get_by_role("button", name="Done", exact=True)).to_be_in_viewport()
        shot(f"{theme_id}-{width}-extension-footer.png")
        install.get_by_role("button", name="Generate a token", exact=True).click()
        token_dialog = page.get_by_role("dialog", name="Sync token", exact=True)
        token_dialog.get_by_role("button", name="Generate token", exact=True).click()
        expect(token_dialog.get_by_role("button", name="Regenerate", exact=True)).to_be_visible()
        first_token = api("get", "/extension/token")["token"]
        token_dialog.get_by_role("button", name="Show", exact=True).click()
        expect(token_dialog.get_by_text(first_token, exact=True)).to_be_visible()
        token_dialog.get_by_role("button", name="Copy token", exact=True).click()
        assert page.evaluate("navigator.clipboard.readText()") == first_token
        token_dialog.get_by_role("button", name="Hide", exact=True).click()
        token_dialog.get_by_role("button", name="Regenerate", exact=True).click()
        page.get_by_role("dialog").filter(
            has=page.get_by_role("heading", name="Regenerate the sync token?", exact=True)
        ).get_by_role("button", name="Cancel", exact=True).click()
        assert api("get", "/extension/token")["token"] == first_token
        token_dialog.get_by_role("button", name="Regenerate", exact=True).click()
        with page.expect_response(
            lambda response: (
                response.url.endswith("/api/v1/extension/token")
                and response.request.method == "POST"
            )
        ) as rotated:
            page.get_by_role("dialog").filter(
                has=page.get_by_role("heading", name="Regenerate the sync token?", exact=True)
            ).get_by_role("button", name="Regenerate", exact=True).click()
        assert rotated.value.ok, rotated.value.text()
        expect(token_dialog.get_by_role("button", name="Show", exact=True)).to_be_visible()
        second_token = api("get", "/extension/token")["token"]
        assert second_token != first_token
        assert (
            context.request.get(
                base + "/api/v1/extension/ping", headers={"Authorization": "Bearer " + first_token}
            ).status
            == 401
        )
        assert context.request.get(
            base + "/api/v1/extension/ping", headers={"Authorization": "Bearer " + second_token}
        ).ok
        shot(f"{theme_id}-{width}-token.png")
        token_dialog.get_by_role("button", name="Turn off sync", exact=True).click()
        page.get_by_role("dialog").filter(
            has=page.get_by_role("heading", name="Turn off cookie synchronization?", exact=True)
        ).get_by_role("button", name="Turn off sync", exact=True).click()
        expect(
            token_dialog.get_by_role("button", name="Generate token", exact=True)
        ).to_be_visible()
        assert (
            context.request.get(
                base + "/api/v1/extension/ping", headers={"Authorization": "Bearer " + second_token}
            ).status
            == 401
        )
        token_dialog.get_by_role("button", name="Done", exact=True).click()
        menu("Delete configuration")
        page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
        assert len(api("get", "/sites")) == 1
        menu("Delete configuration")
        page.get_by_role("dialog").get_by_role("button", name="Delete", exact=True).click()
        expect(page.get_by_text("No sites configured", exact=True)).to_be_visible()

    # Actual sync failures preserve the same backoff/breaker facts across readers.
    page.get_by_role("button", name="Add site", exact=True).click()
    form = page.get_by_role("dialog", name="Add site", exact=True)
    form.get_by_placeholder("Search by site name or address").fill("mteam")
    form.get_by_role("button", name=re.compile("M-Team")).click()
    form.locator('input[type="password"]').fill("fixture-good-key")
    submit(form, "Save and verify")
    verify_state()
    site_http[1].sync_mode = "network"
    lab_sync()
    page.reload()
    page.locator('[role="button"][aria-expanded]').filter(
        has=page.get_by_role("link", name="M-Team", exact=True)
    ).click()
    expect(
        page.get_by_text(
            re.compile("^Last sync failed: The site server is temporarily unavailable")
        )
    ).to_be_visible()
    with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
        original_sync = db.execute(
            "SELECT last_error,last_error_ref,consecutive_failures,sync_interval_seconds "
            "FROM site_sync_cursor WHERE site_id='mteam'"
        ).fetchone()
    assert "自动重试" in original_sync[0] and original_sync[2] == 1
    language("zh-Hans")
    language("en")
    with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
        assert (
            db.execute(
                "SELECT last_error,last_error_ref,consecutive_failures,sync_interval_seconds "
                "FROM site_sync_cursor WHERE site_id='mteam'"
            ).fetchone()
            == original_sync
        )
    site_http[1].sync_mode = "auth"
    lab_sync()
    page.reload()
    verify_state("Verification failed")
    expect(
        page.get_by_text(
            re.compile("synchronization paused after 2 consecutive authentication failures")
        )
    ).to_be_visible()
    shot("netflix-320-sync-breaker.png")
    site_http[1].sync_mode = "success"
    menu("Verify again")
    verify_state()
    sync = api("get", "/sites/sync-stats")["mteam"]
    assert sync["last_error"] is None and sync["consecutive_failures"] == 0

    # Cookie and credential modes use the real TTG parser and login form flow.
    page.get_by_role("button", name="Add site", exact=True).click()
    form = page.get_by_role("dialog", name="Add site", exact=True)
    form.get_by_placeholder("Search by site name or address").fill("ttg")
    form.get_by_role("button", name=re.compile("听听歌")).click()
    expect(form.get_by_text("Cookie string", exact=True)).to_be_visible()
    form.locator("textarea").fill("fixture-session=good")
    submit(form, "Save and verify")
    verify_state(count=2)
    menu("Edit authentication", "听听歌")
    form = page.get_by_role("dialog", name="Edit authentication for “听听歌”", exact=True)
    form.get_by_role("button", name="Username and password", exact=True).click()
    expect(form.locator("textarea")).not_to_be_attached()
    form.locator('input[type="text"]').fill("fixture")
    form.locator('input[type="password"]').fill("bad-pass")
    submit(form, "Save and verify again")
    verify_state("Verification failed")
    expect(
        page.get_by_text(
            "Authentication failed: Sign-in failed: Incorrect username or password", exact=True
        )
    ).to_be_visible()
    menu("Edit authentication", "听听歌")
    form = page.get_by_role("dialog", name="Edit authentication for “听听歌”", exact=True)
    form.locator('input[type="text"]').fill("fixture")
    form.locator('input[type="password"]').fill("fixture-pass")
    submit(form, "Save and verify again")
    verify_state(count=2)
    with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
        credential = db.execute(
            "SELECT auth_type,username,password,cookie,api_key FROM site_credential "
            "WHERE site_id='ttg'"
        ).fetchone()
    assert credential[0] == "CREDENTIAL" and credential[1] == "fixture"
    assert credential[2].startswith("enc::") and "fixture-pass" not in credential[2]
    assert credential[3:] == (None, None)
    shot("netflix-320-credential-restored.png")
    page.get_by_role("button", name="Manage", exact=True).click()
    token_dialog = page.get_by_role("dialog", name="Sync token", exact=True)
    token_dialog.get_by_role("button", name="Generate token", exact=True).click()
    expect(token_dialog.get_by_role("button", name="Regenerate", exact=True)).to_be_visible()
    token = api("get", "/extension/token")["token"]
    token_dialog.get_by_role("button", name="Done", exact=True).click()
    response = context.request.post(
        base + "/api/v1/extension/cookies",
        headers={
            "Authorization": "Bearer " + token,
        },
        data={"domain": "localhost", "cookie": "fixture-session=good; fixture-version=2"},
    )
    assert response.ok, response.text()
    assert response.json()["data"]["site_id"] == "ttg"
    assert response.json()["data"]["display_name"] == "听听歌"
    page.reload()
    verify_state(count=2)
    cookie_site = api("get", "/sites/ttg")
    assert (
        cookie_site["auth_type"] == "cookie"
        and cookie_site["profile"]["username"] == "Fixture TTG User"
    )
    with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
        synchronized = db.execute(
            "SELECT username,password,cookie,api_key FROM site_credential WHERE site_id='ttg'"
        ).fetchone()
    assert synchronized[0:2] == (None, None) and synchronized[3] is None
    assert synchronized[2].startswith("enc::") and "fixture-session" not in synchronized[2]
    shot("netflix-320-cookie-synchronized.png")
    assert not errors, errors
    assert not site_http[1].unknown, site_http[1].unknown
    context.close()
