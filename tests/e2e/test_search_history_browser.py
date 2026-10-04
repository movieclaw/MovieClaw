"""搜索历史分类的浏览器回归：两种主题与视口、乱序响应、清空竞态及失败恢复。

复用观看历史测试的隔离服务栈（临时 SQLite + 假 TMDB），不访问用户数据或 PT 站。
本地：E2E_CHROMIUM=/path/to/chrome pytest -m integration tests/e2e/test_search_history_browser.py
"""

from __future__ import annotations

import asyncio
import json
import re
from concurrent.futures import ThreadPoolExecutor

import pytest

playwright = pytest.importorskip("playwright.sync_api")

from tests.e2e import test_watch_history_clear_browser as history_stack  # noqa: E402

stack = history_stack.stack

pytestmark = history_stack.pytestmark


async def _seed_history(database_url):
    """只播种历史与空结果快照，不访问真实影视来源或 PT 站。"""
    from movieclaw_db.engine import Database
    from movieclaw_db.repositories.search_history_repo import SearchHistoryRepository

    db = Database(database_url)
    try:
        async with db.session() as session:
            repo = SearchHistoryRepository(session)
            for keyword in ("影视独有记录", "共同关键词"):
                history_id = await repo.record(keyword, vertical="media")
                await repo.save_snapshot(history_id, json.dumps({"total": 0, "items": []}))
            for keyword, categories in (
                ("资源独有记录", []),
                ("共同关键词", []),
                ("共同关键词", ["movie"]),
            ):
                history_id = await repo.record(keyword, categories=categories)
                await repo.save_snapshot(
                    history_id, json.dumps({"total": 0, "items": [], "sites": []})
                )
    finally:
        await db.dispose()


@pytest.fixture
def page(stack, request):
    """每个用例重建登录、历史与页面状态；所有写入仅发生在临时测试实例。"""
    theme, width = getattr(request, "param", ("silver", 1280))
    with playwright.sync_playwright() as pw:
        browser = pw.chromium.launch(**history_stack._chromium_kwargs())
        context = browser.new_context(viewport={"width": width, "height": 900})
        api = context.request
        prefix = stack["base"] + "/api/v1"
        response = api.post(prefix + "/auth/bootstrap", data=history_stack.ADMIN)
        if response.status == 409:
            response = api.post(prefix + "/auth/login", data=history_stack.ADMIN)
        assert response.status == 200
        assert api.delete(prefix + "/search/history").status == 200
        with ThreadPoolExecutor(max_workers=1) as pool:
            pool.submit(lambda: asyncio.run(_seed_history(stack["database_url"]))).result()
        prefs = api.get(prefix + "/ui/preferences").json()["data"]
        prefs.update(theme=theme, theme_desktop=theme, theme_mobile=theme)
        assert api.put(prefix + "/ui/preferences", data=prefs).status == 200
        current = context.new_page()
        errors = []
        current.on("pageerror", lambda error: errors.append(str(error)))
        current.goto(stack["base"])
        current.get_by_role("button", name=re.compile(r"^搜索（")).click()
        current.get_by_role("radio", name="影视", exact=True).click()
        playwright.expect(current.get_by_role("list", name="最近搜索")).to_contain_text(
            "影视独有记录"
        )
        yield current
        assert errors == [], f"浏览器异常：{errors}"
        context.close()
        browser.close()


@pytest.mark.parametrize(
    "page", [("silver", 1280), ("silver", 390), ("netflix", 1280), ("netflix", 390)], indirect=True
)
def test_history_follows_search_mode(page, stack):
    history = page.get_by_role("list", name="最近搜索")
    playwright.expect(history).not_to_contain_text("资源独有记录")
    playwright.expect(history).to_contain_text("共同关键词")
    page.get_by_role("radio", name="资源", exact=True).click()
    playwright.expect(history).to_contain_text("资源独有记录")
    playwright.expect(history).not_to_contain_text("影视独有记录")
    playwright.expect(history).to_contain_text("共同关键词")
    page.get_by_role("radio", name="媒体库", exact=True).click()
    playwright.expect(history).to_have_count(0)
    playwright.expect(
        page.get_by_role("button", name=re.compile(r"^清空.*搜索历史$"))
    ).to_have_count(0)
    playwright.expect(
        page.get_by_text(re.compile(r"还没有搜索记录|没有匹配.*搜索记录"))
    ).to_have_count(0)
    page.get_by_role("radio", name="影视", exact=True).click()
    playwright.expect(history).to_contain_text("影视独有记录")
    playwright.expect(history).not_to_contain_text("资源独有记录")
    stack["shots"].mkdir(exist_ok=True)
    page.screenshot(path=str(stack["shots"] / f"history-{page.viewport_size['width']}.png"))


def test_late_response_cannot_replace_current_mode(page):
    """资源结果已经从服务端取得，但延迟送达；切回影视后旧响应不能覆盖列表。"""
    page.evaluate("""() => {
        const original = window.fetch.bind(window);
        window.fetch = async (url, options) => {
            const response = await original(url, options);
            const path = String(url);
            if (path.includes('/search/history?') && path.includes('vertical=torrents')) {
                window.delayedHistoryStarted = true;
                await new Promise(resolve => setTimeout(resolve, 1200));
                window.delayedHistoryDone = true;
            }
            return response;
        };
    }""")
    page.get_by_role("radio", name="资源", exact=True).click()
    page.wait_for_function("window.delayedHistoryStarted")
    page.get_by_role("radio", name="影视", exact=True).click()
    history = page.get_by_role("list", name="最近搜索")
    playwright.expect(history).to_contain_text("影视独有记录")
    page.wait_for_function("window.delayedHistoryDone")
    playwright.expect(history).not_to_contain_text("资源独有记录")
    playwright.expect(history).to_contain_text("影视独有记录")


def test_clear_refreshes_after_delayed_delete_and_mode_switch(page, stack):
    """删除尚未落库时切走再切回；删除完成必须刷新，而不能保留提前读到的旧记录。"""
    page.evaluate("""() => {
        const original = window.fetch.bind(window);
        window.fetch = async (url, options) => {
            const slow = String(url).includes('/search/history?') && options?.method === 'DELETE';
            if (slow) {
                window.slowDeleteStarted = true;
                await new Promise(resolve => setTimeout(resolve, 1200));
            }
            const response = await original(url, options);
            if (slow) window.slowDeleteDone = true;
            return response;
        };
    }""")
    page.get_by_role("button", name="清空影视搜索历史").click()
    page.wait_for_function("window.slowDeleteStarted")
    page.get_by_role("radio", name="资源", exact=True).click()
    page.get_by_role("radio", name="影视", exact=True).click()
    page.wait_for_function("window.slowDeleteDone")
    playwright.expect(page.get_by_role("list", name="最近搜索")).to_have_count(0)
    response = page.request.get(stack["base"] + "/api/v1/search/history")
    assert {item["vertical"] for item in response.json()["data"]} == {"torrents"}
    assert len(response.json()["data"]) == 3
    page.get_by_role("radio", name="资源", exact=True).click()
    playwright.expect(page.get_by_role("list", name="最近搜索")).to_contain_text("资源独有记录")


def test_failed_clear_restores_history_and_reports_error(page, stack):
    """清空失败时恢复真实数据，不能继续把未删除的历史伪装成空列表。"""
    page.evaluate("""() => {
        const original = window.fetch.bind(window);
        window.fetch = async (url, options) => {
            if (String(url).includes('/search/history?') && options?.method === 'DELETE') {
                return new Response(JSON.stringify({success: false, code: 'UNAVAILABLE',
                    message: '测试删除失败', details: null}), {status: 503,
                    headers: {'Content-Type': 'application/json'}});
            }
            return original(url, options);
        };
    }""")
    page.get_by_role("button", name="清空影视搜索历史").click()
    playwright.expect(page.get_by_text("清空搜索历史失败，请重试", exact=True)).to_be_visible()
    playwright.expect(page.get_by_role("list", name="最近搜索")).to_contain_text("影视独有记录")
    assert len(page.request.get(stack["base"] + "/api/v1/search/history").json()["data"]) == 5


def test_failed_single_delete_restores_history(page, stack):
    """单条删除失败后仍显示该记录，并给出错误反馈。"""
    page.evaluate("""() => {
        const original = window.fetch.bind(window);
        window.fetch = async (url, options) => {
            if (String(url).includes('/search/history/') && options?.method === 'DELETE') {
                return new Response(JSON.stringify({success: false, code: 'UNAVAILABLE',
                    message: '测试删除失败', details: null}), {status: 503,
                    headers: {'Content-Type': 'application/json'}});
            }
            return original(url, options);
        };
    }""")
    page.get_by_role("button", name="删除搜索历史：影视独有记录", exact=True).click()
    playwright.expect(page.get_by_text("删除搜索历史失败，请重试", exact=True)).to_be_visible()
    playwright.expect(page.get_by_role("list", name="最近搜索")).to_contain_text("影视独有记录")
    assert len(page.request.get(stack["base"] + "/api/v1/search/history").json()["data"]) == 5


def test_partial_group_delete_waits_for_all_requests(page, stack):
    """整组删除中一条失败、另一条延迟成功；最终只恢复真正未删除的范围。"""
    prefix = stack["base"] + "/api/v1"
    rows = page.request.get(prefix + "/search/history?vertical=torrents").json()["data"]
    group = [row for row in rows if row["keyword"] == "共同关键词"]
    failed_id, deleted_id = [row["id"] for row in group]
    page.evaluate(
        """([failedId, deletedId]) => {
        const original = window.fetch.bind(window);
        window.fetch = async (url, options) => {
            const path = String(url);
            if (options?.method === 'DELETE' && path.endsWith('/history/' + failedId)) {
                return new Response(JSON.stringify({success: false, code: 'UNAVAILABLE',
                    message: '测试删除失败', details: null}), {status: 503,
                    headers: {'Content-Type': 'application/json'}});
            }
            const slow = options?.method === 'DELETE' && path.endsWith('/history/' + deletedId);
            if (slow) await new Promise(resolve => setTimeout(resolve, 1200));
            const response = await original(url, options);
            if (slow) window.groupDeleteDone = true;
            return response;
        };
    }""",
        [failed_id, deleted_id],
    )
    page.get_by_role("radio", name="资源", exact=True).click()
    delete = page.get_by_role("button", name="删除搜索历史组：共同关键词", exact=True)
    playwright.expect(delete).to_be_visible()
    delete.click()
    page.get_by_role("button", name="删除", exact=True).click()
    playwright.expect(page.get_by_text("部分搜索历史删除失败，请重试", exact=True)).to_be_visible()
    assert page.evaluate("window.groupDeleteDone") is True
    playwright.expect(
        page.get_by_role("button", name="删除搜索历史：共同关键词", exact=True)
    ).to_be_visible()
    rows = page.request.get(prefix + "/search/history").json()["data"]
    assert {
        row["id"]
        for row in rows
        if row["vertical"] == "torrents" and row["keyword"] == "共同关键词"
    } == {failed_id}
    assert len([row for row in rows if row["vertical"] == "titles"]) == 2
