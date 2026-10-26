"""搜索结果页「N 站点」详情浮层在站点很多时可以滚动看全（issue #680）。

此前桌面浮层没有高度上限：31 个站点时浮层长过视口，被页面的定高布局裁掉，
下面的站点看不到也滚不到。现在浮层封顶 60dvh、内部滚动。

复用观看历史测试的隔离服务栈（临时 SQLite + 假 TMDB），流式搜索接口在浏览器层给
31 站点的 SSE 夹具，不访问 PT 站。银玻璃与 Netflix 两套主题的桌面视口都走浮层。
本地（E2E_CHROMIUM 指向本机 Chrome）：
    pytest -m integration tests/e2e/test_search_site_status_browser.py
"""

from __future__ import annotations

import json

import pytest

playwright = pytest.importorskip("playwright.sync_api")

from tests.e2e import test_watch_history_clear_browser as history_stack  # noqa: E402

stack = history_stack.stack

pytestmark = history_stack.pytestmark

_SITES = [(f"site{i:02d}", f"测试站点{i:02d}") for i in range(1, 32)]


def _sse_body() -> str:
    def event(name: str, payload: dict) -> str:
        return f"event: {name}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"

    sites = [{"site_id": sid, "site_name": name} for sid, name in _SITES]
    parts = [
        event(
            "start",
            {"keyword": "沙丘", "label": None, "categories": [], "page": 1, "sites": sites},
        )
    ]
    parts += [event("site_start", s) for s in sites]
    statuses = []
    for i, (sid, name) in enumerate(_SITES):
        # 最后一站失败：失败行带重试按钮与原因，是浮层里最高的一行，也最容易被裁掉
        if i == len(_SITES) - 1:
            parts.append(
                event(
                    "site_error",
                    {"site_id": sid, "site_name": name, "error": "登录已过期", "elapsed_ms": 900},
                )
            )
            statuses.append(
                {
                    "site_id": sid,
                    "site_name": name,
                    "count": 0,
                    "error": "登录已过期",
                    "elapsed_ms": 900,
                    "has_more": None,
                }
            )
        else:
            parts.append(
                event(
                    "site_result",
                    {"site_id": sid, "site_name": name, "count": 0, "elapsed_ms": 120, "items": []},
                )
            )
            statuses.append(
                {
                    "site_id": sid,
                    "site_name": name,
                    "count": 0,
                    "error": None,
                    "elapsed_ms": 120,
                    "has_more": False,
                }
            )
    parts.append(event("done", {"total": 0, "elapsed_ms": 900, "sites": statuses}))
    return "".join(parts)


@pytest.mark.parametrize("theme", ["silver", "netflix"])
def test_site_status_popover_scrolls_to_last_site(stack, theme) -> None:
    from playwright.sync_api import expect

    base = stack["base"]
    with playwright.sync_playwright() as pw:
        browser = pw.chromium.launch(**history_stack._chromium_kwargs())
        context = browser.new_context(viewport={"width": 1280, "height": 800})
        api = context.request
        prefix = base + "/api/v1"
        resp = api.post(prefix + "/auth/bootstrap", data=history_stack.ADMIN)
        if resp.status == 409:
            resp = api.post(prefix + "/auth/login", data=history_stack.ADMIN)
        assert resp.ok, resp.text()
        prefs = api.get(prefix + "/ui/preferences").json()["data"]
        prefs.update(theme=theme, theme_desktop=theme, theme_mobile=theme)
        assert api.put(prefix + "/ui/preferences", data=prefs).ok

        page = context.new_page()
        page.set_default_timeout(20_000)
        page.set_default_navigation_timeout(120_000)
        errors: list[str] = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        body = _sse_body()
        page.route(
            "**/api/v1/search/torrents/stream?**",
            lambda route: route.fulfill(
                status=200, headers={"content-type": "text/event-stream"}, body=body
            ),
        )

        page.goto(f"{base}/search?q=%E6%B2%99%E4%B8%98&private=1")
        chip = page.get_by_role("button", name="31 站点")
        expect(chip).to_be_visible()
        chip.click()

        last = page.get_by_text("测试站点31", exact=True)
        retry = page.get_by_role("button", name="重试该站")
        expect(last).to_be_attached()
        popover = page.locator(".solid-popover").filter(has=last)
        box = popover.bounding_box()
        assert box is not None
        # 浮层整体留在视口里，内部内容比它高——靠滚动而不是被裁掉
        assert box["y"] + box["height"] <= 800, box
        scroll = popover.evaluate("el => [el.scrollHeight, el.clientHeight]")
        assert scroll[0] > scroll[1], scroll

        # 滚轮滚到底，最后一站与它的重试按钮都能完整露出来
        popover.hover()
        for _ in range(30):
            page.mouse.wheel(0, 400)
        expect(retry).to_be_in_viewport(ratio=1)
        expect(last).to_be_in_viewport(ratio=1)
        assert popover.evaluate("el => el.scrollTop + el.clientHeight >= el.scrollHeight - 1")
        shots = stack["shots"]
        shots.mkdir(exist_ok=True)
        page.screenshot(path=str(shots / f"site-status-{theme}.png"))

        assert errors == [], f"浏览器异常：{errors}"
        context.close()
        browser.close()
