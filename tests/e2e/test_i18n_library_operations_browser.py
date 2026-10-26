"""Real scans, manual identification, extras and filename organization in both languages."""

from __future__ import annotations

import json
import re
import sqlite3

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import _wait_for
from .test_other_library_browser import _gen_clip

browser = theme.browser


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_I18N_DISCOVERY", "1")
        yield from inventory.stack.__wrapped__(tmp_path_factory)


pytestmark = pytest.mark.integration


def test_identify_ignore_and_organize_real_files(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1100})
    assert context.request.post(f"{base}/api/v1/auth/bootstrap", data=inventory.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(25_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    root = stack["roots"]["movies"]
    files = {
        name: root / f"{name}.mp4" for name in ("UnknownClipA", "UnknownClipB", "UnknownClipC")
    }
    for file in files.values():
        _gen_clip(file, 2)
    subtitle = files["UnknownClipA"].with_suffix(".en.srt")
    subtitle.write_text("1\n00:00:00,000 --> 00:00:02,000\nUser subtitle\n")
    response = context.request.post(
        f"{base}/api/v1/libraries",
        data={
            "name": "Operation samples",
            "kind": "movie",
            "root_paths": [str(root)],
            "realtime_watch": False,
        },
    )
    assert response.ok, response.text()
    library_id = response.json()["data"]["id"]

    def library():
        return context.request.get(f"{base}/api/v1/libraries/{library_id}").json()["data"]

    _wait_for(
        lambda: library()["last_scan"] and not library()["scanning"],
        timeout=120,
        what="real media scan",
    )

    def items():
        return [
            row
            for identity in ("confirmed", "provisional")
            for row in context.request.get(
                f"{base}/api/v1/libraries/{library_id}/items?identity={identity}"
            ).json()["data"]
        ]

    rows = items()
    assert len(rows) == 3, rows
    ids = {row["title"]: row["media_item_id"] for row in rows}
    artifacts = theme.REPO / ".tmp-uidev/i18n/library-operations"
    artifacts.mkdir(parents=True, exist_ok=True)

    def correction(item_id):
        page.goto(f"{base}/library/{library_id}/item/{item_id}")
        page.get_by_role("button", name="More actions", exact=True).click()
        page.get_by_role("menuitem", name="Correct identification…", exact=True).click()
        dialog = page.get_by_role("dialog", name="Correct identification", exact=True)
        expect(dialog.get_by_role("button", name="None match, search…", exact=True)).to_be_visible()
        return dialog

    def recorded_reason(path):
        database = stack["database_url"].removeprefix("sqlite+aiosqlite:///")
        with sqlite3.connect(database) as connection:
            return connection.execute(
                "SELECT unidentified_reason, unidentified_message FROM library_file "
                "WHERE file_path = ?",
                (str(path),),
            ).fetchone()

    original_reason, original_message = recorded_reason(files["UnknownClipA"])
    assert original_reason.startswith("按「UnknownClipA」")
    assert json.loads(original_message)["message_key"] == "library.identification.unconfirmed"
    dialog = correction(ids["UnknownClipA"])
    expect(
        dialog.get_by_text(
            "Could not identify (No TMDB match): Could not confirm “UnknownClipA” on TMDB: "
            "TMDB search returned no results",
            exact=True,
        )
    ).to_be_visible()
    assert not re.search(r"[\u3400-\u9fff]", dialog.inner_text())
    expect(dialog.get_by_text("Current identification", exact=True)).to_be_visible()
    dialog.get_by_role("button", name="None match, search…", exact=True).click()
    dialog.get_by_placeholder("Title keywords or a TMDB ID", exact=True).fill("300")
    dialog.get_by_role("button", name="Look up this ID", exact=True).click()
    expect(dialog.get_by_role("link", name="Check on TMDB ↗", exact=True)).to_be_visible()
    expect(dialog.get_by_text("95 minutes", exact=True)).to_be_visible()
    expect(dialog.get_by_text("Loading details…", exact=True)).to_have_count(0)
    expect(dialog.get_by_text(re.compile("^Could not load details"))).to_have_count(0)
    page.wait_for_function(
        "() => [...document.querySelectorAll('.modal-panel img')].every(img => img.complete)"
    )
    page.evaluate(
        """async () => {
            await document.fonts.ready;
            await new Promise(requestAnimationFrame);
            await new Promise(requestAnimationFrame);
        }"""
    )
    _snapshot(page, artifacts / "claim-en.png")
    dialog.get_by_role("button", name="Assign", exact=True).click()
    expect(dialog.get_by_text(re.compile("Assigned 1 file to “TMDB #300”"))).to_be_visible()
    assert (
        files["UnknownClipA"].exists() and subtitle.exists()
    )  # Claim changes identity, not filenames.
    assert any(row["title"] == "某电影" for row in items())
    assert recorded_reason(files["UnknownClipA"]) == (None, None)
    dialog.get_by_role("button", name="Close", exact=True).last.click()

    dialog = correction(ids["UnknownClipB"])
    dialog.get_by_role("button", name="Not a standalone title", exact=True).click()
    confirmation = page.get_by_role("dialog", name="Mark this 1 file as extras?", exact=True)
    expect(confirmation.get_by_text(re.compile("Disk files stay untouched"))).to_be_visible()
    confirmation.get_by_role("button", name="Mark as extras", exact=True).click()
    expect(dialog.get_by_text(re.compile("Marked 1 file as extras"))).to_be_visible()
    assert files["UnknownClipB"].exists()
    assert recorded_reason(files["UnknownClipB"]) == (None, None)
    assert not any(row["media_item_id"] == ids["UnknownClipB"] for row in items())
    dialog.get_by_role("button", name="Close", exact=True).last.click()

    page.goto(f"{base}/library/{library_id}")
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Organize filenames", exact=True).click()
    dialog = page.get_by_role(
        "dialog", name="Organize filenames in “Operation samples”", exact=True
    )
    start = dialog.get_by_role("button", name="Organize 1 file", exact=True)
    expect(start).to_be_disabled()
    dialog.get_by_role("button", name="Skipped 2 files (show reasons)", exact=True).click()
    expect(
        dialog.get_by_text(
            "Not identified yet. Assign a title in Unidentified first", exact=True
        ).first
    ).to_be_visible()
    assert not re.search(r"[\u3400-\u9fff]", dialog.inner_text().replace("某电影", ""))
    _snapshot(page, artifacts / "organize-en.png")
    page.set_viewport_size({"width": 390, "height": 844})
    _snapshot(page, artifacts / "organize-mobile-en.png")
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    dialog.get_by_role(
        "checkbox", name="I have checked the list and understand the risks above", exact=True
    ).check()
    start.click()
    expect(dialog.get_by_text("Organization complete", exact=True)).to_be_visible(timeout=60_000)
    expect(dialog.get_by_text(re.compile("^Renamed 1 file; moved 1 sidecar"))).to_be_visible()
    _snapshot(page, artifacts / "organized-mobile-en.png")
    assert not files["UnknownClipA"].exists() and not subtitle.exists()
    renamed = list(root.rglob("某电影*.mp4"))
    assert len(renamed) == 1
    assert renamed[0].with_suffix(".en.srt").read_text().endswith("User subtitle\n")
    assert files["UnknownClipB"].exists() and files["UnknownClipC"].exists()
    assert library()["last_organize"]["renamed"] == 1
    preview_url = f"{base}/api/v1/libraries/{library_id}/file-organization-preview"
    chinese = context.request.post(preview_url, headers={"Accept-Language": "zh-Hans"})
    assert chinese.ok, chinese.text()
    assert chinese.json()["data"]["skips"][0]["reason"] == "尚未识别身份，请先在「待识别」里认领"
    dialog.get_by_role("button", name="Done", exact=True).click()
    chinese_context = browser.new_context(
        locale="zh-CN",
        storage_state=context.storage_state(),
        viewport={"width": 1440, "height": 1100},
    )
    chinese_context.add_cookies([{"name": "mc_locale", "value": "zh-Hans", "url": base}])
    chinese_page = chinese_context.new_page()
    chinese_page.goto(f"{base}/library/{library_id}")
    chinese_page.get_by_role("button", name="更多操作", exact=True).click()
    chinese_page.get_by_role("menuitem", name="整理文件名", exact=True).click()
    chinese_dialog = chinese_page.get_by_role(
        "dialog", name="整理「Operation samples」的文件名", exact=True
    )
    expect(
        chinese_dialog.get_by_text(re.compile("^这个库已经很规整了，没有需要改名的文件 🎉"))
    ).to_be_visible()
    chinese_dialog.get_by_role("button", name="跳过 2 个文件（点击查看原因）", exact=True).click()
    expect(
        chinese_dialog.get_by_text("尚未识别身份，请先在「待识别」里认领", exact=True).first
    ).to_be_visible()
    _snapshot(chinese_page, artifacts / "organize-zh.png")
    assert not errors
    chinese_context.close()
    context.close()
