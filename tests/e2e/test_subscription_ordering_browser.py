"""真实 API → 订阅首页 → 电影 / 剧集墙；桌面与手机不把纯洗版重排到前面。"""

# ruff: noqa: F811
from pathlib import Path

import pytest
from tests.e2e.test_smart_subscription_browser import (
    _chromium_kwargs,
    pw,
    settled_screenshot,
    smart_stack,  # noqa: F401
)

pytestmark = pytest.mark.integration


def test_missing_content_precedes_upgrades_on_home_and_walls(smart_stack):
    base, api, root = smart_stack
    with pw.sync_playwright() as playwright:
        options = (
            {"channel": "chrome"}
            if Path("/Applications/Google Chrome.app").exists()
            else _chromium_kwargs()
        )
        browser = playwright.chromium.launch(headless=True, **options)
        context = browser.new_context(viewport={"width": 1440, "height": 1100})
        assert (
            context.request.post(
                f"{base}/api/v1/auth/bootstrap",
                data={"username": "order-admin", "password": "isolated-order-test"},
            ).status
            == 200
        )
        seeded = context.request.post(f"{api}/__lab/subscription-order")
        assert seeded.status == 200, seeded.text()
        ids = seeded.json()
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        for size in ({"width": 1440, "height": 1100}, {"width": 390, "height": 844}):
            page.set_viewport_size(size)
            page.goto(f"{base}/subscriptions")
            for kind in ("movie", "tv"):
                expected = [
                    str(ids[kind][s])
                    for s in ("pipeline", "mixed", "search", "upgrade", "paused", "done")
                ]
                section = page.locator(f'section[aria-labelledby="subs-shelf-{kind}"]')
                section.locator("[data-subscription-id]").first.wait_for()
                actual = section.locator("[data-subscription-id]").evaluate_all(
                    "els => els.map(el => el.dataset.subscriptionId)"
                )
                assert actual == expected
            settled_screenshot(page, root / f"order-home-{size['width']}.png", full_page=True)
            for kind in ("movie", "tv"):
                page.goto(f"{base}/subscriptions/wall/{kind}")
                section = page.get_by_role("region", name="进行中", exact=True)
                section.locator("[data-subscription-id]").first.wait_for()
                actual = section.locator("[data-subscription-id]").evaluate_all(
                    "els => els.map(el => el.dataset.subscriptionId)"
                )
                assert actual == [
                    str(ids[kind][s]) for s in ("pipeline", "mixed", "search", "upgrade")
                ]
                assert (
                    section.locator("[data-subscription-id]")
                    .last.get_attribute("aria-label")
                    .find("洗版中")
                    >= 0
                )
                settled_screenshot(page, root / f"order-{kind}-{size['width']}.png", full_page=True)
        assert not errors, errors
        browser.close()
