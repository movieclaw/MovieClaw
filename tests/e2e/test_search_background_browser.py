"""站点搜索改为后台运行的浏览器端到端（issue #920）。

此前搜索挂在页面的 SSE 连接上：离开搜索页、刷新，服务端就取消还没返回的站点请求，
半截结果也不留快照，回来从头再打一遍站。现在搜索在后台跑完，页面只是显示屏：
离开再回来、刷新都接上同一次搜索（从头回放），不重复打站；「重新搜索」与单站重试
才明确要新结果。

真后端 + 真前端 + 无头 Chromium；PT 站点由 _search_background_api_launcher 换成假实现
（slow 卡在实验台闸门上，测试决定它何时返回），搜索、历史、快照业务都是真的。
next dev 下 React StrictMode 会把搜索 effect 跑两遍：两条请求都到后端，接上同一次运行，
打站次数仍是 1——这本身也在断言范围内。

本地（E2E_CHROMIUM 指向本机 Chrome）：
    pytest -m integration tests/e2e/test_search_background_browser.py
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from urllib.parse import quote

import pytest

from .test_library_manage_browser import REPO, WEB, _chromium_kwargs, _free_port, _wait_http

pw = pytest.importorskip("playwright.sync_api")
pytestmark = pytest.mark.integration

ADMIN = {"username": "bg-search-admin", "password": "isolated-test-only"}


@pytest.fixture(scope="module")
def bg_stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("search-background-browser")
    api_port, web_port = _free_port(), _free_port()
    api_log = (root / "api.log").open("w")
    web_log = (root / "web.log").open("w")
    env = {
        **os.environ,
        "DATABASE_URL": f"sqlite+aiosqlite:///{root / 'data.db'}",
        "SECRET_KEY_FILE": str(root / "secret"),
        "SCHEDULER_ENABLED": "false",
        "METADATA_DIR": str(root / "metadata"),
        "LOG_DIR": str(root / "logs"),
        "PYTHONPATH": f"{REPO / 'src'}:{REPO}",
    }
    api = subprocess.Popen(  # noqa: S603
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._search_background_api_launcher:app",
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
    web = subprocess.Popen(  # noqa: S603
        ["pnpm", "exec", "next", "dev", "--port", str(web_port)],
        cwd=WEB,
        env={
            **os.environ,
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
            "NEXT_DIST_DIR": ".next-search-background-e2e",
        },
        stdout=web_log,
        stderr=subprocess.STDOUT,
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 60)
        _wait_http(f"http://127.0.0.1:{web_port}/login", 180)
        yield {
            "base": f"http://127.0.0.1:{web_port}",
            "lab": f"http://127.0.0.1:{api_port}/__lab",
            "root": root,
        }
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


def _hit(page, keyword: str, site_id: str):
    """某站返回的那条结果：结果按识别出的片名分组（「沙丘2021」），组内各版本行
    带压制组名——假站点把站点 id 大写当压制组，正好用来区分是哪个站的结果。"""
    work = page.get_by_role("listitem").filter(has=page.get_by_text(f"{keyword}2021"))
    return work.get_by_text(re.compile(rf"\b{site_id.upper()}\b"))


def test_search_survives_leaving_and_refreshing_the_page(bg_stack) -> None:
    from playwright.sync_api import expect

    base, lab = bg_stack["base"], bg_stack["lab"]
    shots = bg_stack["root"] / "shots"
    shots.mkdir(exist_ok=True)
    with pw.sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True, **_chromium_kwargs())
        context = browser.new_context(viewport={"width": 1440, "height": 900}, locale="zh-CN")
        page = context.new_page()
        page.set_default_timeout(20_000)
        page.set_default_navigation_timeout(120_000)
        errors: list[str] = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        resp = context.request.post(f"{base}/api/v1/auth/bootstrap", data=ADMIN)
        assert resp.ok, resp.text()

        def api(path: str) -> list | dict:
            r = context.request.get(f"{base}/api/v1{path}")
            assert r.ok, f"{path}: {r.status} {r.text()}"
            return r.json()["data"]

        def calls() -> dict[str, int]:
            log = context.request.get(f"{lab}/search-log").json()
            return {site_id: len(words) for site_id, words in log.items()}

        def lab_post(path: str) -> None:
            assert context.request.post(f"{lab}{path}").ok

        def wait_snapshot(keyword: str) -> dict:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                rows = [h for h in api("/search/history") if h["keyword"] == keyword]
                rows = [h for h in rows if not h["site_ids"]]  # 全站那次（单站重试另记一条）
                if rows and rows[0]["has_snapshot"]:
                    return api(f"/search/history/{rows[0]['id']}/results")
                time.sleep(0.2)
            raise AssertionError(f"「{keyword}」没有在后台跑完写快照")

        # ---- 场景一：搜到一半离开搜索页，慢站在后台返回，回来结果已齐、不重新打站 ----
        lab_post("/slow/hold")
        page.goto(f"{base}/search?q={quote('沙丘')}")
        expect(_hit(page, "沙丘", "fast")).to_be_visible()
        assert calls() == {"fast": 1, "slow": 1, "flaky": 1}
        page.screenshot(path=str(shots / "1-half-way.png"))
        page.goto(f"{base}/")  # 离开：搜索流随之断开
        page.wait_for_load_state("networkidle")
        lab_post("/slow/release")
        # 没有任何页面在看：搜索照样跑完，快照照样写下
        snapshot = wait_snapshot("沙丘")
        assert {i["site_id"] for i in snapshot["items"]} == {"fast", "slow"}
        page.go_back()
        expect(_hit(page, "沙丘", "slow")).to_be_visible()
        expect(_hit(page, "沙丘", "fast")).to_be_visible()
        assert calls() == {"fast": 1, "slow": 1, "flaky": 1}, "回到搜索页不该重新打站"
        page.screenshot(path=str(shots / "1-back-complete.png"))

        # ---- 单站重试：明确要新结果，只重打这一个站 ----
        page.get_by_role("button", name="3 站点").click()
        page.get_by_role("button", name="重试该站").click()
        expect(_hit(page, "沙丘", "flaky")).to_be_visible()
        assert calls() == {"fast": 1, "slow": 1, "flaky": 2}
        page.keyboard.press("Escape")

        # ---- 场景二：搜到一半刷新，已出的结果马上回来，慢站返回后补上 ----
        lab_post("/slow/hold")
        page.goto(f"{base}/search?q={quote('奥本海默')}")
        expect(_hit(page, "奥本海默", "fast")).to_be_visible()
        page.reload()
        expect(_hit(page, "奥本海默", "fast")).to_be_visible()
        expect(_hit(page, "奥本海默", "slow")).to_have_count(0)
        lab_post("/slow/release")
        expect(_hit(page, "奥本海默", "slow")).to_be_visible()
        assert calls() == {"fast": 2, "slow": 2, "flaky": 3}, "刷新不该重新打站"
        page.screenshot(path=str(shots / "2-after-refresh.png"))

        # ---- 快照提示条「重新搜索」：要的是新结果，重新打站；地址栏不留 fresh ----
        history = [
            h for h in api("/search/history") if h["keyword"] == "沙丘" and not h["site_ids"]
        ]
        page.goto(f"{base}/search?q={quote('沙丘')}&snapshot={history[0]['id']}")
        expect(page.get_by_text("的快照")).to_be_visible()
        page.get_by_role("button", name="重新搜索").click()
        page.wait_for_url(lambda u: "snapshot=" not in u)
        expect(_hit(page, "沙丘", "slow")).to_be_visible()
        assert calls() == {"fast": 3, "slow": 3, "flaky": 4}
        page.wait_for_url(lambda u: "fresh" not in u)
        page.reload()  # 刷新接上刚才这次，不再重搜
        expect(_hit(page, "沙丘", "slow")).to_be_visible()
        assert calls() == {"fast": 3, "slow": 3, "flaky": 4}

        assert errors == [], f"页面报错：{errors}"
        context.close()
        browser.close()
