"""Localized duplicate decisions through the real scan, Next, API, SQLite and filesystem."""

import re
import sqlite3
import time
from pathlib import Path

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


async def _seed(database_url, library_ids, folders, offset):
    from movieclaw_api.services.library.origin import scan_origin
    from movieclaw_db.engine import Database
    from movieclaw_db.models import FileSource, LibraryFile, MediaEpisode, MediaItem

    database = Database(database_url)
    try:
        async with database.session() as session:
            items = []
            for index, title in enumerate(
                ("Fixture movie", "Fixture twin", "Fixture show", "Fixture incomplete")
            ):
                row = MediaItem(
                    kind="tv" if index == 2 else "movie",
                    tmdb_id=950000 + offset + index,
                    title=title,
                    original_title=title,
                    year=2024,
                )
                session.add(row)
                items.append(row)
            await session.flush()
            rows, originals = [], {}

            def add(index, name, size, resolution, source, episode=0):
                folder = folders[index == 2]
                path = folder / name
                path.write_bytes((name.encode() * size)[:size])
                row = LibraryFile(
                    library_id=library_ids[index == 2],
                    media_item_id=items[index].id,
                    file_path=str(path),
                    size_bytes=size,
                    duration_seconds=600 + episode,
                    source=FileSource.SCANNED,
                    origin=scan_origin("manual"),
                    resolution=resolution,
                    media_source=source,
                    bit_rate=size * 1000,
                    season_number=1 if index == 2 else 0,
                    episode_number=episode,
                )
                session.add(row)
                rows.append(row)
                originals[name] = path.read_bytes()

            add(0, "Fixture.Movie.2160p.WEB-DL.mkv", 8192, "2160p", "WEB-DL")
            add(0, "Fixture.Movie.1080p.WEB-DL.mkv", 4096, "1080p", "WEB-DL")
            for name in ("Fixture.Twin.mkv", "Fixture.Twin.copy.mkv"):
                add(1, name, 3000, "1080p", "WEB-DL")
            for episode in (1, 2, 3):
                session.add(
                    MediaEpisode(
                        media_item_id=items[2].id,
                        season_number=1,
                        episode_number=episode,
                        name=f"Fixture episode {episode}",
                    )
                )
                add(
                    2,
                    f"Fixture.Show.S01E0{episode}.1080p.BluRay.mkv",
                    2048,
                    "1080p",
                    "Blu-ray",
                    episode,
                )
                add(2, f"Fixture.Show.S01E0{episode}.720p.HDTV.mkv", 1024, "720p", "HDTV", episode)
            add(3, "Fixture.Incomplete.A.mkv", 300, "1080p", None)
            add(3, "Fixture.Incomplete.B.mkv", 400, "1080p", "WEB-DL")
            await session.commit()
            from movieclaw_db.repositories.library_repo import LibraryRepository

            await LibraryRepository(session).refresh_stats(library_ids)
            return {
                "items": [row.id for row in items],
                "originals": originals,
                "paths": {Path(row.file_path).name: row.file_path for row in rows},
            }
    finally:
        await database.dispose()


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_duplicate_file_season_and_group_decisions(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    preferences = api("get", "/ui/preferences")
    preferences.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=preferences)
    root = stack["data"] / f"duplicates-{theme_id}-{width}"
    root.mkdir()
    sentinel = root / "outside-libraries.txt"
    sentinel.write_bytes(b"Keep source bytes")
    folders = [root / "movies", root / "shows"]
    library_ids = []
    for folder, kind in zip(folders, ["movie", "tv"], strict=True):
        folder.mkdir()
        library_ids.append(
            api(
                "post",
                "/libraries",
                data={
                    "name": f"Fixture {kind} {theme_id} {width}",
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
        if row["id"] in library_ids
    ):
        assert time.monotonic() < deadline
        time.sleep(0.1)
    offset = ["silver", "netflix"].index(theme_id) * 10000 + width * 10
    seeded = _run(_seed(stack["database_url"], library_ids, folders, offset))
    page = context.new_page()
    page.set_default_timeout(30000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/library/manage?tab=duplicates")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    page.get_by_role("button", name=re.compile("^(Start scan|Scan again)$")).first.click()
    expect(page.get_by_role("heading", name=re.compile("^Suggested cleanup"))).to_be_visible()
    expect(page.get_by_role("heading", name=re.compile("^Your decision"))).to_be_visible()
    expect(page.get_by_role("button", name="Scan again", exact=True)).to_be_enabled()
    shots = REPO / ".tmp-uidev/i18n/duplicates"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name):
        expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        if not page.evaluate("document.documentElement.scrollWidth <= innerWidth"):
            _snapshot(page, shots / f"{theme_id}-{width}-{name}-overflow.png")
            raise AssertionError(
                page.evaluate("""() => [...document.querySelectorAll('body *')]
                .filter(el => el.getBoundingClientRect().right > innerWidth+1)
                .slice(-10).map(el => ({text:el.textContent?.slice(0,60), cls:el.className}))""")
            )
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return [
                db.execute(query).fetchall()
                for query in (
                    "SELECT id,file_path,state,origin,trash_context,kept_at "
                    "FROM library_file ORDER BY id",
                    "SELECT * FROM library_duplicate_unit ORDER BY id",
                )
            ]

    def card(title):
        return page.get_by_role("link", name=title, exact=True).locator(
            "xpath=ancestor::div[contains(@class,'overflow-hidden')][1]"
        )

    shot("summary")
    before = stored()
    if width == 1280:
        for language in ("zh-Hans", "en"):
            page.goto(base + "/settings/appearance")
            control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
            control.check()
            expect(control).to_be_enabled()
            expect(page.locator("html")).to_have_attribute("lang", language)
            page.goto(base + "/library/manage?tab=duplicates")
            expect(
                page.get_by_role(
                    "heading",
                    name=re.compile("^建议清理" if language == "zh-Hans" else "^Suggested cleanup"),
                )
            ).to_be_visible()
            assert stored() == before
            assert all(
                Path(seeded["paths"][name]).read_bytes() == content
                for name, content in seeded["originals"].items()
            )
    # Search is applied at the reader boundary; clearing restores the same source groups.
    page.get_by_role("searchbox", name="Search duplicate files").fill("Fixture movie")
    page.get_by_role("heading", name=re.compile("^Suggested cleanup")).locator("..").get_by_role(
        "button", name="Review", exact=True
    ).click()
    expect(page.get_by_role("link", name="Fixture movie", exact=True)).to_be_visible()
    expect(page.get_by_role("link", name="Fixture show", exact=True)).to_have_count(0)
    page.get_by_role("button", name="Clear search", exact=True).click()
    page.get_by_role("button", name=re.compile("^Suggested cleanup")).click()
    expect(page.get_by_role("link", name="Fixture show", exact=True)).to_be_visible()
    shot("details")
    movie = card("Fixture movie")
    movie.get_by_role("button", name="Keep this", exact=True).first.click()
    dialog = page.get_by_role("dialog")
    expect(dialog).to_contain_text("Keep Fixture.Movie.2160p.WEB-DL.mkv")
    shot("keep-file")
    dialog.get_by_role("button", name="Cancel", exact=True).click()
    assert stored() == before
    movie.get_by_role("button", name="Keep this", exact=True).first.click()
    dialog.get_by_role("button", name="Recycle · 1", exact=True).click()
    expect(page.get_by_role("link", name="Fixture movie", exact=True)).to_have_count(0)
    assert Path(seeded["paths"]["Fixture.Movie.2160p.WEB-DL.mkv"]).exists()
    assert not Path(seeded["paths"]["Fixture.Movie.1080p.WEB-DL.mkv"]).exists()
    show = card("Fixture show")
    show.get_by_role("button", name="Expand episodes", exact=True).click()
    shot("episodes")
    show.locator("span.font-mono").first.click()
    tooltip = page.get_by_role("tooltip")
    expect(tooltip.locator(".tooltip-bubble")).to_have_css("opacity", "1")
    expect(tooltip).to_contain_text("Original filename")
    shot("paths")
    page.keyboard.press("Escape")
    expect(tooltip).to_have_count(0)
    show.get_by_role("button", name="Collapse episodes", exact=True).click()
    show.get_by_role("button", name="Keep for season", exact=True).first.click()
    expect(dialog).to_contain_text("Keep 1080p Blu-ray")
    shot("keep-season")
    dialog.get_by_role("button", name="Recycle · 3", exact=True).click()
    expect(page.get_by_role("link", name="Fixture show", exact=True)).to_have_count(0)
    for episode in (1, 2, 3):
        assert Path(seeded["paths"][f"Fixture.Show.S01E0{episode}.1080p.BluRay.mkv"]).exists()
        assert not Path(seeded["paths"][f"Fixture.Show.S01E0{episode}.720p.HDTV.mkv"]).exists()
    page.get_by_role("button", name="Summary", exact=True).click()
    unknown = page.get_by_text("Incomplete specifications", exact=True).locator("..")
    unknown.get_by_role("button", name="Keep all", exact=True).click()
    expect(dialog).to_contain_text("Files stay in place")
    shot("keep-group")
    dialog.get_by_role("button", name="Keep all · 1", exact=True).click()
    expect(page.get_by_text("Incomplete specifications", exact=True)).to_have_count(0)
    page.get_by_role("button", name="Clean up all · 1", exact=True).click()
    expect(dialog).to_contain_text("identical files")
    dialog.get_by_role("button", name="Recycle · 1", exact=True).click()
    expect(page.get_by_role("heading", name="No duplicate files", exact=True)).to_be_visible()
    shot("empty")
    page.goto(base + "/library/manage?tab=recycle")
    expect(page.get_by_text("Duplicate cleanup: kept", exact=False).first).to_be_visible()
    trash = api("get", "/libraries/trashed-files")
    assert trash["total_files"] == 5
    for entry in trash["items"]:
        for f in entry["files"]:
            assert Path(f["file_path"]).read_bytes() == seeded["originals"][f["file_name"]]
    for title in ("Fixture movie", "Fixture show", "Fixture twin"):
        entry = page.get_by_role("checkbox", name=f"Select “{title}”", exact=True).locator(
            "xpath=ancestor::div[@role='rowgroup' or contains(@class,'py-3.5')][1]"
        )
        entry.get_by_role("button", name=re.compile("^Restore( 3)?$")).first.click()
        expect(page.get_by_text(title, exact=True)).to_have_count(0)
    expect(page.get_by_role("heading", name="Recycle bin is empty", exact=True)).to_be_visible()
    # Keep restored fixture versions so subsequent independent scenes do not rediscover them.
    for item_id in seeded["items"][:3]:
        api(
            "post",
            "/libraries/duplicate-files/resolve",
            data={
                "media_item_id": item_id,
                "season_number": 1 if item_id == seeded["items"][2] else 0,
                "keep_all": True,
            },
        )
    assert all(
        Path(seeded["paths"][name]).read_bytes() == content
        for name, content in seeded["originals"].items()
    )
    assert sentinel.read_bytes() == b"Keep source bytes"
    assert not errors, errors
    context.close()
