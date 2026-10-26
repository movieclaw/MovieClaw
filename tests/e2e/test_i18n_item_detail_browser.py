"""Item detail, track information and file operations with real local media."""

from __future__ import annotations

import asyncio
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_library_manage_browser import _wait_for

stack = inventory.stack
browser = theme.browser
pytestmark = pytest.mark.integration


def _prepare_media(stack, library_id, item_id):
    from sqlmodel import select

    from movieclaw_api.services.library.subtitles import discover_external_subtitles
    from movieclaw_api.services.media_probe import probe_media
    from movieclaw_db.engine import Database
    from movieclaw_db.models import Library, LibraryFile, MediaMetadata

    entry = stack["roots"]["movies"] / "Inception"
    entry.mkdir()
    clip = entry / "Inception.mp4"
    subprocess.run([
        "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=90",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=90", "-map", "0:v", "-map", "1:a",
        "-map", "1:a",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac",
        "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=jpn",
        "-movflags", "+faststart", str(clip),
    ], check=True)  # fmt: skip
    (entry / "Inception.en.srt").write_text("1\n00:00:00,000 --> 00:01:30,000\nOriginal subtitle\n")
    spec = probe_media(clip)
    assert spec and len(spec.audio_streams) == 2

    async def update():
        db = Database(stack["database_url"])
        try:
            async with db.session() as session:
                file = (
                    await session.execute(
                        select(LibraryFile).where(
                            LibraryFile.library_id == library_id,
                            LibraryFile.media_item_id == item_id,
                        )
                    )
                ).scalar_one()
                Path(file.file_path).unlink()
                file.file_path = str(clip)
                file.size_bytes = clip.stat().st_size
                for name in (
                    "video_codec",
                    "resolution",
                    "duration_seconds",
                    "bit_depth",
                    "frame_rate",
                    "color_space",
                    "audio_streams",
                    "subtitle_streams",
                ):
                    setattr(file, name, getattr(spec, name))
                file.container = "mp4"
                file.external_subtitles = discover_external_subtitles(clip)
                file.chapters = [
                    {"start_ms": 0, "end_ms": 45_000, "title": "Original chapter"},
                    {"start_ms": 45_000, "end_ms": None, "title": None},
                ]
                assets = stack["metadata_dir"] / "images"
                images = []
                for start in (0, 45_000):
                    relative = f"chapters/{item_id}/{file.id}/{start}.jpg"
                    image = assets / relative
                    image.parent.mkdir(parents=True, exist_ok=True)
                    subprocess.run(
                        [
                            "ffmpeg",
                            "-v",
                            "error",
                            "-ss",
                            str(start / 1000),
                            "-i",
                            str(clip),
                            "-frames:v",
                            "1",
                            str(image),
                        ],
                        check=True,
                    )
                    images.append({"start_ms": start, "image": relative, "frame_ms": start})
                file.chapter_images = images
                library = await session.get(Library, library_id)
                library.extract_chapter_images = True
                library.scrape_overrides = {"language_priority": ["en-US"]}
                meta = await session.get(MediaMetadata, item_id)
                meta.original_language = "en"
                await session.commit()
        finally:
            await db.dispose()

    with ThreadPoolExecutor(max_workers=1) as pool:
        pool.submit(lambda: asyncio.run(update())).result()
    return clip


def test_item_details_tracks_transfer_and_delete_use_english(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1100})
    assert context.request.post(f"{base}/api/v1/auth/bootstrap", data=inventory.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    library_id, ids = inventory._ensure_libraries(page, stack)
    item_id = ids["盗梦空间"]
    clip = _prepare_media(stack, library_id, item_id)
    artifacts = theme.REPO / ".tmp-uidev/i18n/item-detail"
    artifacts.mkdir(parents=True, exist_ok=True)
    page.goto(f"{base}/library/{library_id}/item/{item_id}")
    expect(page.get_by_role("button", name="Favorite", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Mark as watched", exact=True)).to_be_visible()
    expect(page.get_by_text("Related links", exact=True)).to_be_visible()
    expect(page.get_by_text("2 chapters", exact=True)).to_be_visible()
    _snapshot(page, artifacts / "item-en.png")
    page.get_by_role("button", name="Favorite", exact=True).click()
    expect(page.get_by_role("button", name="Unfavorite", exact=True)).to_have_attribute(
        "aria-pressed", "true"
    )
    assert context.request.get(f"{base}/api/v1/playback/marks?media_item_id={item_id}").json()[
        "data"
    ]["is_favorite"]
    page.get_by_role("button", name="Mark as watched", exact=True).click()
    expect(page.get_by_role("button", name="Mark as unwatched", exact=True)).to_have_attribute(
        "aria-pressed", "true"
    )
    audio = page.get_by_text("Audio", exact=True).locator("..")
    audio.get_by_role("button").filter(has_text="English").click()
    track_list = page.get_by_role("dialog", name="Audio list", exact=True)
    expect(
        track_list.get_by_text(
            "The track marked “Default” plays automatically: Original audio", exact=True
        )
    ).to_be_visible()
    assert not re.search(r"[\u3400-\u9fff]", track_list.inner_text())
    page.wait_for_function(
        "el => el.getBoundingClientRect().left > 300", arg=track_list.element_handle()
    )
    expect(track_list).to_have_css("opacity", "1")
    _snapshot(page, artifacts / "audio-en.png")
    page.keyboard.press("Escape")
    page.get_by_role(
        "button", name=re.compile("^View chapter image: Original chapter")
    ).first.click(position={"x": 12, "y": 12})
    expect(page.get_by_role("button", name="Play from here", exact=True)).to_be_visible()
    _snapshot(page, artifacts / "chapter-en.png")
    page.keyboard.press("Escape")
    page.evaluate("window.itemLanguageMarker = 1234")
    for locale, label in (("zh-Hans", "标记为未看"), ("en", "Mark as unwatched")):
        _change_language(page, locale)
        expect(page.get_by_role("button", name=label, exact=True)).to_be_visible()
        assert page.evaluate("window.itemLanguageMarker") == 1234
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Add to collection…", exact=True).click()
    page.get_by_placeholder("Name a new collection", exact=True).fill("Viewer picks")
    page.get_by_role("button", name="Create and add", exact=True).click()
    expect(
        page.get_by_text("Created “Viewer picks” and added “盗梦空间”", exact=True)
    ).to_be_visible()
    collections = context.request.get(f"{base}/api/v1/collections?library_id={library_id}").json()[
        "data"
    ]
    assert any(row["name"] == "Viewer picks" and row["item_count"] == 1 for row in collections)
    page.reload()
    expect(page.get_by_text("Viewer picks", exact=True).first).to_be_visible()

    target = stack["roots"]["movies"].parent / "target"
    target.mkdir()
    response = context.request.post(
        f"{base}/api/v1/libraries",
        data={
            "name": "Target library",
            "kind": "movie",
            "root_paths": [str(target)],
            "realtime_watch": False,
        },
    )
    assert response.ok, response.text()
    target_id = response.json()["data"]["id"]
    _wait_for(
        lambda: next(
            (
                r
                for r in context.request.get(f"{base}/api/v1/libraries").json()["data"]
                if r["id"] == target_id and not r["scanning"] and r["last_scan"]
            ),
            None,
        ),
        timeout=90,
        what="target library scan",
    )
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Move to another library…", exact=True).click()
    dialog = page.get_by_role("dialog", name="Move to another library", exact=True)
    dialog.get_by_role("button", name=re.compile("^Target library")).click()
    expect(dialog.get_by_text(re.compile("^1 path ·"))).to_be_visible()
    assert not re.search(
        r"[\u3400-\u9fff]", dialog.inner_text().replace("盗梦空间", "").replace("电影库", "")
    )
    _snapshot(page, artifacts / "transfer-en.png")
    dialog.get_by_role("button", name="Confirm move", exact=True).click()
    expect(dialog.get_by_text("Moved “盗梦空间” to “Target library”", exact=True)).to_be_visible()
    assert not clip.exists()
    moved = target / "Inception" / "Inception.mp4"
    assert moved.is_file() and moved.with_suffix(".en.srt").is_file()
    dialog.get_by_role("button", name="Go to target library", exact=True).click()
    page.wait_for_url(re.compile(f"/library/{target_id}/item/{item_id}$"))
    page.set_viewport_size({"width": 390, "height": 844})
    _snapshot(page, artifacts / "item-mobile-en.png")
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Delete title", exact=True).click()
    dialog = page.get_by_role("dialog", name="Delete title", exact=True)
    expect(
        dialog.get_by_text("Also delete download tasks and source files", exact=True)
    ).to_be_visible()
    assert not re.search(
        r"[\u3400-\u9fff]", dialog.inner_text().replace("盗梦空间", "").replace("电影库", "")
    )
    dialog.get_by_role("checkbox", name=re.compile("^I understand")).check()
    expect(dialog.get_by_role("button", name="Delete permanently", exact=True)).to_be_enabled()
    _snapshot(page, artifacts / "delete-mobile-en.png")
    dialog.get_by_role("button", name="Delete permanently", exact=True).click()
    expect(dialog.get_by_text("Permanently deleted from disk", exact=True)).to_be_visible()
    assert not moved.parent.exists()
    assert not errors
    context.close()


def test_episode_selection_and_watched_state_use_english(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1000})
    context.request.post(f"{base}/api/v1/auth/bootstrap", data=inventory.ADMIN)
    assert context.request.post(f"{base}/api/v1/auth/login", data=inventory.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    inventory._ensure_libraries(page, stack)
    library_id = next(
        row["id"]
        for row in context.request.get(f"{base}/api/v1/libraries").json()["data"]
        if row["name"] == "剧集库"
    )
    item_id = context.request.get(f"{base}/api/v1/libraries/{library_id}/items").json()["data"][0][
        "media_item_id"
    ]
    page.goto(f"{base}/library/{library_id}/item/{item_id}")
    expect(page.get_by_role("heading", name="Episodes", exact=True)).to_be_visible()
    expect(page.get_by_text("Season 1", exact=True)).to_be_visible()
    expect(page.get_by_text("3 / 3 episodes in library", exact=True)).to_be_visible()
    second = page.locator('button[data-episode-number="2"]')
    second.click()
    expect(second).to_have_attribute("aria-pressed", "true")
    page.get_by_role("button", name="Mark as watched", exact=True).click()
    expect(second).to_have_accessible_name(re.compile("Watched"))
    # Finishing an episode advances the resume anchor; explicitly select the watched episode again.
    second.click()
    expect(page.get_by_role("button", name="Mark as unwatched", exact=True)).to_be_visible()
    marks = context.request.get(
        f"{base}/api/v1/playback/marks",
        params={"media_item_id": item_id, "season_number": 1, "episode_number": 2},
    ).json()["data"]
    assert marks["played"] is True
    artifacts = theme.REPO / ".tmp-uidev/i18n/item-detail"
    artifacts.mkdir(parents=True, exist_ok=True)
    page.set_viewport_size({"width": 390, "height": 844})
    notice = page.get_by_role("status").filter(has_text="Connect an AI model")
    page.wait_for_function(
        """el => {
            const rect = el.getBoundingClientRect();
            return rect.right <= innerWidth && el.scrollWidth <= el.clientWidth + 1;
        }""",
        arg=notice.element_handle(),
    )
    _snapshot(page, artifacts / "episodes-mobile-en.png")
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    context.close()
