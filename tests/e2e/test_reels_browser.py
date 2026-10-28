"""网页片段（/reels）与手机媒体库首页「下拉二楼」入口：真实服务上的浏览器验收。

E2E_WEB_URL 指向本分支前端，MC_TEST_USERNAME / MC_TEST_PASSWORD 提供登录；片库里要有能刷的片子
（服务端开了片段预切时只出切好的）。E2E_SHOT_DIR 可保存截图。手机用例用 CDP 发真实触摸事件：
按住往下拉、停住截图、再松手，与手指一样经过首页的触摸处理。
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

pw = pytest.importorskip("playwright.sync_api")
BASE = os.environ.get("E2E_WEB_URL", "").rstrip("/")
SHOTS = Path(os.environ.get("E2E_SHOT_DIR", "/tmp/reels-browser"))
pytestmark = [pytest.mark.integration, pytest.mark.skipif(not BASE, reason="需指定 E2E_WEB_URL")]
TIP = "library.reels-floor"


@pytest.fixture(scope="module")
def browser():
    SHOTS.mkdir(parents=True, exist_ok=True)
    with pw.sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        yield browser
        browser.close()


def _login(context):
    response = context.request.post(
        f"{BASE}/api/v1/auth/login",
        data={
            "username": os.environ["MC_TEST_USERNAME"],
            "password": os.environ["MC_TEST_PASSWORD"],
            "remember": False,
        },
    )
    assert response.ok and response.json()["success"]


@pytest.fixture
def phone(browser):
    context = browser.new_context(
        viewport={"width": 393, "height": 852}, device_scale_factor=3, is_mobile=True, has_touch=True
    )
    _login(context)
    # 提示状态清零：没用过下拉二楼的人才看得到提示卡
    context.request.delete(f"{BASE}/api/v1/tips/state")
    yield context
    context.request.post(f"{BASE}/api/v1/auth/logout")
    context.close()


def _tip_record(context):
    state = context.request.get(f"{BASE}/api/v1/tips/state").json()["data"]
    return next((row for row in state["tips"] if row["tip_id"] == TIP), None)


def _pull(page, cdp, distance, *, release=True, shot=None):
    """手指从屏幕上部往下拉 distance 像素（分 30 步），可在停住时截图，再松手。"""
    x, y = 196, 260
    cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]})
    for i in range(1, 31):
        cdp.send(
            "Input.dispatchTouchEvent",
            {"type": "touchMove", "touchPoints": [{"x": x, "y": y + distance * i / 30}]},
        )
        page.wait_for_timeout(16)
    if shot:
        page.screenshot(path=str(SHOTS / shot))
    armed = page.locator("[data-testid=reels-floor][data-armed]").count() > 0
    if release:
        cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    return armed


def test_pull_down_floor_opens_reels_and_plays(phone):
    page = phone.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(f"{BASE}/library")
    tip = page.locator(f'[data-tip-id="{TIP}"]')
    tip.wait_for(timeout=60000)
    page.screenshot(path=str(SHOTS / "library-tip.png"))
    cdp = phone.new_cdp_session(page)

    # 只拉到刷新的距离：胶片露出来了，但没过线，松手留在首页
    armed = _pull(page, cdp, 360, shot="pull-refresh.png")
    assert not armed
    page.wait_for_timeout(600)
    assert page.url.rstrip("/").endswith("/library")

    # 用力拉过线：片门合上，松手进片段
    armed = _pull(page, cdp, 540, shot="pull-armed.png")
    assert armed, "拉过线时应处于过线状态"
    page.wait_for_url("**/reels", timeout=15000)
    page.get_by_test_id("reels-page").first.wait_for(timeout=60000)

    # 至少有一条能放起来（放不出的往下滑一条，同 iOS 的提示）
    video = page.get_by_test_id("reels-video")
    played = False
    for _ in range(4):
        try:
            page.wait_for_function(
                "el => el.dataset.status === 'playing' && el.currentTime > 0.3",
                arg=video.element_handle(),
                timeout=45000,
            )
            played = True
            break
        except pw.TimeoutError:
            pager = page.get_by_test_id("reels-pager")
            pager.evaluate("el => el.scrollBy({ top: el.clientHeight })")
            page.wait_for_timeout(800)
    assert played, "片段应能放起来"
    page.screenshot(path=str(SHOTS / "reels-playing.png"))

    record = _tip_record(phone)
    assert record and record["invalidated_reason"] == "action_performed", "拉进过一次后提示应作废"
    assert not errors, errors

    # 返回首页：提示卡不再出现，下拉的残影已清掉
    page.go_back()
    page.wait_for_url("**/library", timeout=15000)
    page.wait_for_timeout(1500)
    assert tip.count() == 0
    assert page.locator("[data-testid=reels-floor]").count() == 0


def test_desktop_has_no_pull_entry(browser):
    context = browser.new_context(viewport={"width": 1440, "height": 1000})
    _login(context)
    context.request.delete(f"{BASE}/api/v1/tips/state")
    page = context.new_page()
    page.goto(f"{BASE}/library")
    page.get_by_test_id("library-stats").or_(page.locator("[data-testid^=home-row-]").first).first.wait_for(
        timeout=60000
    )
    assert page.locator(".reels-floor-host").count() == 0
    assert page.locator(f'[data-tip-id="{TIP}"]').count() == 0
    context.close()
