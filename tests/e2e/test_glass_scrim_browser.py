"""Issue #1126: real Next/API/SQLite, computed scrims, sliders and splash lifecycle.

Run: .venv/bin/pytest -m integration tests/e2e/test_glass_scrim_browser.py
"""

import pytest

from . import test_theme_device_class_browser as theme

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_I18N_DISCOVERY", "1")
        patch.setenv("E2E_I18N_ARTWORK", "1")
        patch.setenv("E2E_SCRIM_HERO", "1")
        yield from theme.stack.__wrapped__(tmp_path_factory)


@pytest.fixture
def account(stack, browser):
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 900})
    context.set_default_timeout(60_000)
    context.set_default_navigation_timeout(60_000)
    reply = context.request.post(stack + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if reply.status == 409:
        reply = context.request.post(stack + "/api/v1/auth/login", data=theme.ADMIN)
    assert reply.ok, reply.text()
    reply = context.request.put(
        stack + "/api/v1/ui/preferences",
        data={"language": "en", "theme": "silver", "scrim": {"blur": 7, "dark": 0.42}},
    )
    assert reply.ok, reply.text()
    # A real subscription makes the subscription home render its Hero as well.
    reply = context.request.post(
        stack + "/api/v1/subscriptions",
        data={"title_ref": "tmdb:tv:200", "selected_seasons": [1]},
    )
    assert reply.ok, reply.text()
    yield context
    context.close()


def _scrim(page, blur, dark, selector=".page-scrim", *, hero=False):
    from playwright.sync_api import expect

    scrim = page.locator(selector)
    scrim.wait_for(state="attached", timeout=60_000)
    backdrop = f"blur({blur}px)" if blur else "none"
    if hero and blur:
        backdrop += " saturate(1.35)"
    expect(scrim).to_have_css("backdrop-filter", backdrop, timeout=10_000)
    expect(scrim).to_have_css("background-color", f"rgba(0, 0, 0, {dark})")


@pytest.mark.parametrize("path", ["/library", "/subscriptions", "/discover/movie", "/discover/tv"])
@pytest.mark.parametrize("blur", [0, 7])
def test_saved_scrim_preferences_on_real_pages(stack, account, path, blur):
    reply = account.request.put(
        stack + "/api/v1/ui/preferences", data={"scrim": {"blur": blur, "dark": 0.42}}
    )
    assert reply.ok, reply.text()
    page = account.new_page()
    page.goto(stack + path, wait_until="domcontentloaded")
    page.wait_for_selector(".app-shell")
    if path != "/library":
        # Wait for actual Hero content, rather than testing just a loading state.
        page.wait_for_selector('img[style*="transform: scale"]', state="attached")
        page.wait_for_function(
            "() => document.querySelector('img[style*=\"transform: scale\"]')?.naturalWidth > 0"
        )
    _scrim(page, blur, 0.42, hero=path != "/library")
    page.keyboard.press("Control+k")
    _scrim(page, blur, 0.42, ".search-palette-overlay")


@pytest.mark.parametrize("width", [1280, 390])
def test_sliders_preview_cancel_save_and_reload(stack, account, width):
    from playwright.sync_api import expect

    page = account.new_page()
    page.set_viewport_size({"width": width, "height": 900})
    page.goto(stack + "/settings/appearance?tab=texture", wait_until="domcontentloaded")
    blur = page.get_by_role("slider", name="Background blur", exact=True)
    dark = page.get_by_role("slider", name="Background dimming", exact=True)
    expect(blur).to_be_enabled(timeout=30_000)
    blur.fill("0")
    dark.fill("23")
    _scrim(page, 0, 0.23)
    # Switching tabs cancels the unsaved preview in the same Provider.
    page.get_by_role("button", name="Background", exact=True).click()
    _scrim(page, 7, 0.42)
    page.get_by_role("button", name="Interface effects", exact=True).click()
    blur.fill("0")
    dark.fill("23")
    with page.expect_response(
        lambda r: r.url.endswith("/ui/preferences") and r.request.method == "PUT"
    ) as saved:
        page.get_by_role("button", name="Save", exact=True).click()
    assert saved.value.ok, saved.value.text()
    page.reload(wait_until="domcontentloaded")
    _scrim(page, 0, 0.23)
    expect(blur).to_have_value("0")
    blur.fill("19")
    _scrim(page, 19, 0.23)


@pytest.mark.parametrize("reduced_motion", ["no-preference", "reduce"])
def test_cold_start_unmounts_faded_splash(stack, account, reduced_motion):
    from playwright.sync_api import expect

    page = account.new_page()
    page.emulate_media(reduced_motion=reduced_motion)
    page.goto(stack + "/library", wait_until="domcontentloaded")
    page.wait_for_selector(".app-shell")
    splash = page.locator('div[aria-hidden="true"][class*="z-[100]"]')
    expect(splash).to_have_count(0, timeout=5_000)
    # Library loading has its own legitimate BrandLoader; wait for the usable page.
    expect(page.get_by_role("heading", name="A home for your collection")).to_be_visible(
        timeout=30_000
    )
    assert page.evaluate("""() => !document.getAnimations().some(animation =>
        animation.animationName === 'brand-loader-breath')""")
    page.reload(wait_until="domcontentloaded")
    page.wait_for_selector(".app-shell")
    expect(splash).to_have_count(0, timeout=5_000)
