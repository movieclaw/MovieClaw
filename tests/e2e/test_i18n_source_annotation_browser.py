"""Source annotation via the real upgrade report, API and SQLite with preserved local files."""

import hashlib
import json
import re
import sqlite3

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack


async def _seed(database_url, folder, identity):
    from tests.api import test_upgrade_run as upgrades

    from movieclaw_db.engine import Database
    from movieclaw_db.models import Library, MediaItem, Subscription, SubscriptionStatus

    database = Database(database_url)
    try:
        library_id, item_id, sub_id, _rules = await upgrades._seed(
            database,
            tmdb_id=identity,
            spec={"resolutions": ["2160p"], "upgrade_source": "web-dl"},
            episodes=((7, 1), (7, 2), (7, 3)),
            status=SubscriptionStatus.COMPLETED,
        )
        async with database.session() as session:
            library = await session.get(Library, library_id)
            library.root_paths = [str(folder)]
            item = await session.get(MediaItem, item_id)
            item.title = "Fixture series"
            sub = await session.get(Subscription, sub_id)
            sub.selected_seasons = [7]
            await session.commit()
            paths = []
            for episode in (1, 2, 3):
                path = folder / f"原始 S07E{episode:02}.mkv"
                path.write_bytes(f"Keep original episode {episode}".encode())
                paths.append(path)
                file = upgrades._file(
                    library_id,
                    item_id,
                    7,
                    episode,
                    resolution="2160p",
                    bit_rate=1900000,
                    media_source="WEB-DL" if episode in (2, 3) else None,
                    media_source_manual=episode == 2,
                )
                file.file_path, file.size_bytes = str(path), path.stat().st_size
                session.add(file)
                await session.commit()
                await upgrades._add_wanted(
                    session,
                    sub_id,
                    item_id,
                    7,
                    episode,
                    quality={
                        "resolution": "2160p",
                        "bit_rate": 1900000,
                        **({"media_source": "WEB-DL"} if episode == 3 else {}),
                    },
                )
            return item_id, sub_id, paths
    finally:
        await database.dispose()


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_annotation_preserves_parsed_sources_and_file_bytes(stack, browser, theme_id, width):  # noqa: F811
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
    preferences.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=preferences)
    folder = stack["data"] / f"annotation-{theme_id}-{width}"
    folder.mkdir()
    item_id, sub_id, paths = _run(
        _seed(
            stack["database_url"], folder, 920000 + width + (10000 if theme_id == "netflix" else 0)
        )
    )
    hashes = [hashlib.sha256(path.read_bytes()).hexdigest() for path in paths]

    def rows():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
            return database.execute(
                "SELECT episode_number,media_source,media_source_manual FROM library_file "
                "WHERE media_item_id=? ORDER BY episode_number",
                (item_id,),
            ).fetchall()

    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + f"/subscriptions/{sub_id}?upgrade-run=1")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    report = page.get_by_role("dialog", name="Run a quality upgrade", exact=True)
    report.get_by_role("button", name="Check and upgrade", exact=True).click()
    expect(report.get_by_role("heading", name="Upgrade check report", exact=True)).to_be_visible()
    entry = report.get_by_role("button", name="Annotate source", exact=True)
    expect(entry).to_be_visible()
    candidate_route = "**/api/v1/libraries/media-source-annotations/candidates?*"
    page.route(
        candidate_route,
        lambda route: route.fulfill(
            status=503,
            content_type="application/json",
            body='{"success":false,"message":"Fixture unavailable"}',
        ),
    )
    entry.click()
    dialog = page.get_by_role("dialog", name="Identify source", exact=True)
    expect(
        dialog.get_by_text("Could not load the files to identify. Try again later.", exact=True)
    ).to_be_visible()
    expect(dialog.get_by_role("button", name="Confirm source", exact=True)).to_be_disabled()
    dialog.get_by_role("button", name="Cancel", exact=True).click()
    page.unroute(candidate_route)
    entry.click()
    expect(
        dialog.get_by_role("heading", name="Identify source for Season 7", exact=True)
    ).to_be_visible()
    expect(dialog.get_by_text("2 files will be updated together", exact=True)).to_be_visible()
    expect(dialog.get_by_text(paths[0].name, exact=True)).to_be_visible()
    expect(dialog.get_by_text(paths[1].name, exact=True)).to_be_visible()
    expect(dialog.get_by_text(paths[2].name, exact=True)).to_have_count(0)
    expect(dialog.get_by_text("Currently WEB-DL", exact=True)).to_be_visible()
    lowest = dialog.get_by_role("button", name=re.compile("^Uncertain "))
    lowest.click()
    expect(lowest).to_have_attribute("aria-pressed", "true")
    shots = REPO / ".tmp-uidev/i18n/source-annotation"
    shots.mkdir(parents=True, exist_ok=True)
    copy = dialog.inner_text()
    for path in paths:
        copy = copy.replace(path.name, "Author filename")
    assert not re.search(r"[\u3400-\u9fff]", copy)
    assert dialog.evaluate("node=>node.scrollWidth<=node.clientWidth")
    assert page.evaluate("document.documentElement.scrollWidth<=innerWidth")
    page.screenshot(path=str(shots / f"{theme_id}-{width}-lowest.png"), animations="disabled")
    before = rows()
    dialog.get_by_role("button", name="Cancel", exact=True).click()
    assert rows() == before
    entry.click()
    remux = dialog.get_by_role("button", name=re.compile("^Remux"))
    remux.click()
    expect(remux).to_have_attribute("aria-pressed", "true")
    with page.expect_response(
        lambda r: (
            r.url.endswith("/api/v1/libraries/media-source-annotations")
            and r.request.method == "POST"
        )
    ) as pending:
        dialog.get_by_role("button", name="Confirm source", exact=True).click()
    assert pending.value.ok, pending.value.text()
    assert pending.value.json()["data"]["files"] == 2
    assert pending.value.request.post_data_json == {
        "media_item_id": item_id,
        "season_number": 7,
        "media_source": "Remux",
    }
    expect(dialog).not_to_be_visible()
    expect(report.get_by_role("button", name="Annotate source", exact=True)).to_have_count(0)
    assert rows() == [(1, "Remux", 1), (2, "Remux", 1), (3, "WEB-DL", 0)]
    with sqlite3.connect(stack["data"] / "movieclaw.db") as database:
        quality = json.loads(
            database.execute(
                "SELECT quality FROM wanted_item WHERE subscription_id=? AND episode_number=1",
                (sub_id,),
            ).fetchone()[0]
        )
        assert quality["resolution"] == "2160p" and quality["bit_rate"] == 1900000
        assert quality["media_source"] == "Remux"
    assert [hashlib.sha256(path.read_bytes()).hexdigest() for path in paths] == hashes
    assert not errors, errors
    context.close()
