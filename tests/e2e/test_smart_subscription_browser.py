"""真实页面 → 接口 → 临时数据库 → 详情；外部元数据与下载器隔离。"""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

from .test_library_manage_browser import REPO, WEB, _chromium_kwargs, _free_port, _wait_http

pw = pytest.importorskip("playwright.sync_api")
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def smart_stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("smart-browser")
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
            "tests.e2e._smart_api_launcher:app",
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
            "NEXT_DIST_DIR": ".next-smart-e2e",
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


def settled_screenshot(page, path, **options):
    # 启动遮罩淡出期间允许点击；截图等待其透明度真正降为零。
    page.wait_for_function("""() => {
      const layers = document.querySelectorAll('div[aria-hidden=true].fixed.inset-0');
      return [...layers].filter(el => el.querySelector('svg')).every(el => {
        const style = getComputedStyle(el);
        return style.opacity === '0' || style.display === 'none';
      });
    }""")
    page.screenshot(path=str(path), **options)


def test_setup_reuse_wait_actions_and_mobile(smart_stack):
    base, api, root = smart_stack
    with pw.sync_playwright() as playwright:
        options = (
            {"channel": "chrome"}
            if Path("/Applications/Google Chrome.app").exists()
            else _chromium_kwargs()
        )
        browser = playwright.chromium.launch(headless=True, **options)
        context = browser.new_context(viewport={"width": 1440, "height": 1100})
        response = context.request.post(
            f"{base}/api/v1/auth/bootstrap",
            data={"username": "smart-admin", "password": "isolated-test-only"},
        )
        assert response.status == 200
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        # Removed preview links no longer mount a feature or expose its API.
        page.goto(f"{base}/settings/subscription?preview=1&run=1")
        page.get_by_role("region", name="剧集智能设置").wait_for()
        assert page.get_by_role("link", name="试订阅", exact=False).count() == 0
        assert page.get_by_role("button", name="智能订阅试验室", exact=True).count() == 0
        assert page.get_by_role("region", name="预览结果").count() == 0
        page.goto(f"{base}/settings/smart-lab")
        page.get_by_role("heading", name="404", exact=True).wait_for()
        spec = context.request.get(f"{base}/api/v1/spec").json()
        assert not any("smart-lab" in route for route in spec["paths"])
        assert context.request.post(f"{api}/api/v1/subscriptions/smart-lab", data={}).status in (
            404,
            405,
        )
        assert context.request.get(f"{api}/api/v1/subscriptions/smart-lab/1").status == 404
        page.goto(f"{base}/media/tv/200")
        page.get_by_role("button", name="订阅追踪", exact=True).click()
        card = page.get_by_role("region", name="剧集智能设置")
        card.get_by_role("button", name="保存剧集设置", exact=True).wait_for()
        assert page.get_by_role("button", name="确认订阅", exact=True).is_disabled()
        settled_screenshot(page, root / "tv-first-desktop.png")
        card.get_by_role("button", name="保存剧集设置", exact=True).click()
        card.get_by_role("button", name="修改设置", exact=True).click()
        assert page.get_by_role("button", name="确认订阅", exact=True).is_disabled()
        card.get_by_label("优先分辨率", exact=True).select_option("1080p")
        card.get_by_role("button", name="取消修改", exact=True).click()
        card.get_by_text("优先 4K WEB-DL", exact=True).wait_for()
        assert page.get_by_role("button", name="规则模式", exact=True).count() == 0
        assert page.get_by_text("后续剧集订阅直接复用这套设置。", exact=True).count() == 0
        tracked = page.get_by_role("region", name="追踪范围", exact=True)
        tracked.get_by_role("button", name=re.compile("追踪范围")).click()
        tracked.get_by_role("button", name=re.compile("^第 2 季")).click()
        assert (
            tracked.get_by_role("button", name=re.compile("^第 2 季")).get_attribute("aria-pressed")
            == "false"
        )
        tracked.get_by_role("button", name=re.compile("^第 2 季")).click()
        tracked.get_by_role("switch", name="自动续订", exact=False).click()
        tracked.get_by_role("button", name=re.compile("追踪范围")).click()
        settled_screenshot(page, root / "tv-ready-desktop.png")
        page.get_by_role("button", name="确认订阅", exact=True).click()
        card.wait_for(state="hidden")
        subscriptions = context.request.get(f"{base}/api/v1/subscriptions").json()["data"]
        assert len(subscriptions) == 1
        sub = subscriptions[0]
        assert sub["selection_mode"] == "smart" and sub["smart_policy"]["resolution"] == "2160p"
        assert sub["selected_seasons"] == [1, 2] and sub["follow_future"] is False
        assert context.request.post(f"{api}/__lab/discover").status == 200
        page.goto(f"{base}/subscriptions/{sub['id']}")
        assert page.get_by_role("region", name="智能选择状态").count() == 0
        assert page.get_by_role("button", name="延长 2 小时", exact=True).count() == 0
        season = page.get_by_role("button", name=re.compile(r"^第 1 季"))
        season.click()
        episode = season.locator("..").get_by_role("button", name=re.compile(r"^E01"))
        episode.click()
        status = page.get_by_label("智能选择依据", exact=True)
        status.get_by_role("button", name="延长 2 小时", exact=True).wait_for()
        assert status.locator("xpath=..").get_by_text("搜索", exact=True).count() == 1
        before = context.request.get(f"{base}/api/v1/subscriptions/{sub['id']}").json()["data"]
        row = next(w for w in before["wanted"] if w["selection_state"])
        with page.expect_response(
            lambda r: "/smart-wait" in r.url and r.request.method == "POST"
        ) as request:
            status.get_by_role("button", name="延长 2 小时", exact=True).click()
        changed = request.value.json()["data"]
        from datetime import datetime

        assert (
            datetime.fromisoformat(changed["selection_state"]["deadline"])
            - datetime.fromisoformat(row["selection_state"]["deadline"])
        ).total_seconds() == 7200
        status.get_by_role("button", name="延长 2 小时", exact=True).wait_for()
        settled_screenshot(page, root / "waiting-desktop.png", full_page=True)
        with page.expect_response(
            lambda r: "/smart-wait" in r.url and r.request.method == "POST"
        ) as request:
            status.get_by_role("button", name="立即下载当前候选", exact=True).click()
        assert request.value.status == 200
        # 后台执行完成后刷新；允许浏览器比后台持久化稍早收到响应。
        from .test_library_manage_browser import _wait_for

        _wait_for(
            lambda: any(
                w["status"] == "grabbed"
                for w in context.request.get(f"{base}/api/v1/subscriptions/{sub['id']}").json()[
                    "data"
                ]["wanted"]
            ),
            timeout=15,
            what="立即下载完成认领",
        )
        page.set_viewport_size({"width": 390, "height": 844})
        page.goto(f"{base}/media/movie/100")
        page.get_by_role("button", name="订阅追踪", exact=True).click()
        card = page.get_by_role("region", name="电影智能设置")
        card.get_by_role("button", name="保存电影设置", exact=True).wait_for()
        settled_screenshot(page, root / "movie-first-mobile.png")
        card.get_by_label("优先片源", exact=True).select_option("blu-ray")
        card.get_by_role("button", name="保存电影设置", exact=True).click()
        card.get_by_role("button", name="修改设置", exact=True).wait_for()
        assert (
            context.request.get(f"{base}/api/v1/subscriptions/smart-profiles/tv").json()["data"][
                "preferences"
            ]["source"]
            == "web-dl"
        )
        page.get_by_role("button", name="关闭", exact=True).last.click()
        page.get_by_role("button", name="订阅追踪", exact=True).click()
        card.get_by_text("优先 4K 蓝光", exact=True).wait_for()
        assert page.get_by_text("后续电影订阅直接复用这套设置。", exact=True).count() == 0
        assert card.get_by_role("button", name="保存电影设置", exact=True).count() == 0
        settled_screenshot(page, root / "movie-ready-mobile.png")
        page.get_by_role("button", name="确认订阅", exact=True).click()
        card.wait_for(state="hidden")
        assert not page.evaluate("document.documentElement.scrollWidth > innerWidth")
        page.goto(f"{base}/subscriptions/{sub['id']}")
        page.get_by_text("智能目标", exact=True).wait_for()
        settled_screenshot(page, root / "status-mobile.png", full_page=True)
        assert not page.evaluate("document.documentElement.scrollWidth > innerWidth")
        # 核验状态回到分集行：只有入库核验达标的行显示停止洗版。
        total = len(before["wanted"])
        assert context.request.post(f"{api}/__lab/import-progress/partial").status == 200
        page.reload()
        page.get_by_text("已达标，已停止洗版", exact=False).wait_for()
        assert page.get_by_text("已达标，已停止洗版", exact=False).count() == 1
        settled_screenshot(page, root / "smart-progress-partial.png", full_page=True)
        assert context.request.post(f"{api}/__lab/import-progress/all").status == 200
        page.reload()
        page.get_by_role("button", name=re.compile(r"^第 1 季")).click()
        page.get_by_text("已达标，已停止洗版", exact=False).first.wait_for()
        assert page.get_by_text("已达标，已停止洗版", exact=False).count() == total
        assert not page.evaluate("document.documentElement.scrollWidth > innerWidth")
        settled_screenshot(page, root / "smart-progress-complete.png", full_page=True)
        # 首页横排与海报墙共用卡片：展示海报和标题，不覆盖收录进度线。
        page.set_viewport_size({"width": 1440, "height": 1100})
        for path, name in [("/subscriptions", "home"), ("/subscriptions/wall/tv", "wall")]:
            page.goto(f"{base}{path}")
            poster = page.locator(f'[data-subscription-id="{sub["id"]}"]')
            poster.wait_for()
            assert poster.get_by_text("测试剧集", exact=True).count() == 1
            assert poster.locator('div[aria-hidden="true"][style]').count() == 0
            settled_screenshot(page, root / f"poster-no-progress-{name}.png", full_page=True)
        assert not errors, errors
        # 真实 NAS 旧资源快照：正式链路直接选择两集合包，页面显示在途。
        old = context.request.post(f"{api}/__lab/old-release")
        assert old.status == 200, old.text()
        payload = old.json()
        assert payload["selected"] == 2 and payload["torrents"] == 1
        page.goto(f"{base}/subscriptions/{payload['id']}")
        page.get_by_role("heading", name="幸福伽菜子的快乐杀手生活", exact=False).wait_for()
        assert page.get_by_role("button", name="立即下载当前候选", exact=True).count() == 0
        detail = context.request.get(f"{base}/api/v1/subscriptions/{payload['id']}").json()["data"]
        assert all(
            w["status"] == "grabbed" and w["selection_state"]["anchor_source"] == "published_at"
            for w in detail["wanted"]
        )
        settled_screenshot(page, root / "nas-old-release.png", full_page=True)
        assert context.request.post(f"{api}/__lab/unified-status/{payload['id']}").status == 200
        page.reload()
        page.get_by_role("button", name=re.compile(r"^E05")).wait_for()
        assert page.get_by_role("region", name="智能选择状态").count() == 0
        assert page.get_by_label("智能选择依据", exact=True).count() == 0
        for number in range(1, 6):
            assert page.get_by_role("button", name=re.compile(f"^E{number:02}")).count() == 1
        assert "洗版中" in page.get_by_role("button", name=re.compile(r"^E01")).inner_text()
        assert "待播出" in page.get_by_role("button", name=re.compile(r"^E05")).inner_text()
        page.get_by_role("button", name=re.compile(r"^E03")).click()
        assert page.get_by_label("智能选择依据", exact=True).count() == 0
        page.get_by_text("搜索", exact=True).wait_for()
        settled_screenshot(page, root / "unified-episodes-desktop.png", full_page=True)
        page.set_viewport_size({"width": 390, "height": 844})
        assert not page.evaluate("document.documentElement.scrollWidth > innerWidth")
        settled_screenshot(page, root / "unified-episodes-mobile.png", full_page=True)
        assert not errors, errors
        browser.close()
    if output := os.environ.get("MOVIECLAW_SMART_EVIDENCE"):
        import shutil

        target = Path(output)
        target.mkdir(parents=True, exist_ok=True)
        for artifact in [*root.glob("*.png"), *root.glob("*.log")]:
            shutil.copy2(artifact, target / artifact.name)
        root = target
    print(f"浏览器证据：{root}")


def test_compact_subscription_options_and_saved_profile(smart_stack):
    """已保存偏好的一次确认；展开选项、改库、传统模式及配置告警均走真实 API。"""
    from playwright.sync_api import expect

    base, api, root = smart_stack
    shots = Path(os.environ.get("MOVIECLAW_SMART_EVIDENCE", root))
    shots.mkdir(parents=True, exist_ok=True)
    with pw.sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True,
            **(
                {"channel": "chrome"}
                if Path("/Applications/Google Chrome.app").exists()
                else _chromium_kwargs()
            ),
        )
        context = browser.new_context(viewport={"width": 1440, "height": 1000})
        credentials = {"username": "smart-admin", "password": "isolated-test-only"}
        bootstrap = context.request.get(f"{base}/api/v1/auth/bootstrap").json()["data"]
        # 可独立运行，也可接在完整追踪流程之后运行。
        auth = context.request.post(f"{base}/api/v1/auth/login", data=credentials)
        if auth.status != 200:
            assert (
                context.request.post(f"{base}/api/v1/auth/bootstrap", data=credentials).status
                == 200
            ), bootstrap
        profile_url = f"{base}/api/v1/subscriptions/smart-profiles/movie"
        current = context.request.get(profile_url).json()["data"]
        preferences = {
            "resolution": "2160p",
            "source": "web-dl",
            "wait_seconds": 86400,
            "allow_upgrade": True,
            "strict_resolution": False,
        }
        assert (
            context.request.put(
                profile_url, data={"revision": current["revision"], "preferences": preferences}
            ).status
            == 200
        )
        assert context.request.post(f"{api}/__lab/subscription-downloader/true").status == 200
        libraries = []
        for name in ("电影", "收藏"):
            directory = root / name
            directory.mkdir(exist_ok=True)
            response = context.request.post(
                f"{base}/api/v1/libraries",
                data={
                    "name": name,
                    "kind": "movie",
                    "root_paths": [str(directory)],
                    "realtime_watch": False,
                },
            )
            assert response.status == 200, response.text()
            libraries.append(response.json()["data"])

        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))

        def open_movie(movie_id=101):
            page.goto(f"{base}/media/movie/{movie_id}")
            page.get_by_role("button", name="订阅追踪", exact=True).click()
            dialog = page.get_by_role("dialog", name=re.compile("^订阅《"))
            dialog.get_by_text("优先 4K WEB-DL", exact=True).wait_for()
            return dialog

        for width, height, theme in (
            (1440, 1000, "silver"),
            (390, 844, "silver"),
            (375, 667, "silver"),
            (390, 844, "netflix"),
        ):
            prefs_url = f"{base}/api/v1/ui/preferences"
            prefs = context.request.get(prefs_url).json()["data"]
            prefs.update(theme=theme, theme_desktop=theme, theme_mobile=theme)
            assert context.request.put(prefs_url, data=prefs).status == 200
            page.set_viewport_size({"width": width, "height": height})
            dialog = open_movie()
            expect(dialog.get_by_role("button", name="确认订阅", exact=True)).to_be_enabled()
            assert dialog.get_by_role("button", name=re.compile("^入库到")).count() == 0
            assert dialog.get_by_role("button", name=re.compile("^选择方式")).count() == 0
            assert "最多等 1 天 · 达标后停止洗版" in dialog.inner_text()
            assert "自动选库" not in dialog.inner_text() and str(root) not in dialog.inner_text()
            panel = dialog.locator(".modal-panel").bounding_box()
            assert panel and panel["height"] < 530 and panel["y"] >= 0, panel
            assert not page.evaluate("document.documentElement.scrollWidth > innerWidth")
            settled_screenshot(page, shots / f"compact-movie-{theme}-{width}.png")
            page.keyboard.press("Escape")

        # 桌面展开模式与入库位置：切回智能后复用原设置，无需重新保存。
        page.set_viewport_size({"width": 1440, "height": 1000})
        dialog = open_movie()
        dialog.get_by_role("button", name=re.compile("^更多选项")).click()
        dialog.get_by_role("button", name=re.compile("^选择方式")).click()
        page.get_by_role("menuitemradio", name="规则模式", exact=True).click()
        dialog.get_by_role("region", name="规则选择").wait_for()
        dialog.get_by_role("button", name=re.compile("^选择方式")).click()
        page.get_by_role("menuitemradio", name="智能选择", exact=True).click()
        dialog.get_by_text("优先 4K WEB-DL", exact=True).wait_for()
        dialog.get_by_role("button", name=re.compile("^入库到")).click()
        page.get_by_role("menuitemradio", name="收藏", exact=True).click()
        dialog.get_by_role("button", name=re.compile("^更多选项")).click()
        assert "存入「收藏」" in dialog.inner_text()
        dialog.get_by_role("button", name="修改设置", exact=True).click()
        expect(dialog.get_by_role("button", name="确认订阅", exact=True)).to_be_disabled()
        dialog.get_by_label("等待耐心", exact=True).select_option("0")
        dialog.get_by_label("允许后续洗版", exact=True).uncheck()
        dialog.get_by_text("选择说明与最低要求", exact=True).click()
        dialog.get_by_label("只接受 4K，到期也不降低分辨率", exact=True).check()
        dialog.get_by_role("button", name="保存电影设置", exact=True).click()
        dialog.get_by_text("尽快下载 · 入库后不洗版", exact=True).wait_for()
        dialog.get_by_text("只接受 4K", exact=True).wait_for()
        dialog.get_by_role("button", name="确认订阅", exact=True).click()
        dialog.wait_for(state="hidden")
        rows = context.request.get(f"{base}/api/v1/subscriptions").json()["data"]
        created = next(s for s in rows if s["media"]["tmdb_id"] == 101)
        assert created["selection_mode"] == "smart" and created["library_id"] == libraries[1]["id"]
        assert created["smart_policy"]["wait_seconds"] == 0
        assert created["smart_policy"]["strict_resolution"] is True
        assert created["smart_policy"]["allow_upgrade"] is False

        # 配置告警不能被「更多选项」藏起来；恢复后用原规则方式完成订阅。
        assert context.request.post(f"{api}/__lab/subscription-downloader/false").status == 200
        dialog = open_movie(102)
        expect(dialog.get_by_role("alert")).to_contain_text("没有可用的默认下载器")
        assert dialog.get_by_role("button", name=re.compile("^入库到")).count() == 0
        page.keyboard.press("Escape")
        assert context.request.post(f"{api}/__lab/subscription-downloader/true").status == 200
        dialog = open_movie(102)
        dialog.get_by_role("button", name=re.compile("^更多选项")).click()
        dialog.get_by_role("button", name=re.compile("^选择方式")).click()
        page.get_by_role("menuitemradio", name="规则模式", exact=True).click()
        dialog.get_by_role("button", name="确认订阅", exact=True).click()
        dialog.wait_for(state="hidden")
        rows = context.request.get(f"{base}/api/v1/subscriptions").json()["data"]
        created = next(s for s in rows if s["media"]["tmdb_id"] == 102)
        assert created["selection_mode"] == "rules" and created["rule_set_id"] > 0
        assert created["library_id"] == libraries[0]["id"]
        assert not errors, errors
        browser.close()


@pytest.mark.parametrize(
    "kind,width,days,legacy_hours,media_id",
    [
        ("movie", 1440, 7, 72, 103),
        ("tv", 390, 2, 6, 201),
    ],
)
def test_custom_day_input_persists_into_subscription(
    smart_stack, kind, width, days, legacy_hours, media_id
):
    base, _, root = smart_stack
    label = "电影" if kind == "movie" else "剧集"
    with pw.sync_playwright() as playwright:
        options = (
            {"channel": "chrome"}
            if Path("/Applications/Google Chrome.app").exists()
            else _chromium_kwargs()
        )
        browser = playwright.chromium.launch(headless=True, **options)
        context = browser.new_context(viewport={"width": width, "height": 1000})
        credentials = {"username": "smart-admin", "password": "isolated-test-only"}
        auth = context.request.post(f"{base}/api/v1/auth/login", data=credentials)
        if auth.status != 200:
            assert (
                context.request.post(f"{base}/api/v1/auth/bootstrap", data=credentials).status
                == 200
            )
        profile_url = f"{base}/api/v1/subscriptions/smart-profiles/{kind}"
        profile = context.request.get(profile_url).json()["data"]
        preferences = {
            "resolution": "2160p",
            "source": "web-dl",
            "wait_seconds": legacy_hours * 3600,
            "allow_upgrade": True,
            "strict_resolution": False,
        }
        assert (
            context.request.put(
                profile_url, data={"revision": profile["revision"], "preferences": preferences}
            ).status
            == 200
        )
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(f"{base}/settings/subscription")
        card = page.get_by_role("region", name=f"{label}智能设置", exact=True)
        card.get_by_role("button", name="修改设置", exact=True).click()
        select = card.get_by_label("等待耐心", exact=True)
        number = card.get_by_role("spinbutton", name="自定义等待天数", exact=True)
        decrease = card.get_by_role("button", name="减少 1 天", exact=True)
        increase = card.get_by_role("button", name="增加 1 天", exact=True)
        save_button = card.get_by_role("button", name=f"保存{label}设置", exact=True)
        if legacy_hours % 24:
            assert select.input_value() == str(legacy_hours * 3600)
            assert number.count() == 0
            assert f"原有设置 · {legacy_hours} 小时" in select.inner_text()
            save_button.click()
            card.get_by_role("button", name="修改设置", exact=True).wait_for()
            assert (
                context.request.get(profile_url).json()["data"]["preferences"]["wait_seconds"]
                == legacy_hours * 3600
            )
            card.get_by_role("button", name="修改设置", exact=True).click()
            select.select_option("custom")
            assert number.input_value() == str(max(1, (legacy_hours + 23) // 24))
        else:
            assert select.input_value() == "custom"
            assert number.input_value() == str(legacy_hours // 24)
        assert number.get_attribute("inputmode") == "numeric"
        assert "可直接输入" not in card.inner_text()
        assert "1–72" not in card.inner_text()
        assert "1–7 天" not in card.inner_text()
        assert card.get_by_role("slider").count() == 0
        assert select.locator("option").all_text_contents()[:4] == [
            "尽快下载 · 不等待",
            "可以等 · 最多 3 小时",
            "更有耐心 · 最多 1 天",
            "自定义",
        ]
        select.select_option("0")
        assert number.count() == 0
        select.select_option("custom")
        assert number.input_value() == "1"
        assert decrease.is_disabled()
        increase.click()
        assert number.input_value() == "2"
        decrease.click()
        assert number.input_value() == "1"
        for seconds, expected in [("10800", 1), ("86400", 1)]:
            select.select_option(seconds)
            assert number.count() == 0
            select.select_option("custom")
            assert number.input_value() == str(expected)
            increase.click()
            assert number.input_value() == str(expected + 1)
            decrease.click()
            assert number.input_value() == str(expected)
            assert select.input_value() == "custom"
        # Direct entry, keyboard increments, limits, and invalid edits all use the
        # same form that saves a real profile; no stale value may be submitted.
        number.fill("7")
        assert increase.is_disabled()
        decrease.click()
        assert number.input_value() == "6"
        number.press("ArrowUp")
        assert number.input_value() == "7"
        before_invalid = context.request.get(profile_url).json()["data"]
        updates = []
        page.on(
            "request",
            lambda request: (
                updates.append(request.url)
                if request.method == "PUT" and "/smart-profiles/" in request.url
                else None
            ),
        )
        for invalid in ["", "0", "8", "1.5"]:
            number.fill(invalid)
            assert not number.evaluate("el => el.validity.valid")
            save_button.click()
            assert number.is_visible()
        assert updates == []
        assert context.request.get(profile_url).json()["data"] == before_invalid
        number.fill(str(days))
        assert number.evaluate("el => el.validity.valid")
        assert number.input_value() == str(days)
        card.get_by_role("button", name=f"保存{label}设置", exact=True).click()
        card.get_by_role("button", name="修改设置", exact=True).wait_for()
        assert (
            context.request.get(profile_url).json()["data"]["preferences"]["wait_seconds"]
            == days * 86400
        )
        assert f"最多等 {days} 天" in card.inner_text()
        page.reload()
        card.get_by_role("button", name="修改设置", exact=True).click()
        assert select.input_value() == "custom" and number.input_value() == str(days)
        card.get_by_role("button", name="取消修改", exact=True).click()
        page.goto(f"{base}/media/{kind}/{media_id}")
        page.get_by_role("button", name="订阅追踪", exact=True).click()
        card.get_by_role("button", name="修改设置", exact=True).wait_for()
        assert f"最多等 {days} 天" in card.inner_text()
        card.get_by_role("button", name="修改设置", exact=True).click()
        assert select.input_value() == "custom" and number.input_value() == str(days)
        evidence = Path(os.environ.get("MOVIECLAW_SMART_EVIDENCE", str(root)))
        evidence.mkdir(parents=True, exist_ok=True)
        settled_screenshot(page, evidence / f"custom-days-{kind}-{width}.png")
        card.get_by_role("button", name="取消修改", exact=True).click()
        page.get_by_role("button", name="确认订阅", exact=True).click()
        card.wait_for(state="hidden")
        subscriptions = context.request.get(f"{base}/api/v1/subscriptions").json()["data"]
        subscription = next(
            sub
            for sub in subscriptions
            if sub["media"]["tmdb_id"] == media_id and sub["media"]["kind"] == kind
        )
        assert subscription["smart_policy"]["wait_seconds"] == days * 86400
        assert not page.evaluate("document.documentElement.scrollWidth > innerWidth")
        assert not errors
        browser.close()


@pytest.mark.parametrize("width,height", [(1440, 1000), (390, 844)])
def test_settings_tabs_rule_editor_and_real_preview(smart_stack, width, height):
    from playwright.sync_api import expect

    base, api, root = smart_stack
    evidence = Path(os.environ.get("MOVIECLAW_SMART_EVIDENCE", str(root)))
    evidence.mkdir(parents=True, exist_ok=True)
    with pw.sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True,
            **(
                {"channel": "chrome"}
                if Path("/Applications/Google Chrome.app").exists()
                else _chromium_kwargs()
            ),
        )
        context = browser.new_context(viewport={"width": width, "height": height})
        credentials = {"username": "smart-admin", "password": "isolated-test-only"}
        if context.request.post(f"{base}/api/v1/auth/login", data=credentials).status != 200:
            assert (
                context.request.post(f"{base}/api/v1/auth/bootstrap", data=credentials).status
                == 200
            )
        # Ensure this case can also run on its own.
        profile_url = f"{base}/api/v1/subscriptions/smart-profiles/movie"
        profile = context.request.get(profile_url).json()["data"]
        if not profile["preferences"]:
            assert (
                context.request.put(
                    profile_url,
                    data={"revision": profile["revision"], "preferences": {"wait_seconds": 86400}},
                ).status
                == 200
            )
        assert context.request.post(f"{api}/__lab/subscription-downloader/true").status == 200
        profiles_before = {
            kind: context.request.get(f"{base}/api/v1/subscriptions/smart-profiles/{kind}").json()[
                "data"
            ]
            for kind in ("movie", "tv")
        }
        subscriptions_before = context.request.get(f"{base}/api/v1/subscriptions").json()["data"]
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(f"{base}/settings/subscription")
        smart_tab = page.get_by_role("tab", name="智能选择", exact=True)
        rules_tab = page.get_by_role("tab", name="自定义规则", exact=True)
        smart = page.get_by_role("tabpanel", name="智能选择", exact=True)
        rules = page.get_by_role("tabpanel", name="自定义规则", exact=True)
        expect(smart_tab).to_have_attribute("aria-selected", "true")
        expect(smart).to_be_visible()
        assert page.get_by_role("button", name="预览匹配", exact=True).count() == 0
        assert page.get_by_role("searchbox", name="搜索预览作品").count() == 0
        movie = smart.get_by_role("region", name="电影智能设置", exact=True)
        movie.get_by_role("button", name="修改设置", exact=True).click()
        movie.get_by_label("优先分辨率", exact=True).select_option("1080p")
        smart_tab.focus()
        smart_tab.press("ArrowRight")
        expect(rules_tab).to_be_focused()
        expect(rules).to_be_visible()
        assert smart.get_by_role("region", name="电影智能设置").count() == 0
        rules_tab.press("Home")
        expect(smart).to_be_visible()
        assert movie.get_by_label("优先分辨率", exact=True).input_value() == "1080p"
        movie.get_by_role("button", name="取消修改", exact=True).click()
        settled_screenshot(page, evidence / f"settings-smart-{width}.png")
        rules_tab.click()
        rules.get_by_role("button", name="新建规则组", exact=True).click()
        editor = page.get_by_role("dialog", name="新建规则组", exact=True)
        rule_name = f"页面验证 {width}"
        editor.get_by_placeholder("如：4K 免费、追剧省流", exact=True).fill(rule_name)
        editor.get_by_role("button", name=re.compile("^适用范围")).click()
        editor.get_by_role("button", name="电影", exact=True).click()
        editor.get_by_role("button", name="保存", exact=True).click()
        editor.wait_for(state="hidden")
        rules.get_by_role("button", name=rule_name, exact=True).click()
        editor = page.get_by_role("dialog", name=f"编辑规则组「{rule_name}」", exact=True)
        renamed = f"{rule_name} 已编辑"
        editor.get_by_placeholder("如：4K 免费、追剧省流", exact=True).fill(renamed)
        editor.get_by_role("button", name="保存", exact=True).click()
        editor.wait_for(state="hidden")
        rules.get_by_role("button", name=renamed, exact=True).wait_for()
        rows = context.request.get(f"{base}/api/v1/rule-sets").json()["data"]
        saved = next(row for row in rows if row["name"] == renamed)
        assert saved["match_rules"] == [{"field": "kind", "op": "any_of", "values": ["movie"]}]
        assert not rules.locator("details").evaluate("el => el.open")
        assert page.get_by_role("searchbox", name="搜索预览作品").count() == 0
        settled_screenshot(page, evidence / f"settings-rules-{width}.png")
        rules.get_by_role("button", name="预览匹配", exact=True).click()
        dialog = page.get_by_role("dialog", name="规则与入库预览", exact=True)
        dialog.get_by_role("searchbox", name="搜索预览作品").fill("测试电影")
        candidate = dialog.get_by_role("button", name=re.compile("^测试电影"))
        candidate.wait_for()
        # Exercise the visible failure/retry state, then run the real API.
        preview_pattern = "**/api/v1/subscriptions/download-routing-preview?*"
        page.route(preview_pattern, lambda route: route.abort())
        candidate.click()
        dialog.get_by_role("alert").wait_for()
        assert dialog.get_by_text("正在预演…", exact=True).count() == 0
        page.unroute(preview_pattern)
        with page.expect_response(
            lambda response: "/download-routing-preview?" in response.url
        ) as response:
            dialog.get_by_role("button", name="重试预览", exact=True).click()
        assert response.value.status == 200
        preview = response.value.json()["data"]
        assert preview["rule_set_id"] in {row["id"] for row in rows}
        dialog.get_by_text(preview["rule_set_reason"], exact=True).wait_for()
        settled_screenshot(page, evidence / f"settings-preview-{width}.png")
        details = dialog.locator("details")
        assert not details.evaluate("el => el.open")
        details.locator("summary").click()
        assert details.evaluate("el => el.open")
        assert details.evaluate("el => el.scrollWidth <= el.clientWidth")
        settled_screenshot(page, evidence / f"settings-preview-details-{width}.png")
        dialog.get_by_role("button", name="关闭预览", exact=True).click()
        expect(rules).to_be_visible()
        rules.get_by_role("button", name="预览匹配", exact=True).click()
        assert dialog.get_by_role("searchbox", name="搜索预览作品").input_value() == ""
        page.keyboard.press("Escape")
        expect(dialog).to_be_hidden()
        assert (
            context.request.get(f"{base}/api/v1/subscriptions").json()["data"]
            == subscriptions_before
        )
        assert {
            kind: context.request.get(f"{base}/api/v1/subscriptions/smart-profiles/{kind}").json()[
                "data"
            ]
            for kind in ("movie", "tv")
        } == profiles_before
        assert not page.evaluate("document.documentElement.scrollWidth > innerWidth")
        assert not errors
        browser.close()


def test_identity_skip_is_informational_on_desktop_and_mobile(smart_stack):
    base, api, root = smart_stack
    with pw.sync_playwright() as playwright:
        options = (
            {"channel": "chrome"}
            if Path("/Applications/Google Chrome.app").exists()
            else _chromium_kwargs()
        )
        browser = playwright.chromium.launch(headless=True, **options)
        context = browser.new_context(viewport={"width": 1440, "height": 1000})
        credentials = {"username": "identity-test", "password": "isolated-test-only"}
        assert context.request.post(f"{base}/api/v1/auth/bootstrap", data=credentials).status == 200
        result = context.request.post(f"{api}/__lab/identity/false").json()
        assert result["dispatched"] == 0
        sub_id = result["id"]
        page = context.new_page()
        for width in (1440, 390):
            page.set_viewport_size({"width": width, "height": 1000})
            page.goto(f"{base}/subscriptions/{sub_id}")
            info = page.get_by_role("group", name="资源身份说明")
            info.wait_for()
            assert page.get_by_role("button", name="立即下载当前候选").count() == 0
            assert page.get_by_role("button", name="延长 1 天").count() == 0
            assert page.get_by_text("最晚等待至", exact=False).count() == 0
            assert page.get_by_text("最近一次被拒", exact=False).count() == 0
            assert not info.get_by_text("The.Odyssey", exact=False).is_visible()
            info.get_by_text("查看详情", exact=True).click()
            assert info.get_by_text("The.Odyssey", exact=False).is_visible()
            settled_screenshot(page, root / f"identity-{width}.png", full_page=True)
        assert context.request.get(f"{base}/api/v1/system/notices").json()["data"] == []
        recovered = context.request.post(f"{api}/__lab/identity/true").json()
        assert recovered["dispatched"] == 1
        page.reload()
        page.get_by_text("已提交下载器", exact=True).wait_for()
        assert page.get_by_role("group", name="资源身份说明").count() == 0
        browser.close()
