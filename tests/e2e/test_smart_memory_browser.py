"""智能订阅记忆的浏览器验收：真实页面 → 接口 → 临时数据库；元数据与站点资源隔离。

按用户真实使用的顺序走一遍设计里的每个记忆场景（docs/design/smart-subscription-memory.md）：
首次设置、第一次碰到某种语言时问一次、等字幕与「这次先下原版」、改字幕回答、
按地区与平台记住画质、冲突时写明用了哪条、系列沿用、在设置里看和删、手机布局、成员视角。
"""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

from .test_library_manage_browser import REPO, WEB, _chromium_kwargs, _free_port, _wait_http

pw = pytest.importorskip("playwright.sync_api")
pytestmark = pytest.mark.integration

ADMIN = {"username": "memory-admin", "password": "isolated-test-only"}
SHOTS = Path(os.environ.get("MC_SHOT_DIR", "/tmp/smart-memory-shots"))


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("smart-memory-browser")
    api_port, web_port = _free_port(), _free_port()
    api_log = (root / "api.log").open("w")
    web_log = (root / "web.log").open("w")
    env = {
        **os.environ,
        "DATABASE_URL": f"sqlite+aiosqlite:///{root / 'data.db'}",
        "SECRET_KEY_FILE": str(root / "secret"),
        "SCHEDULER_ENABLED": "false",
        "SUBSCRIPTION_DISPATCH_DRY_RUN": "true",
        "METADATA_DIR": str(root / "metadata"),
        "LOG_DIR": str(root / "logs"),
        "PYTHONPATH": f"{REPO / 'src'}:{REPO}",
    }
    api = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "tests.e2e._smart_memory_api_launcher:app",
         "--host", "127.0.0.1", "--port", str(api_port)],
        cwd=REPO, env=env, stdout=api_log, stderr=subprocess.STDOUT,
    )
    web = subprocess.Popen(
        ["pnpm", "exec", "next", "dev", "--port", str(web_port)],
        cwd=WEB,
        env={**os.environ, "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
             "NEXT_DIST_DIR": ".next-smart-memory-e2e"},
        stdout=web_log, stderr=subprocess.STDOUT,
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 60)
        _wait_http(f"http://127.0.0.1:{web_port}/login", 180)
        yield f"http://127.0.0.1:{web_port}", f"http://127.0.0.1:{api_port}"
    finally:
        for proc in (web, api):
            proc.terminate()
        for proc in (web, api):
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        api_log.close()
        web_log.close()


@pytest.fixture(scope="module")
def browser():
    with pw.sync_playwright() as playwright:
        options = (
            {"channel": "chrome"} if Path("/Applications/Google Chrome.app").exists()
            else _chromium_kwargs()
        )
        browser = playwright.chromium.launch(headless=True, **options)
        yield browser
        browser.close()


def shot(page, name):
    SHOTS.mkdir(parents=True, exist_ok=True)
    page.wait_for_timeout(300)
    page.screenshot(path=str(SHOTS / f"web-{name}.png"))


def open_dialog(page, base, ref):
    kind, tmdb_id = ref.split(":")[1:]
    page.goto(f"{base}/media/{kind}/{tmdb_id}")
    page.get_by_role("button", name="订阅追踪").first.click()
    card = page.get_by_role("region", name="智能选择")
    card.wait_for()
    return card


def confirm(page):
    page.get_by_role("button", name="确认订阅", exact=True).last.click()
    page.get_by_role("region", name="智能选择").wait_for(state="detached")


def subscription_id(context, base, tmdb_id):
    rows = context.request.get(f"{base}/api/v1/subscriptions").json()["data"]
    items = rows["items"] if isinstance(rows, dict) else rows
    return next(s["id"] for s in items if s["media"]["tmdb_id"] == tmdb_id)


def detail(context, base, sub_id):
    return context.request.get(f"{base}/api/v1/subscriptions/{sub_id}").json()["data"]


def test_memory_follows_the_whole_household_journey(stack, browser):
    base, api = stack
    context = browser.new_context(viewport={"width": 1440, "height": 1000})
    assert context.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN).status == 200
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))

    # 1 首次设置就在弹层里，电影和剧集共用一套
    card = open_dialog(page, base, "tmdb:movie:701")
    card.get_by_text("只需设置一次，电影和剧集都按它来。").wait_for()
    assert page.get_by_role("button", name="确认订阅", exact=True).last.is_disabled()
    shot(page, "01-first-setup")
    card.get_by_role("button", name="保存设置").click()

    # 2 第一次碰到英语：问一次，默认已选好，直接订阅
    question = card.get_by_role("group", name="这是英语片，要中文字幕吗？")
    question.wait_for()
    assert question.get_by_label("要，只下带中文字幕的").is_checked()
    shot(page, "02-first-english-question")
    confirm(page)
    oppenheimer = subscription_id(context, base, 701)
    assert detail(context, base, oppenheimer)["smart_policy"]["watchable_languages"] == ["zh"]

    # 3 站点上只有英语原版：详情写明在等字幕；这次先下原版，然后追问看不看得懂
    released = context.request.post(f"{api}/__lab/release/movie/701?name=RAW&hours_ago=1").json()
    assert released["dispatched"] == 0
    page.goto(f"{base}/subscriptions/{oppenheimer}")
    page.get_by_text("已有 1 个原版，在等带字幕的版本").first.wait_for()
    waiting = page.get_by_role("group", name="等待字幕版")
    waiting.get_by_text("英语 · 只下带中文字幕的").wait_for()
    shot(page, "03-awaiting-subtitles")
    waiting.get_by_role("button", name="这次先下原版").click()
    follow_up = page.get_by_role("group", name="看得懂这种语言吗")
    follow_up.get_by_text("已开始下载原版。你看得懂英语吗？").wait_for()
    shot(page, "04-understood-follow-up")
    follow_up.get_by_role("button", name="只这次").click()
    follow_up.wait_for(state="detached")
    # 服务端在后台立即处理这次请求：原版交给了下载器（dry-run）
    context.request.post(f"{api}/__lab/evaluate/{oppenheimer}")
    assert detail(context, base, oppenheimer)["wanted"][0]["status"] != "wanted"

    # 4 同一种语言不再问，剧集照用；点「改」改成看得懂
    card = open_dialog(page, base, "tmdb:tv:804")
    card.get_by_text("英语 · 只下带中文字幕的").wait_for()
    assert card.get_by_role("group", name=re.compile("要中文字幕吗")).count() == 0
    card.get_by_role("button", name="改字幕要求").click()
    card.get_by_label("不用，我看得懂英语").check()
    card.get_by_text("英语 · 不需要字幕").count()  # 预览会在提交后由服务端确认
    shot(page, "05-change-language-answer")
    confirm(page)
    breaking_bad = subscription_id(context, base, 804)
    assert detail(context, base, breaking_bad)["smart_policy"]["watchable_languages"] == []
    # 奥本海默已经下载了，不会因此重下；记忆里多了英语
    page.goto(f"{base}/settings/subscription")
    languages = page.get_by_role("list", name="看得懂的语言")
    languages.get_by_text("英语").wait_for()
    languages.get_by_text("订阅《绝命毒师》时加入").wait_for()

    # 5 改了画质才问要不要记住，原因由用户自己点
    card = open_dialog(page, base, "tmdb:tv:801")
    card.get_by_role("group", name="这是韩语片，要中文或英语字幕吗？").wait_for()
    card.get_by_role("button", name="改画质").click()
    card.get_by_role("group", name="分辨率").get_by_role("button", name="1080p").click()
    remember = card.get_by_role("group", name="以后也这样吗？")
    assert remember.get_by_label("只这部").is_checked()
    assert [r.inner_text().strip() for r in remember.locator("label").all()] == [
        "只这部", "所有剧集", "韩国的剧", "tvN 的剧",
    ]
    remember.get_by_label("韩国的剧").check()
    shot(page, "06-remember-scope")
    confirm(page)

    card = open_dialog(page, base, "tmdb:tv:802")
    card.get_by_text("优先 1080p WEB-DL").wait_for()
    card.get_by_text("按「韩国的剧」的习惯").wait_for()
    card.get_by_text("韩语 · 只下带中文或英语字幕的").wait_for()
    shot(page, "07-habit-applied")
    page.get_by_role("button", name="取消", exact=True).last.click()

    # 6 平台习惯比地区具体，写明被盖住的那条
    card = open_dialog(page, base, "tmdb:tv:803")
    card.get_by_role("button", name="改画质").click()
    card.get_by_role("group", name="分辨率").get_by_role("button", name="4K").click()
    card.get_by_role("group", name="以后也这样吗？").get_by_label("Netflix 的剧").check()
    confirm(page)
    card = open_dialog(page, base, "tmdb:tv:806")
    card.get_by_text("优先 4K WEB-DL").wait_for()
    card.get_by_text("按「Netflix 的剧」的习惯").wait_for()
    card.get_by_text("「韩国的剧」是 1080p").wait_for()
    shot(page, "08-conflict-order")
    page.get_by_role("button", name="取消", exact=True).last.click()

    # 7 「只这部」不会白设：续集沿用
    card = open_dialog(page, base, "tmdb:movie:703")
    card.get_by_role("button", name="改画质").click()
    card.get_by_role("group", name="片源").get_by_role("button", name="Remux").click()
    confirm(page)
    card = open_dialog(page, base, "tmdb:movie:704")
    card.get_by_text("优先 4K Remux").wait_for()
    card.get_by_text("按《沙丘》的设置").wait_for()
    shot(page, "09-series-carry-over")
    confirm(page)
    sequel = detail(context, base, subscription_id(context, base, 704))
    assert sequel["smart_policy"]["source"] == "remux"

    # 8 设置页：所有记忆在一个列表里，写明来源，可以删；删了就回到默认
    page.goto(f"{base}/settings/subscription")
    habits = page.get_by_role("list", name="画质习惯")
    habits.get_by_text("韩国的剧 · 1080p").wait_for()
    habits.get_by_text("来自《请回答1988》").wait_for()
    habits.get_by_text("Netflix 的剧 · 4K").wait_for()
    shot(page, "10-settings-memory")
    habits.get_by_role("button", name="移除韩国的剧").click()
    habits.get_by_text("韩国的剧 · 1080p").wait_for(state="detached")
    reply = subscription_id(context, base, 801)
    assert detail(context, base, reply)["smart_policy"]["resolution"] == "2160p"
    page.get_by_label("添加看得懂的语言").select_option("ja")
    page.get_by_role("button", name="添加", exact=True).click()
    page.get_by_role("list", name="看得懂的语言").get_by_text("日语").wait_for()
    page.get_by_role("button", name="移除日语").click()
    page.get_by_role("list", name="看得懂的语言").get_by_text("日语").wait_for(state="detached")

    # 9 手机：同一张卡片，问题照样只问一次
    phone = browser.new_context(viewport={"width": 390, "height": 844}, is_mobile=True,
                                has_touch=True, storage_state=context.storage_state())
    mobile = phone.new_page()
    mobile.on("pageerror", lambda error: errors.append(str(error)))
    card = open_dialog(mobile, base, "tmdb:movie:702")
    card.get_by_role("group", name="这是粤语片，要中文或英语字幕吗？").wait_for()
    shot(mobile, "11-phone-cantonese")
    phone.close()
    assert errors == []
    context.close()


def test_members_only_see_conclusions(stack, browser):
    base, _api = stack
    admin = browser.new_context()
    assert admin.request.post(f"{base}/api/v1/auth/login", data=ADMIN).status == 200
    assert admin.request.post(
        f"{base}/api/v1/members", data={"username": "kid", "password": "member-pass-1"}
    ).status == 200
    admin.close()
    context = browser.new_context(viewport={"width": 1440, "height": 1000})
    assert context.request.post(
        f"{base}/api/v1/auth/login", data={"username": "kid", "password": "member-pass-1"}
    ).status == 200
    page = context.new_page()
    card = open_dialog(page, base, "tmdb:tv:805")
    card.get_by_text("日语 · 只下带中文或英语字幕的").wait_for()
    assert card.get_by_role("button", name="改画质").count() == 0
    assert card.get_by_role("button", name="修改设置").count() == 0
    assert card.get_by_role("button", name="改字幕要求").count() == 0
    assert card.get_by_role("group", name=re.compile("字幕吗")).count() == 0
    shot(page, "12-member-view")
    context.close()


def test_switching_modes_never_leaves_submit_stuck(stack, browser):
    """改到一半切到规则模式再切回来：没保存的编辑作废，确认订阅不会一直灰着。"""
    base, _api = stack
    context = browser.new_context(viewport={"width": 1440, "height": 1000})
    assert context.request.post(f"{base}/api/v1/auth/login", data=ADMIN).status == 200
    page = context.new_page()
    card = open_dialog(page, base, "tmdb:movie:706")
    card.get_by_role("button", name="修改设置").click()
    submit = page.get_by_role("button", name="确认订阅", exact=True).last
    assert submit.is_disabled()
    page.get_by_role("button", name=re.compile("^更多选项")).click()
    page.get_by_role("button", name=re.compile("^选择方式")).click()
    page.get_by_role("menuitemradio", name="规则模式").click()
    page.get_by_role("button", name=re.compile("^选择方式")).click()
    page.get_by_role("menuitemradio", name="智能选择").click()
    page.get_by_role("region", name="智能选择").get_by_text("优先 4K WEB-DL").wait_for()
    assert submit.is_enabled()
    context.close()
