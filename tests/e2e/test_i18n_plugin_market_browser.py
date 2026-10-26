"""Marketplace browsing through a signed loopback HTTP catalog and real asset verification."""

import base64
import copy
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from tests.api import test_plugin_market as catalog

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider


@pytest.fixture(scope="module")
def market_http():
    fake = catalog.FakeGitHub()
    fake.key = Ed25519PrivateKey.generate()
    document = catalog.publish(fake)
    entry = document["plugins"][0]
    entry.update(
        name="Fixture plugin", summary="Fixture integration", description="Fixture details"
    )
    entry["downloads"] = 12800
    entry["versions"] = [value for value in entry["versions"] if value["version"] != "1.5.0"]
    for version in entry["versions"]:
        version["notes"] = ""
        readme = b"# Fixture documentation\n\nReadme from the verified catalog.\n"
        version["readme"] = catalog._asset(version["readme"]["url"], readme)
        fake.files[version["readme"]["url"]] = readme
    other = copy.deepcopy(entry)
    other.update(id="fixture-other", name="Other fixture", category="unknown-category")
    document["plugins"].append(other)
    raw = json.dumps(document).encode()
    fake.files[catalog.INDEX_URL] = raw
    fake.files[catalog.INDEX_URL + ".sig"] = base64.b64encode(fake.key.sign(raw)) + b"\n"

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            url = unquote(self.path[1:])
            fake.requests.append(url)
            data = fake.files.get(url)
            self.send_response(200 if data is not None else 404)
            self.end_headers()
            if data is not None:
                self.wfile.write(data)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    public = base64.b64encode(
        fake.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    ).decode()
    try:
        yield f"http://127.0.0.1:{server.server_port}", {"test-1": public}, fake
    finally:
        server.shutdown()
        server.server_close()
        thread.join(5)


@pytest.fixture(scope="module")
def stack(tmp_path_factory, search_provider, market_http):  # noqa: F811
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("E2E_MARKET_UPSTREAM", market_http[0])
        patch.setenv("E2E_MARKET_KEYS", json.dumps(market_http[1]))
        yield from ai.stack.__wrapped__(tmp_path_factory, search_provider)


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_marketplace_browse_permissions_and_versions(stack, browser, market_http, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    base = stack["base"]
    reply = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not reply.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    prefs = context.request.get(base + "/api/v1/ui/preferences").json()["data"]
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    assert context.request.put(base + "/api/v1/ui/preferences", data=prefs).ok
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/plugins")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    page.get_by_role("button", name="Plugin marketplace", exact=True).click()
    expect(page.get_by_text("Signature verified", exact=True)).to_be_visible()
    expect(page.get_by_text("12.8K downloads", exact=False).first).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/plugin-market"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name, target=None):
        target = target or page.locator("main")
        assert not re.search(r"[\u3400-\u9fff]", target.inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    shot("list")
    page.get_by_placeholder("Search plugins or authors", exact=True).fill("no-match-fixture")
    expect(page.get_by_text("No matching plugins.", exact=True)).to_be_visible()
    page.get_by_placeholder("Search plugins or authors", exact=True).fill("")
    page.get_by_role("button", name="Other", exact=True).click()
    expect(page.get_by_text("Other fixture", exact=True)).to_be_visible()
    expect(page.get_by_text("Fixture plugin", exact=True)).not_to_be_visible()
    page.get_by_role("button", name="All", exact=True).click()
    page.get_by_text("Fixture plugin", exact=True).click()
    drawer = page.get_by_role("dialog", name="Fixture plugin", exact=True)
    expect(drawer.get_by_text("Readme from the verified catalog.", exact=True)).to_be_visible()
    shot("about", drawer)
    drawer.get_by_role("button", name="Permissions", exact=True).click()
    expect(drawer.get_by_text("Calls 1 host operation", exact=True)).to_be_visible()
    expect(drawer.get_by_text("app.plugins.list", exact=True)).to_be_visible()
    shot("permissions", drawer)
    drawer.get_by_role("button", name="Versions (2)", exact=True).click()
    expect(drawer.get_by_text("Prerelease", exact=True)).to_be_visible()
    expect(
        drawer.get_by_text("No release notes for this version.", exact=True).first
    ).to_be_visible()
    shot("versions", drawer)
    drawer.locator("header").get_by_role("button", name="Close", exact=True).click()
    if width == 1280:
        original_index = market_http[2].files[catalog.INDEX_URL]
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
            page.get_by_role(
                "button",
                name="Plugin marketplace" if language == "en" else "插件市场",
                exact=True,
            ).click()
            expect(
                page.get_by_text(
                    "Signature verified" if language == "en" else "签名已验证", exact=True
                )
            ).to_be_visible()
            assert page.evaluate("window.__i18nDocument") == "kept"
            assert market_http[2].files[catalog.INDEX_URL] == original_index
        shot("roundtrip")
    page.get_by_role("button", name="Check for updates", exact=True).click()
    expect(page.get_by_text("Up to date", exact=True)).to_be_visible()
    assert not errors
    assert catalog.INDEX_URL in market_http[2].requests
    assert catalog.INDEX_URL + ".sig" in market_http[2].requests
    assert any("README.md" in url for url in market_http[2].requests)
    assert (
        context.request.get(base + "/api/v1/app/plugins/packages").json()["data"]["pending"] == []
    )
    context.close()
