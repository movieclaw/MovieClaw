"""Create and adjust once, then read the same stored activities in both languages."""

import re

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_I18N_DISCOVERY", "1")
        yield from inventory.stack.__wrapped__(tmp_path_factory)


def test_lifecycle_history_changes_language_without_repeating_actions(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = theme.REPO / ".tmp-uidev/i18n/subscription-lifecycle"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    for name, path in (
        ("我的剧集", stack["roots"]["shows"]),
        ("另一个剧集库", stack["roots"]["shows"].parent / "other-shows"),
    ):
        path.mkdir(exist_ok=True)
        library = api(
            "post", "/libraries", data={"name": name, "kind": "tv", "root_paths": [str(path)]}
        )
    target_library = library["id"]
    api("get", "/discover/titles/tmdb:tv:200")
    page.goto(base + "/media/tv/200")
    page.get_by_role("button", name="Track this title", exact=True).click()
    dialog = page.get_by_role("dialog", name="Subscribe to “测试剧集”", exact=True)
    options = dialog.get_by_role("region", name="More subscription options", exact=True)
    options.get_by_role("button", name=re.compile("^More options")).click()
    options.get_by_role("button", name=re.compile("^Selection mode")).click()
    page.get_by_role("menuitemradio", name="Rule mode", exact=True).click()
    dialog.get_by_role("button", name="Confirm subscription", exact=True).click()
    expect(dialog).not_to_be_visible()
    sub = next(row for row in api("get", "/subscriptions") if row["media"]["tmdb_id"] == 200)
    sub_id = sub["id"]
    path = f"/subscriptions/{sub_id}"
    page.goto(base + path)
    page.get_by_role("button", name="More", exact=True).click()
    page.get_by_role("menuitem", name="Adjust subscription…", exact=True).click()
    dialog = page.get_by_role("dialog", name="Adjust subscription", exact=True)
    dialog.get_by_role("combobox", name="Import to", exact=True).select_option(str(target_library))
    dialog.get_by_role("button", name="Save changes", exact=True).click()
    expect(dialog).not_to_be_visible()

    def histories():
        rows = api("get", path + "/activities")
        return {
            row["message_key"]: row
            for row in rows
            if row["message_key"]
            in {
                "activity.subscription.created",
                "activity.subscription.adjusted",
            }
        }

    english = histories()
    assert len(english) == 2
    identity = {key: row["id"] for key, row in english.items()}

    def show_history():
        button = page.get_by_role(
            "button",
            name=re.compile(
                "^Troubleshooting history"
                if page.locator("html").get_attribute("lang") == "en"
                else "^排查记录"
            ),
        )
        if button.get_attribute("aria-expanded") != "true":
            button.click()
        rows = list(histories().values())
        for row in rows:
            expect(page.get_by_text(row["message"], exact=True)).to_be_visible()
        page.get_by_text(rows[-1]["message"], exact=True).scroll_into_view_if_needed()
        expect(button).to_have_attribute("aria-expanded", "true")

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + path)
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
            page.locator('[class*="nf:"]').first.wait_for(state="attached")
        show_history()
        assert histories() == english
        for row in english.values():
            assert not re.search(r"[\u3400-\u9fff]", row["message"].replace("测试剧集", ""))
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-en.png", full_page=True)

    page.set_viewport_size({"width": 1280, "height": 1000})
    page.evaluate("window.lifecycleMarker = 812")
    for locale in ("zh-Hans", "en"):
        _change_language(page, locale)
        show_history()
        rendered = histories()
        assert {key: row["id"] for key, row in rendered.items()} == identity
        assert api("get", path)["selected_seasons"] == [1]
        assert api("get", path)["library_id"] == target_library
        if locale == "zh-Hans":
            assert rendered["activity.subscription.created"]["message"] == (
                "创建订阅《测试剧集》：勾选第 1 季，自动续订开；共生成 3 个追踪项——"
                "3 集已播出、排入搜索队列"
            )
            assert rendered["activity.subscription.adjusted"]["message"] == (
                "调整订阅：勾选第 1 季，自动续订开；新增 0 个单元，重新纳入 0 个，退出范围 0 个"
                "（下载器任务不会自动删除；退出范围后停止搜索与换源）"
            )
        else:
            assert rendered == english
        assert page.evaluate("window.lifecycleMarker") == 812
        _snapshot(page, shots / f"history-{locale}.png", full_page=True)
    assert len(api("get", "/subscriptions")) == 1
    assert not errors
    context.close()
