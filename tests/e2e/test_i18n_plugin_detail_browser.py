"""Real SDK configuration, callback URL rotation/revocation and plugin lifecycle through the UI."""

import io
import re
import zipfile
from urllib.parse import urlsplit

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack

SOURCE = """
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from movieclaw_sdk import plugin
from movieclaw_sdk.callbacks import PLUGIN_CALLBACKS, CallbackResponse
from movieclaw_sdk.events import PLUGIN_EVENTS, plugin_event

class Updated(BaseModel):
    model_config = ConfigDict(frozen=True)
    value: int = 1

UPDATED = plugin_event("i18n-config.updated", Updated, title="Fixture update")

class Config(BaseModel):
    interval: int = Field(30, ge=5, le=3600, title="Interval")
    token: SecretStr | None = Field(None, title="Access token")

@plugin(
    "i18n-config", title="Fixture config", config=Config, inject=(PLUGIN_CALLBACKS, PLUGIN_EVENTS)
)
async def apply(ctx):
    await ctx.use(PLUGIN_EVENTS).register(ctx, UPDATED)
    callbacks = ctx.use(PLUGIN_CALLBACKS)
    async def notify(request):
        return CallbackResponse.text(f"fixture-{ctx.config.interval}")
    callbacks.endpoint(ctx, "notify", notify)
    if not await callbacks.keys(ctx, "notify"):
        await callbacks.issue(ctx, "notify")
"""


def package():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr(
            "movieclaw-plugin.toml",
            '[plugin]\nid="i18n-config"\ntitle="Fixture config"\nversion="1.0.0"\n'
            'description="Fixture config description"\nentry="config_fixture"\n'
            'runtime="inline"\nsdk="^1.0"\n[permissions]\ncallbacks=["notify"]\n'
            '[[events]]\nname="i18n-config.updated"\ntitle="Fixture update"\n',
        )
        archive.writestr("config_fixture/__init__.py", SOURCE)
    return stream.getvalue()


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_plugin_settings_callbacks_and_lifecycle(stack, browser, theme_id, width):  # noqa: F811
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

    for value in api("get", "/app/plugins/packages")["installed"]:
        api("delete", f"/app/plugins/packages/{value['id']}")
    uploaded = context.request.post(
        base + "/api/v1/app/plugins/packages",
        multipart={
            "file": {"name": "fixture.mcplugin", "mimeType": "application/zip", "buffer": package()}
        },
    )
    assert uploaded.ok, uploaded.text()
    installed = api(
        "post",
        "/app/plugins/packages/i18n-config/approve",
        data={"version": "1.0.0", "operations": [], "allow_inline": True},
    )
    assert installed["status"] == "active", installed
    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/plugins/i18n-config")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_label("Interval", exact=True)).to_be_visible()
    expect(page.get_by_text("Publishes “Fixture update”", exact=True)).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/plugin-detail"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name, target=None):
        expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
        target = target or page.locator("main")
        assert not re.search(r"[\u3400-\u9fff]", target.inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    shot("initial")
    page.get_by_label("Interval", exact=True).fill("45")
    page.get_by_label("Access token", exact=True).fill("Fixture-secret-2026")
    with page.expect_response(
        lambda response: (
            response.request.method == "PUT" and response.url.endswith("/i18n-config/settings")
        )
    ) as saved:
        page.get_by_role("button", name="Save", exact=True).click()
    assert saved.value.ok, saved.value.text()
    values = api("get", "/app/plugins/i18n-config/settings")
    assert values["values"]["interval"] == 45 and values["secrets_set"] == ["token"]
    assert "Fixture-secret-2026" not in str(values)
    shot("saved")
    if width == 1280:
        before_callback = api("get", "/app/plugins/i18n-config")["callbacks"]
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
            page.get_by_text("Fixture config", exact=True).click()
            expect(page.get_by_label("Interval", exact=True)).to_have_value("45")
            current = api("get", "/app/plugins/i18n-config/settings")
            assert current["values"] == values["values"]
            assert current["secrets_set"] == values["secrets_set"]
            assert api("get", "/app/plugins/i18n-config")["callbacks"] == before_callback
            assert page.evaluate("window.__i18nDocument") == "kept"
        shot("roundtrip")
    page.get_by_text("Diagnostics", exact=True).click()
    expect(page.get_by_text("Circuit closed", exact=False)).to_be_visible()
    page.locator("details").evaluate("element => element.scrollIntoView({block: 'center'})")
    shot("diagnostics")
    page.get_by_role("button", name="Callback URL actions", exact=True).click()
    page.get_by_role("menuitem", name="Replace URL", exact=True).click()
    confirm = page.get_by_role("dialog", name="Replace this callback URL?", exact=True)
    shot("rotate", confirm)
    with page.expect_response(
        lambda response: (
            response.request.method == "POST"
            and "/callbacks/" in response.url
            and response.url.endswith("/rotate")
        )
    ) as rotated:
        confirm.get_by_role("button", name="Replace URL", exact=True).click()
    assert rotated.value.ok
    url = rotated.value.json()["data"]["url"]
    path = urlsplit(url).path
    callback = context.request.post(base + path)
    assert callback.ok and callback.text() == "fixture-45"
    shot("fresh-url")
    page.get_by_role("button", name="Callback URL actions", exact=True).click()
    page.get_by_role("menuitem", name="Revoke", exact=True).click()
    confirm = page.get_by_role("dialog", name="Revoke this callback URL?", exact=True)
    confirm.get_by_role("button", name="Revoke", exact=True).click()
    expect(page.get_by_text("Revoked", exact=True)).to_be_visible()
    assert not context.request.post(base + path).ok
    page.get_by_role("button", name="Disable", exact=True).click()
    confirm = page.get_by_role("dialog", name="Disable “Fixture config”?", exact=True)
    shot("disable", confirm)
    confirm.get_by_role("button", name="Disable", exact=True).click()
    expect(page.get_by_role("button", name="Enable", exact=True)).to_be_visible()
    assert api("get", "/app/plugins/i18n-config")["plugin"]["state"] == "disabled"
    page.get_by_role("button", name="Enable", exact=True).click()
    expect(page.get_by_role("button", name="Disable", exact=True)).to_be_visible()
    assert api("get", "/app/plugins/i18n-config")["plugin"]["state"] == "active"
    assert api("get", "/app/plugins/i18n-config/settings")["values"]["interval"] == 45
    page.get_by_role("button", name="Uninstall", exact=True).click()
    confirm = page.get_by_role("dialog", name="Uninstall “Fixture config”?", exact=True)
    shot("uninstall", confirm)
    confirm.get_by_role("button", name="Cancel", exact=True).click()
    assert api("get", "/app/plugins/packages")["installed"][0]["id"] == "i18n-config"
    page.get_by_role("button", name="Uninstall", exact=True).click()
    confirm.get_by_role("button", name="Uninstall", exact=True).click()
    expect(page.get_by_role("heading", name="Plugins", exact=True)).to_be_visible()
    assert api("get", "/app/plugins/packages")["installed"] == []
    assert not errors
    context.close()
