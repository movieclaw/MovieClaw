"""issue #640 端到端：TMDB 少录集数时，订阅能按真实集数继续追。

真实页面 → 接口 → 临时数据库；TMDB 与豆瓣是本地假响应（《死刑将至》TMDB 6 集、
豆瓣 27 集），站点新种子与入库由 ``/__lab`` 模拟。用户路径：

1. 从豆瓣条目订阅：弹层提示「按豆瓣集数追（27 集）」，打开后订阅追 27 集；
2. 详情页「更多 → 调整集数」改成 30 集、再改回 TMDB 的 6 集；
3. 改回后豆瓣证据重新浮出提示 → 忽略；
4. 6 集入库订阅收齐；站点出现第 30 集 → 订阅退回追踪并提示 → 一键按 30 集追，
   随后第 30 集的单集种子被自动投递；
5. 手机尺寸：「更多」抽屉里有「调整集数」，弹层可用。
"""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

from .test_library_manage_browser import (
    REPO,
    WEB,
    _chromium_kwargs,
    _free_port,
    _wait_for,
    _wait_http,
)
from .test_smart_subscription_browser import settled_screenshot

pw = pytest.importorskip("playwright.sync_api")
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("episode-floor-browser")
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
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._episode_floor_api_launcher:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(api_port),
        ],
        cwd=REPO,
        env=env,
        stdout=api_log,
        stderr=subprocess.STDOUT,
    )
    web = subprocess.Popen(
        ["pnpm", "exec", "next", "dev", "--port", str(web_port)],
        cwd=WEB,
        env={
            **os.environ,
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
            "NEXT_DIST_DIR": ".next-episode-floor-e2e",
        },
        stdout=web_log,
        stderr=subprocess.STDOUT,
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 60)
        _wait_http(f"http://127.0.0.1:{web_port}/login", 120)
        yield f"http://127.0.0.1:{web_port}", f"http://127.0.0.1:{api_port}", root
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


def _detail(context, base, sub_id):
    return context.request.get(f"{base}/api/v1/subscriptions/{sub_id}").json()["data"]


def _in_scope(detail):
    return sorted(w["episode_number"] for w in detail["wanted"] if w["season_number"] == 1)


def test_episode_floor_user_journey(stack):
    base, api, root = stack
    with pw.sync_playwright() as playwright:
        options = (
            {"channel": "chrome"}
            if Path("/Applications/Google Chrome.app").exists()
            else _chromium_kwargs()
        )
        browser = playwright.chromium.launch(headless=True, **options)
        context = browser.new_context(viewport={"width": 1440, "height": 1000})
        assert (
            context.request.post(
                f"{base}/api/v1/auth/bootstrap",
                data={"username": "floor-admin", "password": "isolated-floor-test"},
            ).status
            == 200
        )
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))

        # —— 1. 从豆瓣条目订阅，确认按豆瓣集数追 ——
        page.goto(f"{base}/media/douban/36000640")
        page.get_by_role("button", name="订阅追踪", exact=True).click()
        card = page.get_by_role("region", name="剧集智能设置")
        card.get_by_role("button", name="保存剧集设置", exact=True).click()
        toggle = page.get_by_role("switch", name=re.compile("按豆瓣集数追（27 集）"))
        toggle.wait_for()
        page.get_by_text("豆瓣显示第 1 季共 27 集，TMDB 只录了 6 集", exact=False).wait_for()
        assert toggle.get_attribute("aria-checked") == "false"  # 默认不改，要用户确认
        toggle.click()
        assert toggle.get_attribute("aria-checked") == "true"
        settled_screenshot(page, root / "1-subscribe-douban-toggle.png")
        page.get_by_role("button", name="确认订阅", exact=True).click()
        card.wait_for(state="hidden")

        subs = context.request.get(f"{base}/api/v1/subscriptions").json()["data"]
        assert len(subs) == 1
        sub_id = subs[0]["id"]
        detail = _detail(context, base, sub_id)
        assert _in_scope(detail) == list(range(1, 28))
        assert detail["episode_seasons"] == [{"season_number": 1, "tmdb_count": 6, "floor": 27}]
        provisional = [w["episode_number"] for w in detail["wanted"] if w["provisional"]]
        assert provisional == list(range(7, 28))
        assert detail["episode_hints"] == []  # 已按豆瓣集数追，豆瓣证据不再提示

        # —— 2. 详情页调整集数：改成 30，再改回 TMDB 的 6 ——
        page.goto(f"{base}/subscriptions/{sub_id}")
        page.get_by_role("button", name="更多", exact=True).first.click()
        page.get_by_role("menuitem", name="调整集数…").click()
        field = page.get_by_label("第 1 季集数", exact=True)
        assert field.input_value() == "27"
        page.get_by_text("TMDB 录了 6 集 · 当前按 27 集追", exact=True).wait_for()
        field.fill("30")
        settled_screenshot(page, root / "2-floor-dialog-desktop.png")
        page.get_by_role("button", name="保存", exact=True).click()
        page.get_by_text("已按新的集数继续追踪", exact=True).wait_for()
        _wait_for(
            lambda: [w for w in _in_scope(_detail(context, base, sub_id))] == list(range(1, 31)),
            timeout=10,
            what="调成 30 集后追踪 E01～E30",
        )

        page.get_by_role("button", name="更多", exact=True).first.click()
        page.get_by_role("menuitem", name="调整集数…").click()
        page.get_by_label("第 1 季集数", exact=True).fill("6")
        page.get_by_role("button", name="保存", exact=True).click()
        page.get_by_text("已改回以 TMDB 集数为准", exact=True).wait_for()
        detail = _detail(context, base, sub_id)
        assert detail["episode_seasons"][0]["floor"] is None
        # 超出 TMDB 的占位集全部出域，进度只算 TMDB 的 6 集
        assert detail["progress"]["total"] == 6, detail["progress"]

        # —— 3. 改回后豆瓣证据重新提示 → 忽略 ——
        banner = page.get_by_text("第 1 季可能还没收齐", exact=True)
        banner.wait_for()
        page.get_by_text("豆瓣显示共 27 集，TMDB 只录了 6 集", exact=True).wait_for()
        settled_screenshot(page, root / "3-douban-hint-desktop.png")
        page.get_by_role("button", name="忽略", exact=True).click()
        banner.wait_for(state="hidden")
        assert _detail(context, base, sub_id)["episode_hints"] == []

        # —— 4. 6 集入库 → 收齐；站点出现第 30 集 → 退回追踪并提示 → 一键采纳 ——
        imported = context.request.post(f"{api}/__lab/import-all/{sub_id}")
        assert imported.json()["status"] == "completed", imported.text()
        context.request.post(
            f"{api}/__lab/torrent",
            data={
                "torrent_id": "e30",
                "title": "Death Row Is Coming S01E30 1080p WEB-DL",
                "attrs": {"seasons": [1], "episodes": [30]},
            },
        )
        detail = _detail(context, base, sub_id)
        assert detail["status"] == "active"
        assert [(h["suggested"], h["site_episode"]) for h in detail["episode_hints"]] == [(30, 30)]
        page.reload()
        page.get_by_text("站点上已出现第 30 集的资源，TMDB 只录了 6 集", exact=True).wait_for()
        page.get_by_text("Death Row Is Coming S01E30 1080p WEB-DL", exact=True).wait_for()
        settled_screenshot(page, root / "4-site-hint-desktop.png", full_page=True)
        page.get_by_role("button", name="按 30 集继续追", exact=True).click()
        page.get_by_text("第 1 季可能还没收齐", exact=True).wait_for(state="hidden")
        detail = _detail(context, base, sub_id)
        assert detail["episode_seasons"][0]["floor"] == 30
        assert detail["status"] == "active"
        wanted = {w["episode_number"]: w for w in detail["wanted"]}
        assert all(wanted[n]["status"] == "imported" for n in range(1, 7))
        assert all(wanted[n]["status"] == "wanted" for n in range(7, 31))

        # 采纳后再到的第 30 集单集种子能满足占位集：达到智能目标档位，自动投递（dry-run）
        context.request.post(
            f"{api}/__lab/torrent",
            data={
                "torrent_id": "e30-web",
                "title": "Death Row Is Coming S01E30 2160p WEB-DL-LAB",
                "attrs": {
                    "seasons": [1],
                    "episodes": [30],
                    "resolution": "2160p",
                    "media_source": "WEB-DL",
                    "release_group": "LAB",
                },
            },
        )
        wanted = {w["episode_number"]: w for w in _detail(context, base, sub_id)["wanted"]}
        assert wanted[30]["status"] == "grabbed"
        assert wanted[30]["provisional"] is True
        assert wanted[29]["status"] == "wanted"
        page.reload()
        # 单季剧的分集列表常驻展开，直接点开第 30 集的履历
        page.get_by_role("button", name=re.compile(r"^E30")).click()
        page.get_by_text("TMDB 未收录这一集，按设置的集数追踪", exact=True).wait_for()
        settled_screenshot(page, root / "4b-e30-grabbed-desktop.png", full_page=True)

        # —— 5. 手机尺寸：「更多」抽屉里的调整集数 ——
        page.set_viewport_size({"width": 390, "height": 844})
        page.goto(f"{base}/subscriptions/{sub_id}")
        page.get_by_role("button", name="更多", exact=True).last.click()
        page.get_by_role("button", name="调整集数", exact=True).click()
        mobile_field = page.get_by_label("第 1 季集数", exact=True)
        assert mobile_field.input_value() == "30"
        settled_screenshot(page, root / "5-floor-sheet-mobile.png")

        assert not errors, errors
        browser.close()
