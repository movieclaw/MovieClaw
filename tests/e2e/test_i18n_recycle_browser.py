"""Trash controls and real filesystem recovery/deletion through Next, API and SQLite."""

import re
import sqlite3
import time
from datetime import timedelta
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


async def _seed_recycle(database_url, movie_lib, tv_lib, movies, tv, offset):
    from movieclaw_api.i18n.stored import reference, stored_fields
    from movieclaw_api.services.library.recycle import recycle_file
    from movieclaw_db.engine import Database
    from movieclaw_db.models import FileSource, LibraryFile, MediaEpisode, MediaItem, utcnow
    from movieclaw_db.repositories.library_repo import LibraryRepository

    database = Database(database_url)
    try:
        async with database.session() as session:
            movie = MediaItem(
                kind="movie",
                tmdb_id=910000 + offset,
                title="Fixture movie",
                original_title="Fixture movie",
                year=2024,
            )
            show = MediaItem(
                kind="tv",
                tmdb_id=920000 + offset,
                title="Fixture show",
                original_title="Fixture show",
                year=2024,
            )
            session.add_all([movie, show])
            await session.flush()
            files = []
            paths = []
            for index in range(4):
                root = movies if index == 0 else tv
                path = root / (
                    "Fixture.Movie.1080p.mkv" if index == 0 else f"Fixture.Show.S01E0{index}.mkv"
                )
                if index == 3:
                    path = tv / "Fixture.Show.S01E03.disc"
                    path.mkdir()
                    child_path = path / "tracked-child.mkv"
                    child_path.write_bytes(b"Tracked source file must be protected")
                    child = LibraryFile(
                        library_id=tv_lib,
                        media_item_id=show.id,
                        file_path=str(child_path),
                        size_bytes=child_path.stat().st_size,
                        source=FileSource.IMPORTED,
                        season_number=1,
                        episode_number=3,
                    )
                    session.add(child)
                else:
                    path.write_bytes((f"Original fixture content {index}\n" * 40).encode())
                row = LibraryFile(
                    library_id=movie_lib if index == 0 else tv_lib,
                    media_item_id=movie.id if index == 0 else show.id,
                    file_path=str(path),
                    size_bytes=path.stat().st_size if path.is_file() else child_path.stat().st_size,
                    source=FileSource.IMPORTED,
                    resolution="1080p" if index == 0 else "720p" if index < 3 else None,
                    media_source="WEB-DL" if index == 0 else "HDTV" if index < 3 else None,
                    video_codec="h264",
                    season_number=0 if index == 0 else 1,
                    episode_number=index,
                    audio_streams=[{"codec": "aac", "channels": 2}],
                )
                session.add(row)
                files.append(row)
                paths.append(str(path))
                if index:
                    session.add(
                        MediaEpisode(
                            media_item_id=show.id,
                            season_number=1,
                            episode_number=index,
                            name=f"Fixture episode {index}",
                        )
                    )
            await session.flush()
            for index, row in enumerate(files):
                key = (
                    "library.recycle.noteRefuted" if index == 3 else "library.recycle.noteUpgraded"
                )
                params = (
                    {}
                    if index == 3
                    else {
                        "old": "1080p WEB-DL" if index == 0 else "720p HDTV",
                        "new": "2160p Remux" if index == 0 else "1080p Blu-ray",
                    }
                )
                await recycle_file(
                    session,
                    row,
                    reason="upgrade_refuted" if index == 3 else "upgrade_replaced",
                    trigger={"kind": "member", "id": 0, "label": "Fixture author"},
                    note=stored_fields(key, **params)["message"],
                    note_ref=reference(key, **params),
                )
                row.purge_after = utcnow() + timedelta(
                    hours=6.5 if index == 0 else 9.5 if index < 3 else 50.5
                )
            await session.commit()
            await LibraryRepository(session).refresh_stats([movie_lib, tv_lib])
            await session.commit()
            return {
                "movie_id": movie.id,
                "show_id": show.id,
                "ids": [row.id for row in files],
                "originals": paths,
                "kept_id": files[-1].id,
                "child_id": child.id,
                "child_path": str(child_path),
            }
    finally:
        await database.dispose()


async def _remove_test_child_record(database_url, child_id):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import LibraryFile

    database = Database(database_url)
    try:
        async with database.session() as session:
            await session.delete(await session.get(LibraryFile, child_id))
            await session.commit()
    finally:
        await database.dispose()


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_recycle_restore_selection_guard_and_retry(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    reply = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not reply.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    root = stack["data"] / f"recycle-{theme_id}-{width}"
    root.mkdir()
    sentinel = root / "keep-original.txt"
    sentinel.write_bytes(b"External original must survive all Trash actions")
    folders = [root / "movies", root / "shows"]
    libraries = []
    for folder, kind in zip(folders, ["movie", "tv"], strict=True):
        folder.mkdir()
        libraries.append(
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
    while True:
        rows = api("get", "/libraries")
        if all(not row["scanning"] and row["last_scan"] for row in rows if row["id"] in libraries):
            break
        assert time.monotonic() < deadline, "Initial empty library scans did not finish"
        time.sleep(0.1)
    offset = ["silver", "netflix"].index(theme_id) * 10000 + width
    seeded = _run(_seed_recycle(stack["database_url"], *libraries, *folders, offset))
    page = context.new_page()
    page.set_default_timeout(30000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/library/manage?tab=recycle")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_text("Fixture movie", exact=True)).to_be_visible()
    expect(page.get_by_text("Fixture show", exact=True)).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/recycle"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name):
        expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        if not page.evaluate("document.documentElement.scrollWidth <= innerWidth"):
            _snapshot(page, shots / f"{theme_id}-{width}-{name}-overflow.png")
            offenders = page.evaluate("""() => [...document.querySelectorAll('body *')]
            .filter(el => {
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.right > innerWidth + 1;
            }).slice(-12).map(el => ({
                tag:el.tagName, cls:el.className, text:el.textContent?.slice(0,60),
                right:el.getBoundingClientRect().right
            }))""")
            raise AssertionError(offenders)
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return db.execute(
                "SELECT id,file_path,state,trash_context FROM library_file ORDER BY id"
            ).fetchall()

    def content():
        return {
            str(path): path.read_bytes()
            for folder in folders
            for path in folder.rglob("*")
            if path.is_file()
        }

    shot("loaded")
    search = page.get_by_role("searchbox", name="Search recycle bin", exact=True)
    search.fill("Fixture movie")
    expect(page.get_by_text("Fixture show", exact=True)).to_have_count(0)
    expect(page.get_by_role("button", name="Delete all now · 1", exact=True)).to_be_visible()
    page.get_by_role("button", name="Clear search", exact=True).click()
    expect(page.get_by_text("Fixture show", exact=True)).to_be_visible()
    reason = page.get_by_role("button", name=re.compile("^Replaced by upgrade"))
    reason.click()
    expect(page.get_by_role("button", name="Delete all now · 3", exact=True)).to_be_visible()
    reason.click()
    expect(page.get_by_role("button", name="Delete all now · 4", exact=True)).to_be_visible()
    before, original_bytes = stored(), content()
    if width == 1280:
        for language in ("zh-Hans", "en"):
            page.goto(base + "/settings/appearance")
            control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
            control.check()
            expect(control).to_be_enabled()
            expect(page.locator("html")).to_have_attribute("lang", language)
            page.get_by_role(
                "button",
                name="返回工作台" if language == "zh-Hans" else "Back to dashboard",
                exact=True,
            ).click()
            page.goto(base + "/library/manage?tab=recycle")
            expect(page.get_by_text("Fixture movie", exact=True)).to_be_visible()
            assert stored() == before and content() == original_bytes
    expand = (
        page.get_by_role("button", name="Expand 3 files", exact=True)
        if width == 1280
        else page.get_by_role("button", name=re.compile("3 episodes.*1 season"))
    )
    expand.click()
    expect(page.get_by_text("Fixture episode 1", exact=True)).to_be_visible()
    shot("expanded")
    filename = page.get_by_role(
        "button", name="View the location of “Fixture.Show.S01E01.mkv”", exact=True
    )
    filename.click()
    expect(page.get_by_role("tooltip").locator(".tooltip-bubble")).to_have_css("opacity", "1")
    expect(
        page.get_by_text("Original path (restore destination)", exact=True).first
    ).to_be_visible()
    _snapshot(page, shots / f"{theme_id}-{width}-paths.png")
    page.keyboard.press("Escape")
    expect(page.get_by_role("tooltip")).to_have_count(0)
    page.get_by_role("checkbox", name="Select “Fixture show”", exact=True).check()
    shot("selected")
    page.get_by_role(
        "button", name="Restore selected" if width == 1280 else "Restore", exact=True
    ).last.click()
    expect(page.locator(".toast-item")).to_contain_text("Restored 3 files")
    assert all(Path(path).exists() for path in seeded["originals"][1:])
    assert Path(seeded["child_path"]).read_bytes() == b"Tracked source file must be protected"

    # Recycle the protected folder again through the mechanism to exercise the actual purge guard.
    # Other files stay restored; the movie remains in Trash.
    async def retrash():
        from movieclaw_api.i18n.stored import reference
        from movieclaw_api.services.library.recycle import recycle_file
        from movieclaw_db.engine import Database
        from movieclaw_db.models import LibraryFile

        database = Database(stack["database_url"])
        try:
            async with database.session() as session:
                row = await session.get(LibraryFile, seeded["kept_id"])
                await recycle_file(
                    session,
                    row,
                    reason="upgrade_refuted",
                    trigger={"kind": "member", "label": "Fixture author"},
                    note="洗版证伪：实测档位不高于当前版本",
                    note_ref=reference("library.recycle.noteRefuted"),
                )
                await session.commit()
        finally:
            await database.dispose()

    _run(retrash())
    page.reload()
    expect(page.get_by_role("button", name="Delete all now · 2", exact=True)).to_be_visible()
    page.get_by_role("button", name="Delete all now · 2", exact=True).click()
    dialog = page.get_by_role("dialog")
    expect(dialog.get_by_text("Deletion cannot be undone.", exact=False)).to_be_visible()
    dialog.get_by_role("button", name="Not now", exact=True).click()
    assert len(api("get", "/libraries/trashed-files")["items"]) == 2
    movie_trash = next(
        file
        for item in api("get", "/libraries/trashed-files")["items"]
        for file in item["files"]
        if file["id"] == seeded["ids"][0]
    )
    assert Path(movie_trash["file_path"]).exists()
    page.get_by_role("button", name="Delete all now · 2", exact=True).click()
    dialog.get_by_role("button", name="Delete 2 files", exact=True).click()
    expect(page.locator(".toast-item")).to_contain_text("1 failed")
    assert not Path(movie_trash["file_path"]).exists()
    assert Path(seeded["child_path"]).read_bytes() == b"Tracked source file must be protected"
    expect(page.get_by_text("Could not purge:", exact=False)).to_be_visible()
    shot("protected")
    _run(_remove_test_child_record(stack["database_url"], seeded["child_id"]))
    page.get_by_role("button", name="Delete all now · 1", exact=True).click()
    dialog.get_by_role("button", name="Delete 1 file", exact=True).click()
    expect(page.get_by_text("Recycle bin is empty", exact=True)).to_be_visible()
    assert not Path(seeded["originals"][3]).exists()
    for index in (1, 2):
        assert (
            Path(seeded["originals"][index]).read_bytes()
            == (f"Original fixture content {index}\n" * 40).encode()
        )
    assert sentinel.read_bytes() == b"External original must survive all Trash actions"
    shot("empty")
    assert not errors, errors
    context.close()
