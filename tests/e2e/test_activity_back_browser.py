"""#1100：从别的标签页经「活动」入口进来，二级页的返回键回到活动总览，而不是上一个标签页。"""

import re

import pytest

from . import test_theme_device_class_browser as theme
from .test_i18n_subscription_cancel_browser import _run

# 复用同一套隔离后端 + next dev
from .test_i18n_task_activity_browser import _seed, stack  # noqa: F401

browser = theme.browser
pytestmark = pytest.mark.integration

OVERVIEW = re.compile(r"/activity$")
ACTIVE_PAGE = re.compile(r"/activity\?view=active$")


def test_activity_subpage_back_returns_to_overview(stack, browser):  # noqa: F811
    from playwright.sync_api import expect

    base, direct, root = stack
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 900})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    _run(_seed(f"sqlite+aiosqlite:///{root / 'data.db'}"))
    assert context.request.post(direct + "/__lab/task-reset").ok
    prefs = context.request.get(base + "/api/v1/ui/preferences").json()["data"]
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    assert context.request.put(base + "/api/v1/ui/preferences", data=prefs).ok

    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))

    # 桌面：先在另一个标签页，侧栏「活动」带进行中角标（只有进行中、没有需要处理）
    page.goto(base + "/library")
    entry = page.locator("aside").get_by_role("button", name=re.compile(r"^Activity"))
    expect(entry).to_contain_text(re.compile(r"Activity\s*\d+"))
    entry.click()
    # 入口落在总览：角标要说的事（进行中）就在总览上，二级页只从总览进
    expect(page).to_have_url(OVERVIEW)
    page.get_by_role("link", name="See all").first.click()
    expect(page).to_have_url(ACTIVE_PAGE)
    page.get_by_role("button", name="Back to activity", exact=True).click()
    expect(page).to_have_url(OVERVIEW)
    # 返回消费的是真实历史：再退一步回到来时的标签页，没有多垫出一条总览
    page.go_back()
    expect(page).to_have_url(re.compile(r"/library$"))

    # 已在二级页时点侧栏「活动」回到总览（标签根），而不是原地不动
    page.goto(base + "/activity?view=active")
    entry.click()
    expect(page).to_have_url(OVERVIEW)

    # 直达二级页（无站内历史）：返回键落到总览
    fresh = context.new_page()
    fresh.goto(base + "/activity?view=active")
    fresh.get_by_role("button", name="Back to activity", exact=True).click()
    expect(fresh).to_have_url(OVERVIEW)
    fresh.close()

    # 手机：底栏「活动」页签 → 查看全部 → 顶栏返回，同样回总览
    page.set_viewport_size({"width": 390, "height": 844})
    page.goto(base + "/library")
    page.get_by_role("link", name="Activity", exact=True).click()
    expect(page).to_have_url(OVERVIEW)
    page.get_by_role("link", name="See all").first.click()
    expect(page).to_have_url(ACTIVE_PAGE)
    page.get_by_role("button", name="Back", exact=True).click()
    expect(page).to_have_url(OVERVIEW)

    assert errors == []
    context.close()
