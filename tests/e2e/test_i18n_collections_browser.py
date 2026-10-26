"""English collections and favorites through the real Next/API/SQLite stack."""

from __future__ import annotations

import re

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_i18n_library_browse_browser import _english_interface

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_I18N_DISCOVERY", "1")
        yield from inventory.stack.__wrapped__(tmp_path_factory)


def test_collections_favorites_and_gallery_use_english(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1100})
    assert context.request.post(f"{base}/api/v1/auth/bootstrap", data=inventory.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    library_id, ids = inventory._ensure_libraries(page, stack)
    artifacts = theme.REPO / ".tmp-uidev/i18n/collections"
    artifacts.mkdir(parents=True, exist_ok=True)

    page.goto(f"{base}/library/{library_id}?g=16&c=JP")
    page.get_by_role("button", name="Save as collection", exact=True).click()
    dialog = page.get_by_role("dialog", name="Save as collection", exact=True)
    name = dialog.get_by_role("textbox", name="Name", exact=True)
    expect(name).to_have_value("Animation · Japan")
    expect(dialog.get_by_role("button", name="Close", exact=True)).to_be_visible()
    expect(dialog.get_by_text(re.compile("^.* titles match these conditions$"))).to_be_visible()
    expect(dialog.get_by_role("button", name=re.compile("^Auto-adds titles"))).to_be_visible()
    name.fill("Japanese animation")
    _english_interface(page)
    _snapshot(page, artifacts / "save-collection-en.png")
    dialog.get_by_role("button", name="Save as collection", exact=True).click()
    expect(dialog).not_to_be_visible()
    tabs = page.get_by_role("tab")
    expect(tabs.first).to_be_visible()
    assert any("Collections" in text for text in tabs.all_text_contents()), tabs.all_text_contents()
    tabs.filter(has_text="Collections").click()
    card = page.get_by_role("link").filter(has_text="Japanese animation").first
    expect(card).to_be_visible()
    expect(card).to_contain_text("Auto-adds titles")
    card.click()
    expect(page.get_by_role("heading", name="Japanese animation", exact=True)).to_be_visible()
    expect(page.get_by_text("Animation", exact=True)).to_be_visible()
    _english_interface(page)
    _snapshot(page, artifacts / "collection-rules-en.png")
    collection_url = page.url
    page.evaluate("window.collectionsLanguageMarker = 789")
    for locale, genre in (("zh-Hans", "动画"), ("en", "Animation")):
        _change_language(page, locale)
        expect(page.get_by_text(genre, exact=True)).to_be_visible()
        assert page.url == collection_url
        assert page.evaluate("window.collectionsLanguageMarker") == 789
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Edit conditions…", exact=True).click()
    expect(page.get_by_role("button", name="Save conditions", exact=True)).to_be_visible()
    page.get_by_role("button", name="Cancel", exact=True).click()

    manual = context.request.post(
        f"{base}/api/v1/collections",
        data={
            "name": "Weekend picks",
            "library_id": library_id,
            "item_ids": [ids["千与千寻"], ids["你的名字"]],
        },
    ).json()["data"]
    manual_id = manual["id"]
    page.goto(f"{base}/library/{library_id}/c/{manual_id}")
    expect(
        page.get_by_text("Fixed list · New titles are not added automatically", exact=True)
    ).to_be_visible()
    expect(page.get_by_role("button", name="Sort", exact=True)).to_contain_text("Custom order")
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Arrange order…", exact=True).click()
    expect(page.get_by_role("heading", name="Arrange order", exact=True)).to_be_visible()
    page.get_by_role("button", name="Move down", exact=True).first.click()
    _snapshot(page, artifacts / "collection-order-en.png")
    page.get_by_role("button", name="Save order", exact=True).click()
    expect(page.get_by_role("heading", name="Arrange order", exact=True)).not_to_be_visible()
    items = context.request.get(f"{base}/api/v1/collections/{manual_id}/items").json()["data"]
    assert [i["media_item_id"] for i in items] == [ids["你的名字"], ids["千与千寻"]]
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Gallery view", exact=True).click()
    tiles = page.locator("[data-gallery-tile-id]")
    expect(tiles.first).to_be_visible()
    _english_interface(page)
    tiles.first.click()
    expect(page.get_by_role("link", name="Go to title details", exact=True)).to_be_visible()
    page.keyboard.press("Escape")

    assert context.request.post(
        f"{base}/api/v1/playback/marks", data={"media_item_id": ids["千与千寻"], "favorite": True}
    ).ok
    page.goto(f"{base}/library/collections")
    expect(page.get_by_text("My favorites", exact=True)).to_be_visible()
    _english_interface(page)
    expect(page.get_by_text("Type", exact=True)).to_be_visible()
    expect(page.get_by_role("link", name="Collections", exact=True)).to_be_visible()
    _snapshot(page, artifacts / "all-collections-en.png")
    page.set_viewport_size({"width": 390, "height": 844})
    _snapshot(page, artifacts / "all-collections-mobile-en.png")
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    page.set_viewport_size({"width": 1440, "height": 1100})
    page.evaluate("window.collectionsLanguageMarker = 789")
    for locale, favorite in (("zh-Hans", "我的收藏"), ("en", "My favorites")):
        _change_language(page, locale)
        expect(page.get_by_text(favorite, exact=True)).to_be_visible()
        assert page.evaluate("window.collectionsLanguageMarker") == 789

    page.goto(f"{base}/library/favorites")
    expect(page.get_by_role("heading", name="My favorites", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Sort", exact=True)).to_contain_text(
        "Recently favorited"
    )
    _english_interface(page)
    _snapshot(page, artifacts / "favorites-en.png")
    page.get_by_role("button", name="Gallery view", exact=True).click()
    expect(page.locator("[data-gallery-tile-id]").first).to_be_visible()
    _english_interface(page)
    _snapshot(page, artifacts / "favorites-gallery-en.png")
    page.set_viewport_size({"width": 390, "height": 844})
    _snapshot(page, artifacts / "favorites-gallery-mobile-en.png")
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    page.set_viewport_size({"width": 1440, "height": 1100})
    page.goto(f"{base}/discover/movie/collections/tmdb/popular")
    expect(page.get_by_role("heading", name="Popular movies", exact=True)).to_be_visible()
    expect(page.get_by_text("Loaded 4 / 4 titles", exact=True)).to_be_visible()
    _snapshot(page, artifacts / "discovery-list-en.png")
    for locale, title in (("zh-Hans", "热门电影"), ("en", "Popular movies")):
        _change_language(page, locale)
        expect(page.get_by_role("heading", name=title, exact=True)).to_be_visible()
    assert not errors
    context.close()


def test_photo_months_lightbox_and_original_download_follow_the_language(stack, browser):
    from PIL import Image
    from playwright.sync_api import expect

    from .test_library_manage_browser import _wait_for

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1000})
    context.request.post(f"{base}/api/v1/auth/bootstrap", data=inventory.ADMIN)
    response = context.request.post(f"{base}/api/v1/auth/login", data=inventory.ADMIN)
    assert response.ok, response.text()
    page = context.new_page()
    page.on("pageerror", lambda error: print("Photo page error:", str(error)))
    page.set_default_timeout(20_000)
    photos = stack["roots"]["movies"].parent / "photos"
    photos.mkdir()
    image = Image.new("RGB", (900, 600), "#355f85")
    exif = Image.Exif()
    exif.get_ifd(34665)[36867] = "2024:05:01 12:30:00"
    image.save(photos / "Holiday.jpg", exif=exif)
    response = context.request.post(
        f"{base}/api/v1/libraries",
        data={
            "name": "Photo memories",
            "kind": "photo",
            "root_paths": [str(photos)],
            "realtime_watch": False,
        },
    )
    assert response.ok, response.text()
    library_id = response.json()["data"]["id"]
    _wait_for(
        lambda: next(
            (
                row
                for row in context.request.get(f"{base}/api/v1/libraries").json()["data"]
                if row["id"] == library_id and not row["scanning"] and row["last_scan"]
            ),
            None,
        ),
        timeout=90,
        what="photo scan",
    )
    page.goto(f"{base}/library/{library_id}")
    expect(page.get_by_role("heading", name="May 2024", exact=True)).to_be_visible()
    expect(page.get_by_text("1 image", exact=True)).to_be_visible()
    photo = page.get_by_role("button", name="View Holiday", exact=True)
    expect(photo).to_be_visible()
    photo.click()
    page.get_by_role("button", name="Photo information", exact=True).click()
    panel = page.get_by_role("region", name="Photo information", exact=True)
    expect(panel.get_by_text("Holiday.jpg", exact=True)).to_be_visible()
    expect(panel.get_by_text("Capture date", exact=True)).to_be_visible()
    expect(panel.get_by_text("2024-05-01", exact=True)).to_be_visible()
    assert not re.search(r"[\u3400-\u9fff]", panel.inner_text())
    artifacts = theme.REPO / ".tmp-uidev/i18n/collections"
    _snapshot(page, artifacts / "photo-info-en.png")
    with page.expect_download() as event:
        page.get_by_role("link", name="Download original", exact=True).click()
    assert event.value.suggested_filename == "Holiday.jpg"
    assert event.value.path().stat().st_size > 1_000
    page.set_viewport_size({"width": 390, "height": 844})
    _snapshot(page, artifacts / "photo-info-mobile-en.png")
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    page.get_by_role("button", name="Close (Esc)", exact=True).click()
    page.set_viewport_size({"width": 1440, "height": 1000})
    for locale, month in (("zh-Hans", "2024 年 5 月"), ("en", "May 2024")):
        _change_language(page, locale)
        expect(page.get_by_role("heading", name=month, exact=True)).to_be_visible()
    context.close()
