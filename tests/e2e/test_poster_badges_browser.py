"""海报角标：真实 Next + API + SQLite 下，从「自定义首页」切开关、海报墙立即按偏好重画。

覆盖用户的整条路径：新用户墙面与改版前一致（一枚角标都没有）→ 在设置区用鼠标和键盘
打开几枚 → 不刷新页面回到海报墙，角标即时出现、数值来自接口 → 偏好落库（刷新后仍在，
存的是成员自己那份）→ 最低评分、仅悬停、关掉其中几枚 → 剧集未看集数与详情页播出状态
→ 窄屏（手机两列）角标不溢出卡片。
"""

import re
import time

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .poster_badges_fixture import seed
from .test_i18n_subscription_cancel_browser import _run

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack


def test_poster_badges_settings_drive_the_wall(stack, browser):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    preferences = api("get", "/ui/preferences")
    assert not any(v for k, v in preferences["poster_badges"].items() if k != "min_rating")
    preferences.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    api("put", "/ui/preferences", data=preferences)

    root = stack["data"] / "poster-badges"
    libraries = {}
    for kind, name in (("movie", "Badge movies"), ("tv", "Badge series")):
        folder = root / kind
        folder.mkdir(parents=True)
        library = api(
            "post",
            "/libraries",
            data={"name": name, "kind": kind, "root_paths": [str(folder)], "realtime_watch": False},
        )
        libraries[kind] = (library["id"], folder)
    deadline = time.monotonic() + 120
    wanted = {lib_id for lib_id, _ in libraries.values()}
    while not all(
        not row["scanning"] and row["last_scan"]
        for row in api("get", "/libraries")
        if row["id"] in wanted
    ):
        assert time.monotonic() < deadline
        time.sleep(0.1)
    ids = _run(
        seed(stack["database_url"], libraries["movie"], libraries["tv"], stack["data"] / "metadata")
    )
    movie_wall = f"{base}/library/{libraries['movie'][0]}"
    tv_wall = f"{base}/library/{libraries['tv'][0]}"

    page = context.new_page()
    page.set_default_timeout(30000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))

    def cell(key):
        return page.locator(f'[data-library-item-id="{ids[key]}"]')

    # —— 1. 新用户：墙面与改版前一致，只有收藏的心 ——
    page.goto(movie_wall)
    expect(cell("aurora")).to_be_visible()
    expect(cell("garden")).to_be_visible()
    assert page.locator("[data-badge]").count() == 0
    assert page.get_by_test_id("poster-badges-top").count() == 0
    expect(cell("garden").locator('[aria-label="In favorites"]')).to_be_visible()

    # —— 2. 在设置区打开几枚（单页内跳转，不整页刷新）——
    page.evaluate("window.next.router.push('/library/customize')")
    section = page.get_by_test_id("poster-badge-settings")
    expect(section.get_by_role("heading", name="Poster badges")).to_be_visible()
    switches = section.get_by_role("switch")
    expect(switches).to_have_count(9)
    for name in (
        "Rating",
        "Resolution (4K, 1080p…)",
        "HDR, Dolby Vision and Atmos",
        "Chinese subtitles",
    ):
        switch = section.get_by_role("switch", name=name, exact=True)
        expect(switch).to_have_attribute("aria-checked", "false")
        switch.click()
        expect(switch).to_have_attribute("aria-checked", "true")
    # 键盘：Tab 进来按空格同样能开
    progress = section.get_by_role("switch", name="Watch progress bar", exact=True)
    progress.focus()
    page.keyboard.press("Space")
    expect(progress).to_have_attribute("aria-checked", "true")

    def stored_badges(predicate):
        end = time.monotonic() + 15
        while True:
            badges = api("get", "/ui/preferences")["poster_badges"]
            if predicate(badges):
                return badges
            assert time.monotonic() < end, badges
            time.sleep(0.1)

    saved = stored_badges(lambda b: b["progress"])
    assert {k for k, v in saved.items() if v is True} == {
        "rating",
        "resolution",
        "format",
        "chinese_subtitle",
        "progress",
    }

    # —— 3. 回到海报墙（浏览器后退，仍是同一个单页应用）：角标即时出现 ——
    page.go_back()
    expect(cell("aurora").locator('[data-badge="rating"]')).to_have_text("8.4")
    expect(cell("aurora").locator('[data-badge="resolution"]')).to_have_text("4K")
    expect(cell("aurora").locator('[data-badge="format"]')).to_have_text(["DV", "Atmos"])
    expect(cell("aurora").locator('[data-badge="chinese-subtitle"]')).to_have_text("ZH")
    width = (
        cell("aurora").locator('[data-badge="progress"] > span').evaluate("el => el.style.width")
    )
    assert width == "35%"
    expect(cell("aurora").get_by_role("link")).to_have_attribute(
        "aria-label",
        re.compile(r"Rating 8\.4.*4K.*DV.*Atmos.*Chinese subtitles available.*35% watched"),
    )
    expect(cell("paper").locator('[data-badge="format"]')).to_have_text("HDR10")
    expect(cell("paper").locator('[data-badge="resolution"]')).to_have_text("1080p")
    assert cell("paper").locator('[data-badge="chinese-subtitle"]').count() == 0
    # 无评分不画评分；外挂中文字幕也算；看完的不画进度条
    assert cell("orbit").locator('[data-badge="rating"]').count() == 0
    expect(cell("orbit").locator('[data-badge="chinese-subtitle"]')).to_be_visible()
    assert cell("orbit").locator('[data-badge="progress"]').count() == 0
    # 只有「简体中文」标题、语言码未知的内封轨
    expect(cell("tide").locator('[data-badge="chinese-subtitle"]')).to_be_visible()
    # 收藏的心并进角标层右上那一排
    assert cell("garden").get_by_test_id("poster-badges-top").locator("svg").count() >= 1
    assert not errors, errors

    # —— 4. 刷新后仍在（落库），并调最低评分 / 仅悬停 ——
    page.goto(base + "/library/customize")
    section = page.get_by_test_id("poster-badge-settings")
    expect(section.get_by_role("switch", name="Rating", exact=True)).to_have_attribute(
        "aria-checked", "true"
    )
    section.get_by_role("combobox").select_option("6.5")
    section.get_by_role("radio", name="Show on hover").click()
    expect(section.get_by_role("radio", name="Show on hover")).to_have_attribute(
        "aria-checked", "true"
    )
    stored_badges(lambda b: b["min_rating"] == 6.5 and b["hover_only"])
    page.go_back()
    expect(cell("aurora").locator('[data-badge="rating"]')).to_have_text("8.4")
    assert cell("paper").locator('[data-badge="rating"]').count() == 0, "6.1 < 6.5"
    assert cell("tide").locator('[data-badge="rating"]').count() == 0, "4.2 < 6.5"
    # 仅悬停：顶部角标平时透明，悬停后显现；底部「中」不受影响
    rating = cell("aurora").locator('[data-badge="rating"]')
    page.mouse.move(5, 5)
    expect(rating).to_have_css("opacity", "0")
    expect(cell("aurora").locator('[data-badge="chinese-subtitle"]')).to_have_css("opacity", "1")
    cell("aurora").get_by_role("link").hover()
    expect(rating).to_have_css("opacity", "1")

    # —— 5. 关掉其中几枚、打开剧集相关的几枚 ——
    page.evaluate("window.next.router.push('/library/customize')")
    section = page.get_by_test_id("poster-badge-settings")
    section.get_by_role("radio", name="Always show").click()
    for name in (
        "HDR, Dolby Vision and Atmos",
        "Chinese subtitles",
        "Unwatched episode count",
        "Series ended",
    ):
        section.get_by_role("switch", name=name, exact=True).click()
    stored_badges(
        lambda b: b["unwatched"] and b["ended"] and not b["format"] and not b["chinese_subtitle"]
    )
    page.go_back()
    expect(cell("aurora").locator('[data-badge="resolution"]')).to_have_text("4K")
    expect(cell("aurora").locator('[data-badge="format"]')).to_have_count(0)
    expect(cell("aurora").locator('[data-badge="chinese-subtitle"]')).to_have_count(0)

    page.goto(tv_wall)
    expect(cell("signal").locator('[data-badge="unwatched"]')).to_have_text("6")
    expect(cell("copper").locator('[data-badge="unwatched"]')).to_have_text("8")
    expect(cell("relay").locator('[data-badge="unwatched"]')).to_have_text("10")
    assert cell("lantern").locator('[data-badge="unwatched"]').count() == 0, "all watched"
    expect(cell("signal").locator('[data-badge="status"]')).to_have_text("Ended")
    assert cell("copper").locator('[data-badge="status"]').count() == 0, "airing is off"
    expect(cell("signal").locator('[data-badge="progress"]')).to_be_visible()

    # —— 6. 详情页：标题旁的播出状态（任一状态开关打开即标两种）——
    page.goto(f"{tv_wall}/item/{ids['signal']}")
    expect(page.get_by_test_id("detail-air-status")).to_have_text("Ended")
    page.goto(f"{tv_wall}/item/{ids['copper']}")
    expect(page.get_by_test_id("detail-air-status")).to_have_text("Airing")
    page.goto(f"{movie_wall}/item/{ids['aurora']}")
    expect(page.get_by_role("heading", level=1)).to_be_visible()
    assert page.get_by_test_id("detail-air-status").count() == 0

    # —— 7. 窄屏两列：角标都在卡片里，页面不横向滚动 ——
    phone = browser.new_context(
        locale="en-US",
        viewport={"width": 320, "height": 800},
        is_mobile=True,
        has_touch=True,
        storage_state=context.storage_state(),
    )
    small = phone.new_page()
    small.goto(tv_wall)
    small.locator(f'[data-library-item-id="{ids["signal"]}"] [data-badge="unwatched"]').wait_for()
    assert small.evaluate("document.documentElement.scrollWidth <= innerWidth")
    overflow = small.evaluate(
        """() => [...document.querySelectorAll('[data-badge]')].filter(badge => {
            const frame = badge.closest('.overflow-hidden');
            const a = badge.getBoundingClientRect(), b = frame.getBoundingClientRect();
            return a.left < b.left - 0.5 || a.right > b.right + 0.5;
        }).length"""
    )
    assert overflow == 0
    phone.close()
    assert not errors, errors
    context.close()
