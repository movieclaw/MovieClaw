"""全幅剧照类型卡：真实服务上的只读浏览器验收。

E2E_WEB_URL 指向本分支前端（可以反代 NAS），MC_TEST_USERNAME / MC_TEST_PASSWORD
提供登录；E2E_SHOT_DIR 可保存截图。额外的缺图/长标题案例只拦截浏览器响应，不写服务端。
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

pw = pytest.importorskip("playwright.sync_api")
BASE = os.environ.get("E2E_WEB_URL", "").rstrip("/")
SHOTS = Path(os.environ.get("E2E_SHOT_DIR", "/tmp/genre-cards-browser"))
pytestmark = [pytest.mark.integration, pytest.mark.skipif(not BASE, reason="需指定 E2E_WEB_URL")]


@pytest.fixture(scope="module")
def browser():
    SHOTS.mkdir(parents=True, exist_ok=True)
    with pw.sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        yield browser
        browser.close()


@pytest.fixture
def session(browser):
    context = browser.new_context(viewport={"width": 1440, "height": 1050})
    response = context.request.post(
        f"{BASE}/api/v1/auth/login",
        data={
            "username": os.environ["MC_TEST_USERNAME"],
            "password": os.environ["MC_TEST_PASSWORD"],
            "remember": False,
        },
    )
    assert response.ok and response.json()["success"]
    yield context
    context.request.post(f"{BASE}/api/v1/auth/logout")
    context.close()


@pytest.mark.parametrize("width", [1440, 393])
@pytest.mark.parametrize("kind", ["movie", "tv"])
def test_real_genre_card_and_filtered_wall(session, width, kind):
    page = session.new_page()
    page.set_viewport_size({"width": width, "height": 1050 if width > 400 else 852})
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    genres = session.request.get(f"{BASE}/api/v1/libraries/kinds/{kind}/genres").json()["data"]
    assert genres, "测试片库需包含该种类型"
    first = genres[0]
    page.goto(f"{BASE}/library")
    row = page.get_by_test_id(f"home-row-genres:{kind}")
    card = row.locator("a").first
    card.wait_for(timeout=60000)
    card.scroll_into_view_if_needed()
    page.wait_for_function(
        "el => el.complete && el.naturalWidth > 0", arg=card.locator("img").element_handle()
    )
    box = card.bounding_box()
    assert box and box["width"] == pytest.approx(236, abs=1)
    assert box["height"] == pytest.approx(150, abs=1)
    assert (
        card.get_attribute("aria-label")
        == f"浏览{first['label']}，{first['count']} 部{'电影' if kind == 'movie' else '剧集'}"
    )
    assert "最近入库" not in card.inner_text()
    assert card.get_attribute("href") == f"/library/kind/{kind}?g={first['value']}"
    # 等现有 PosterImage 的 500 ms 淡入结束，截图才代表最终渲染。
    page.wait_for_function(
        "el => getComputedStyle(el).opacity === '1'", arg=card.locator("img").element_handle()
    )
    card.screenshot(path=str(SHOTS / f"web-{width}-{kind}-card.png"), animations="disabled")
    page.screenshot(path=str(SHOTS / f"web-{width}-{kind}.png"), animations="disabled")
    with page.expect_response(
        lambda r: f"/libraries/kinds/{kind}/items?" in r.url and f"g={first['value']}" in r.url
    ) as filtered:
        card.focus()
        page.keyboard.press("Enter")
    assert filtered.value.ok
    assert filtered.value.json()["data"], "真实类型墙应返回影片"
    page.wait_for_url(f"**/library/kind/{kind}?g={first['value']}")
    page.go_back()
    row.wait_for()
    row.locator("a").last.scroll_into_view_if_needed()
    assert row.locator("a").last.is_visible()
    assert not errors
    page.close()


def test_missing_failed_art_and_long_tv_label(session):
    page = session.new_page()
    page.set_viewport_size({"width": 393, "height": 852})

    def genres_override(route):
        body = route.fetch().json()
        body["data"][0].update(label="科幻奇幻", count=999999, cover_url=None)
        body["data"][1]["cover_url"] = "/images/genre-test-missing.jpg"
        route.fulfill(json=body)

    page.route("**/api/v1/libraries/kinds/tv/genres", genres_override)
    page.route(
        "**/api/v1/images/genre-test-missing.jpg*", lambda route: route.fulfill(status=404, body="")
    )
    page.goto(f"{BASE}/library")
    row = page.get_by_test_id("home-row-genres:tv")
    first = row.locator("a").first
    first.wait_for(timeout=60000)
    first.scroll_into_view_if_needed()
    assert first.locator("img").count() == 0
    assert "科幻奇幻" in first.inner_text() and "999999 部剧集" in first.inner_text()
    assert first.bounding_box()["height"] == pytest.approx(150, abs=1)
    first.screenshot(path=str(SHOTS / "web-missing-long-card.png"))
    second = row.locator("a").nth(1)
    second.scroll_into_view_if_needed()
    pw.expect(second.locator("img")).to_have_count(0, timeout=15000)
    assert second.bounding_box()["height"] == pytest.approx(150, abs=1)
    second.screenshot(path=str(SHOTS / "web-failed-image-card.png"))
    page.close()
