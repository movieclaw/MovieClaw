"""Issue #613：真实后端、真实前端、真实媒体的分享起播回归。"""

import re

import pytest
from tests.e2e.test_media_share_browser import (
    ADMIN,
    _chromium_kwargs,
    _play_current_video,
    _wait_for,
)

pytestmark = pytest.mark.integration
pytest_plugins = ("tests.e2e.test_media_share_browser",)


def test_shared_movie_starts_in_browser(stack):
    from playwright.sync_api import expect, sync_playwright

    base = stack["base"]
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, **_chromium_kwargs())
        admin = browser.new_context()
        bootstrap = admin.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)
        assert bootstrap.ok, bootstrap.text()
        library = admin.request.post(
            f"{base}/api/v1/libraries",
            data={"name": "电影", "kind": "movie", "root_paths": [str(stack["movie_root"])]},
        )
        assert library.ok, library.text()
        library_id = library.json()["data"]["id"]

        def scanned():
            response = admin.request.get(f"{base}/api/v1/libraries/{library_id}/items")
            assert response.ok, response.text()
            rows = response.json()["data"]
            if isinstance(rows, dict):
                rows = rows.get("items", [])
            return next((row for row in rows if row["title"] == "某电影"), None)

        movie = _wait_for(scanned, timeout=180, what="电影扫描入库")
        item_id = movie["media_item_id"]
        share = admin.request.post(
            f"{base}/api/v1/libraries/{library_id}/items/{item_id}/share",
            data={},
        )
        assert share.ok, share.text()
        slug = share.json()["data"]["slug"]
        visitor = browser.new_context(viewport={"width": 1280, "height": 800}, locale="zh-CN")
        page = visitor.new_page()
        page.goto(f"{base}/s/{slug}")
        expect(page.get_by_role("heading", name="某电影")).to_be_visible(timeout=60_000)
        with page.expect_response(
            lambda r: r.request.method == "POST" and r.url.endswith("/playback/sessions"),
            timeout=60_000,
        ) as pending:
            page.get_by_role("button", name="播放", exact=True).click()
        page.wait_for_url(re.compile(f"/s/{slug}/play"))
        response = pending.value
        stack["shots"].mkdir(exist_ok=True)
        if response.status != 200:
            expect(page.get_by_role("button", name="重试", exact=True)).to_be_visible(
                timeout=15_000
            )
            page.screenshot(path=str(stack["shots"] / "issue-613-playback-error.png"))
        assert response.status == 200, f"起播 HTTP {response.status}: {response.text()}"
        _play_current_video(page)
        page.screenshot(path=str(stack["shots"] / "issue-613-playing.png"))
        browser.close()
