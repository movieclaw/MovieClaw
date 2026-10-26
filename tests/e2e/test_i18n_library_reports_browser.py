"""Library reports from a real SDK cloud scan and persisted collection rules."""

import re
import sqlite3
import time

import pytest

from . import test_i18n_drive_settings_browser as drives
from . import test_theme_device_class_browser as theme
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = drives.browser
search_provider = drives.search_provider
drive_http = drives.drive_http
stack = drives.stack


def wait_for(check):
    deadline = time.monotonic() + 60
    while True:
        result = check()
        if result:
            return result
        assert time.monotonic() < deadline
        time.sleep(0.1)


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_cloud_report_and_overlap_advice_preserve_source_facts(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

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
    account = api(
        "post", "/drives/accounts/cookie", data={"backend": "fixture", "cookie": "session=good"}
    )["account"]
    created = []
    for suffix in ("A", "B", "Cloud"):
        folder = stack["data"] / f"reports-{theme_id}-{width}-{suffix}"
        folder.mkdir()
        data = {
            "name": f"Fixture {suffix} {theme_id} {width}",
            "kind": "movie",
            "root_paths": [str(folder)],
            "realtime_watch": False,
        }
        if suffix != "Cloud":
            data["match_rules"] = [{"field": "genres", "op": "any_of", "values": [16]}]
        else:
            data["cloud_folders"] = [
                {
                    "account_id": account["id"],
                    "remote_dir_id": "free",
                    "display_path": "Archive",
                    "is_primary": False,
                }
            ]
        created.append(api("post", "/libraries", data=data))
    a, b, cloud = created
    ids = {row["id"] for row in created}
    wait_for(
        lambda: all(
            not row["scanning"] and row["last_scan"]
            for row in api("get", "/libraries")
            if row["id"] in ids
        )
    )
    actual = wait_for(
        lambda: (
            (row := api("get", f"/libraries/{cloud['id']}"))["cloud_folders"][0]["report"] and row
        )
    )
    assert actual["cloud_folders"][0]["report"]["videos"] == 0

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
            return (
                database.execute(
                    "SELECT id,match_rules FROM library WHERE id IN (?,?,?) ORDER BY id",
                    tuple(sorted(ids)),
                ).fetchall(),
                database.execute(
                    "SELECT report FROM library_cloud_folder WHERE library_id=?", (cloud["id"],)
                ).fetchall(),
            )

    before = stored()
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/library-reports"
    shots.mkdir(parents=True, exist_ok=True)
    for language in ("en", "zh-Hans", "en"):
        page.goto(base + "/settings/appearance")
        control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
        control.check()
        expect(control).to_be_enabled()
        expect(page.locator("html")).to_have_attribute("lang", language)
        page.goto(base + "/library/manage")
        warning = (
            page.locator("main div.border-amber-400\\/25")
            .filter(has_text=a["name"])
            .filter(has_text=b["name"])
        )
        expect(warning).to_be_visible()
        expect(warning).to_contain_text(
            "add a “Region” condition" if language == "en" else "补上「区域」条件"
        )
        if language == "en":
            assert not re.search(r"[\u3400-\u9fff]", warning.inner_text())
            page.screenshot(
                path=str(shots / f"{theme_id}-{width}-overlap.png"), animations="disabled"
            )
        row = page.locator(f'[data-library-row="{cloud["id"]}"]')
        row.locator('button[aria-haspopup="menu"]').click()
        page.get_by_role(
            "menuitem", name="Import report" if language == "en" else "纳管报告", exact=True
        ).click()
        dialog = page.get_by_role(
            "dialog", name="Cloud import report" if language == "en" else "纳管报告", exact=True
        )
        expect(
            dialog.get_by_role(
                "heading",
                name=("Cloud import report · " if language == "en" else "纳管报告 · ")
                + cloud["name"],
                exact=True,
            )
        ).to_be_visible()
        expect(
            dialog.get_by_text("0 video files" if language == "en" else "0 个视频文件", exact=True)
        ).to_be_visible()
        if language == "en":
            expect(dialog.get_by_text("Identified", exact=True)).to_be_visible()
            expect(dialog.get_by_text("Unidentified", exact=True)).to_be_visible()
            expect(dialog.get_by_role("button", name="Identify files", exact=True)).to_have_count(0)
            assert not re.search(r"[\u3400-\u9fff]", dialog.inner_text())
            assert dialog.evaluate("node=>node.scrollWidth<=node.clientWidth")
            page.screenshot(
                path=str(shots / f"{theme_id}-{width}-report.png"), animations="disabled"
            )
        dialog.get_by_role(
            "button", name="Close" if language == "en" else "关闭", exact=True
        ).last.click()
        assert stored() == before
    api(
        "put",
        f"/libraries/{b['id']}",
        data={
            "name": b["name"],
            "kind": b["kind"],
            "root_paths": b["root_paths"],
            "realtime_watch": b["realtime_watch"],
            "match_rules": [
                *b["match_rules"],
                {"field": "origin_countries", "op": "any_of", "values": ["JP"]},
            ],
        },
    )
    page.reload()
    expect(page.locator("main div.border-amber-400\\/25").filter(has_text=a["name"])).to_have_count(
        0
    )
    assert api("get", f"/libraries/{a['id']}")["match_rules"] == a["match_rules"]
    assert not errors, errors
    for item in created:
        api("delete", f"/libraries/{item['id']}")
    api("delete", f"/drives/accounts/{account['id']}")
    context.close()
