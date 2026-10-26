"""订阅窗口端到端：一季上千集时先订阅一段，完结季往后加、在播季往前补。

真实页面 → 接口 → 临时数据库；TMDB 是本地假响应（《长篇漫剧》一季 120 集已完结、
《在播长篇剧》一季 120 集剧还在播、《短篇剧》一季 12 集），文件整理入库由
``/__lab`` 模拟。用户路径：

1. 短篇剧：订阅弹层里没有任何「先订阅」选项（选项只在用得上时出现）；
2. 长篇漫剧（完结）：弹层里预填「先订阅前 20 集 · 本季共 120 集」，一次点击订阅，
   只展开 20 个工单；
3. 前 20 集入库：订阅仍在订阅中（不判「已收齐」），详情页横幅等用户决定，
   媒体页状态行说「已订阅到第 20 集 · 可继续」；
4. 「继续订阅 20 集」：end → 40，新增的 20 集补上工单；
5. 「调整订阅」里把集数改成 60；
6. 「订阅全部」：窗口清除，回到整季；全部入库后才收齐；
7. 已收齐的订阅再设窗口：回到订阅中；
8. 在播长篇剧：弹层预填「先订阅最新 20 集 · 本季已播 120 集」，自动续订默认开，
   订阅只展开第 101～120 集的工单；横幅「已订阅最新 20 集」，「往前再订 20 集」
   补到 81，「订阅全部」清掉窗口；
9. 手机尺寸：详情页横幅与「调整订阅」抽屉里的窗口行。
"""

import os
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

# 隔离环境里的一次性测试账号，只在本文件拉起的临时实例里有效
ADMIN = {"username": "cap-admin", "password": "isolated-cap-test"}


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("episode-cap-browser")
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
        "PYTHONPATH": f"{REPO / 'src'}{os.pathsep}{REPO}",
    }
    api = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._episode_cap_api_launcher:app",
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
            "NEXT_DIST_DIR": ".next-episode-cap-e2e",
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


def _subscriptions(context, base):
    rows = context.request.get(f"{base}/api/v1/subscriptions").json()["data"]
    return rows["items"] if isinstance(rows, dict) else rows


def _detail(context, base, sub_id):
    return context.request.get(f"{base}/api/v1/subscriptions/{sub_id}").json()["data"]


def _in_scope(detail):
    return sorted(w["episode_number"] for w in detail["wanted"] if w["season_number"] == 1)


def _patch(context, base, sub_id, body):
    response = context.request.patch(f"{base}/api/v1/subscriptions/{sub_id}", data=body)
    assert response.status == 200, response.text()
    return response.json()["data"]


def test_episode_cap_user_journey(stack):
    base, api, root = stack
    with pw.sync_playwright() as playwright:
        options = (
            {"channel": "chrome"}
            if Path("/Applications/Google Chrome.app").exists()
            else _chromium_kwargs()
        )
        browser = playwright.chromium.launch(headless=True, **options)
        context = browser.new_context(viewport={"width": 1440, "height": 1000})
        assert context.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN).status == 200
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        cap_field = page.get_by_label("第 1 季先订阅的集数", exact=True)

        # —— 1. 短篇剧：没有「先订阅」选项 ——
        page.goto(f"{base}/media/tv/1044")
        page.get_by_role("button", name="订阅追踪", exact=True).click()
        page.get_by_role("region", name="智能选择").get_by_role(
            "button", name="保存设置", exact=True
        ).click()
        page.get_by_role("region", name="追踪范围").wait_for()
        assert cap_field.count() == 0
        assert page.get_by_text("先订阅前", exact=False).count() == 0
        assert page.get_by_text("先订阅最新", exact=False).count() == 0
        page.get_by_role("button", name="取消", exact=True).click()

        # —— 2. 长篇漫剧（完结）：预填先订阅前 20 集，一次点击订阅 ——
        page.goto(f"{base}/media/tv/1043")
        page.get_by_role("button", name="订阅追踪", exact=True).click()
        cap_field.wait_for()
        assert cap_field.input_value() == "20"
        page.get_by_text("本季共 120 集", exact=False).wait_for()
        settled_screenshot(page, root / "1-subscribe-cap-desktop.png")
        page.get_by_role("button", name="确认订阅", exact=True).click()
        page.get_by_role("region", name="追踪范围").wait_for(state="detached")

        subs = _wait_for(lambda: _subscriptions(context, base), timeout=10, what="订阅创建完成")
        assert len(subs) == 1
        sub_id = subs[0]["id"]
        detail = _detail(context, base, sub_id)
        assert _in_scope(detail) == list(range(1, 21))
        assert detail["progress"]["total"] == 20
        assert detail["episode_windows"] == [
            {"season_number": 1, "start": 1, "end": 20, "total": 120}
        ]
        assert detail["status"] == "active"

        # —— 3. 前 20 集入库：订阅仍在订阅中，横幅等用户决定 ——
        imported = context.request.post(f"{api}/__lab/import-all/{sub_id}")
        assert imported.json()["status"] == "active", imported.text()  # 不判「已收齐」
        page.goto(f"{base}/subscriptions/{sub_id}")
        page.get_by_text("已订阅到第 20 集", exact=True).wait_for()
        page.get_by_text("第 1 季（前 20 集）", exact=True).wait_for()
        settled_screenshot(page, root / "2-window-banner-desktop.png", full_page=True)
        page.goto(f"{base}/media/tv/1043")
        page.get_by_text("已订阅到第 20 集 · 可继续", exact=True).wait_for()

        # —— 4. 继续订阅 20 集 ——
        page.goto(f"{base}/subscriptions/{sub_id}")
        page.get_by_role("button", name="继续订阅 20 集", exact=True).click()
        page.get_by_text("已继续订阅到第 40 集", exact=True).wait_for()
        _wait_for(
            lambda: _in_scope(_detail(context, base, sub_id)) == list(range(1, 41)),
            timeout=10,
            what="继续订阅后追踪 E01～E40",
        )
        detail = _detail(context, base, sub_id)
        wanted = {w["episode_number"]: w for w in detail["wanted"]}
        assert all(wanted[n]["status"] == "imported" for n in range(1, 21))  # 已入库的原样保留
        assert all(wanted[n]["status"] == "wanted" for n in range(21, 41))
        assert detail["episode_windows"] == [
            {"season_number": 1, "start": 1, "end": 40, "total": 120}
        ]

        # —— 5. 调整订阅里把集数改成 60（只改了窗口，库与季都不动） ——
        page.reload()
        page.get_by_role("button", name="更多", exact=True).first.click()
        page.get_by_role("menuitem", name="调整订阅…").click()
        assert cap_field.input_value() == "40"
        assert page.get_by_role("button", name="保存调整", exact=True).is_disabled()  # 没改动不可存
        cap_field.fill("60")
        cap_field.press("Enter")
        settled_screenshot(page, root / "3-adjust-cap-desktop.png")
        page.get_by_role("button", name="保存调整", exact=True).click()
        page.get_by_text("订阅已调整", exact=True).wait_for()
        assert _detail(context, base, sub_id)["episode_windows"][0]["end"] == 60

        # —— 6. 订阅全部：窗口清除，回到整季；全部入库后才收齐 ——
        page.get_by_role("button", name="订阅全部", exact=True).click()
        page.get_by_text("已订阅第 1 季全部 120 集", exact=True).wait_for()
        detail = _detail(context, base, sub_id)
        assert detail["episode_windows"] is None
        assert detail["episode_seasons"][0]["window"] is None
        assert detail["progress"]["total"] == 120
        imported = context.request.post(f"{api}/__lab/import-all/{sub_id}")
        assert imported.json()["status"] == "completed", imported.text()

        # —— 7. 已收齐的订阅再设窗口：回到订阅中，活动里说明原因 ——
        detail = _patch(
            context, base, sub_id, {"episode_caps": {"1": {"start": 1, "end": 20}}}
        )
        assert detail["status"] == "active" and detail["progress"]["total"] == 20
        activities = context.request.get(
            f"{base}/api/v1/subscriptions/{sub_id}/activities"
        ).json()["data"]
        assert any("本季还有没订到的集，可随时继续订阅" in a["message"] for a in activities)

        # —— 8. 在播长篇剧：预填最新 20 集、追新照常，横幅可往前补 ——
        page.goto(f"{base}/media/tv/1045")
        page.get_by_role("button", name="订阅追踪", exact=True).click()
        cap_field.wait_for()
        assert cap_field.input_value() == "20"
        page.get_by_text("本季已播 120 集", exact=False).wait_for()
        settled_screenshot(page, root / "6-subscribe-airing-desktop.png")
        page.get_by_role("button", name="确认订阅", exact=True).click()
        page.get_by_role("region", name="追踪范围").wait_for(state="detached")

        _wait_for(
            lambda: len(_subscriptions(context, base)) == 2, timeout=10, what="订阅创建完成"
        )
        subs = _subscriptions(context, base)
        sub_id = next(row["id"] for row in subs if row["media"]["tmdb_id"] == 1045)
        detail = _detail(context, base, sub_id)
        # 只订最新的 20 集，之后播出的集照常进来（追新默认开）
        assert detail["follow_future"] is True
        assert _in_scope(detail) == list(range(101, 121))
        assert detail["episode_windows"] == [
            {"season_number": 1, "start": 101, "end": None, "total": 120}
        ]

        page.goto(f"{base}/subscriptions/{sub_id}")
        page.get_by_text("已订阅最新 20 集", exact=True).wait_for()
        page.get_by_text("第 1 季（最新 20 集）", exact=True).wait_for()
        settled_screenshot(page, root / "7-airing-banner-desktop.png", full_page=True)
        page.get_by_role("button", name="往前再订 20 集", exact=True).click()
        page.get_by_text("已往前订到第 81 集", exact=True).wait_for()
        _wait_for(
            lambda: _in_scope(_detail(context, base, sub_id)) == list(range(81, 121)),
            timeout=10,
            what="往前再订后追踪 E81～E120",
        )
        assert _detail(context, base, sub_id)["episode_windows"] == [
            {"season_number": 1, "start": 81, "end": None, "total": 120}
        ]
        page.get_by_role("button", name="订阅全部", exact=True).click()
        page.get_by_text("已订阅第 1 季全部 120 集", exact=True).wait_for()
        assert _detail(context, base, sub_id)["episode_windows"] is None

        # —— 9. 手机尺寸：横幅与「调整订阅」抽屉里的窗口行 ——
        page.set_viewport_size({"width": 390, "height": 844})
        _patch(context, base, sub_id, {"episode_caps": {"1": {"start": 101, "end": None}}})
        page.goto(f"{base}/subscriptions/{sub_id}")
        page.get_by_text("已订阅最新 20 集", exact=True).wait_for()
        settled_screenshot(page, root / "8-airing-banner-mobile.png")
        page.get_by_role("button", name="更多", exact=True).last.click()
        page.get_by_role("button", name="调整订阅", exact=True).click()
        assert cap_field.input_value() == "20"
        settled_screenshot(page, root / "9-adjust-sheet-mobile.png")

        assert not errors, errors
        browser.close()
