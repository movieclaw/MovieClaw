"""Log controls use the reader language; real daily files and log payloads remain raw."""

import re

import pytest

from . import test_i18n_storage_browser as storage
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot

stack = storage.stack
browser = theme.browser
pytestmark = pytest.mark.integration


def test_log_filters_tail_refresh_fullscreen_and_language(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    folder = stack["data"] / "logs"
    folder.mkdir(exist_ok=True)
    latest_day, old_day = "2099-01-02", "2099-01-01"
    latest, older = (folder / f"movieclaw-{day}.log" for day in (latest_day, old_day))
    lines = [f"{latest_day} 10:00:00 | INFO | raw.module | only-at-start"]
    lines.extend(f"{latest_day} 10:00:01 | INFO | raw.module | filler-{n}" for n in range(2100))
    lines.extend(
        [
            f"{latest_day} 10:00:02 | ERROR | raw.module | Raw error 原始错误",
            "  raw stack 原始堆栈",
            f"{latest_day} 10:00:03 | WARNING | raw.module | Raw warning",
            f"{latest_day} 10:00:04 | CRITICAL | raw.module | Raw critical",
            f"{latest_day} 10:00:05 | DEBUG | raw.module | Raw debug",
        ]
    )
    original = ("\n".join(lines) + "\n").encode()
    historical = f"{old_day} 10:00:00 | INFO | raw.module | Raw historical 原始历史\n".encode()
    older.write_bytes(historical)
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors, reads = [], []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.on("response", lambda r: reads.append(r.url) if "/system/logs/" in r.url else None)
    shots = theme.REPO / ".tmp-uidev/i18n/logs"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def english():
        text = page.locator("main").inner_text()
        for raw in ("原始错误", "原始堆栈", "原始历史"):
            text = text.replace(raw, "")
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        latest.write_bytes(original)
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/logs")
        expect(page.get_by_role("combobox", name="Choose log date")).to_have_value(latest_day)
        expect(page.get_by_role("button", name="Load all", exact=True)).to_be_visible()
        expect(page.get_by_role("button", name="Refresh", exact=True)).to_be_enabled()
        page.get_by_role("radio", name="Off", exact=True).click()
        english()
        _snapshot(page, shots / f"{theme_id}-{width}-tail-en.png")
        page.get_by_role("radio", name=re.compile("^Errors")).click()
        expect(page.get_by_text("Raw error 原始错误", exact=False)).to_be_visible()
        expect(page.get_by_text("Raw critical", exact=True)).to_be_visible()
        expect(page.get_by_text("Raw warning", exact=True)).not_to_be_visible()
        page.get_by_role("radio", name=re.compile("^Warnings")).click()
        expect(page.get_by_text("Raw warning", exact=True)).to_be_visible()
        page.get_by_role("radio", name=re.compile("^All")).click()
        search = page.get_by_role("searchbox", name="Search logs", exact=True)
        search.fill("only-at-start")
        expect(
            page.get_by_text("No matching logs. Try a different level or keyword.")
        ).to_be_visible()
        page.get_by_role("button", name="Load all", exact=True).click()
        expect(page.get_by_text("only-at-start", exact=True)).to_be_visible()
        expect(page.get_by_role("button", name="Load all", exact=True)).to_have_count(0)
        search.fill("")
        page.get_by_role("radio", name="3s", exact=True).click()
        assert page.evaluate("localStorage.getItem('movieclaw.log-refresh-interval')") == "3000"
        scroll = page.locator("main div.font-mono.overflow-auto")
        page.wait_for_timeout(650)  # Let the existing 12 × 40ms initial tail settling finish.
        scroll.evaluate("el => {el.scrollTop = 0; el.dispatchEvent(new Event('scroll'))}")
        appended = (
            f"{latest_day} 10:00:06 | INFO | raw.module | Raw new {theme_id}-{width}\n".encode()
        )
        with latest.open("ab") as stream:
            stream.write(appended)
        fresh = page.get_by_role("button", name=re.compile("1 new log entry"))
        expect(fresh).to_be_visible(timeout=15_000)
        fresh.click()
        expect(page.get_by_text(f"Raw new {theme_id}-{width}", exact=True)).to_be_visible()
        page.get_by_role("button", name="View fullscreen", exact=True).click()
        dialog = page.get_by_role("dialog", name="System logs (fullscreen)")
        expect(dialog).to_be_visible()
        dialog.get_by_role("radio", name=re.compile("^Errors")).click()
        dialog.get_by_role("searchbox", name="Search logs", exact=True).fill("原始错误")
        expect(dialog.get_by_text("Raw error ", exact=False)).to_be_visible()
        _snapshot(page, shots / f"{theme_id}-{width}-fullscreen-en.png")
        page.keyboard.press("Escape")
        expect(dialog).to_have_count(0)
        expect(search).to_have_value("原始错误")
        expect(page.get_by_role("radio", name=re.compile("^Errors"))).to_have_attribute(
            "aria-checked", "true"
        )
        search.fill("")
        page.get_by_role("radio", name=re.compile("^All")).click()
        page.get_by_role("combobox", name="Choose log date").select_option(old_day)
        expect(page.get_by_text("Raw historical 原始历史", exact=True)).to_be_visible()
        expect(
            page.get_by_text("Viewing historical logs; auto refresh is paused", exact=True)
        ).to_be_visible()
        old_reads = reads.count(base + "/api/v1/system/logs/" + old_day)
        page.wait_for_timeout(
            3500
        )  # Observe one full 3-second refresh window on a historical date.
        assert reads.count(base + "/api/v1/system/logs/" + old_day) == old_reads
        english()
        page.get_by_text(
            "Viewing historical logs; auto refresh is paused", exact=True
        ).scroll_into_view_if_needed()
        _snapshot(page, shots / f"{theme_id}-{width}-historical-en.png")
        assert latest.read_bytes() == original + appended and older.read_bytes() == historical

    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/library")
    page.evaluate("window.__logsLanguageDocument = true")
    _change_language(page, "zh-Hans")
    assert page.evaluate("window.__logsLanguageDocument")
    page.goto(base + "/settings/logs")
    expect(page.get_by_role("combobox", name="选择日志日期")).to_have_value(latest_day)
    expect(page.get_by_role("radio", name="3s", exact=True)).to_have_attribute(
        "aria-checked", "true"
    )
    _snapshot(page, shots / "logs-zh.png")
    page.goto(base + "/library")
    _change_language(page, "en")
    page.goto(base + "/settings/logs")
    expect(page.get_by_role("button", name="Load all", exact=True)).to_be_visible()
    page.route(
        "**/api/v1/system/logs",
        lambda route: route.fulfill(
            status=503,
            content_type="application/json",
            body='{"success":false,"message":"Raw log failure","code":"FIXTURE"}',
        ),
    )
    page.get_by_role("button", name="Refresh", exact=True).click()
    expect(page.get_by_text("Raw log failure", exact=True)).to_be_visible()
    _snapshot(page, shots / "logs-error-en.png")
    page.unroute("**/api/v1/system/logs")
    page.get_by_role("button", name="Refresh", exact=True).click()
    expect(page.get_by_text("Raw log failure", exact=True)).to_have_count(0)
    expect(page.get_by_role("button", name="Load all", exact=True)).to_be_visible()
    assert not errors, errors
    context.close()
