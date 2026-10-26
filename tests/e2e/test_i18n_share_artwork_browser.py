"""English share creation, anonymous playback, collections and real artwork files."""

from __future__ import annotations

import re

import pytest

from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import _wait_for
from .test_media_share_browser import _gen_clip, _no_site_entrances, _play_current_video

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_I18N_DISCOVERY", "1")
        patch.setenv("E2E_I18N_ARTWORK", "1")
        yield from inventory.stack.__wrapped__(tmp_path_factory)


def _api(context, base, method, path, **kwargs):
    response = getattr(context.request, method)(
        f"{base}/api/v1{path}", headers={"Accept-Language": "en"}, **kwargs
    )
    assert response.ok, response.text()
    return response.json()["data"]


def _media(context, stack):
    base = stack["base"]
    initialized = _api(context, base, "get", "/auth/bootstrap")["initialized"]
    _api(
        context,
        base,
        "post",
        "/auth/login" if initialized else "/auth/bootstrap",
        data=inventory.ADMIN,
    )
    libraries = _api(context, base, "get", "/libraries")
    library = next((row for row in libraries if row["name"] == "Shared media"), None)
    entry = stack["roots"]["movies"] / "某电影 (2020)"
    if library is None:
        clip = entry / "某电影.2020.mp4"
        _gen_clip(clip, 20, chapters=[(0, "Original chapter"), (8, "高潮")])
        clip.with_suffix(".en.srt").write_text(
            "1\n00:00:00,000 --> 00:00:20,000\nOriginal subtitle\n"
        )
        clip.with_suffix(".nfo").write_text(
            "<movie><title>某电影</title><year>2020</year><runtime>95</runtime>"
            "<uniqueid type='tmdb' default='true'>300</uniqueid>"
            "<director>张三</director><actor><name>李四</name></actor></movie>"
        )
        library = _api(
            context,
            base,
            "post",
            "/libraries",
            data={
                "name": "Shared media",
                "kind": "movie",
                "root_paths": [str(stack["roots"]["movies"])],
                "realtime_watch": False,
                "extract_chapter_images": True,
            },
        )
    library_id = library["id"]
    _wait_for(
        lambda: (
            (row := _api(context, base, "get", f"/libraries/{library_id}"))["last_scan"]
            and not row["scanning"]
        ),
        timeout=120,
        what="shared media scan",
    )
    rows = _api(context, base, "get", f"/libraries/{library_id}/items")
    assert len(rows) == 1
    return library_id, rows[0]["media_item_id"], entry


def test_english_shares_and_anonymous_playback(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    admin_context = browser.new_context(
        locale="en-US",
        viewport={"width": 1440, "height": 1000},
        permissions=["clipboard-read", "clipboard-write"],
    )
    library_id, item_id, _entry = _media(admin_context, stack)
    page = admin_context.new_page()
    page.set_default_timeout(25_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    artifacts = theme.REPO / ".tmp-uidev/i18n/share-artwork"
    artifacts.mkdir(parents=True, exist_ok=True)
    page.goto(f"{base}/library/{library_id}/item/{item_id}")
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Share…", exact=True).click()
    dialog = page.get_by_role("dialog", name="Share title", exact=True)
    expect(dialog.get_by_text("Share “某电影”", exact=True)).to_be_visible()
    dialog.get_by_role("radio", name="3 days", exact=True).click()
    dialog.get_by_role("checkbox", name="Password protection", exact=True).check()
    password = dialog.get_by_label("Access password", exact=True)
    password.fill("abc")
    dialog.get_by_role("button", name="Create link", exact=True).click()
    expect(dialog.get_by_text("Password must be 4–32 characters long", exact=True)).to_be_visible()
    password.fill("e2e42x")
    _snapshot(page, artifacts / "share-form-en.png")
    dialog.get_by_role("button", name="Create link", exact=True).click()
    expect(dialog.get_by_text("“某电影” is shared", exact=True)).to_be_visible()
    share = _api(admin_context, base, "get", f"/libraries/{library_id}/items/{item_id}/share")
    slug = share["slug"]
    dialog.get_by_role("button", name="Copy link and password", exact=True).click()
    copied = page.evaluate("navigator.clipboard.readText()")
    assert copied == f"“某电影” Link: {base}/s/{slug} Password: e2e42x"
    password_row = dialog.get_by_text("Password", exact=True).locator("..")
    assert password_row.evaluate("""row => {
        const label = row.querySelector('span');
        const range = document.createRange();
        range.selectNodeContents(label);
        const labelRight = range.getBoundingClientRect().right;
        const iconLeft = row.querySelector('svg').getBoundingClientRect().left;
        return labelRight <= iconLeft;
    }""")
    _snapshot(page, artifacts / "share-ready-en.png")
    page.keyboard.press("Escape")

    visitor_context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    visitor = visitor_context.new_page()
    visitor.set_default_timeout(25_000)
    visitor.on("pageerror", lambda error: errors.append(str(error)))
    visitor.goto(f"{base}/s/{slug}")
    expect(visitor.get_by_role("heading", name="Password required", exact=True)).to_be_visible()
    assert "某电影" not in visitor.locator("body").inner_text()
    _no_site_entrances(visitor)
    visitor.get_by_label("Password", exact=True).fill("wrong0")
    visitor.get_by_role("button", name="Open", exact=True).click()
    expect(visitor.get_by_text("Incorrect password. Try again.", exact=True)).to_be_visible()
    _snapshot(visitor, artifacts / "share-password-en.png")
    visitor.get_by_label("Password", exact=True).fill("e2e42x")
    visitor.get_by_role("button", name="Open", exact=True).click()
    expect(visitor.get_by_role("heading", name="某电影", exact=True)).to_be_visible()
    expect(visitor.get_by_text("Audio", exact=True)).to_be_visible()
    expect(visitor.get_by_text("Subtitles", exact=True)).to_be_visible()
    expect(visitor.get_by_text("Related links", exact=True)).to_be_visible()
    expect(visitor.get_by_text(re.compile("Link: Expires in 3 days"))).to_be_visible()
    _no_site_entrances(visitor)
    _snapshot(visitor, artifacts / "share-visitor-en.png")
    visitor.set_viewport_size({"width": 390, "height": 844})
    assert visitor.evaluate("document.documentElement.scrollWidth <= innerWidth")
    _snapshot(visitor, artifacts / "share-visitor-mobile-en.png")
    visitor.set_viewport_size({"width": 1280, "height": 1000})
    visitor.get_by_role("button", name="Play", exact=True).click()
    visitor.wait_for_url(re.compile(f"/s/{slug}/play$"))
    _play_current_video(visitor)
    assert visitor.evaluate("document.querySelector('video').currentTime") > 2
    stream = visitor.evaluate("document.querySelector('video').currentSrc")
    visitor.go_back()
    expect(visitor.get_by_role("heading", name="某电影", exact=True)).to_be_visible()

    collection = _api(
        admin_context,
        base,
        "post",
        "/collections",
        data={
            "name": "Weekend picks",
            "library_id": library_id,
            "item_ids": [item_id],
        },
    )
    collection_share = _api(
        admin_context,
        base,
        "post",
        f"/collections/{collection['id']}/share",
        data={"expires_in_days": 7, "password": None},
    )
    visitor.goto(f"{base}/s/{collection_share['slug']}")
    expect(visitor.get_by_role("heading", name="Weekend picks", exact=True)).to_be_visible()
    expect(visitor.get_by_text("1 title", exact=True)).to_be_visible()
    visitor.get_by_role("button").filter(has_text="某电影").click()
    expect(visitor.get_by_role("button", name="Back to collection", exact=True)).to_be_visible()
    visitor.get_by_role("button", name="Back to collection", exact=True).click()
    expect(visitor.get_by_role("heading", name="Weekend picks", exact=True)).to_be_visible()

    page.goto(f"{base}/library/manage?tab=shares")
    expect(page.get_by_role("link", name="某电影", exact=True)).to_be_visible()
    row = page.locator("li").filter(has=page.get_by_role("link", name="某电影", exact=True))
    expect(row.get_by_text(re.compile("Viewed [1-9]"))).to_be_visible()
    _snapshot(page, artifacts / "shares-list-en.png")
    row.get_by_role("button", name="Cancel", exact=True).click()
    confirmation = page.get_by_role("dialog", name="Revoke sharing for “某电影”?", exact=True)
    confirmation.get_by_role("button", name="Revoke share", exact=True).click()
    expect(page.get_by_role("link", name="某电影", exact=True)).to_have_count(0)
    assert visitor_context.request.get(stream).status == 404
    visitor.goto(f"{base}/s/{slug}")
    expect(
        visitor.get_by_role(
            "heading", name="This share does not exist or has been cancelled", exact=True
        )
    ).to_be_visible()
    expect(visitor).to_have_title(re.compile("^Share unavailable"))
    _snapshot(visitor, artifacts / "share-revoked-en.png")
    assert not errors
    visitor_context.close()
    admin_context.close()


def test_english_artwork_selection_changes_real_assets(stack, browser):
    from PIL import Image
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1000})
    library_id, item_id, entry = _media(context, stack)
    page = context.new_page()
    page.set_default_timeout(25_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(f"{base}/library/{library_id}/item/{item_id}")
    page.get_by_role("button", name="More actions", exact=True).click()
    page.get_by_role("menuitem", name="Change artwork…", exact=True).click()
    dialog = page.get_by_role("dialog", name="Change artwork", exact=True)
    expect(dialog.get_by_role("button", name="Backdrop", exact=True)).to_be_visible()
    candidate = dialog.locator('button:has(img[src*="i18n-red"])')
    expect(candidate).to_be_visible()
    candidate.click()
    expect(
        dialog.get_by_text(
            "Your backdrop is selected manually. Metadata refreshes will keep it.", exact=True
        )
    ).to_be_visible()
    choices = _api(
        context, base, "get", f"/libraries/{library_id}/items/{item_id}/artwork/candidates"
    )
    assert choices["backdrop_locked"] and choices["current_backdrop"] == "/i18n-red.png"
    asset = entry / "fanart.jpg"
    assert asset.is_file()
    with Image.open(asset) as image:
        red, green, blue = image.convert("RGB").getpixel((0, 0))
        assert red > 150 and red > green + 80 and red > blue + 80
    artifacts = theme.REPO / ".tmp-uidev/i18n/share-artwork"
    artifacts.mkdir(parents=True, exist_ok=True)
    _snapshot(page, artifacts / "artwork-en.png")
    dialog.get_by_role("button", name="Restore automatic selection", exact=True).click()
    expect(
        dialog.get_by_text(
            "Your backdrop is selected manually. Metadata refreshes will keep it.", exact=True
        )
    ).to_have_count(0)
    choices = _api(
        context, base, "get", f"/libraries/{library_id}/items/{item_id}/artwork/candidates"
    )
    assert not choices["backdrop_locked"]
    dialog.get_by_role("button", name="Logo", exact=True).click()
    expect(dialog.get_by_text("Japanese", exact=True)).to_be_visible()
    dialog.get_by_role("button", name=re.compile("^＋ Find more logos on Fanart.tv")).click()
    page.set_viewport_size({"width": 390, "height": 844})
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    _snapshot(page, artifacts / "artwork-mobile-en.png")
    assert not errors
    context.close()


def test_english_shared_series_episode_selection_and_playback(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    _media(context, stack)
    root = stack["roots"]["shows"]
    for episode in (1, 2):
        _gen_clip(root / "Test Show (2024)" / "Season 01" / f"Test.Show.S01E{episode:02d}.mp4", 8)
    library = _api(
        context,
        base,
        "post",
        "/libraries",
        data={
            "name": "Shared TV",
            "kind": "tv",
            "root_paths": [str(root)],
            "realtime_watch": False,
        },
    )
    library_id = library["id"]
    _wait_for(
        lambda: (
            (row := _api(context, base, "get", f"/libraries/{library_id}"))["last_scan"]
            and not row["scanning"]
        ),
        timeout=120,
        what="shared TV scan",
    )
    item = _api(context, base, "get", f"/libraries/{library_id}/items")[0]
    share = _api(
        context,
        base,
        "post",
        f"/libraries/{library_id}/items/{item['media_item_id']}/share",
        data={"expires_in_days": 1, "password": None},
    )
    visitor_context = browser.new_context(locale="en-US", viewport={"width": 390, "height": 844})
    page = visitor_context.new_page()
    page.set_default_timeout(25_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(f"{base}/s/{share['slug']}")
    expect(page.get_by_role("heading", name="测试剧集", exact=True)).to_be_visible()
    expect(page.get_by_role("heading", name="Episodes", exact=True)).to_be_visible()
    expect(
        page.locator('[data-episode-number="3"]').get_by_text("Missing", exact=True)
    ).to_be_visible()
    page.locator('[data-episode-number="2"]').click()
    expect(page.get_by_text("Season 1, episode 2 - E2", exact=True)).to_be_visible()
    artifacts = theme.REPO / ".tmp-uidev/i18n/share-artwork"
    artifacts.mkdir(parents=True, exist_ok=True)
    _snapshot(page, artifacts / "share-series-mobile-en.png")
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    page.get_by_role("button", name="Play", exact=True).click()
    page.wait_for_url(re.compile(f"/s/{share['slug']}/play/s01e02$"))
    _play_current_video(page)
    assert not errors
    visitor_context.close()
    context.close()
