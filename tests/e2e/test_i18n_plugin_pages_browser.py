"""Real plugin web consent, sidebar visibility, member grants and revocation through the UI."""

import io
import json
import re
import zipfile

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack


def package():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr(
            "movieclaw-plugin.toml",
            '[plugin]\nid="i18n-board"\ntitle="Fixture Board"\nversion="1.0.0"\n',
        )
        archive.writestr("web/index.html", "<!doctype html><title>Fixture Board</title>Sentinel")
        archive.writestr(
            "web/manifest.webmanifest",
            json.dumps({"name": "Fixture Board", "short_name": "Board", "start_url": "."}),
        )
    return stream.getvalue()


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_plugin_web_approval_and_revocation(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    reply = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not reply.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    existing = api("get", "/app/plugins/packages")["installed"]
    if any(item["id"] == "i18n-board" for item in existing):
        api("delete", "/app/plugins/packages/i18n-board")
    upload = context.request.post(
        base + "/api/v1/app/plugins/packages",
        multipart={
            "file": {"name": "board.mcplugin", "mimeType": "application/zip", "buffer": package()}
        },
    )
    assert upload.ok, upload.text()
    api(
        "post",
        "/app/plugins/packages/i18n-board/approve",
        data={"version": "1.0.0", "operations": [], "allow_web": True},
    )
    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/plugins")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    section = page.locator("section").filter(
        has=page.get_by_role("heading", name="Plugin web pages", exact=True)
    )
    expect(section.get_by_text("Fixture Board", exact=True)).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/plugin-pages"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name, target=section):
        assert not re.search(r"[\u3400-\u9fff]", target.inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def more():
        section.get_by_role("button", name="More actions for “Fixture Board”", exact=True).click()

    def row():
        return next(item for item in api("get", "/app/plugins/pages") if item["id"] == "i18n-board")

    shot("approved")
    if width == 1280:
        original = row()
        state_file = stack["data"] / "plugins" / "packages" / "state.json"
        state = state_file.read_bytes()
        page.evaluate("window.__i18nDocument = 'kept'")
        for language in ("zh-Hans", "en"):
            english = page.locator("html").get_attribute("lang") == "en"
            page.get_by_role(
                "button", name="Appearance and language" if english else "外观与语言", exact=True
            ).click()
            control = page.get_by_test_id("language-settings")
            control.locator(f'input[value="{language}"]').check()
            expect(page.locator("html")).to_have_attribute("lang", language)
            expect(control).to_be_enabled()
            page.get_by_role(
                "button", name="Plugins" if language == "en" else "插件", exact=True
            ).click()
            expect(
                page.get_by_role(
                    "heading",
                    name="Plugin web pages" if language == "en" else "插件网页",
                    exact=True,
                )
            ).to_be_visible()
            assert row() == original
            assert state_file.read_bytes() == state
            assert page.evaluate("window.__i18nDocument") == "kept"
        shot("roundtrip")
    more()
    page.get_by_role("menuitem", name="Remove from sidebar", exact=True).click()
    expect(
        section.get_by_text(
            "/apps/i18n-board · Plugin package · Administrators only · Not in the sidebar",
            exact=True,
        )
    ).to_be_visible()
    assert row()["nav"] is False
    more()
    page.get_by_role("menuitem", name="Visible to members too", exact=True).click()
    expect(section.get_by_text(re.compile("Visible to members"))).to_be_visible()
    assert row()["members"] is True
    more()
    page.get_by_role("menuitem", name="Revoke approval", exact=True).click()
    dialog = page.get_by_role("dialog", name="Revoke web pages from “Fixture Board”?", exact=True)
    shot("revoke-dialog", dialog)
    dialog.get_by_role("button", name="Cancel", exact=True).click()
    assert row()["approved"] is True
    more()
    page.get_by_role("menuitem", name="Revoke approval", exact=True).click()
    dialog.get_by_role("button", name="Revoke", exact=True).click()
    expect(section.get_by_text("Awaiting approval", exact=True)).to_be_visible()
    assert context.request.get(base + "/api/v1/plugins/i18n-board/web/").status == 404
    section.get_by_role("button", name="Approve", exact=True).click()
    dialog = page.get_by_role("dialog", name="Allow web pages from “Fixture Board”?", exact=True)
    expect(dialog.get_by_text(re.compile("full administrator access"))).to_be_visible()
    expect(page.get_by_text("Revoked", exact=True)).not_to_be_visible(timeout=15000)
    shot("approve-dialog", dialog)
    dialog.get_by_role("checkbox", name="Visible to members too").check()
    dialog.get_by_role("button", name="Approve", exact=True).click()
    expect(section.get_by_role("button", name="Open", exact=True)).to_be_visible()
    assert row()["approved"] and row()["nav"] and row()["members"]
    response = context.request.get(base + "/api/v1/plugins/i18n-board/web/")
    assert response.ok and "Sentinel" in response.text()
    shot("restored")
    assert not errors
    api("delete", "/app/plugins/packages/i18n-board")
    context.close()
