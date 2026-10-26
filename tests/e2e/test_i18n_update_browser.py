"""Real update API, SQLite, local artifact downloads, rollback staging and two browser themes.

GitHub metadata is local fixture data. Process restart requests are recorded at the
boundary; this test does not replace or restart a user's deployed application.
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from movieclaw_api import __version__

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO, WEB, _free_port, _wait_http

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def artifacts():
    class Handler(BaseHTTPRequestHandler):
        paths = []

        def do_GET(self):
            self.paths.append(self.path)
            self.send_response(200)
            self.send_header("Content-Length", "3")
            self.end_headers()
            self.wfile.write(b"bad")  # Real downloaded bytes must fail manifest verification.

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
def stack(tmp_path_factory, artifacts):
    from movieclaw_api.core.config import Settings

    root = tmp_path_factory.mktemp("update-browser")
    data = root / "data"
    data.mkdir()
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
        "models_dir": "models",
        "web_port_file": "config/web-port",
    }
    env = {
        **os.environ,
        **{Settings.model_fields[key].alias: str(data / value) for key, value in paths.items()},
        "DATABASE_URL": f"sqlite+aiosqlite:///{data / 'movieclaw.db'}",
        "SCHEDULER_ENABLED": "false",
        "MOVIECLAW_RUNTIME_VERSION": "1",
        "MOVIECLAW_CODE_SOURCE": "overlay",
        "MOVIECLAW_OVERLAY_VERSION": __version__,
        "UPDATE_DOWNLOAD_MIRROR": artifacts[0],
        "E2E_UPDATE_ROOT": str(root),
        "PYTHONPATH": f"{REPO / 'src'}:{REPO}",
    }
    api_port, web_port = _free_port(), _free_port()
    logs = [(root / name).open("w") for name in ("api.log", "web.log")]
    api = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._update_api_launcher:app",
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
            "NEXT_DIST_DIR": ".next-update-e2e",
        },
        stdout=logs[1],
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 60)
        base = f"http://127.0.0.1:{web_port}"
        _wait_http(base + "/login", 120)
        yield {"base": base, "root": root, "data": data, "database_url": env["DATABASE_URL"]}
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


def test_update_controls_progress_and_rollback_language(stack, browser, artifacts):
    from playwright.sync_api import expect

    base, root, data = stack["base"], stack["root"], stack["data"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/update"
    shots.mkdir(parents=True, exist_ok=True)
    updates = data / "updates"

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def english():
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    def language(value):
        viewport = page.viewport_size
        page.set_viewport_size({"width": 1280, "height": 1000})
        english = page.locator("html").get_attribute("lang") == "en"
        page.get_by_role(
            "button", name="Appearance and language" if english else "外观与语言", exact=True
        ).click()
        page.get_by_test_id("language-settings").locator(f'input[value="{value}"]').check()
        expect(page.locator("html")).to_have_attribute("lang", value)
        page.get_by_role(
            "button",
            name=re.compile("^更新与维护" if value == "zh-Hans" else "^Updates and maintenance"),
        ).click()
        page.set_viewport_size(viewport)

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        assert context.request.post(base + "/api/v1/__lab/update/seed").ok
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/app")
        expect(
            page.get_by_role("heading", name="NER recognition model", exact=True)
        ).to_be_visible()
        expect(page.get_by_text(re.compile("^Installed v0.6.0 is not running"))).to_be_visible()
        expect(
            page.get_by_text(re.compile("The backend process exited unexpectedly"))
        ).to_be_visible()
        english()
        if width == 320:
            label = page.get_by_text("Current version", exact=True).bounding_box()
            button = page.get_by_role("button", name="Check for updates", exact=True).bounding_box()
            assert label["width"] >= 100 and button["y"] > label["y"] + label["height"]
        _snapshot(page, shots / f"{theme_id}-{width}-status-en.png")
        history = (updates / "state/last-exit.json").read_bytes()
        page.evaluate("window.__updateLanguageMarker = 'same-document'")
        language("zh-Hans")
        expect(page.get_by_text(re.compile("后端进程异常退出"))).to_be_visible()
        assert (updates / "state/last-exit.json").read_bytes() == history
        language("en")
        expect(
            page.get_by_text(re.compile("The backend process exited unexpectedly"))
        ).to_be_visible()
        assert page.evaluate("window.__updateLanguageMarker") == "same-document"
        page.get_by_role("button", name="Got it", exact=True).click()
        expect(
            page.get_by_text(re.compile("The backend process exited unexpectedly"))
        ).to_have_count(0)
        assert not (updates / "state/last-exit.json").exists()

        # Password inputs expose a label rather than the textbox role.
        token = page.get_by_label("GitHub access token", exact=True)
        token.fill("ghp_fixture_secret_1234")
        page.get_by_role("button", name="Save", exact=True).click()
        expect(page.get_by_text("Configured ****1234", exact=True)).to_be_visible()
        assert api("get", "/app/update/github-token") == {"configured": True, "masked": "****1234"}
        assert token.input_value() == ""
        page.get_by_role("button", name="Clear", exact=True).click()
        expect(page.get_by_text("Not configured", exact=True)).to_be_visible()
        assert not api("get", "/app/update/github-token")["configured"]

        page.get_by_role("button", name="Choose a version…", exact=True).click()
        dialog = page.get_by_role("dialog", name="Choose rollback version", exact=True)
        for version, summary, detail in [
            ("0.4.0", "Switch directly; data retained", "retain all data unchanged"),
            (
                "0.3.0",
                "Restore the data backup",
                "later data, including subscription activity and library records, will be lost",
            ),
            ("0.2.0", "No matching data backup", "Startup failures trigger an automatic fallback"),
        ]:
            choice = dialog.get_by_role("button", name=re.compile("^v" + re.escape(version) + " "))
            expect(choice).to_contain_text(summary)
            choice.click()
            expect(dialog).to_contain_text(detail)
            english()
            _snapshot(page, shots / f"{theme_id}-{width}-rollback-{version}-en.png")
            confirmation = dialog.get_by_role("button", name=re.compile("^Roll back to"))
            assert confirmation.evaluate("node => node.scrollWidth <= node.clientWidth")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        assert (updates / "current").resolve().name == "v0.6.0"
        assert not (root / "restart-requests.jsonl").exists()
        page.get_by_role("button", name="Retain more versions", exact=True).click()
        expect(page.get_by_role("button", name="Retain more versions", exact=True)).to_be_enabled()
        assert api("get", "/app/update/rollback/options")["keep_versions"] == 6
        page.get_by_role("button", name="Retain fewer versions", exact=True).click()
        expect(page.get_by_role("button", name="Retain fewer versions", exact=True)).to_be_enabled()
        assert api("get", "/app/update/rollback/options")["keep_versions"] == 5

        page.get_by_role("button", name="Check for model updates", exact=True).click()
        expect(
            page.get_by_text(re.compile("^New model torrent-ner-v999 is available"))
        ).to_be_visible()
        assert page.get_by_role("button", name="Update model", exact=True).count() == 0
        (updates / "state/bad-9.9.9").touch()
        (root / "github.json").write_text(json.dumps({"version": "9.9.9", "runtime": 9}))
        page.get_by_role("button", name="Check for updates", exact=True).click()
        expect(
            page.get_by_text(
                "This update changes dependencies. Pull the new Docker image to upgrade.",
                exact=True,
            )
        ).to_be_visible()
        assert page.get_by_role("button", name="Update now", exact=True).count() == 0
        (root / "github.json").write_text(json.dumps({"version": "9.9.9", "runtime": 1}))
        page.get_by_role("button", name="Check for updates", exact=True).click()
        expect(page.get_by_role("button", name="Update now", exact=True)).to_be_visible()
        expect(page.get_by_text(re.compile("^Warning: v9.9.9 previously failed"))).to_be_visible()
        page.get_by_role("button", name="Update now", exact=True).click()
        expect(
            page.get_by_text(re.compile("checksum for app-backend.tar.gz does not match"))
        ).to_be_visible()
        assert (updates / "current").resolve().name == "v0.6.0"
        assert not (root / "restart-requests.jsonl").exists()
        assert any(path.endswith("/app-backend.tar.gz") for path in artifacts[1].paths)
        failed = api("get", "/app/update/progress")
        assert failed["phase"] == "failed" and failed["target_version"] == "9.9.9"
        language("zh-Hans")
        expect(page.get_by_text(re.compile("app-backend.tar.gz 的校验和不匹配"))).to_be_visible()
        language("en")
        expect(
            page.get_by_text(re.compile("checksum for app-backend.tar.gz does not match"))
        ).to_be_visible()
        english()
        failure = page.get_by_text(re.compile("checksum for app-backend.tar.gz does not match"))
        failure.scroll_into_view_if_needed()
        assert failure.evaluate(
            "node => node.scrollWidth <= node.clientWidth "
            "&& getComputedStyle(node).textOverflow !== 'ellipsis'"
        )
        _snapshot(page, shots / f"{theme_id}-{width}-download-failed-en.png")
        page.get_by_role("button", name="Restart app", exact=True).click()
        dialog = page.get_by_role("dialog")
        expect(dialog).to_contain_text("The service will be briefly unavailable")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        assert not (root / "restart-requests.jsonl").exists()

    # Confirm a data-preserving target. The real service writes version pointers and an online
    # SQLite backup; only the process-exit boundary is recorded by the isolated fixture.
    page.get_by_role("button", name="Choose a version…", exact=True).click()
    dialog = page.get_by_role("dialog", name="Choose rollback version", exact=True)
    dialog.get_by_role("button", name=re.compile(r"^v0\.4\.0 ")).click()
    dialog.get_by_role("button", name="Roll back to v0.4.0 and restart", exact=True).click()
    expect(page.get_by_text("Restarting and switching versions…", exact=True)).to_be_visible()
    assert (updates / "current").resolve().name == "v0.4.0"
    assert (updates / "previous").resolve().name == "v" + __version__
    assert json.loads((root / "restart-requests.jsonl").read_text().strip()) == {"code": 43}
    assert list((updates / "backup").glob("movieclaw-v" + __version__ + "-*.db"))
    english()
    _snapshot(page, shots / "rollback-waiting-en.png")
    assert not errors, errors
    context.close()
