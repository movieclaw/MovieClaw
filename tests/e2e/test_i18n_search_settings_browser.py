"""Search category preferences through real Next/API/SQLite and owned loopback tracker adapters."""

import json
import re
import sqlite3
import time
from urllib.parse import parse_qs, urlsplit

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_i18n_site_config_browser as sites
from . import test_theme_device_class_browser as theme
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
site_http = sites.site_http


@pytest.fixture(scope="module")
def stack(tmp_path_factory, search_provider, site_http):  # noqa: F811
    yield from ai.stack.__wrapped__(tmp_path_factory, search_provider)


def wait_for(check):
    deadline = time.monotonic() + 30
    while True:
        result = check()
        if result:
            return result
        assert time.monotonic() < deadline
        time.sleep(0.1)


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_category_preferences_preserve_names_scope_and_history(
    stack, browser, site_http, theme_id, width
):  # noqa: F811
    from playwright.sync_api import expect

    from movieclaw_api.settings.schemas import default_search_tabs

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(
        locale="en-US",
        viewport={"width": width, "height": 1000},
        is_mobile=width == 320,
        has_touch=width == 320,
    )
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    preferences = api("get", "/ui/preferences")
    preferences.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=preferences)
    api(
        "put",
        "/search/presets",
        data={"presets": [tab.model_dump() for tab in default_search_tabs()]},
    )
    api("delete", "/search/history")
    patched = context.request.post(
        base + "/api/v1/__lab/sites/upstream",
        data={
            "mteam": site_http[0] + "/mteam",
            "ttg": site_http[0].replace("127.0.0.1", "localhost") + "/ttg",
        },
    )
    assert patched.ok, patched.text()
    for row in api("get", "/sites"):
        api("delete", "/sites/" + row["site_id"])
    proper_names = [row["display_name"] for row in api("get", "/sites/catalog")]
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    target = base + "/settings/sites?tab=search"
    page.goto(target)
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_role("heading", name="Search categories", exact=True)).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/search-settings"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(label):
        body = page.locator("main").inner_text().replace("电影", "Author name")
        for proper_name in proper_names:
            body = body.replace(proper_name, "Site name")
        assert not re.search(r"[\u3400-\u9fff]", body), body
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        assert page.locator("main button, main input").evaluate_all(
            "nodes => nodes.every(node => { const r=node.getBoundingClientRect(); "
            "return !r.width || !r.height || (r.left >= -0.5 && r.right <= innerWidth + 0.5); })"
        )
        page.screenshot(path=str(shots / f"{theme_id}-{width}-{label}.png"), animations="disabled")

    def saved(action, *, status=200):
        with page.expect_response(
            lambda r: r.url.endswith("/api/v1/search/presets") and r.request.method == "PUT"
        ) as pending:
            action()
        assert pending.value.status == status, pending.value.text()
        return pending.value.json()

    def presets():
        return api("get", "/search/presets")["presets"]

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
            return database.execute(
                "SELECT value_json FROM app_setting WHERE namespace='search.preferences'"
            ).fetchone()[0]

    saved(
        lambda: page.get_by_role(
            "switch", name="Hide “Movies” in search categories", exact=True
        ).click()
    )
    assert not next(row for row in presets() if row["id"] == "movie")["visible"]
    saved(
        lambda: page.get_by_role(
            "switch", name="Show “Movies” in search categories", exact=True
        ).click()
    )
    page.get_by_role("button", name="New custom category", exact=True).click()
    expect(
        page.get_by_text(
            "No sites are connected yet. Add one under Site connections, "
            "or save now to search all available sites by default.",
            exact=True,
        )
    ).to_be_visible()
    page.get_by_role("button", name="Cancel", exact=True).click()
    for payload in [
        {"site_id": "mteam", "auth_type": "apikey", "api_key": "fixture-good-key"},
        {
            "site_id": "ttg",
            "auth_type": "credential",
            "username": "fixture",
            "password": "fixture-pass",
            "enabled": False,
        },
    ]:
        api("post", "/sites", data=payload)
    wait_for(
        lambda: all(row["status"] not in {"pending", "verifying"} for row in api("get", "/sites"))
    )
    assert api("get", "/sites/mteam")["usable"]
    assert not api("get", "/sites/ttg")["usable"]
    page.get_by_role("button", name="New custom category", exact=True).click()
    name = page.get_by_placeholder("e.g. 4K media", exact=True)
    name.fill("电影")
    page.locator("main").get_by_role("button", name="Movies", exact=True).click()
    page.locator("main").get_by_role("button", name="TV shows", exact=True).click()
    page.locator("main").get_by_role("button", name="M-Team", exact=True).click()
    unavailable = page.locator("main button[title]").filter(has_text="Unavailable")
    expect(unavailable).to_have_attribute(
        "title",
        "This site is unavailable (disabled or verification failed) "
        "and will be skipped during searches.",
    )
    unavailable.click()
    page.get_by_role("switch", name="Turn on poster mode", exact=True).click()
    page.get_by_role("switch", name="Turn on private search", exact=True).click()
    shot("editor")
    page.get_by_role("button", name="Save", exact=True).evaluate(
        "node => node.scrollIntoView({block: 'center'})"
    )
    shot("editor-footer")
    saved(lambda: page.get_by_role("button", name="Save", exact=True).click())
    custom = next(row for row in presets() if row["type"] == "preset")
    assert custom["name"] == "电影" and custom["categories"] == ["movie", "tv"]
    assert (
        custom["site_ids"] == ["mteam", "ttg"] and custom["poster_mode"] and custom["skip_history"]
    )
    custom_id = custom["id"]
    page.get_by_role("button", name="New custom category", exact=True).click()
    name.fill("电影")
    saved(lambda: page.get_by_role("button", name="Save", exact=True).click(), status=400)
    expect(
        page.get_by_text('A custom category named "电影" already exists', exact=True)
    ).to_be_visible()
    expect(name).to_have_value("电影")
    assert len([row for row in presets() if row["type"] == "preset"]) == 1
    page.get_by_role("button", name="Cancel", exact=True).click()
    before_order = [row["id"] for row in presets()]
    handle = page.get_by_role(
        "button", name="Drag to reorder “电影”, or use the up and down arrow keys", exact=True
    )
    saved(lambda: handle.press("ArrowUp"))
    assert [row["id"] for row in presets()].index(custom_id) == before_order.index(custom_id) - 1
    handles = page.locator('main button[aria-label^="Drag to reorder"]')
    handles.first.scroll_into_view_if_needed()
    first = handles.nth(0).bounding_box()
    second = handles.nth(1).bounding_box()
    x, y = first["x"] + first["width"] / 2, first["y"] + first["height"] / 2
    end_y = second["y"] + second["height"] / 2 + 8
    first_id = presets()[0]["id"]
    with page.expect_response(
        lambda r: r.url.endswith("/api/v1/search/presets") and r.request.method == "PUT"
    ) as moved:
        if width == 320:
            cdp = context.new_cdp_session(page)
            cdp.send(
                "Input.dispatchTouchEvent",
                {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]},
            )
            for step in range(1, 9):
                cdp.send(
                    "Input.dispatchTouchEvent",
                    {
                        "type": "touchMove",
                        "touchPoints": [{"x": x, "y": y + (end_y - y) * step / 8}],
                    },
                )
            cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
            cdp.detach()
        else:
            page.mouse.move(x, y)
            page.mouse.down()
            page.mouse.move(x, end_y, steps=8)
            page.mouse.up()
    assert moved.value.ok
    assert presets()[0]["id"] != first_id
    shot("ordered")
    before_language = stored()
    page.evaluate("window.__searchSettingsDocument = 'retained'")
    for language in ("zh-Hans", "en"):
        current = page.locator("html").get_attribute("lang")
        if width == 320:
            page.get_by_role(
                "button", name="Back" if current == "en" else "返回", exact=True
            ).click()
            expect(page).to_have_url(base + "/settings")
        page.get_by_role(
            "button",
            name="Appearance and language" if current == "en" else "外观与语言",
            exact=True,
        ).click()
        control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
        control.check()
        expect(control).to_be_enabled()
        expect(page.locator("html")).to_have_attribute("lang", language)
        if width == 320:
            page.get_by_role(
                "button", name="返回" if language == "zh-Hans" else "Back", exact=True
            ).click()
            expect(page).to_have_url(base + "/settings")
        page.get_by_role(
            "button", name="资源站点" if language == "zh-Hans" else "Trackers", exact=True
        ).click()
        page.get_by_role(
            "button", name="搜索分类" if language == "zh-Hans" else "Search categories", exact=True
        ).click()
        expect(page.get_by_text("电影", exact=True).last).to_be_visible()
        assert page.evaluate("window.__searchSettingsDocument") == "retained"
        assert stored() == before_language

    def search(keyword):
        page.goto(base + "/library")
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
        page.get_by_role("button", name=re.compile(r"^Search \(")).click()
        dialog = page.get_by_role("dialog", name="Search", exact=True)
        expect(dialog).to_be_visible()
        dialog.get_by_role("radio", name="Resources", exact=True).click()
        field = dialog.get_by_role("textbox", name="Search site resources", exact=True)
        if theme_id == "silver" and width == 320:
            reset = dialog.get_by_role("button", name=re.compile("^Search scope:"))
            if reset.count():
                reset.click()
            field.fill(keyword)
            dialog.get_by_role("button", name=re.compile("^电影")).click()
        else:
            dialog.get_by_role("button", name="电影", exact=True).click()
            field.fill(keyword)
            field.press("Enter")
        expect(page).to_have_url(re.compile("/search\\?"))
        params = parse_qs(urlsplit(page.url).query)
        assert params["label"] == ["电影"] and "label_key" not in params
        assert params["cats"] == ["movie,tv"] and params["sites"] == ["mteam,ttg"]
        wait_for(
            lambda: any(
                method == "POST"
                and path.endswith("/torrent/search")
                and json.loads(body).get("keyword") == keyword
                for method, path, body in site_http[1].requests
            )
        )
        return params

    private_keyword = f"private-{theme_id}-{width}"
    params = search(private_keyword)
    assert params["private"] == ["1"] and params["poster"] == ["1"]
    assert not any(row["keyword"] == private_keyword for row in api("get", "/search/history"))
    page.goto(target)
    page.get_by_role("button", name="Actions for “电影”", exact=True).click()
    page.get_by_role("menuitem", name="Edit", exact=True).click()
    expect(name).to_have_value("电影")
    page.get_by_role("switch", name="Turn off private search", exact=True).click()
    saved(lambda: page.get_by_role("button", name="Save", exact=True).click())
    keyword = f"history-{theme_id}-{width}"
    params = search(keyword)
    assert "private" not in params
    record = wait_for(
        lambda: next(
            (row for row in api("get", "/search/history") if row["keyword"] == keyword), None
        )
    )
    assert record["label"] == "电影" and record["label_key"] is None
    assert not any(row["keyword"] == private_keyword for row in api("get", "/search/history"))
    with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
        assert database.execute(
            "SELECT label,label_key FROM search_history WHERE keyword=?", (keyword,)
        ).fetchone() == ("电影", None)
    page.goto(target)
    page.get_by_role("button", name="Actions for “电影”", exact=True).click()
    page.get_by_role("menuitem", name="Delete", exact=True).click()
    confirmation = page.get_by_role("dialog", name="Delete custom category “电影”?", exact=True)
    expect(confirmation.get_by_text("Search history is retained.", exact=True)).to_be_visible()
    confirmation.get_by_role("button", name="Cancel", exact=True).click()
    assert any(row["id"] == custom_id for row in presets())
    page.get_by_role("button", name="Actions for “电影”", exact=True).click()
    page.get_by_role("menuitem", name="Delete", exact=True).click()
    saved(
        lambda: (
            page.get_by_role("dialog", name="Delete custom category “电影”?", exact=True)
            .get_by_role("button", name="Delete", exact=True)
            .click()
        )
    )
    assert all(row["id"] != custom_id for row in presets())
    assert any(row["id"] == record["id"] for row in api("get", "/search/history"))
    assert not site_http[1].unknown, site_http[1].unknown
    assert not errors, errors
    context.close()
