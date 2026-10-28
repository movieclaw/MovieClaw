"""网页片段（/reels）与手机媒体库首页「下拉二楼」入口：真实服务上的浏览器验收。

E2E_WEB_URL 指向本分支前端，MC_TEST_USERNAME / MC_TEST_PASSWORD 提供登录（超管）；
片库里要有能刷的片子（服务端开了片段预切时只出切好的）。E2E_SHOT_DIR 可保存截图。
手机用例用 CDP 发真实触摸事件：按住往下拉、停住截图、再松手，与手指一样经过首页的触摸处理。

片段页的筛选、收藏 / 已看、画质、字幕、分享各一个用例，按片库里实际有的片子取材（不认片名）；
收藏 / 已看点两下复原，已看只挑没有续播点的条目（标已看会清掉续播点）。成员的分享另要
MC_MEMBER_USERNAME / MC_MEMBER_PASSWORD，不给就跳过。
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest

pw = pytest.importorskip("playwright.sync_api")
BASE = os.environ.get("E2E_WEB_URL", "").rstrip("/")
SHOTS = Path(os.environ.get("E2E_SHOT_DIR", "/tmp/reels-browser"))
pytestmark = [pytest.mark.integration, pytest.mark.skipif(not BASE, reason="需指定 E2E_WEB_URL")]
TIP = "library.reels-floor"
PHONE = {
    "viewport": {"width": 393, "height": 852},
    "device_scale_factor": 3,
    "is_mobile": True,
    "has_touch": True,
}


@pytest.fixture(scope="module")
def browser():
    SHOTS.mkdir(parents=True, exist_ok=True)
    with pw.sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        yield browser
        browser.close()


def _login(context, username=None, password=None):
    response = context.request.post(
        f"{BASE}/api/v1/auth/login",
        data={
            "username": username or os.environ["MC_TEST_USERNAME"],
            "password": password or os.environ["MC_TEST_PASSWORD"],
            "remember": False,
        },
    )
    assert response.ok and response.json()["success"]


@pytest.fixture
def phone(browser):
    context = browser.new_context(**PHONE)
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
    page.get_by_test_id("library-stats").or_(
        page.locator("[data-testid^=home-row-]").first
    ).first.wait_for(timeout=60000)
    assert page.locator(".reels-floor-host").count() == 0
    assert page.locator(f'[data-tip-id="{TIP}"]').count() == 0
    context.close()


ACTIVE = "[data-testid=reels-page][data-active]"
MEMBER = (os.environ.get("MC_MEMBER_USERNAME"), os.environ.get("MC_MEMBER_PASSWORD"))


class Reels:
    """片段页的一次浏览：记下信息流返回的条目、开会话的请求与字幕请求，按当前页认条目。"""

    def __init__(self, context):
        self.page = context.new_page()
        self.items: list[dict] = []
        self.subtitles: list[tuple[int, str]] = []
        self.errors: list[str] = []
        self.page.on("pageerror", lambda error: self.errors.append(str(error)))
        self.page.on("response", self._on_response)

    def _on_response(self, response):
        url = response.url
        if "/api/v1/reels?" in url:
            if response.ok:
                if "offset" not in parse_qs(
                    urlparse(url).query
                ):  # 第一页：进页面或换了条件，从头记
                    self.items = []
                self.items.extend(response.json()["data"]["items"])
        elif "/subtitles?" in url:
            self.subtitles.append((response.status, url))

    def open(self):
        self.page.goto(f"{BASE}/reels")
        self.page.get_by_test_id("reels-page").first.wait_for(timeout=60000)

    @property
    def video(self):
        return self.page.get_by_test_id("reels-video")

    def current(self) -> dict:
        """当前这一页的条目（按「详情」链接里的条目与季集认）"""
        detail = self.page.locator(f"{ACTIVE} [data-testid=reels-detail]")
        link = urlparse(detail.get_attribute("href"))
        media_item_id = int(link.path.rstrip("/").split("/")[-1])
        query = parse_qs(link.query)
        unit = (int(query["season"][0]), int(query["episode"][0])) if "season" in query else None
        for item in self.items:
            episode = item["title"]["episode"]
            if (
                item["title"]["media_item_id"] == media_item_id
                and ((episode["season"], episode["episode"]) if episode else None) == unit
            ):
                return item
        raise AssertionError(f"信息流里没有当前这一页：{link.geturl()}")

    def swipe(self):
        pager = self.page.get_by_test_id("reels-pager")
        pager.evaluate("el => el.scrollBy({ top: el.clientHeight })")
        self.page.wait_for_timeout(900)

    def wait_playing(self, tries=4):
        """等当前这一条放起来；放不出的（片源转不了）往下滑一条，同 iOS 的提示"""
        for _ in range(tries):
            try:
                self.page.wait_for_function(
                    "el => el.dataset.status === 'playing' && el.currentTime > 0.3",
                    arg=self.video.element_handle(),
                    timeout=45000,
                )
                return
            except pw.TimeoutError:
                self.swipe()
        raise AssertionError("片段应能放起来")

    def seek_to(self, accept, limit=8) -> dict:
        """往下滑到第一条满足条件的片段并等它放起来"""
        for _ in range(limit):
            self.wait_playing()
            item = self.current()
            if accept(item):
                return item
            self.swipe()
        pytest.skip("前几条里没有合适的片段")


@pytest.fixture
def reels(phone):
    session = Reels(phone)
    session.open()
    yield session
    assert not session.errors, session.errors


def _is_feed(response) -> bool:
    return "/api/v1/reels?" in response.url


def _is_session(request) -> bool:
    return request.url.endswith("/playback/sessions") and request.method == "POST"


def _marks(context, target: dict) -> dict:
    query = "&".join(f"{key}={value}" for key, value in target.items())
    return context.request.get(f"{BASE}/api/v1/playback/marks?{query}").json()["data"]


def test_filter_sheet_narrows_feed_and_clears(phone, reels):
    page = reels.page
    genres = phone.request.get(f"{BASE}/api/v1/reels/facets").json()["data"]["genres"]
    genre = max(genres, key=lambda value: value["count"], default=None)
    if not genre or not genre["count"]:
        pytest.skip("片库里没有带类型的片子")
    everything = page.get_by_test_id("reels-filter").inner_text()

    page.get_by_test_id("reels-filter").click()
    sheet = page.get_by_role("dialog")
    chip = re.compile(rf"^{re.escape(genre['label'])}\s*{genre['count']}$")
    with page.expect_response(_is_feed) as narrowed:
        sheet.get_by_role("button", name=chip).click()
    # 信息流按新条件从头取
    assert parse_qs(urlparse(narrowed.value.url).query).get("g") == [genre["value"]]
    # 计数跟着条件重算：这一类有几部，抽屉上就写几部
    pw.expect(sheet.get_by_test_id("reels-filter-total")).to_contain_text(str(genre["count"]))
    page.screenshot(path=str(SHOTS / "reels-filter-sheet.png"))
    page.keyboard.press("Escape")

    # 顶栏只有一个条件时写它的值
    pw.expect(page.get_by_test_id("reels-filter")).to_have_text(genre["label"])
    reels.wait_playing()

    page.get_by_test_id("reels-filter").click()
    with page.expect_response(_is_feed) as cleared:
        page.get_by_role("dialog").get_by_test_id("reels-filter-clear").click()
    assert "g" not in parse_qs(urlparse(cleared.value.url).query)
    page.keyboard.press("Escape")
    pw.expect(page.get_by_test_id("reels-filter")).to_have_text(everything)
    reels.wait_playing()


def test_favorite_and_played_write_through(phone, reels):
    page = reels.page
    reels.wait_playing()
    item = reels.current()
    whole = {"media_item_id": item["title"]["media_item_id"]}
    favorite = page.locator(f"{ACTIVE} [data-testid=reels-favorite]")
    before = _marks(phone, whole)["is_favorite"]
    pw.expect(favorite).to_have_attribute("aria-pressed", str(before).lower())
    favorite.click()
    pw.expect(favorite).to_have_attribute("aria-pressed", str(not before).lower())
    assert _marks(phone, whole)["is_favorite"] is (not before)
    favorite.click()  # 复原
    pw.expect(favorite).to_have_attribute("aria-pressed", str(before).lower())
    assert _marks(phone, whole)["is_favorite"] is before

    # 已看：电影标整部、剧集标这一集。挑没看过、没有续播点的（标已看会清掉续播点）
    item = reels.seek_to(
        lambda reel: not reel["title"]["played"] and reel["title"]["progress_percent"] is None
    )
    episode = item["title"]["episode"]
    unit = {"media_item_id": item["title"]["media_item_id"]}
    if episode:
        unit |= {"season_number": episode["season"], "episode_number": episode["episode"]}
    played = page.locator(f"{ACTIVE} [data-testid=reels-played]")
    played.click()
    pw.expect(played).to_have_attribute("aria-pressed", "true")
    assert _marks(phone, unit)["played"] is True
    page.screenshot(path=str(SHOTS / "reels-played.png"))
    played.click()
    pw.expect(played).to_have_attribute("aria-pressed", "false")
    assert _marks(phone, unit)["played"] is False


def test_quality_reopens_current_reel_with_limit(reels):
    page = reels.page
    # 预切片段没有画质可选（本身就是 1080p 小文件）：找一条原片起播的
    item = reels.seek_to(lambda reel: reel["play"]["mode"] != "clip")
    page.wait_for_timeout(2500)  # 放一会儿：换画质要从这里接着放，不是从片段开头
    quality = page.locator(f"{ACTIVE} [data-testid=reels-quality]")
    quality.click()
    with page.expect_request(_is_session, timeout=30000) as opened:
        page.get_by_test_id("reels-quality-720").click()
    body = json.loads(opened.value.post_data)
    assert body["file_id"] == item["segment"]["file_id"] and body["max_height"] == 720, body
    assert item["segment"]["start_ms"] + 1500 < body["start_ms"] < item["segment"]["end_ms"], body
    reels.wait_playing(tries=1)
    pw.expect(quality).to_have_text(re.compile("720p"))
    assert page.evaluate("() => localStorage.getItem('movieclaw.reels.quality')") == "720"
    page.screenshot(path=str(SHOTS / "reels-quality-720.png"))

    # 记住了：之后刷到的原片也按 720p 开
    with page.expect_request(_is_session, timeout=60000) as later:
        for _ in range(6):
            reels.swipe()
            if reels.current()["play"]["mode"] != "clip":
                break
    assert json.loads(later.value.post_data)["max_height"] == 720


def test_clip_subtitles_follow_the_reel(reels):
    page = reels.page
    item = reels.seek_to(lambda reel: bool((reel["play"]["subtitle"] or {}).get("url")))
    page.wait_for_timeout(1500)
    file_id = item["segment"]["file_id"]
    # 只抽片段前后一小段的字幕文件，不是整轨
    window = f"/files/{file_id}/subtitles?"
    fetched = [(code, url) for code, url in reels.subtitles if window in url]
    assert fetched, reels.subtitles
    assert all(code == 200 and "start_ms=" in url for code, url in fetched), fetched
    if item["play"]["subtitle"]["format"] == "srt":
        # srt 让服务端转成 VTT 交浏览器解析，字幕层自己画
        assert all("format=vtt" in url for _, url in fetched)
        page.wait_for_function(
            "() => document.querySelector('[data-testid=reels-video] track')?.readyState === 2",
            timeout=15000,
        )
    else:
        # ASS 交 JASSUB，画布和视频在同一个框里
        page.wait_for_function(
            "() => !!document.querySelector('[data-testid=reels-video]')"
            ".parentElement.querySelector('canvas')",
            timeout=15000,
        )
    page.screenshot(path=str(SHOTS / "reels-subtitle.png"))


def test_share_opens_link_dialog_for_admin(reels):
    page = reels.page
    reels.wait_playing()
    name = reels.current()["title"]["name"]
    page.locator(f"{ACTIVE} [data-testid=reels-share]").click()
    dialog = page.get_by_role("dialog")
    pw.expect(dialog).to_contain_text(name)
    pw.expect(reels.video).to_have_attribute("data-status", "paused")
    page.screenshot(path=str(SHOTS / "reels-share.png"))
    page.keyboard.press("Escape")
    pw.expect(dialog).to_have_count(0)


@pytest.mark.skipif(not all(MEMBER), reason="需指定 MC_MEMBER_USERNAME / MC_MEMBER_PASSWORD")
def test_share_sends_title_for_member(browser):
    context = browser.new_context(**PHONE)
    _login(context, *MEMBER)
    session = Reels(context)
    # 手机浏览器的系统分享面板：记下分享出去的内容
    session.page.add_init_script(
        "navigator.share = data => { window.__shared = data; return Promise.resolve(); }"
    )
    session.open()
    session.wait_playing()
    title = session.current()["title"]
    session.page.locator(f"{ACTIVE} [data-testid=reels-share]").click()
    shared = session.page.wait_for_function("() => window.__shared").json_value()
    assert title["name"] in shared["text"]
    if title["year"]:
        assert str(title["year"]) in shared["text"]
    # 成员不能建分享链接：不弹分享弹窗
    assert session.page.get_by_role("dialog").count() == 0
    assert not session.errors, session.errors
    context.request.post(f"{BASE}/api/v1/auth/logout")
    context.close()
