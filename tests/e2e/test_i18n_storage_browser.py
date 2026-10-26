"""Real cached storage snapshots, cleanup requests, SQLite membership and file protection."""

import os
import re
import signal
import subprocess
import sys
import time
from contextlib import suppress

import pytest

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import REPO, WEB, _free_port, _wait_http

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    from movieclaw_api.core.config import Settings

    root = tmp_path_factory.mktemp("storage-browser")
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
        "web_port_file": "config/web-port",
    }
    env = {
        **os.environ,
        **{Settings.model_fields[key].alias: str(data / value) for key, value in paths.items()},
        "DATABASE_URL": f"sqlite+aiosqlite:///{data / 'movieclaw.db'}",
        "SCHEDULER_ENABLED": "false",
        "PYTHONPATH": f"{REPO / 'src'}:{REPO}",
    }
    api_port, web_port = _free_port(), _free_port()
    logs = [(root / name).open("w") for name in ("api.log", "web.log")]
    api = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._smart_api_launcher:app",
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
            "NEXT_DIST_DIR": ".next-storage-e2e",
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


async def _seed(database_url, path):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import Library, LibraryFile, MediaItem

    path.parent.mkdir()
    path.write_bytes(b"original movie; cleanup must preserve this")
    database = Database(database_url)
    try:
        async with database.session() as session:
            library = Library(name="Raw library", kind="movie", root_paths=[str(path.parent)])
            item = MediaItem(kind="movie", tmdb_id=991441, title="Raw movie", original_title="Raw")
            session.add(library)
            session.add(item)
            await session.flush()
            file = LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                file_path=str(path),
                size_bytes=path.stat().st_size,
                source="scanned",
            )
            session.add(file)
            await session.commit()
            return file.id
    finally:
        await database.dispose()


def test_storage_confirmation_cleanup_and_reader_language(stack, browser):
    from playwright.sync_api import expect

    base, data = stack["base"], stack["data"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    movie = stack["root"] / "library/movie.mkv"
    file_id = _run(_seed(stack["database_url"], movie))
    original = movie.read_bytes()
    source = data / "cache/playback-trickplay"
    keep, orphan = source / str(file_id) / "sprite.jpg", source / "999999" / "sprite.jpg"
    busy, unknown = source / ".pending.part" / "sprite.jpg", source / "notes.txt"
    stray = data / "unregistered/raw-user-name"
    stray.parent.mkdir()
    stray.write_bytes(b"user data must remain")
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/storage"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def usage(refresh=False):
        state = api("get", "/app/storage" + ("?refresh=1" if refresh else ""))
        deadline = time.monotonic() + 10
        while state["computing"] or state["usage"] is None:
            assert time.monotonic() < deadline
            time.sleep(0.05)
            state = api("get", "/app/storage")
        return state["usage"]

    def open_clean(action):
        for toast in page.locator(".toast-item").all():
            toast.click()
        page.get_by_role("button", name="Cleanup actions for Seek preview thumbnails").click()
        page.get_by_role("menuitem", name=action, exact=True).click()
        dialog = page.get_by_role("dialog")
        dialog.wait_for()
        page.wait_for_function("""() => [...document.querySelectorAll('.modal-panel')].every(
            el => el.getAnimations().every(a => a.playState === 'finished'))""")
        for button in dialog.get_by_role("button").all():
            box = button.bounding_box()
            if button.get_attribute("aria-label") == "Close":
                continue
            assert box and box["x"] >= 0 and box["x"] + box["width"] <= page.viewport_size["width"]
            assert box["y"] >= 0 and box["y"] + box["height"] <= page.viewport_size["height"]
        return dialog

    def english():
        text = page.locator("main").inner_text()
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        label = page.get_by_text("Seek preview thumbnails", exact=True)
        assert label.bounding_box()["width"] >= 120

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        for path, content in (
            (keep, b"keep"),
            (orphan, b"orphan"),
            (busy, b"busy"),
            (unknown, b"notes"),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        before = usage(True)
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/app?tab=storage")
        expect(
            page.get_by_role("button", name="Cleanup actions for Seek preview thumbnails")
        ).to_be_visible()
        page.wait_for_function(
            "theme => (document.documentElement.dataset.theme || 'silver') === theme", arg=theme_id
        )
        english()
        _snapshot(page, shots / f"{theme_id}-{width}-overview-en.png")
        info = page.get_by_role("button", name="About Seek preview thumbnails", exact=True)
        info.scroll_into_view_if_needed()
        info.click()
        expect(page.get_by_text(re.compile("^Thumbnails displayed when seeking"))).to_be_visible()
        page.wait_for_function("""() => [...document.querySelectorAll('.tooltip-bubble')].some(
            el => getComputedStyle(el).opacity === '1')""")
        _snapshot(page, shots / f"{theme_id}-{width}-description-en.png")
        page.keyboard.press("Escape")
        dialog = open_clean("Clean orphan entries")
        expect(dialog).to_contain_text("Content in use is unaffected")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        assert orphan.read_bytes() == b"orphan" and keep.read_bytes() == b"keep"
        assert usage()["computed_at"] == before["computed_at"]
        dialog = open_clean("Clean orphan entries")
        _snapshot(page, shots / f"{theme_id}-{width}-orphans-en.png")
        with page.expect_response(
            lambda r: r.request.method == "POST" and "/storage/" in r.url
        ) as cleaned:
            dialog.get_by_role("button", name="Clean orphan entries", exact=True).click()
        result = cleaned.value.json()["data"]
        assert result == {
            "key": "cache.trickplay",
            "mode": "orphans",
            "removed": 1,
            "skipped_busy": 1,
            "freed_bytes": 6,
        }
        expect(
            page.get_by_text("Freed 6 B; removed 1 entry; skipped 1 entry in use", exact=True)
        ).to_be_visible()
        assert not orphan.exists()
        assert keep.read_bytes() == b"keep" and unknown.read_bytes() == b"notes"
        assert busy.read_bytes() == b"busy"
        usage()
        dialog = open_clean("Clear all")
        expect(dialog).to_contain_text("Recreating them requires reading the entire video")
        confirm = dialog.get_by_role("button", name=re.compile("^Clear and free"))
        assert "red-500" in confirm.get_attribute("class")
        _snapshot(page, shots / f"{theme_id}-{width}-clear-en.png")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        assert keep.exists() and unknown.exists()
        dialog = open_clean("Clear all")
        with page.expect_response(
            lambda r: r.request.method == "POST" and "/storage/" in r.url
        ) as cleaned:
            dialog.get_by_role("button", name=re.compile("^Clear and free")).click()
        result = cleaned.value.json()["data"]
        assert (result["removed"], result["freed_bytes"], result["skipped_busy"]) == (2, 9, 1)
        assert not keep.exists() and not unknown.exists()
        assert busy.read_bytes() == b"busy" and movie.read_bytes() == original
        assert stray.read_bytes() == b"user data must remain"
        page.get_by_role("button", name="Refresh", exact=True).click()
        expect(page.get_by_role("button", name="Refresh", exact=True)).to_be_enabled()
        english()
    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/library")
    page.evaluate("window.__storageLanguageDocument = true")
    before = usage()
    _change_language(page, "zh-Hans")
    assert page.evaluate("window.__storageLanguageDocument")
    page.goto(base + "/settings/app?tab=storage")
    expect(page.get_by_role("button", name="「进度条预览图」的清理操作")).to_be_visible()
    after = usage()
    assert before["computed_at"] == after["computed_at"]
    assert before["cache_bytes"] == after["cache_bytes"]
    _snapshot(page, shots / "storage-zh.png")
    page.goto(base + "/library")
    page.evaluate("window.__storageLanguageDocument = true")
    _change_language(page, "en")
    assert page.evaluate("window.__storageLanguageDocument")
    page.goto(base + "/settings/app?tab=storage")
    expect(
        page.get_by_role("button", name="Cleanup actions for Seek preview thumbnails")
    ).to_be_visible()
    english()
    assert movie.read_bytes() == original and busy.read_bytes() == b"busy"
    assert not errors, errors
    context.close()
