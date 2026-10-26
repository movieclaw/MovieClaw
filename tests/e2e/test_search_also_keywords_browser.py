"""详情页「搜索资源」带英文名/原名一起搜的浏览器端到端（issue #680）。

此前三处入口（发现详情、媒体库条目详情、订阅「手动选种」）只按中文名搜一个词，
只认英文名的站点有资源也搜不到。现在和订阅一样：中文名为主词，英文名、原名同搜，
每站结果按种子合并。

真后端 + 真前端 + 无头 Chromium；TMDB 与 PT 站点由 _search_also_api_launcher 换成假实现
（馒头只认中文名、TTG 只认英文名），搜索、历史、快照、订阅业务都是真的。
覆盖：发现详情 → 结果页「另含」与两站结果 → 后端每站收到三个词 → 历史行回放快照 →
快照「重新搜索」仍带同搜词 → 媒体库条目详情 → 订阅「手动选种」。

本地（E2E_CHROMIUM 指向本机 Chrome）：
    pytest -m integration tests/e2e/test_search_also_keywords_browser.py
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from urllib.parse import parse_qs, urlparse

import pytest

from .test_library_manage_browser import REPO, WEB, _chromium_kwargs, _free_port, _wait_http

pw = pytest.importorskip("playwright.sync_api")
pytestmark = pytest.mark.integration

ADMIN = {"username": "also-admin", "password": "isolated-test-only"}
CHINESE = "恶人传"
ENGLISH = "The Gangster, the Cop, the Devil"
ORIGINAL = "악인전"
SCENE_TITLE = "The.Gangster.the.Cop.the.Devil.2019.1080p.BluRay.x264-WiKi"


@pytest.fixture(scope="module")
def also_stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("search-also-browser")
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
    api = subprocess.Popen(  # noqa: S603
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._search_also_api_launcher:app",
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
            "NEXT_DIST_DIR": ".next-search-also-e2e",
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


def _query(url: str) -> dict[str, list[str]]:
    return parse_qs(urlparse(url).query)


def _searched_triples(keywords: list[str]) -> bool:
    """站点把中文名、英文名、原名都搜了，且遍数一样。dev 模式下 React StrictMode 会把搜索
    effect 跑两遍（第一条流随即中止，但请求已到后端、可能与第二条交错），所以不断言遍数与顺序。"""
    counts = {word: keywords.count(word) for word in (CHINESE, ENGLISH, ORIGINAL)}
    return sum(counts.values()) == len(keywords) > 0 and len(set(counts.values())) == 1


def _assert_results_with_also(page) -> None:
    """结果页：标题旁写着实际同搜的词，只认英文名的 TTG 也出了结果，同一种子只一条。"""
    from playwright.sync_api import expect

    expect(page.get_by_text(f"另含 {ENGLISH} · {ORIGINAL}", exact=True)).to_be_visible()
    expect(page.get_by_text("共 2 条结果")).to_be_visible()
    expect(page.get_by_text(re.compile(r"Gangster.*WiKi|WiKi")).first).to_be_visible()


def test_detail_search_includes_english_and_original_titles(also_stack) -> None:
    from playwright.sync_api import expect

    base, lab = also_stack["base"], also_stack["lab"]
    shots = also_stack["root"] / "shots"
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

        def api(method: str, path: str, **kw) -> dict:
            r = context.request.fetch(f"{base}/api/v1{path}", method=method, **kw)
            assert r.ok, f"{method} {path}: {r.status} {r.text()}"
            return r.json()["data"]

        def lab_log() -> dict[str, list[str]]:
            return context.request.get(f"{lab}/search-log").json()

        # ---- 发现详情 → 搜索资源 ----
        page.goto(f"{base}/media/movie/104")
        page.get_by_role("link", name="搜索资源").click()
        page.wait_for_url(re.compile(r"/search\?"))
        params = _query(page.url)
        assert params["q"] == [CHINESE], page.url
        assert params["also"] == [ENGLISH, ORIGINAL], page.url
        assert params["cats"] == ["movie"], page.url
        _assert_results_with_also(page)
        # 后端真的把三个词逐个下发给了每个站（主词在前）
        log = lab_log()
        assert _searched_triples(log["mteam"]), log
        assert _searched_triples(log["ttg"]), log
        page.screenshot(path=str(shots / "discover-search-results.png"))

        # ---- 历史：同搜词记进历史，点开回放快照，「重新搜索」仍带同搜词 ----
        history = api("GET", "/search/history?vertical=torrents")
        assert [(h["keyword"], h["also_keywords"]) for h in history] == [
            (CHINESE, [ENGLISH, ORIGINAL])
        ]
        page.goto(base)
        page.get_by_role("button", name=re.compile(r"^搜索（")).click()
        page.get_by_role("radio", name="资源", exact=True).click()
        row = page.get_by_text(re.compile(f"另含 {re.escape(ENGLISH)} / {ORIGINAL}"))
        expect(row.first).to_be_visible()
        page.screenshot(path=str(shots / "history-row.png"))
        row.first.click()
        page.wait_for_url(re.compile(r"snapshot="))
        assert _query(page.url)["also"] == [ENGLISH, ORIGINAL], page.url
        expect(page.get_by_text("的快照")).to_be_visible()
        _assert_results_with_also(page)
        searched_before = len(lab_log()["ttg"])
        page.get_by_role("button", name="重新搜索").click()
        page.wait_for_url(lambda u: "snapshot=" not in u)
        assert _query(page.url)["also"] == [ENGLISH, ORIGINAL], page.url
        _assert_results_with_also(page)
        assert _searched_triples(lab_log()["ttg"][searched_before:])

        # ---- 媒体库条目详情：⋯ →「搜索资源」带上库里存的英文名 ----
        movies = also_stack["root"] / "media" / "movies"
        movies.mkdir(parents=True)
        library = api(
            "POST",
            "/libraries",
            data={
                "name": "电影",
                "kind": "movie",
                "root_paths": [str(movies)],
                "realtime_watch": False,
            },
        )
        seeded = context.request.post(
            f"{lab}/library-item",
            params={"library_id": library["id"], "root": str(movies)},
        )
        assert seeded.ok, seeded.text()
        item_id = seeded.json()["item_id"]
        page.goto(f"{base}/library/{library['id']}/item/{item_id}")
        page.get_by_role("button", name="更多操作").click()
        page.get_by_role("menuitem", name="搜索资源").click()
        page.wait_for_url(re.compile(r"/search\?"))
        assert _query(page.url)["also"] == [ENGLISH, ORIGINAL], page.url
        _assert_results_with_also(page)

        # ---- 订阅详情「手动选种」：同样带上英文名/原名，仍在选种模式 ----
        sub = api("POST", "/subscriptions", data={"title_ref": "tmdb:movie:104"})["subscription"]
        page.goto(f"{base}/subscriptions/{sub['id']}")
        page.get_by_role("link", name="手动选种").click()
        page.wait_for_url(re.compile(r"for_sub="))
        params = _query(page.url)
        assert params["also"] == [ENGLISH, ORIGINAL], page.url
        assert params["for_sub"] == [str(sub["id"])], page.url
        expect(page.get_by_text(re.compile(f"正在为《{CHINESE}》手动选种"))).to_be_visible()
        _assert_results_with_also(page)
        page.screenshot(path=str(shots / "manual-pick.png"))

        assert errors == [], f"页面报错：{errors}"
        context.close()
        browser.close()
