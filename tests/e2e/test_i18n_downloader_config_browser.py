"""Downloader setup through real Next/API/SQLite, SDKs and loopback WebUI/RPC."""

import json
import re
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack


@pytest.fixture(scope="module")
def downloader_http():
    class Handler(BaseHTTPRequestHandler):
        requests = []
        unknown = []
        qb = {
            "downloadLimit": 0,
            "uploadLimit": 0,
            "speedLimitsMode": 0,
            "queueing_enabled": False,
            "max_active_downloads": 3,
            "max_active_uploads": 4,
            "max_active_torrents": 7,
        }
        transmission = {
            "version": "4.0.6",
            "rpc-version": 17,
            "rpc-version-minimum": 14,
            "download-dir": "/downloads",
            "speed-limit-down": 0,
            "speed-limit-down-enabled": False,
            "speed-limit-up": 0,
            "speed-limit-up-enabled": False,
            "alt-speed-enabled": False,
            "download-queue-enabled": False,
            "download-queue-size": 3,
            "seed-queue-enabled": False,
            "seed-queue-size": 4,
        }

        def reply(self, value, *, status=200, headers=None):
            body = (value if isinstance(value, str) else json.dumps(value)).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlsplit(self.path).path
            self.requests.append(("GET", path, None))
            values = {
                "/api/v2/app/version": "v5.0.2",
                "/api/v2/app/webapiVersion": "2.11.4",
                "/api/v2/app/preferences": self.qb,
                "/api/v2/torrents/info": [],
                "/api/v2/transfer/info": {"dl_info_speed": 0, "up_info_speed": 0},
            }
            for key in ("downloadLimit", "uploadLimit", "speedLimitsMode"):
                values["/api/v2/transfer/" + key] = str(self.qb[key])
            if path in values:
                self.reply(values[path])
            else:
                self.unknown.append(("GET", path))
                self.reply({}, status=404)

        def do_POST(self):
            path = urlsplit(self.path).path
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.requests.append(("POST", path, body))
            if path == "/transmission/rpc":
                if self.headers.get("X-Transmission-Session-Id") != "fixture-session":
                    self.reply(
                        "", status=409, headers={"X-Transmission-Session-Id": "fixture-session"}
                    )
                    return
                payload = json.loads(body)
                method = payload["method"]
                if method == "session-set":
                    self.transmission.update(payload["arguments"])
                elif method not in {"session-get", "torrent-get"}:
                    self.unknown.append(("RPC", method))
                self.reply(
                    {
                        "result": "success",
                        "arguments": (
                            self.transmission
                            if method == "session-get"
                            else {"torrents": []}
                            if method == "torrent-get"
                            else {}
                        ),
                        "tag": payload.get("tag"),
                    }
                )
                return
            fields = parse_qs(body.decode(), keep_blank_values=True)
            if path == "/api/v2/auth/login":
                good = fields.get("username") == ["fixture"] and fields.get("password") == [
                    "fixture-pass"
                ]
                self.reply(
                    "Ok." if good else "Fails.", headers={"Set-Cookie": "SID=fixture; Path=/"}
                )
                return
            if path == "/api/v2/torrents/info":
                self.reply([])
                return
            if path == "/api/v2/app/setPreferences":
                self.qb.update(json.loads(fields["json"][0]))
            elif path in {"/api/v2/transfer/setDownloadLimit", "/api/v2/transfer/setUploadLimit"}:
                key = "downloadLimit" if "Download" in path else "uploadLimit"
                self.qb[key] = int(fields["limit"][0])
            elif path == "/api/v2/transfer/setSpeedLimitsMode":
                self.qb["speedLimitsMode"] = int(fields["mode"][0])
            elif path == "/api/v2/transfer/toggleSpeedLimitsMode":
                self.qb["speedLimitsMode"] = 1 - self.qb["speedLimitsMode"]
            else:
                self.unknown.append(("POST", path))
                self.reply({}, status=404)
                return
            self.reply("")

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


def test_downloader_configuration_and_language(stack, browser, downloader_http):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(25_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/downloader-config"
    shots.mkdir(parents=True, exist_ok=True)
    local = stack["data"] / "downloader-storage"
    local.mkdir()
    sentinel = local / "keep.txt"
    sentinel.write_text("Keep the downloaded file")

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def stored(client_id):
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return db.execute(
                "SELECT last_error,last_error_ref,password,path_mappings "
                "FROM downloader_client WHERE id=?",
                (client_id,),
            ).fetchone()

    def english():
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    def shot(name):
        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(node => node.click())")
        english()
        _snapshot(page, shots / name)

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
            "button", name="Downloaders" if value == "en" else "下载器", exact=True
        ).click()
        page.set_viewport_size({"width": width, "height": 1000})

    def menu(name, action):
        page.get_by_role("button", name=f"More actions for “{name}”", exact=True).click()
        page.get_by_role("menuitem", name=action, exact=True).click()

    def choose_directory(button):
        button.click()
        picker = page.get_by_role("dialog", name="Choose a server folder", exact=True)
        expect(picker.get_by_role("button", name="Choose this folder", exact=True)).to_be_enabled()
        picker.get_by_title("Enter path manually", exact=True).click()
        picker.get_by_placeholder("Enter an absolute path and press Enter", exact=True).fill(
            str(local)
        )
        picker.get_by_placeholder("Enter an absolute path and press Enter", exact=True).press(
            "Enter"
        )
        expect(picker.locator("p[title]")).to_have_attribute("title", str(local))
        picker.get_by_role("button", name="Choose this folder", exact=True).click()

    def submit(dialog, label):
        with page.expect_response(
            lambda r: (
                r.request.method in {"POST", "PUT"}
                and re.search(r"/api/v1/downloaders(?:/\d+)?$", r.url)
            )
        ) as saved:
            dialog.get_by_role("button", name=label, exact=True).click()
        assert saved.value.ok, saved.value.text()
        expect(dialog).not_to_be_visible()
        return saved.value.json()["data"]["id"]

    for theme_id, width in [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]:
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/downloaders")
        expect(page.get_by_text("No downloaders connected", exact=True)).to_be_visible()
        shot(f"{theme_id}-{width}-empty.png")
        page.get_by_role("button", name="Add downloader", exact=True).click()
        form = page.get_by_role("dialog", name="Add downloader", exact=True)
        form.get_by_placeholder("For example: Home qBittorrent").fill("Fixture qB")
        form.get_by_placeholder("http://192.168.1.10:8080").fill(downloader_http[0])
        form.locator('input[type="text"]').nth(2).fill("fixture")
        form.locator('input[type="password"]').fill("bad-pass")
        choose_directory(
            form.get_by_role("button", name="Browse and select a server directory…", exact=True)
        )
        form.get_by_role(
            "button", name=re.compile(r"Path mappings \(optional\)"), exact=False
        ).click()
        form.get_by_role("button", name="Add mapping", exact=True).click()
        expect(form.get_by_role("button", name="Add", exact=True)).to_be_disabled()
        expect(
            form.get_by_text(re.compile("Complete both sides of every mapping:"))
        ).to_be_visible()
        choose_directory(form.get_by_title("MovieClaw path (browse to select)", exact=True))
        form.get_by_placeholder("Downloader path, for example /downloads").fill("/downloads")
        form.get_by_role("button", name="Add mapping", exact=True).click()
        choose_directory(form.get_by_title("MovieClaw path (browse to select)", exact=True).nth(1))
        form.get_by_placeholder("Downloader path, for example /downloads").nth(1).fill("/downloads")
        expect(
            form.get_by_text(
                "Each MovieClaw path and each downloader path can appear only once. "
                "Edit or remove duplicate rows.",
                exact=True,
            )
        ).to_be_visible()
        expect(form.get_by_role("button", name="Add", exact=True)).to_be_disabled()
        form.get_by_role("button", name="Remove this mapping", exact=True).nth(1).click()
        shot(f"{theme_id}-{width}-form.png")
        client_id = submit(form, "Add")
        expect(
            page.get_by_text("qBittorrent login failed: incorrect username or password", exact=True)
        ).to_be_visible()
        raw = stored(client_id)
        assert raw[0] == "qBittorrent 登录失败：用户名或密码错误"
        assert json.loads(raw[1])["message_key"] == "errors.downloader.qbLogin"
        assert raw[2].startswith("enc::") and "bad-pass" not in raw[2]
        page.evaluate("window.__i18nDownloaderDocument = 'retained'")
        language("zh-Hans")
        expect(page.get_by_text(raw[0], exact=True)).to_be_visible()
        language("en")
        expect(
            page.get_by_text("qBittorrent login failed: incorrect username or password", exact=True)
        ).to_be_visible()
        assert page.evaluate("window.__i18nDownloaderDocument") == "retained"
        assert stored(client_id) == raw
        page.get_by_role("button", name="Edit", exact=True).click()
        form = page.get_by_role("dialog", name="Edit “Fixture qB”", exact=True)
        form.get_by_placeholder("Re-enter for security").fill("fixture-pass")
        submit(form, "Save")
        expect(page.get_by_text("Connected", exact=True)).to_be_visible()
        assert stored(client_id)[0] is None
        assert json.loads(stored(client_id)[1]) is None
        mapping = json.loads(stored(client_id)[3])
        assert mapping == [{"local": str(local), "remote": "/downloads"}]
        assert api("get", f"/downloaders/{client_id}")["save_path"] == str(local)
        menu("Fixture qB", "Speed limits and queues…")
        limits = page.get_by_role("dialog", name="Speed limits and queues", exact=True)
        expect(limits.locator('input[type="number"]').nth(0)).to_be_enabled()
        limits.locator('input[type="number"]').nth(0).fill("512")
        limits.locator('input[type="number"]').nth(1).fill("128")
        if (
            limits.get_by_role("switch", name="Alternative speed limits", exact=True).get_attribute(
                "aria-checked"
            )
            == "false"
        ):
            limits.get_by_role("switch", name="Alternative speed limits", exact=True).click()
        if (
            limits.get_by_role("switch", name="Task queues", exact=True).get_attribute(
                "aria-checked"
            )
            == "false"
        ):
            limits.get_by_role("switch", name="Task queues", exact=True).click()
        for index, value in enumerate(["5", "6", "11"], start=2):
            limits.locator('input[type="number"]').nth(index).fill(value)
        shot(f"{theme_id}-{width}-limits.png")
        limits.get_by_role("button", name="Save", exact=True).click()
        expect(limits).not_to_be_visible()
        assert downloader_http[1].qb["downloadLimit"] == 512 * 1024
        assert downloader_http[1].qb["uploadLimit"] == 128 * 1024
        assert downloader_http[1].qb["max_active_torrents"] == 11
        assert downloader_http[1].qb["speedLimitsMode"] == 1
        menu("Fixture qB", "Disable downloader")
        expect(page.get_by_text("Disabled", exact=True)).to_be_visible()
        menu("Fixture qB", "Enable downloader")
        expect(page.get_by_text("Disabled", exact=True)).not_to_be_visible()
        menu("Fixture qB", "Test connection again")
        expect(page.get_by_text("Connected", exact=True)).to_be_visible()
        shot(f"{theme_id}-{width}-connected.png")
        menu("Fixture qB", "Delete configuration")
        confirm = page.get_by_role("dialog")
        expect(
            confirm.get_by_text(
                "Existing tasks stay in the downloader. "
                "MovieClaw will stop sending downloads to it.",
                exact=True,
            )
        ).to_be_visible()
        confirm.get_by_role("button", name="Cancel", exact=True).click()
        assert len(api("get", "/downloaders")) == 1
        menu("Fixture qB", "Delete configuration")
        page.get_by_role("dialog").get_by_role("button", name="Delete", exact=True).click()
        expect(page.get_by_text("No downloaders connected", exact=True)).to_be_visible()
        assert sentinel.read_text() == "Keep the downloaded file"

    page.get_by_role("button", name="Add downloader", exact=True).click()
    form = page.get_by_role("dialog", name="Add downloader", exact=True)
    form.get_by_role("button", name="Transmission", exact=True).click()
    expect(form.get_by_text("RPC URL", exact=True)).to_be_visible()
    expect(
        form.get_by_text("The path defaults to /transmission/rpc when omitted", exact=True)
    ).to_be_visible()
    form.get_by_placeholder("For example: Home qBittorrent").fill("Fixture Transmission")
    form.get_by_placeholder("http://192.168.1.10:9091").fill(downloader_http[0])
    transmission_id = submit(form, "Add")
    expect(page.get_by_text("Connected", exact=True)).to_be_visible()
    menu("Fixture Transmission", "Speed limits and queues…")
    limits = page.get_by_role("dialog", name="Speed limits and queues", exact=True)
    expect(limits.locator('input[type="number"]').nth(0)).to_be_enabled()
    limits.get_by_role("switch", name="Task queues", exact=True).click()
    expect(limits.locator('input[type="number"]')).to_have_count(4)
    expect(limits.get_by_text("Maximum active torrents", exact=True)).not_to_be_visible()
    limits.locator('input[type="number"]').nth(0).fill("125")
    limits.locator('input[type="number"]').nth(2).fill("8")
    limits.get_by_role("button", name="Save", exact=True).click()
    expect(limits).not_to_be_visible()
    assert downloader_http[1].transmission["speed-limit-down"] == 128
    assert downloader_http[1].transmission["download-queue-size"] == 8
    assert api("get", f"/downloaders/{transmission_id}/limits")["download_limit_bytes"] == 128000

    page.goto(base + "/settings/downloaders?suggest_mapping=" + quote(str(local), safe=""))
    form = page.get_by_role("dialog", name="Edit “Fixture Transmission”", exact=True)
    expect(form.get_by_text(re.compile("The health check suggestion prefilled"))).to_be_visible()
    expect(form.get_by_role("button", name="Save", exact=True)).to_be_disabled()
    form.get_by_role("button", name="Copy left path to right", exact=True).click()
    expect(form.get_by_placeholder("Downloader path, for example /downloads")).to_have_value(
        str(local)
    )
    shot("netflix-320-suggested-mapping.png")
    submit(form, "Save")
    expect(page.get_by_text("Connected", exact=True)).to_be_visible()
    assert json.loads(stored(transmission_id)[3]) == [{"local": str(local), "remote": str(local)}]

    page.get_by_role("button", name="Add downloader", exact=True).click()
    form = page.get_by_role("dialog", name="Add downloader", exact=True)
    form.get_by_placeholder("For example: Home qBittorrent").fill("Second qB")
    form.get_by_placeholder("http://192.168.1.10:8080").fill(downloader_http[0])
    form.locator('input[type="text"]').nth(2).fill("fixture")
    form.locator('input[type="password"]').fill("fixture-pass")
    second_id = submit(form, "Add")
    expect(page.get_by_text("Connected", exact=True)).to_have_count(2)
    with page.expect_response(
        lambda response: (
            response.url.endswith(f"/downloaders/{second_id}/default")
            and response.request.method == "POST"
        )
    ) as saved_default:
        menu("Second qB", "Set as default")
    assert saved_default.value.ok, saved_default.value.text()
    expect(page.get_by_text("Default", exact=True)).to_have_count(1)
    default_ids = [row["id"] for row in api("get", "/downloaders") if row["is_default"]]
    assert default_ids == [second_id]
    page.goto(base + f"/settings/downloaders?limits={transmission_id}")
    limits = page.get_by_role("dialog", name="Speed limits and queues", exact=True)
    expect(
        limits.get_by_role(
            "heading", name="Speed limits and queues · Fixture Transmission", exact=True
        )
    ).to_be_visible()
    expect(limits.locator('input[type="number"]')).to_have_count(4)
    shot("netflix-320-transmission-limits.png")
    limits.get_by_role("button", name="Cancel", exact=True).click()
    assert not downloader_http[1].unknown
    assert not any("delete" in path for _, path, _ in downloader_http[1].requests)
    assert not errors, errors
    context.close()
