"""Localized library management and confirmations against real API/SQLite state."""

from __future__ import annotations

import re

import pytest

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot

stack = theme.stack
browser = theme.browser
pytestmark = pytest.mark.integration


def test_library_management_actions_in_english(stack, browser, tmp_path):
    from playwright.sync_api import expect

    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 900})
    assert context.request.post(f"{stack}/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    roots = [tmp_path / "videos", tmp_path / "movies"]
    libraries = []
    for root, name, kind in zip(roots, ("我的录像", "Cinema"), ("video", "movie"), strict=True):
        root.mkdir()
        response = context.request.post(
            f"{stack}/api/v1/libraries",
            data={
                "name": name,
                "kind": kind,
                "source": "local" if kind == "video" else "tmdb",
                "root_paths": [str(root)],
            },
        )
        assert response.ok, response.text()
        libraries.append(response.json()["data"]["id"])
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(f"{stack}/library/manage")
    expect(page.get_by_role("heading", name="Library management", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Create library", exact=True)).to_be_visible()
    expect(page.get_by_role("tab", name="Recycle bin", exact=True)).to_be_visible()
    expect(page.get_by_role("tab", name="Duplicate files", exact=True)).to_be_visible()
    actions = page.get_by_role("button", name='Actions for "我的录像"', exact=True)
    expect(actions).to_be_visible()
    page.wait_for_function(
        """() => document.querySelector('main')?.innerText.includes('No new files')"""
    )
    text = page.locator("main").first.inner_text().replace("我的录像", "")
    assert not re.search(r"[\u3400-\u9fff]", text), text
    artifacts = theme.REPO / ".tmp-uidev/i18n/library-manage"
    artifacts.mkdir(parents=True, exist_ok=True)
    detail = page.locator("[data-library-row]").first.get_by_text(re.compile("^Last scanned"))
    assert detail.evaluate(
        "e => e.scrollWidth <= e.clientWidth + 1 && e.scrollHeight <= e.clientHeight + 1"
    )
    _snapshot(page, artifacts / "management-en.png")

    actions.click()
    page.get_by_role("menuitem", name="Scan library", exact=True).click()
    dialog = page.get_by_role("dialog")
    expect(dialog.get_by_role("heading", name='Scan "我的录像"?', exact=True)).to_be_visible()
    expect(
        dialog.get_by_text("Your files will not be moved, changed or deleted.", exact=True)
    ).to_be_visible()
    _snapshot(page, artifacts / "scan-confirm-en.png")
    with page.expect_response(
        lambda response: response.url.endswith(f"/libraries/{libraries[0]}/scan")
    ) as result:
        dialog.get_by_role("button", name="Start scan", exact=True).click()
    assert result.value.ok
    expect(page.get_by_text('Started scanning "我的录像"', exact=True)).to_be_visible()
    assert roots[0].is_dir()

    actions.click()
    page.get_by_role("menuitem", name="Exclude from home page", exact=True).click()
    expect(
        page.get_by_text('"我的录像" is now excluded from the home page', exact=True)
    ).to_be_visible()
    saved = context.request.get(f"{stack}/api/v1/libraries/{libraries[0]}").json()["data"]
    assert saved["exclude_from_home"] is True

    page.get_by_role("button", name='Actions for "Cinema"', exact=True).click()
    page.get_by_role("menuitem", name=re.compile("^Delete library")).click()
    dialog = page.get_by_role("dialog")
    expect(
        dialog.get_by_role("heading", name='Delete library "Cinema"?', exact=True)
    ).to_be_visible()
    dialog.get_by_role("button", name="Delete library", exact=True).click()
    expect(page.get_by_text('Deleted library "Cinema"', exact=True)).to_be_visible()
    assert roots[1].is_dir()
    assert context.request.get(f"{stack}/api/v1/libraries/{libraries[1]}").status == 404
    assert not errors
    context.close()
