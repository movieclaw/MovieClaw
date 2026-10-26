"""Home-row presentation and real preference edits through Next, API and SQLite."""

import re
import sqlite3
import time

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack


async def _seed(database_url, library_id, folder, offset):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import FileSource, LibraryFile, MediaItem
    from movieclaw_db.repositories.library_repo import LibraryRepository

    database = Database(database_url)
    try:
        async with database.session() as session:
            item = MediaItem(
                kind="movie",
                tmdb_id=990000 + offset,
                title="Fixture title",
                original_title="Fixture title",
                year=2024,
            )
            session.add(item)
            await session.flush()
            path = folder / "Fixture.mkv"
            path.write_bytes(b"Keep the original fixture unchanged")
            session.add(
                LibraryFile(
                    library_id=library_id,
                    media_item_id=item.id,
                    file_path=str(path),
                    size_bytes=path.stat().st_size,
                    source=FileSource.SCANNED,
                )
            )
            await session.commit()
            await LibraryRepository(session).refresh_stats([library_id])
            return item.id, path
    finally:
        await database.dispose()


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_custom_home_rows_preserve_facts_and_preferences(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

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
    preferences.update(
        theme=theme_id,
        theme_desktop=theme_id,
        theme_mobile=theme_id,
        language="en",
        home={"rows": []},
    )
    api("put", "/ui/preferences", data=preferences)
    root = stack["data"] / f"customize-{theme_id}-{width}"
    root.mkdir()
    ids = []
    folders = []
    for suffix, kind in [("movies A", "movie"), ("movies B", "movie"), ("shows", "tv")]:
        folder = root / suffix
        folder.mkdir()
        folders.append(folder)
        ids.append(
            api(
                "post",
                "/libraries",
                data={
                    "name": f"Fixture {suffix} {theme_id} {width}",
                    "kind": kind,
                    "root_paths": [str(folder)],
                    "realtime_watch": False,
                },
            )["id"]
        )
    deadline = time.monotonic() + 120
    while not all(
        not row["scanning"] and row["last_scan"]
        for row in api("get", "/libraries")
        if row["id"] in ids
    ):
        assert time.monotonic() < deadline
        time.sleep(0.1)
    item_id, original = _run(
        _seed(
            stack["database_url"],
            ids[0],
            folders[0],
            ["silver", "netflix"].index(theme_id) * 10000 + width,
        )
    )
    collection = api(
        "post",
        "/collections",
        data={
            "name": f"Fixture collection {theme_id} {width}",
            "library_id": ids[0],
            "item_ids": [item_id],
        },
    )
    page = context.new_page()
    page.set_default_timeout(30000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/library/customize")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_role("heading", name="Customize home", exact=True)).to_be_visible()
    rows = page.get_by_test_id("home-rows")
    expect(rows).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/library-customize"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name):
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def prefs():
        return api("get", "/ui/preferences")

    def wait_saved(predicate):
        end = time.monotonic() + 15
        while True:
            current = prefs()
            if predicate(current):
                return current
            assert time.monotonic() < end, current["home"]
            time.sleep(0.1)

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return db.execute(
                "SELECT json_extract(value_json,'$.home'), "
                "json_extract(value_json,'$.nav'), json_extract(value_json,'$.sidebar') "
                "FROM app_setting WHERE namespace='ui.preferences'"
            ).fetchone()

    shot("defaults")
    initial_ids = set(rows.locator("li").evaluate_all("els => els.map(el=>el.dataset.rowId)"))
    page.get_by_role("button", name=re.compile("^All movies")).click()
    expect(rows.locator("li")).to_have_count(len(initial_ids) + 1)
    new_id = next(
        key
        for key in rows.locator("li").evaluate_all("els=>els.map(el=>el.dataset.rowId)")
        if key not in initial_ids
    )
    extra = page.get_by_test_id(f"home-row-item-{new_id}")
    expect(extra.get_by_test_id("row-settings")).to_be_visible()
    extra.get_by_test_id("row-sort").get_by_role("button").click()
    expect(page.get_by_role("menu")).to_have_css("opacity", "1")
    shot("sort-menu")
    page.get_by_role("menuitemradio", name="First added", exact=True).click()
    extra.get_by_test_id("row-name").fill("Author evening")
    extra.get_by_test_id("row-unwatched").check()
    current = wait_saved(
        lambda p: any(
            r["id"] == new_id
            and r["name"] == "Author evening"
            and r["order"] == "asc"
            and r["unwatched"]
            for r in p["home"]["rows"]
        )
    )
    assert next(r for r in current["home"]["rows"] if r["id"] == new_id)["sort"] == "added_at"
    extra.scroll_into_view_if_needed()
    shot("row-settings")
    extra.get_by_test_id("row-visibility").click()
    wait_saved(lambda p: next(r for r in p["home"]["rows"] if r["id"] == new_id)["hidden"])
    expect(extra.get_by_test_id("row-title")).to_contain_text("Hidden")
    extra.get_by_test_id("row-visibility").click()
    wait_saved(lambda p: not next(r for r in p["home"]["rows"] if r["id"] == new_id)["hidden"])
    grip = extra.get_by_test_id("row-grip")
    grip.focus()
    grip.press("Alt+ArrowUp")
    before_keys = [r["id"] for r in current["home"]["rows"]]
    current = wait_saved(lambda p: [r["id"] for r in p["home"]["rows"]] != before_keys)
    assert [r["id"] for r in current["home"]["rows"]].index(new_id) == len(initial_ids) - 1
    page.get_by_role("button", name=re.compile("^" + re.escape(collection["name"]))).click()
    expect(
        page.get_by_role("button", name=re.compile("^" + re.escape(collection["name"]))).filter(
            has_text="On home"
        )
    ).to_be_disabled()
    current = wait_saved(
        lambda p: any(r["collection_id"] == collection["id"] for r in p["home"]["rows"])
    )
    added_collection = next(
        r for r in current["home"]["rows"] if r["collection_id"] == collection["id"]
    )
    assert not added_collection["name"]
    page.get_by_test_id(f"home-row-item-{added_collection['id']}").scroll_into_view_if_needed()
    shot("edited")
    # Exercise the real pointer path; narrow scenes use browser touch events.
    rows.locator("li").first.scroll_into_view_if_needed()
    first = rows.locator("li").nth(0).get_by_test_id("row-grip")
    second = rows.locator("li").nth(1).get_by_test_id("row-grip")
    first_id = rows.locator("li").nth(0).get_attribute("data-row-id")
    a, b = first.bounding_box(), second.bounding_box()
    x, y = a["x"] + a["width"] / 2, a["y"] + a["height"] / 2
    target = b["y"] + b["height"] / 2 + 8
    if width == 320:
        session = context.new_cdp_session(page)
        session.send(
            "Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x, "y": y}]}
        )
        for step in range(1, 9):
            session.send(
                "Input.dispatchTouchEvent",
                {"type": "touchMove", "touchPoints": [{"x": x, "y": y + (target - y) * step / 8}]},
            )
        session.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
        session.detach()
    else:
        page.mouse.move(x, y)
        page.mouse.down()
        page.mouse.move(x, target, steps=8)
        page.mouse.up()
    wait_saved(lambda p: p["home"]["rows"][0]["id"] != first_id)
    before = stored()
    for language in ("zh-Hans", "en"):
        page.goto(base + "/settings/appearance")
        control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
        control.check()
        expect(control).to_be_enabled()
        expect(page.locator("html")).to_have_attribute("lang", language)
        page.goto(base + "/library/customize")
        expect(
            page.get_by_role(
                "heading",
                name="自定义首页" if language == "zh-Hans" else "Customize home",
                exact=True,
            )
        ).to_be_visible()
        expect(
            page.get_by_test_id(f"home-row-item-{new_id}").get_by_test_id("row-title")
        ).to_contain_text("Author evening")
        assert stored() == before
    page.goto(base + "/library")
    expect(page.get_by_text("Author evening", exact=True)).to_be_visible()
    page.goto(base + "/library/customize")
    extra = page.get_by_test_id(f"home-row-item-{new_id}")
    extra.get_by_test_id("row-title").click()
    extra.get_by_test_id("row-remove").click()
    expect(extra).to_have_count(0)
    wait_saved(lambda p: all(r["id"] != new_id for r in p["home"]["rows"]))
    before = stored()

    def cancel(dialog):
        assert dialog.message == "Reset the layout? Rows you added will be removed."
        dialog.dismiss()

    page.once("dialog", cancel)
    page.get_by_role("button", name="Reset layout", exact=True).click()
    assert stored() == before
    page.once("dialog", lambda dialog: dialog.accept())
    page.get_by_role("button", name="Reset layout", exact=True).click()
    final = wait_saved(lambda p: p["home"]["rows"] == [])
    for key in ("nav", "sidebar", "scrim", "language"):
        assert final[key] == preferences[key]
    shot("reset")
    assert original.read_bytes() == b"Keep the original fixture unchanged"
    assert not errors, errors
    context.close()
