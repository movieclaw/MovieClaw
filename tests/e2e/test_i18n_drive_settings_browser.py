"""Drive settings and cloud directory selection through Next/API/SQLite and a real SDK plugin."""

import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO, WEB, _free_port, _wait_http

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider


@pytest.fixture(scope="module")
def drive_http():
    class Handler(BaseHTTPRequestHandler):
        requests = []
        flows = {}
        mode = "pending"

        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            self.requests.append((self.path, payload))
            status = 200
            if self.path == "/begin":
                flow_id = str(len(self.flows) + 1)
                self.flows[flow_id] = payload["options"]
                data = {"flow_id": flow_id, "status": "pending", "qr": "fixture://scan/" + flow_id}
            elif self.path == "/poll":
                flow_id = payload["flow_id"]
                data = {"flow_id": flow_id, "status": self.mode}
                if self.mode == "confirmed":
                    data["result"] = {
                        "user_id": "fixture-user",
                        "display_name": "Original account",
                        "credentials": {"token": "fixture-scan-token"},
                    }
                elif self.mode == "expired":
                    data["message"] = "Upstream QR expired"
            elif self.path == "/cancel":
                data = {"ok": True}
            elif self.path in {"/form", "/cookie"}:
                valid = payload.get(
                    "client_secret"
                ) == "fixture-secret" or "session=good" in payload.get("cookie", "")
                if not valid:
                    status, data = 401, {"error": "Invalid fixture credentials"}
                else:
                    data = {
                        "user_id": payload.get("client_id", "fixture-user"),
                        "display_name": "Original account",
                        "credentials": {"token": "fixture-secret-token"},
                    }
            elif self.path == "/profile":
                data = {
                    "display_name": "Original account",
                    "vip": "Fixture VIP",
                    "quota_total": 107374182400,
                    "quota_used": 42949672960,
                }
            elif self.path == "/dirs":
                data = {
                    "": [
                        {
                            "remote_id": "media",
                            "name": "Media",
                            "has_children": True,
                            "video_count": 2,
                        },
                        {
                            "remote_id": "free",
                            "name": "Archive",
                            "has_children": False,
                            "video_count": 0,
                        },
                    ],
                    "media": [
                        {
                            "remote_id": "films",
                            "name": "Films",
                            "has_children": False,
                            "video_count": 2,
                        }
                    ],
                    "films": [],
                    "free": [],
                }[payload["parent"]]
            elif self.path == "/tree":
                data = {"ok": True}
            else:
                raise AssertionError(self.path)
            body = json.dumps(data).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", Handler
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


@pytest.fixture(scope="module")
def stack(tmp_path_factory, search_provider, drive_http):
    from movieclaw_api.core.config import Settings

    root = tmp_path_factory.mktemp("drive-settings-browser")
    data = root / "data"
    data.mkdir()
    (data / "plugins").mkdir()
    (data / "plugins" / "fixture_drive.py").write_text(
        (REPO / "tests/e2e/_drive_settings_fixture.py")
        .read_text()
        .replace('os.environ["E2E_DRIVE_UPSTREAM"]', repr(drive_http[0]))
    )
    (data / "plugins.yaml").write_text(
        "- id: drive-settings-fixture\n  local: true\n  module: fixture_drive\n  runtime: process\n"
    )
    paths = {
        "data_dir": ".",
        "metadata_dir": "metadata",
        "people_images_dir": "metadata/people",
        "image_cache_dir": "cache/images",
        "trickplay_cache_dir": "cache/playback-trickplay",
        "playback_subs_cache_dir": "cache/playback-subs",
        "reels_cache_dir": "cache/reels",
        "reels_clips_dir": "cache/reels-clips",
        "offline_exports_dir": "cache/offline-exports",
        "playback_cues_cache_dir": "cache/playback_cues",
        "audio_fingerprint_dir": "cache/audio-fingerprints",
        "subtitle_gen_cache_dir": "cache/subtitle_gen",
        "transcode_dir": "transcodes",
        "log_dir": "logs",
        "media_dir": "uploads",
        "secret_key_file": ".secret_key",
        "site_configs_dir": "site-configs",
        "agent_workspace_dir": "agent-workspace",
        "agent_sessions_dir": "agent-sessions",
        "agent_skills_dir": "agent-skills",
        "updates_dir": "updates",
        "web_port_file": "config/web-port",
    }
    env = {
        **os.environ,
        **{Settings.model_fields[key].alias: str(data / value) for key, value in paths.items()},
        "DATABASE_URL": f"sqlite+aiosqlite:///{data / 'movieclaw.db'}",
        "SCHEDULER_ENABLED": "false",
        "E2E_SEARCH_UPSTREAM": search_provider[0],
        "PYTHONPATH": f"{REPO / 'src'}:{REPO}",
    }
    api_port, web_port = _free_port(), _free_port()
    logs = [(root / name).open("w") for name in ("api.log", "web.log")]
    api = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._drive_settings_api_launcher:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(api_port),
        ],
        cwd=REPO,
        env=env,
        stdout=logs[0],
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    web = subprocess.Popen(
        ["pnpm", "exec", "next", "dev", "--port", str(web_port)],
        cwd=WEB,
        env={
            **env,
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
            "NEXT_DIST_DIR": ".next-drive-settings-e2e",
        },
        stdout=logs[1],
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 60)
        base = f"http://127.0.0.1:{web_port}"
        _wait_http(base + "/login", 120)
        yield {
            "base": base,
            "api_base": f"http://127.0.0.1:{api_port}",
            "root": root,
            "data": data,
            "database_url": env["DATABASE_URL"],
        }
    finally:
        for process in (web, api):
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
        for process in (web, api):
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        for log in logs:
            log.close()


@pytest.mark.parametrize(
    "theme_id,width",
    [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)],
    ids=["silver-1280", "silver-320", "netflix-1280", "netflix-320"],
)
def test_drive_settings_and_cloud_folder_selection(stack, browser, drive_http, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    bootstrap = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not bootstrap.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/drive-settings"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def get_account(account_id):
        return next(row for row in api("get", "/drives/accounts") if row["id"] == account_id)

    def shot(name):
        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(node => node.click())")
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        assert page.locator("main button").evaluate_all(
            "buttons => buttons.every(button => { const r = button.getBoundingClientRect(); "
            "return !r.width || !r.height || (r.left >= -0.5 && r.right <= innerWidth + 0.5); })"
        ), "A drive settings action is clipped"
        _snapshot(page, shots / name)

    def change_language(value):
        current = page.locator("html").get_attribute("lang")
        page.get_by_role(
            "button",
            name="Appearance and language" if current == "en" else "外观与语言",
            exact=True,
        ).click()
        page.get_by_test_id("language-settings").locator(f'input[value="{value}"]').check()
        expect(page.locator("html")).to_have_attribute("lang", value)
        expect(page.get_by_test_id("language-settings")).to_be_enabled()
        target = page.get_by_role(
            "button", name="Cloud drives" if value == "en" else "网盘", exact=True
        )
        try:
            target.click()
        except Exception:
            print(page.locator("body").inner_text())
            raise
        expect(
            page.get_by_role(
                "heading", name="Cloud drives" if value == "en" else "网盘", exact=True
            )
        ).to_be_visible()

    def updated(action):
        with page.expect_response(
            lambda response: (
                "/api/v1/drives/accounts/" in response.url and response.request.method == "PATCH"
            )
        ) as saved:
            action()
        assert saved.value.ok, saved.value.text()

    for account in api("get", "/drives/accounts"):
        api("delete", f"/drives/accounts/{account['id']}")
    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": width, "height": 1000})
    page.goto(base + "/settings/drives")
    expect(page.get_by_text("No cloud drive accounts yet", exact=True)).to_be_visible()
    shot(f"{theme_id}-{width}-empty.png")
    drive_http[1].mode = "pending"
    page.get_by_role("button", name="Add cloud drive account", exact=True).click()
    login = page.get_by_role("dialog", name="Add Fixture Drive account", exact=True)
    expect(login.get_by_alt_text("Fixture Drive sign-in QR code")).to_be_visible()
    login.locator("select").select_option("web")
    expect(login.get_by_text("Shares the browser sign-in", exact=True)).to_be_visible()
    drive_http[1].mode = "expired"
    expect(login.get_by_text("Sign-in incomplete", exact=True)).to_be_visible()
    expect(login.get_by_text("Upstream QR expired", exact=True)).to_be_visible()
    shot(f"{theme_id}-{width}-scan-expired.png")
    drive_http[1].mode = "pending"
    login.get_by_role("button", name="Scan a new code", exact=True).click()
    expect(login.get_by_alt_text("Fixture Drive sign-in QR code")).to_be_visible()
    drive_http[1].mode = "confirmed"
    expect(login).not_to_be_visible()
    expect(page.get_by_text("Original account", exact=True)).to_be_visible()
    [account] = api("get", "/drives/accounts")
    account_id = account["id"]
    card = page.get_by_test_id(f"drive-account-{account_id}")
    card.get_by_role("button", name="Adjust", exact=True).click()
    slots = card.get_by_role("spinbutton", name="Concurrent streams", exact=True)
    slots.fill("11")
    expect(card.get_by_role("button", name="Save", exact=True)).to_be_disabled()
    shot(f"{theme_id}-{width}-slots.png")
    slots.fill("3")
    updated(lambda card=card: card.get_by_role("button", name="Save", exact=True).click())
    assert get_account(account_id)["read_slots"] == 3
    card.get_by_role("button", name=re.compile("^Advanced")).click()
    limits = card.locator('input[type="number"]')
    limits.nth(0).fill("0")
    expect(card.get_by_text("Request rate must be between 0.1 and 20", exact=True)).to_be_visible()
    limits.nth(0).fill("10")
    limits.nth(1).fill("1000")
    updated(lambda card=card: card.get_by_role("button", name="Save", exact=True).click())
    actual = get_account(account_id)
    assert actual["qps"] == 10 and actual["daily_budget"] == 1000
    shot(f"{theme_id}-{width}-limits.png")
    updated(
        lambda card=card: card.get_by_role(
            "button", name="Restore default", exact=True
        ).first.click()
    )
    assert not get_account(account_id)["qps_custom"]
    card.get_by_role("button", name="More actions for “Original account”", exact=True).click()
    page.get_by_role("menuitem", name="Rename", exact=True).click()
    prompt = page.get_by_role("dialog", name="Account name", exact=True)
    prompt.locator("input").fill("My archive")
    updated(lambda prompt=prompt: prompt.get_by_role("button", name="Confirm", exact=True).click())
    expect(card.get_by_text("My archive", exact=True)).to_be_visible()
    # Existing accounts are updated by real form/cookie login, never duplicated.
    page.get_by_role("button", name="Add cloud drive account", exact=True).click()
    login = page.get_by_role("dialog", name="Add Fixture Drive account", exact=True)
    login.get_by_role("button", name="Enter credentials", exact=True).click()
    expect(login.get_by_label("Client Secret *", exact=True)).to_be_visible()
    login.locator('input[type="text"]').fill("fixture-user")
    login.locator('input[type="password"]').fill("bad-secret")
    login.get_by_role("button", name="Verify and sign in", exact=True).click()
    expect(
        login.get_by_text(
            "Fixture Drive rejected these credentials: Invalid fixture credentials", exact=True
        )
    ).to_be_visible()
    shot(f"{theme_id}-{width}-form-error.png")
    login.locator('input[type="password"]').fill("fixture-secret")
    login.get_by_role("button", name="Verify and sign in", exact=True).click()
    expect(login).not_to_be_visible()
    [actual] = api("get", "/drives/accounts")
    assert (
        actual["id"] == account_id
        and actual["name"] == "My archive"
        and actual["login_method"] == "form"
    )
    page.get_by_role("button", name="Add cloud drive account", exact=True).click()
    login = page.get_by_role("dialog", name="Add Fixture Drive account", exact=True)
    login.get_by_role("button", name="Use browser extension", exact=True).click()
    login.get_by_role("button", name="Extension unavailable? Paste cookies", exact=True).click()
    login.locator("textarea").fill("session=good")
    shot(f"{theme_id}-{width}-cookie.png")
    login.get_by_role("button", name="Sign in", exact=True).click()
    expect(login).not_to_be_visible()
    [actual] = api("get", "/drives/accounts")
    assert (
        actual["id"] == account_id
        and actual["login_method"] == "cookie"
        and actual["login_detail"] == "Web sign-in"
    )
    with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
        original = db.execute(
            "SELECT credentials,login_detail FROM drive_account WHERE id=?", (account_id,)
        ).fetchone()
    assert original[0].startswith("enc::") and "fixture-secret-token" not in original[0]
    assert original[1] == "网页端"
    if width == 1280:
        page.evaluate("window.__driveLanguageDocument = true")
        change_language("zh-Hans")
        expect(page.get_by_text("浏览器导入 · 网页端", exact=False)).to_be_visible()
        change_language("en")
        assert page.evaluate("window.__driveLanguageDocument")
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            assert (
                db.execute(
                    "SELECT credentials,login_detail FROM drive_account WHERE id=?",
                    (account_id,),
                ).fetchone()
                == original
            )
    shot(f"{theme_id}-{width}-account.png")
    toggle = page.get_by_role(
        "switch", name="Delete download tasks after releasing local space", exact=True
    )
    with page.expect_response(
        lambda response: (
            response.url.endswith("/api/v1/drives/settings") and response.request.method == "PUT"
        )
    ):
        toggle.click()
    assert api("get", "/drives/settings")["remove_download_tasks"] == toggle.is_checked()
    card.get_by_role("button", name="More actions for “My archive”", exact=True).click()
    page.get_by_role("menuitem", name="Remove account", exact=True).click()
    confirm = page.get_by_role("dialog").filter(
        has=page.get_by_role("button", name="Remove", exact=True)
    )
    confirm.get_by_role("button", name="Cancel", exact=True).click()
    assert len(api("get", "/drives/accounts")) == 1
    card.get_by_role("button", name="More actions for “My archive”", exact=True).click()
    page.get_by_role("menuitem", name="Remove account", exact=True).click()
    with page.expect_response(
        lambda response, account_id=account_id: (
            response.url.endswith(f"/api/v1/drives/accounts/{account_id}")
            and response.request.method == "DELETE"
        )
    ):
        page.get_by_role("dialog").get_by_role("button", name="Remove", exact=True).click()
    expect(page.get_by_text("No cloud drive accounts yet", exact=True)).to_be_visible()
    assert not errors, errors
    assert all(path not in {"/delete", "/upload"} for path, _ in drive_http[1].requests)
    context.close()


def test_cloud_folder_picker_persists_selection_and_rejects_overlap(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 320, "height": 1000})
    bootstrap = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not bootstrap.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    prefs = api("get", "/ui/preferences")
    prefs.update(theme="netflix", theme_mobile="netflix", theme_desktop="netflix", language="en")
    api("put", "/ui/preferences", data=prefs)
    account = api(
        "post", "/drives/accounts/cookie", data={"backend": "fixture", "cookie": "session=good"}
    )["account"]
    root = stack["data"] / "occupied-staging"
    free_root = stack["data"] / "free-staging"
    root.mkdir()
    free_root.mkdir()
    sentinel = free_root / ".keep"
    sentinel.write_bytes(b"local staging is kept")
    occupied = api(
        "post",
        "/libraries",
        data={
            "name": "Occupied library",
            "kind": "movie",
            "root_paths": [str(root)],
            "realtime_watch": False,
            "cloud_folders": [
                {
                    "account_id": account["id"],
                    "remote_dir_id": "films",
                    "display_path": "Media/Films",
                    "is_primary": False,
                }
            ],
        },
    )
    page = context.new_page()
    page.set_default_timeout(25000)
    page.goto(base + "/library/manage")
    expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    page.get_by_role("button", name="Create library", exact=True).click()
    form = page.get_by_role("dialog", name="Add library", exact=True)
    form.get_by_role("button", name=re.compile("^Movie")).click()
    form.get_by_placeholder("e.g. Movies / Animation").fill("Cloud archive")
    form.get_by_role("button", name="Browse and add a server folder", exact=True).click()
    server_picker = page.get_by_role("dialog", name="Choose a server folder", exact=True)
    expect(
        server_picker.get_by_role("button", name="Choose this folder", exact=True)
    ).to_be_enabled()
    server_picker.get_by_title("Enter path manually", exact=True).click()
    field = server_picker.get_by_placeholder("Enter an absolute path and press Enter")
    field.fill(str(free_root))
    field.press("Enter")
    expect(server_picker.locator("p[title]")).to_have_attribute("title", str(free_root.resolve()))
    try:
        server_picker.get_by_role("button", name="Choose this folder", exact=True).click()
    except Exception:
        print(page.locator("body").inner_text())
        _snapshot(page, REPO / ".tmp-uidev/i18n/drive-settings/folder-error.png")
        raise
    form.get_by_role("button", name="Fixture Drive folders", exact=True).click()
    picker = page.get_by_role("dialog", name="Choose a cloud drive folder", exact=True)
    expect(picker.get_by_role("button", name="Choose this folder", exact=True)).to_be_disabled()
    picker.get_by_role("button", name=re.compile("^Media")).click()
    picker.get_by_role("button", name=re.compile("^Films")).click()
    expect(picker.get_by_text("Already in library “Occupied library”", exact=True)).to_be_visible()
    expect(picker.get_by_role("button", name="Choose this folder", exact=True)).to_be_disabled()
    _snapshot(page, REPO / ".tmp-uidev/i18n/drive-settings/netflix-320-folder-occupied.png")
    picker.get_by_role("button", name="Original account", exact=True).click()
    picker.get_by_role("button", name=re.compile("^Archive")).click()
    expect(
        picker.get_by_text("No subfolders here. You can choose this folder.", exact=True)
    ).to_be_visible()
    picker.get_by_role("button", name="Choose this folder", exact=True).click()
    expect(picker).not_to_be_visible()
    form.get_by_role("button", name="Fixture Drive folders", exact=True).click()
    picker.get_by_role("button", name=re.compile("^Archive")).click()
    expect(
        picker.get_by_text("Overlaps with a cloud folder already added", exact=True)
    ).to_be_visible()
    expect(picker.get_by_role("button", name="Choose this folder", exact=True)).to_be_disabled()
    _snapshot(page, REPO / ".tmp-uidev/i18n/drive-settings/netflix-320-folder-duplicate.png")
    picker.get_by_role("button", name="Cancel", exact=True).click()
    form.get_by_role("button", name="Next: collection scope", exact=True).click()
    form.get_by_role("button", name="Skip, create and start scan", exact=True).click()
    expect(form).not_to_be_visible()
    library = next(row for row in api("get", "/libraries") if row["name"] == "Cloud archive")
    [folder] = library["cloud_folders"]
    assert (
        folder["account_id"] == account["id"]
        and folder["remote_dir_id"] == "free"
        and folder["display_path"] == "Archive"
    )
    blocked = context.request.delete(
        base + f"/api/v1/drives/accounts/{account['id']}", headers={"Accept-Language": "en"}
    )
    assert blocked.status == 409
    assert (
        "Occupied library" in blocked.json()["message"]
        and "Cloud archive" in blocked.json()["message"]
    )
    assert "still use this account’s cloud drive folders" in blocked.json()["message"]
    for row in (occupied, library):
        api("delete", f"/libraries/{row['id']}")
    api("delete", f"/drives/accounts/{account['id']}")
    assert sentinel.read_bytes() == b"local staging is kept"
    context.close()
