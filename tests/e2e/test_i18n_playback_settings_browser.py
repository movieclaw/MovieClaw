"""Playback preferences with real HTTP/SQLite, a WebSocket worker and disposable MP4 clips."""

import hashlib
import json
import re
import sqlite3
import subprocess
import time
from pathlib import Path

import pytest
from websockets.sync.client import connect

from . import test_i18n_drive_settings_browser as drives
from . import test_theme_device_class_browser as theme
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = drives.browser
search_provider = drives.search_provider
drive_http = drives.drive_http
stack = drives.stack


def wait_for(check):
    deadline = time.monotonic() + 30
    while True:
        value = check()
        if value:
            return value
        assert time.monotonic() < deadline
        time.sleep(0.1)


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_playback_controls_and_worker_lifecycle(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    from movieclaw_api.services.playback.remote_worker import REMOTE_WORKER_PROTOCOL_VERSION

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(
        locale="en-US",
        viewport={"width": width, "height": 1000},
        is_mobile=width == 320,
        has_touch=width == 320,
    )
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    preferences = api("get", "/ui/preferences")
    preferences.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=preferences)
    api("delete", "/tips/state")
    api(
        "put",
        "/playback/policy",
        data={
            "reel_clips_enabled": False,
            "trickplay_enabled": True,
            "transcode_cache_enabled": True,
            "cloud_stream_mode": "auto",
        },
    )
    api("put", "/transcode-worker/config", data={"enabled": False, "base_url": ""})
    account = api(
        "post", "/drives/accounts/cookie", data={"backend": "fixture", "cookie": "session=good"}
    )["account"]
    folder = stack["data"] / f"playback-{theme_id}-{width}"
    folder.mkdir()
    library = api(
        "post",
        "/libraries",
        data={
            "name": f"Fixture {theme_id} {width}",
            "kind": "movie",
            "root_paths": [str(folder)],
            "realtime_watch": False,
        },
    )
    wait_for(
        lambda: any(
            row["id"] == library["id"] and not row["scanning"] and row["last_scan"]
            for row in api("get", "/libraries")
        )
    )
    original = folder / "Fixture.mp4"
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=blue:s=160x90:r=10",
            "-t",
            "8",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            str(original),
        ],
        check=True,
    )
    original_hash = hashlib.sha256(original.read_bytes()).hexdigest()
    receipt = context.request.post(
        base + "/api/v1/__lab/playback/clip",
        data={"library_id": library["id"], "path": str(original)},
    )
    assert receipt.ok, receipt.text()
    clip = Path(receipt.json()["path"])
    assert clip.read_bytes() == original.read_bytes()
    sentinel = stack["data"] / f"keep-{theme_id}-{width}.txt"
    sentinel.write_text("Keep outside the clip cache")
    api("post", "/tips/events/reels.played-without-clips")
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/library")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(
        page.get_by_text("Prepare clips for smoother trailers and reels", exact=True)
    ).to_be_visible()
    expect(page.get_by_role("button", name="Dismiss tip", exact=True)).to_be_visible()
    page.get_by_role("button", name="Turn it on", exact=True).click()
    expect(page).to_have_url(re.compile("/settings/playback$"))
    shots = REPO / ".tmp-uidev/i18n/playback-settings"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(label, target=None):
        if target is not None:
            target.evaluate("node => node.scrollIntoView({block: 'center'})")
        page.locator(".toast-item").evaluate_all("nodes=>nodes.forEach(node=>node.click())")
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        assert page.locator("main button, main select, main input").evaluate_all(
            "nodes => nodes.every(node => { const r = node.getBoundingClientRect(); "
            "return !r.width || !r.height || (r.left >= -0.5 && r.right <= innerWidth + 0.5); })"
        ), "A playback settings control extends beyond the viewport"
        page.screenshot(path=str(shots / f"{theme_id}-{width}-{label}.png"), animations="disabled")

    def saved(action, path):
        with page.expect_response(
            lambda r: r.url.endswith("/api/v1" + path) and r.request.method == "PUT"
        ) as pending:
            action()
        assert pending.value.ok, pending.value.text()
        return pending.value.json()["data"]

    def toggle(name, field):
        control = page.get_by_role("switch", name=name, exact=True)
        before = api("get", "/playback/policy")[field]
        saved(control.click, "/playback/policy")
        expect(control).to_be_checked(checked=not before)
        assert api("get", "/playback/policy")[field] == (not before)

    toggle("Generate timeline previews", "trickplay_enabled")
    toggle("Generate timeline previews", "trickplay_enabled")
    toggle("Keep transcoded files for resume and replay", "transcode_cache_enabled")
    toggle("Keep transcoded files for resume and replay", "transcode_cache_enabled")
    toggle("Prepare clips", "reel_clips_enabled")
    expect(
        page.get_by_text("1 title is ready. New titles are processed automatically.", exact=True)
    ).to_be_visible()
    prepare = page.get_by_role("switch", name="Prepare clips", exact=True)
    prepare.click()
    expect(
        page.get_by_role("heading", name="Turn off clip preparation?", exact=True)
    ).to_be_visible()
    checkbox = page.get_by_role("checkbox", name=re.compile("^Also delete 1 prepared clip"))
    expect(checkbox).not_to_be_checked()
    shot("clip-confirm")
    page.get_by_role("button", name="Cancel", exact=True).click()
    assert api("get", "/playback/policy")["reel_clips_enabled"] and clip.is_file()
    prepare.click()
    saved(
        lambda: page.get_by_role("button", name="Turn off", exact=True).click(), "/playback/policy"
    )
    assert not api("get", "/playback/policy")["reel_clips_enabled"] and clip.is_file()
    toggle("Prepare clips", "reel_clips_enabled")
    prepare.click()
    checkbox.check()
    with page.expect_response(
        lambda r: r.url.endswith("/api/v1/reels/clips") and r.request.method == "DELETE"
    ) as deleted:
        saved(
            lambda: page.get_by_role("button", name="Turn off", exact=True).click(),
            "/playback/policy",
        )
    assert deleted.value.ok, deleted.value.text()
    assert deleted.value.json()["data"]["count"] == 1
    assert not clip.exists() and api("get", "/reels/clips/stats")["count"] == 0
    assert hashlib.sha256(original.read_bytes()).hexdigest() == original_hash
    assert sentinel.read_text() == "Keep outside the clip cache"
    for title, value in [
        ("Always relay through home", "relay"),
        ("Always connect directly to the cloud drive", "direct"),
        ("Automatic (recommended)", "auto"),
    ]:
        radio = page.get_by_role("radio", name=re.compile("^" + re.escape(title)))
        saved(radio.click, "/playback/policy")
        expect(radio).to_be_checked()
        assert api("get", "/playback/policy")["cloud_stream_mode"] == value
    shot("cloud-policy", page.get_by_role("radiogroup"))
    remote = page.get_by_role("switch", name="Enable remote hardware transcoding", exact=True)
    saved(remote.click, "/transcode-worker/config")
    expect(
        page.get_by_text("Configuration is ready. No worker is connected yet.", exact=True)
    ).to_be_visible()
    existing_workers = [
        row
        for row in api("get", "/auth/devices", params={"all": "true"})
        if row["scope"] == "transcode"
    ]
    if not existing_workers:
        expect(page.get_by_text("No workers connected yet", exact=True)).to_be_visible()
    else:
        expect(page.get_by_text(existing_workers[0]["name"], exact=True)).to_be_visible()

    def grant(name):
        authorized = api(
            "post", "/auth/device/authorize", data={"client_type": "worker", "client_name": name}
        )
        api("post", f"/auth/devices/requests/{authorized['user_code']}/approve")
        return api("post", "/auth/device/token", data={"device_code": authorized["device_code"]})[
            "token"
        ]

    worker_name = f"author-{theme_id}-{width}"
    token = grant(worker_name)
    offline_name = f"offline-{theme_id}-{width}"
    grant(offline_name)
    ws_url = stack["api_base"].replace("http://", "ws://") + "/api/v1/transcode-worker/ws"
    with connect(ws_url, additional_headers={"Authorization": f"Bearer {token}"}) as worker:
        worker.send(
            json.dumps(
                {
                    "type": "worker.hello",
                    "protocol_version": REMOTE_WORKER_PROTOCOL_VERSION,
                    "worker_id": worker_name,
                    "worker_version": "fixture-1",
                    "capabilities": {
                        "platform": "macOS",
                        "arch": "arm64",
                        "backends": ["videotoolbox"],
                        "max_jobs": 2,
                        "server_config": True,
                        "hardware": {"chip": "M4", "cpu_cores": 10, "memory_bytes": 17179869184},
                    },
                }
            )
        )
        accepted = json.loads(worker.recv(timeout=10))
        assert accepted["type"] == "worker.accepted"
        worker.send(
            json.dumps(
                {
                    "type": "worker.heartbeat",
                    "load": {"cpu": 0.42, "memory_pressure": 1, "thermal_state": 2},
                }
            )
        )
        assert json.loads(worker.recv(timeout=10))["type"] == "worker.heartbeat.ack"
        expect(page.get_by_text("Ready · 1 worker online", exact=True)).to_be_visible()
        expect(
            page.get_by_text("CPU 42% · Memory pressure: elevated · Cooling down", exact=True)
        ).to_be_visible()
        expect(page.get_by_text(offline_name, exact=True)).to_be_visible()
        limit = page.get_by_role(
            "combobox", name=f"Maximum concurrent jobs for {worker_name}", exact=True
        )
        device_id = next(
            row["device_id"]
            for row in api("get", "/transcode-worker/status")["workers"]
            if row["worker_id"] == worker_name
        )
        saved(lambda: limit.select_option("3"), f"/transcode-worker/devices/{device_id}/config")
        updated = json.loads(worker.recv(timeout=10))
        assert updated == {"type": "worker.config", "max_jobs": 3}
        assert api("get", "/transcode-worker/status")["device_limits"][f"ld-{device_id}"] == 3
        shot("worker-online", limit)
    expect(
        page.get_by_text("Configuration is ready. No worker is connected yet.", exact=True)
    ).to_be_visible()
    expect(page.get_by_text(worker_name, exact=True)).to_be_visible()
    shot("worker-offline", remote)
    saved(remote.click, "/transcode-worker/config")
    address = page.get_by_role("textbox", name="Source and upload address override", exact=True)
    address.fill("invalid-url")
    saved(lambda: address.press("Enter"), "/transcode-worker/config")
    expect(
        page.get_by_text(
            "The remote transcoding override address must begin with http:// or https://. "
            'Current value: "invalid-url"',
            exact=False,
        )
    ).to_be_visible()
    with page.expect_response(
        lambda r: r.url.endswith("/api/v1/transcode-worker/config") and r.request.method == "PUT"
    ) as rejected:
        remote.click()
    assert rejected.value.status == 400
    expect(remote).not_to_be_checked()
    expect(page.get_by_text(re.compile("^Could not enable remote transcoding:"))).to_be_visible()
    shot("invalid-override", remote)
    address.fill("http://unsaved.example")
    address.press("Escape")
    expect(address).to_have_value("invalid-url")
    assert api("get", "/transcode-worker/config")["base_url_override"] == "invalid-url"
    address.fill("")
    saved(lambda: address.press("Enter"), "/transcode-worker/config")
    saved(remote.click, "/transcode-worker/config")
    assert api("get", "/transcode-worker/config")["ready"]
    shot("automatic-address", address)

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
            return database.execute(
                "SELECT namespace,value_json FROM app_setting WHERE namespace IN "
                "('playback.policy','playback.remote_transcode','playback.worker_limits') "
                "ORDER BY namespace"
            ).fetchall()

    before = stored()
    page.evaluate("window.__playbackLocaleDocument = 'same-document'")
    for language in ("zh-Hans", "en"):
        current = page.locator("html").get_attribute("lang")
        if width == 320:
            page.get_by_role(
                "button", name="Back" if current == "en" else "返回", exact=True
            ).click()
            expect(page).to_have_url(base + "/settings")
        page.get_by_role(
            "button",
            name="Appearance and language" if current == "en" else "外观与语言",
            exact=True,
        ).click()
        control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
        control.check()
        expect(control).to_be_enabled()
        expect(page.locator("html")).to_have_attribute("lang", language)
        if width == 320:
            page.get_by_role(
                "button", name="返回" if language == "zh-Hans" else "Back", exact=True
            ).click()
            expect(page).to_have_url(base + "/settings")
        page.get_by_role(
            "button", name="播放" if language == "zh-Hans" else "Playback", exact=True
        ).click()
        assert page.evaluate("window.__playbackLocaleDocument") == "same-document"
        expect(
            page.get_by_role(
                "switch",
                name="启用远程硬件转码"
                if language == "zh-Hans"
                else "Enable remote hardware transcoding",
                exact=True,
            )
        ).to_be_checked()
        expect(page.get_by_text(worker_name, exact=True)).to_be_visible()
        assert stored() == before
    expect(page.get_by_role("button", name="Go to Devices", exact=True)).to_have_count(0)
    page.get_by_role(
        "button", name="Approve new transcoders, review access or revoke it in Devices", exact=True
    ).click()
    expect(page).to_have_url(re.compile("/settings/devices$"))
    page.get_by_role(
        "button", name="View all command-line clients and transcoders", exact=True
    ).click()
    expect(page.get_by_text(worker_name, exact=True)).to_be_visible()
    assert hashlib.sha256(original.read_bytes()).hexdigest() == original_hash
    assert sentinel.is_file()
    assert not errors, errors
    api("delete", f"/libraries/{library['id']}")
    api("delete", f"/drives/accounts/{account['id']}")
    assert hashlib.sha256(original.read_bytes()).hexdigest() == original_hash
    context.close()
