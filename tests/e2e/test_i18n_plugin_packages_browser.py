"""Upload, consent, upgrade, rollback and uninstall real packages through Next and API."""

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


def package(version=1, *, inline=False):
    identifier = "i18n-inline" if inline else "i18n-board"
    name = "Fixture inline" if inline else "Fixture Board"
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr(
            "movieclaw-plugin.toml",
            f'[plugin]\nid="{identifier}"\ntitle="{name}"\nversion="{version}.0.0"\n'
            + ('entry="inline_fixture"\nruntime="inline"\nsdk="^1.0"\n' if inline else ""),
        )
        if inline:
            archive.writestr(
                "inline_fixture/__init__.py",
                "from movieclaw_sdk import plugin\n"
                '@plugin("i18n-inline", title="Fixture inline")\n'
                "async def apply(ctx):\n    pass\n",
            )
        else:
            archive.writestr(
                "web/index.html", f"<!doctype html><title>Fixture Board</title>Sentinel v{version}"
            )
            archive.writestr(
                "web/manifest.webmanifest",
                json.dumps({"name": "Fixture Board", "short_name": "Board", "start_url": "."}),
            )
    return {"name": "fixture.mcplugin", "mimeType": "application/zip", "buffer": stream.getvalue()}


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_package_install_upgrade_rollback_and_uninstall(stack, browser, theme_id, width):  # noqa: F811
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

    for item in api("get", "/app/plugins/packages")["installed"]:
        api("delete", f"/app/plugins/packages/{item['id']}")
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
        has=page.get_by_role("heading", name="Third-party plugins", exact=True)
    )
    expect(section.get_by_text("No third-party plugins installed yet.", exact=True)).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/plugin-packages"
    shots.mkdir(parents=True, exist_ok=True)
    guard = stack["root"] / f"{theme_id}-{width}-outside-plugin.txt"
    guard.write_bytes(b"original file outside plugin")

    def shot(name, target):
        expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
        assert not re.search(r"[\u3400-\u9fff]", target.inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        for button in target.locator("footer button").all():
            box = button.bounding_box()
            assert box and box["x"] >= 0 and box["x"] + box["width"] <= width
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def upload(content, title):
        page.locator('input[type="file"]').set_input_files(content)
        drawer = page.get_by_role("dialog", name=title, exact=True)
        expect(drawer).to_be_visible()
        return drawer

    def approve(drawer, identifier):
        with page.expect_response(
            lambda response: (
                response.request.method == "POST"
                and response.url.endswith(f"/api/v1/app/plugins/packages/{identifier}/approve")
            )
        ) as mutation:
            drawer.get_by_role("button", name="Approve and install", exact=True).click()
        assert mutation.value.ok
        expect(drawer).not_to_be_visible()

    drawer = upload(package(), "Install “Fixture Board” v1.0.0")
    expect(drawer.get_by_role("button", name="Approve and install", exact=True)).to_be_disabled()
    shot("web-before-consent", drawer)
    drawer.get_by_role("button", name="Cancel", exact=True).click()
    assert api("get", "/app/plugins/packages")["installed"] == []
    section.get_by_role("button", name="Review and approve", exact=True).click()
    drawer.get_by_role("checkbox", name="I trust this plugin’s web pages", exact=True).check()
    drawer.get_by_role("checkbox", name="Visible to members too", exact=True).check()
    approve(drawer, "i18n-board")
    expect(section.get_by_text("1 installed plugin", exact=True)).to_be_visible()
    assert "Sentinel v1" in context.request.get(base + "/api/v1/plugins/i18n-board/web/").text()
    drawer = upload(package(2), "Upgrade “Fixture Board” to v2.0.0")
    expect(
        drawer.get_by_role("checkbox", name="Visible to members too", exact=True)
    ).to_be_checked()
    expect(
        drawer.get_by_role("checkbox", name="I trust this plugin’s web pages", exact=True)
    ).not_to_be_checked()
    drawer.get_by_role("checkbox", name="I trust this plugin’s web pages", exact=True).check()
    shot("upgrade", drawer)
    approve(drawer, "i18n-board")
    expect(section.get_by_text(re.compile("v2.0.0"))).to_be_visible()
    section.get_by_role("button", name="More actions for “Fixture Board”", exact=True).click()
    page.get_by_role("menuitem", name="Switch back to v1.0.0", exact=True).click()
    confirm = page.get_by_role("dialog", name="Switch “Fixture Board” back to v1.0.0?", exact=True)
    shot("rollback", confirm)
    confirm.get_by_role("button", name="Switch to previous version", exact=True).click()
    expect(section.get_by_text(re.compile("v1.0.0"))).to_be_visible()
    assert "Sentinel v1" in context.request.get(base + "/api/v1/plugins/i18n-board/web/").text()
    section.get_by_role("button", name="More actions for “Fixture Board”", exact=True).click()
    page.get_by_role("menuitem", name="Uninstall", exact=True).click()
    confirm = page.get_by_role("dialog", name="Uninstall “Fixture Board”?", exact=True)
    shot("uninstall", confirm)
    confirm.get_by_role("button", name="Cancel", exact=True).click()
    assert api("get", "/app/plugins/packages")["installed"][0]["id"] == "i18n-board"
    section.get_by_role("button", name="More actions for “Fixture Board”", exact=True).click()
    page.get_by_role("menuitem", name="Uninstall", exact=True).click()
    confirm.get_by_role("button", name="Uninstall", exact=True).click()
    expect(section.get_by_text("No third-party plugins installed yet.", exact=True)).to_be_visible()
    assert context.request.get(base + "/api/v1/plugins/i18n-board/web/").status == 404
    assert guard.read_bytes() == b"original file outside plugin"
    drawer = upload(package(inline=True), "Install “Fixture inline” v1.0.0")
    expect(drawer.get_by_role("button", name="Approve and install", exact=True)).to_be_disabled()
    drawer.get_by_role(
        "checkbox",
        name="I trust this plugin and allow it to run in the application process",
        exact=True,
    ).check()
    shot("inline-consent", drawer)
    approve(drawer, "i18n-inline")
    expect(section.get_by_text("1 installed plugin", exact=True)).to_be_visible()
    item = api("get", "/app/plugins/packages")["installed"][0]
    assert item["id"] == "i18n-inline" and item["runtime"] == "inline" and item["state"] == "active"
    api("delete", "/app/plugins/packages/i18n-inline")
    assert not errors
    context.close()
