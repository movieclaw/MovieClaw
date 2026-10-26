"""Automatic import settings, real filesystem safety and file identity through Next/API/SQLite."""

import hashlib
import re
import sqlite3
import subprocess
import time

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
def stack(tmp_path_factory, search_provider, downloader_http):  # noqa: F811
    yield from ai.stack.__wrapped__(tmp_path_factory, search_provider)


@pytest.mark.parametrize(
    "theme_id,width",
    [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)],
    ids=["silver-1280", "silver-320", "netflix-1280", "netflix-320"],
)
def test_automatic_import_rule_configuration(stack, browser, theme_id, width, downloader_http):  # noqa: F811
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    bootstrap = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not bootstrap.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    assert context.request.post(base + "/api/v1/__lab/import-watch/tick").ok
    for rule in api("get", "/import-watch"):
        api("delete", f"/import-watch/{rule['id']}")
    for existing_library in api("get", "/libraries"):
        api("delete", f"/libraries/{existing_library['id']}")
    root = stack["root"] / f"{theme_id}-{width}"
    source, destination, custom = [root / name for name in ["Downloads", "Library", "Organized"]]
    for folder in (source, destination, custom):
        folder.mkdir(parents=True)
    old_file = source / "Existing.mkv"
    old_file.write_bytes(b"existing download preserved")
    for downloader in api("get", "/downloaders"):
        api("delete", f"/downloaders/{downloader['id']}")
    client = api(
        "post",
        "/downloaders",
        data={
            "name": "Fixture qB",
            "client_type": "qbittorrent",
            "url": downloader_http[0],
            "username": "fixture",
            "password": "fixture-pass",
            "path_mappings": [{"local": str(source), "remote": "/downloads"}],
        },
    )
    for _ in range(200):
        if api("get", f"/downloaders/{client['id']}")["status"] == "active":
            break
        time.sleep(0.1)
    assert api("get", f"/downloaders/{client['id']}")["status"] == "active"
    library = api(
        "post",
        "/libraries",
        data={
            "name": f"Original {theme_id} {width}",
            "kind": "video",
            "root_paths": [str(destination)],
            "realtime_watch": False,
        },
    )
    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/import-watch")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_text("No automatic import rules yet", exact=True)).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/import-watch"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name):
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def language(value):
        current = page.locator("html").get_attribute("lang")
        page.get_by_role(
            "button",
            name="Appearance and language" if current == "en" else "外观与语言",
            exact=True,
        ).click()
        page.get_by_test_id("language-settings").locator(f'input[value="{value}"]').check()
        expect(page.locator("html")).to_have_attribute("lang", value)
        expect(page.get_by_test_id("language-settings")).to_be_enabled()
        page.get_by_role(
            "button", name="Automatic import" if value == "en" else "自动入库", exact=True
        ).click()
        expect(
            page.get_by_role(
                "heading",
                name="Automatic import rules" if value == "en" else "自动入库规则",
                exact=True,
            )
        ).to_be_visible()

    def pick(form, label, path):
        form.get_by_role("button", name=str(label)).click()
        picker = page.get_by_role("dialog", name="Choose a server folder", exact=True)
        expect(picker.get_by_role("button", name="Choose this folder", exact=True)).to_be_enabled()
        picker.get_by_title("Enter path manually", exact=True).click()
        field = picker.get_by_placeholder("Enter an absolute path and press Enter")
        field.fill(str(path))
        field.press("Enter")
        expect(picker.locator("p[title]")).to_have_attribute("title", str(path.resolve()))
        expect(picker.locator("p[title]")).to_be_visible()
        _snapshot(page, shots / f"{theme_id}-{width}-server-folder.png")
        picker.get_by_role("button", name="Choose this folder", exact=True).click()
        expect(picker).not_to_be_visible()

    shot("empty")
    page.get_by_role("button", name="Add rule", exact=True).click()
    form = page.get_by_role("dialog", name="Add automatic import rule", exact=True)
    expect(form.get_by_role("button", name="Save", exact=True)).to_be_disabled()
    pick(form, "Browse and choose a server folder…", destination)
    form.get_by_role("button", name=library["name"], exact=True).click()
    form.get_by_role("button", name="Save", exact=True).click()
    expect(form.get_by_text(re.compile("overlap"))).to_be_visible()
    # Reopen the chosen source path, preserving its original filesystem value.
    form.get_by_title(f"{source} (from downloader “Fixture qB”)", exact=True).click()
    form.get_by_role("button", name="Custom folder…", exact=True).click()
    pick(form, "Choose a folder for organized files…", custom)
    form.get_by_role("button", name="Other", exact=True).click()
    form.get_by_role("button", name="Copy", exact=True).click()
    form.get_by_role("button", name="Skip existing files", exact=True).click()
    shot("custom-form")
    form.get_by_role("button", name="Save", exact=True).click()
    expect(form).not_to_be_visible()
    [rule] = api("get", "/import-watch")
    assert (
        rule["target_path"] == str(custom)
        and rule["kind"] == "video"
        and rule["strategy"] == "copy"
        and not rule["process_existing"]
    )
    assert rule["target_label"] == f"Custom folder (Other · {custom})"
    with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
        original = db.execute(
            "SELECT source_path,target_path,kind,strategy,process_existing "
            "FROM import_watch WHERE id=?",
            (rule["id"],),
        ).fetchone()
    reader_cookies = "; ".join(
        cookie["name"] + "=" + cookie["value"]
        for cookie in context.cookies()
        if cookie["name"] != "mc_locale"
    )
    zh = api(
        "get", "/import-watch", headers={"Accept-Language": "zh-Hans", "Cookie": reader_cookies}
    )[0]
    assert zh["target_label"] == f"自定义目录（其他 · {custom}）"
    assert api("get", "/import-watch")[0]["target_label"] == rule["target_label"]
    with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
        assert (
            db.execute(
                "SELECT source_path,target_path,kind,strategy,process_existing "
                "FROM import_watch WHERE id=?",
                (rule["id"],),
            ).fetchone()
            == original
        )
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        assert context.request.post(base + "/api/v1/__lab/import-watch/tick").ok
        skipped = api("get", f"/import-watch/{rule['id']}/entries")
        if skipped["counts"].get("ignored") == 1:
            break
        time.sleep(0.2)
    assert skipped["counts"].get("ignored") == 1, skipped
    assert old_file.read_bytes() == b"existing download preserved"
    assert not list(custom.rglob("*.mkv"))
    page.reload()
    expect(page.get_by_text("Ignored 1", exact=True)).to_be_visible()
    if width == 1280:
        page.evaluate("window.__importLanguageDocument = true")
        language("zh-Hans")
        expect(page.get_by_text(re.compile("^复制 → 自定义目录"))).to_be_visible()
        language("en")
        expect(page.get_by_text(re.compile("^Copy → Custom folder"))).to_be_visible()
        assert page.evaluate("window.__importLanguageDocument")
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            assert (
                db.execute(
                    "SELECT source_path,target_path,kind,strategy,process_existing "
                    "FROM import_watch WHERE id=?",
                    (rule["id"],),
                ).fetchone()
                == original
            )
    shot("custom-rule")

    def edit():
        page.get_by_role("button", name=f"Actions for {source}", exact=True).click()
        page.get_by_role("menuitem", name="Edit", exact=True).click()
        return page.get_by_role("dialog", name="Edit automatic import rule", exact=True)

    form = edit()
    form.get_by_role("button", name="Import into an Other library", exact=True).click()
    form.get_by_role("button", name="Hard link", exact=True).click()
    form.get_by_role("button", name="Process existing files", exact=True).click()
    form.get_by_role("button", name="Save", exact=True).click()
    expect(form).not_to_be_visible()
    [rule] = api("get", "/import-watch")
    assert (
        rule["target_path"] is None
        and rule["library_id"] is None
        and rule["target_label"] == "Automatic routing (Other)"
    )
    shot("auto-rule")
    video = source / "Original.Clip.mkv"
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x180:rate=5:duration=10",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            str(video),
        ],
        check=True,
        timeout=60,
    )
    digest = hashlib.sha256(video.read_bytes()).hexdigest()
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        assert context.request.post(base + "/api/v1/__lab/import-watch/tick").ok
        entries = api("get", f"/import-watch/{rule['id']}/entries")
        if entries["counts"].get("imported"):
            break
        time.sleep(0.25)
    assert entries["counts"].get("imported"), entries
    files = list(destination.rglob("*.mkv"))
    assert len(files) == 1 and hashlib.sha256(files[0].read_bytes()).hexdigest() == digest
    assert hashlib.sha256(video.read_bytes()).hexdigest() == digest
    assert video.stat().st_ino == files[0].stat().st_ino
    page.reload()
    expect(page.get_by_text("Imported 1 title", exact=True)).to_be_visible()
    shot("imported")
    page.get_by_role("button", name=f"Actions for {source}", exact=True).click()
    page.get_by_role("menuitem", name="Delete", exact=True).click()
    confirm = page.get_by_role("dialog").filter(
        has=page.get_by_role("button", name="Delete", exact=True)
    )
    confirm.get_by_role("button", name="Cancel", exact=True).click()
    assert len(api("get", "/import-watch")) == 1
    page.get_by_role("button", name=f"Actions for {source}", exact=True).click()
    page.get_by_role("menuitem", name="Delete", exact=True).click()
    with page.expect_response(
        lambda response: (
            "/api/v1/import-watch/" in response.url and response.request.method == "DELETE"
        )
    ):
        page.get_by_role("dialog").get_by_role("button", name="Delete", exact=True).click()
    expect(page.get_by_text("No automatic import rules yet", exact=True)).to_be_visible()
    assert (
        video.exists()
        and files[0].exists()
        and hashlib.sha256(files[0].read_bytes()).hexdigest() == digest
    )
    assert not errors, errors
    context.close()
