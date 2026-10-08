"""#615：真实设置页预览 → 保存接口 → 持久化 → 刷新读回，允许自由命名模板。

沿用现有真后端、真前端与 Chromium 基座；文件落盘由 test_naming_tokens_e2e 覆盖。
"""

from __future__ import annotations

import re

import pytest

from .test_library_manage_browser import (  # noqa: F401  (stack 是 fixture，按名注入)
    ADMIN,
    _chromium_kwargs,
    stack,
)

playwright = pytest.importorskip("playwright.sync_api")
pytestmark = [pytest.mark.integration]


def test_free_naming_templates_preview_save_and_reload(stack) -> None:  # noqa: F811
    with playwright.sync_playwright() as p:
        browser = p.chromium.launch(headless=True, **_chromium_kwargs())
        context = browser.new_context(viewport={"width": 1440, "height": 1000}, locale="zh-CN")
        base = stack["base"]
        boot = context.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)
        assert boot.ok, boot.text()
        page = context.new_page()
        page.set_default_timeout(20_000)
        page.set_default_navigation_timeout(120_000)
        errors: list[str] = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(f"{base}/settings/scrape")
        page.get_by_role("button", name=re.compile("^命名模板")).click()

        payload = {
            "naming_entry_dir": "{tmdb_id}",
            "naming_movie_file": "{release_name}",
            "naming_season_dir": "{season_name}",
            "naming_episode_file": "{release_name}",
        }
        for directories in ({}, {"naming_entry_dir": "收藏", "naming_season_dir": "剧集"}):
            payload.update(directories)
            for key, value in payload.items():
                page.locator(f"#{key}").fill(value)
            playwright.expect(page.get_by_text("✓ 模板有效", exact=True)).to_be_visible()
            playwright.expect(
                page.get_by_text(re.compile(r"Dune\.Part\.Two\.2024.*\.mkv$"))
            ).to_be_visible()
            playwright.expect(
                page.get_by_text(re.compile(r"Kite\.2017\.S01E03.*\.mkv$"))
            ).to_be_visible()
            with page.expect_response(
                lambda response: (
                    response.url.endswith("/api/v1/scrape/config")
                    and response.request.method == "PUT"
                )
            ) as saved:
                page.get_by_role("button", name="保存", exact=True).click()
            assert saved.value.ok, saved.value.text()
            stored = context.request.get(f"{base}/api/v1/scrape/config").json()["data"]["setting"]
            for key, value in payload.items():
                assert stored[key] == value
            page.reload()
            page.get_by_role("button", name=re.compile("^命名模板")).click()
            for key, value in payload.items():
                playwright.expect(page.locator(f"#{key}")).to_have_value(value)

        page.locator("#naming_entry_dir").fill("{release_name}")
        playwright.expect(
            page.get_by_text("不可用的占位符：{release_name}", exact=True)
        ).to_be_visible()
        page.locator("#naming_entry_dir").fill("{title}/{year}")
        playwright.expect(
            page.get_by_text("不能包含路径分隔符（目录层级是固定的）", exact=True)
        ).to_be_visible()
        assert errors == []
        browser.close()
