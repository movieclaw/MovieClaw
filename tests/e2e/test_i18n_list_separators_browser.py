"""Visible lists use the reader's separators: missing-episode summaries and download sources."""

from __future__ import annotations

import re
import socket
import sqlite3
from datetime import UTC, datetime

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_library_manage_browser import _wait_for

browser = theme.browser
stack = inventory.stack

pytestmark = pytest.mark.integration


def _closed_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def test_missing_summary_and_source_warning_follow_reader_language(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 900})
    assert context.request.post(f"{base}/api/v1/auth/bootstrap", data=inventory.ADMIN).ok
    context.add_cookies([{"name": "mc_locale", "value": "en", "url": base}])
    page = context.new_page()
    page.set_default_timeout(25_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    inventory._ensure_libraries(page, stack)
    libraries = context.request.get(f"{base}/api/v1/libraries").json()["data"]
    shows_id = next(row["id"] for row in libraries if row["name"] == "剧集库")

    # Two episodes of season 1 and one of season 2 are recorded but gone from disk.
    database = stack["database_url"].removeprefix("sqlite+aiosqlite:///")
    gone = datetime.now(UTC).replace(tzinfo=None).isoformat(sep=" ")
    with sqlite3.connect(database) as db:
        db.execute(
            "UPDATE library_file SET season_number = 2 WHERE library_id = ? AND episode_number = 3",
            (shows_id,),
        )
        db.execute(
            "UPDATE library_file SET state = 'missing', missing_since = ? WHERE library_id = ?",
            (gone, shows_id),
        )
    missing = context.request.get(f"{base}/api/v1/libraries/{shows_id}/missing").json()["data"]
    assert sorted(f["season_number"] for item in missing for f in item["files"]) == [1, 1, 2]

    page.goto(f"{base}/library/{shows_id}")
    page.get_by_role("button", name="1 missing title", exact=True).click()
    summary = "Season 1: 2 missing episodes and Season 2: 1 missing episode"
    expect(page.get_by_text(summary, exact=True)).to_be_visible()

    # Two downloaders that cannot be reached: their warnings share one sentence.
    for name in ("Alpha qB", "Beta qB"):
        saved = context.request.post(
            f"{base}/api/v1/downloaders",
            data={
                "name": name,
                "client_type": "qbittorrent",
                "url": f"http://127.0.0.1:{_closed_port()}",
                "username": "admin",
                "password": "secret",
            },
        )
        assert saved.ok, saved.text()
    _wait_for(
        lambda: (
            len(
                [
                    source
                    for source in context.request.get(f"{base}/api/v1/downloaders/tasks").json()[
                        "data"
                    ]["sources"]
                    if source["status"] != "active"
                ]
            )
            == 2
        ),
        timeout=60,
        what="both downloaders reported unavailable",
    )
    page.goto(f"{base}/activity?view=active")
    warning = page.locator("p").filter(has_text="Alpha qB").filter(has_text="Beta qB")
    expect(warning).to_have_count(1)
    text = warning.inner_text()
    assert re.search(r"”: .+; “", text), text
    assert "；" not in text and "、" not in text

    chinese = browser.new_context(
        locale="zh-CN",
        storage_state=context.storage_state(),
        viewport={"width": 1280, "height": 900},
    )
    chinese.add_cookies([{"name": "mc_locale", "value": "zh-Hans", "url": base}])
    zh_page = chinese.new_page()
    zh_page.goto(f"{base}/library/{shows_id}")
    zh_page.get_by_role("button", name="1 个条目缺失", exact=True).click()
    expect(zh_page.get_by_text("第 1 季缺 2 集、第 2 季缺 1 集", exact=True)).to_be_visible()
    zh_page.goto(f"{base}/activity?view=active")
    zh_warning = zh_page.locator("p").filter(has_text="Alpha qB").filter(has_text="Beta qB")
    expect(zh_warning).to_have_count(1)
    assert re.search(r"」.+；「", zh_warning.inner_text()), zh_warning.inner_text()
    assert not errors
    chinese.close()
    context.close()
