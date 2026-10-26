"""AI provider forms through real Next, API, encrypted SQLite and local model HTTP."""

import json
import re
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from tests.api import test_llm as llm

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack
model_gateway = llm.model_gateway


@pytest.fixture
def rejected_endpoint():
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            body = json.dumps(
                {
                    "error": {
                        "message": "Fixture invalid key",
                        "type": "invalid_api_key",
                        "code": "invalid_api_key",
                    }
                }
            ).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/v1"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_provider_setup_errors_and_chatgpt_pairing(
    stack,
    browser,
    model_gateway,
    rejected_endpoint,
):
    from playwright.sync_api import expect
    from tests.llm.unit.test_chatgpt import credentials

    base = stack["base"]
    context = browser.new_context(
        locale="en-US",
        viewport={"width": 1280, "height": 1000},
        permissions=["clipboard-read", "clipboard-write"],
    )
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(25000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/llm"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def english():
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        assert page.locator("main button").evaluate_all("""buttons => buttons.every(button => {
            const r = button.getBoundingClientRect();
            return r.width === 0 || (r.left >= 0 && r.right <= innerWidth + 1
                && button.scrollHeight <= button.clientHeight + 1);
        })""")

    def shot(name):
        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(node => node.click())")
        english()
        _snapshot(page, shots / name)

    def save():
        with page.expect_response(
            lambda response: (
                response.request.method in {"POST", "PUT"} and "/llm/providers" in response.url
            )
        ) as saved:
            page.get_by_role("button", name="Save and test", exact=True).click()
        assert saved.value.ok, saved.value.text()
        return saved.value.json()["data"]["id"]

    def language(value):
        width = page.viewport_size["width"]
        page.set_viewport_size({"width": 1280, "height": 1000})
        current = page.locator("html").get_attribute("lang")
        page.get_by_role(
            "button",
            name="Appearance and language" if current == "en" else "外观与语言",
            exact=True,
        ).click()
        page.get_by_test_id("language-settings").locator(f'input[value="{value}"]').check()
        expect(page.locator("html")).to_have_attribute("lang", value)
        page.get_by_role(
            "button", name="AI providers" if value == "en" else "模型接入", exact=True
        ).click()
        page.set_viewport_size({"width": width, "height": 1000})

    def stored(provider_id):
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return db.execute(
                "SELECT last_error, last_error_ref, api_key FROM llm_provider WHERE id=?",
                (provider_id,),
            ).fetchone()

    for theme_id, width in [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]:
        for provider in api("get", "/llm/providers"):
            api("delete", f"/llm/providers/{provider['id']}")
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/llm")
        expect(page.get_by_text("No AI providers connected yet", exact=True)).to_be_visible()
        shot(f"{theme_id}-{width}-empty.png")
        page.get_by_role("button", name="Connect provider", exact=True).click()
        page.get_by_label("Provider", exact=True).select_option("openai")
        page.get_by_placeholder("OpenAI", exact=True).fill("Fixture Provider")
        page.get_by_placeholder("https://api.openai.com/v1").fill(model_gateway[0])
        page.get_by_placeholder("sk-…", exact=True).fill("sk-loopback-key-1234")
        page.get_by_role("button", name="Show API key", exact=True).click()
        expect(page.get_by_role("button", name="Hide API key", exact=True)).to_be_visible()
        page.get_by_role("button", name="Hide API key", exact=True).click()
        page.get_by_role("button", name="Fetch models from endpoint", exact=True).click()
        expect(
            page.get_by_role("status").filter(has_text="The endpoint returned 2 models.")
        ).to_be_visible()
        page.get_by_label("Endpoint model list", exact=True).select_option("gpt-6-luna")
        assert page.get_by_label("Connection test model", exact=True).input_value() == "gpt-6-luna"
        page.locator("summary").click()
        page.get_by_label("API protocol", exact=True).select_option("openai_chat")
        assert page.locator('#llm-test-model option[value="gpt-6-astra"]').count() == 0
        page.get_by_label("API protocol", exact=True).select_option("openai_responses")
        page.get_by_placeholder(
            "Leave blank to use the SDK default"
        ).count()  # SDK UA is normally provided by the API.
        page.locator("details input").fill("Fixture-UA/1.0")
        page.get_by_label("Endpoint model list", exact=True).select_option("my-local-model")
        page.get_by_placeholder("131072", exact=True).fill("131072")
        page.get_by_placeholder("8192", exact=True).fill("8192")
        page.locator("select").filter(has=page.locator('option[value="effort"]')).select_option(
            "effort"
        )
        expect(
            page.get_by_text(
                "Select at least one available level for direct effort control.", exact=True
            )
        ).to_be_visible()
        assert page.get_by_role("button", name="Add to catalog", exact=True).is_disabled()
        page.get_by_label("Low", exact=True).check()
        page.get_by_label("High", exact=True).check()
        page.get_by_label("Supports turning reasoning off", exact=True).check()
        shot(f"{theme_id}-{width}-custom.png")
        page.get_by_role("button", name="Add to catalog", exact=True).click()
        page.get_by_label("Connection test model", exact=True).select_option("my-local-model")
        provider_id = save()
        expect(page.get_by_text("Connected", exact=True)).to_be_visible()
        row = next(r for r in api("get", "/llm/providers") if r["id"] == provider_id)
        assert row["name"] == "Fixture Provider" and row["default_model"] == "my-local-model"
        assert row["api_protocol"] == "openai_responses" and row["user_agent"] == "Fixture-UA/1.0"
        assert row["extra_models"][0]["thinking_control"] == {
            "kind": "effort",
            "levels": ["low", "high"],
            "supports_off": True,
            "off_body": None,
        }
        encrypted = stored(provider_id)[2]
        assert encrypted.startswith("enc::") and "sk-loopback" not in encrypted
        assert any(
            path == "/v1/responses" and payload["model"] == "my-local-model"
            for path, payload, _ in model_gateway[1]
            if payload
        )
        page.get_by_role("button", name="Edit", exact=True).click()
        page.get_by_placeholder("https://api.openai.com/v1").fill(rejected_endpoint)
        expect(
            page.get_by_text(
                "The provider or API endpoint has changed. Enter the API key again.", exact=True
            )
        ).to_be_visible()
        assert page.get_by_role("button", name="Save and test", exact=True).is_disabled()
        page.get_by_placeholder("sk-…", exact=True).fill("sk-loopback-key-1234")
        save()
        expect(page.get_by_text("Connection failed", exact=True)).to_be_visible(timeout=45000)
        expect(page.get_by_text(re.compile("Authentication failed"))).to_be_visible()
        snapshot = stored(provider_id)
        assert snapshot[1] and "认证失败" in snapshot[0]
        document = page.evaluate("window.__llmDocument = Date.now()")
        language("zh-Hans")
        expect(page.get_by_text("连接失败", exact=True)).to_be_visible()
        assert stored(provider_id) == snapshot
        language("en")
        expect(page.get_by_text(re.compile("Authentication failed"))).to_be_visible()
        assert page.evaluate("window.__llmDocument") == document
        assert stored(provider_id) == snapshot
        shot(f"{theme_id}-{width}-failed.png")
        page.get_by_role("button", name="Edit", exact=True).click()
        page.get_by_placeholder("https://api.openai.com/v1").fill(model_gateway[0])
        page.get_by_placeholder("sk-…", exact=True).fill("sk-loopback-key-1234")
        save()
        expect(page.get_by_text("Connected", exact=True)).to_be_visible()
        assert stored(provider_id)[0:2] == (None, "null")
        shot(f"{theme_id}-{width}-connected.png")
        page.get_by_role("button", name='More actions for "Fixture Provider"', exact=True).click()
        page.get_by_role("menuitem", name="Delete…", exact=True).click()
        page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
        assert len(api("get", "/llm/providers")) == 1
        page.get_by_role("button", name="Connect provider", exact=True).click()
        page.get_by_label("Provider", exact=True).select_option("chatgpt")
        pairing = page.get_by_test_id("chatgpt-plan-connect")
        expect(pairing.locator("code")).to_have_text("mclaw llm chatgpt login")
        pairing.get_by_role("button", name="Copy connection command", exact=True).click()
        assert page.evaluate("navigator.clipboard.readText()") == "mclaw llm chatgpt login"
        pairing.get_by_role("button", name="Wait for authorization", exact=True).click()
        expect(pairing.get_by_role("status")).to_have_text(
            "Waiting for authorization and model verification…"
        )
        shot(f"{theme_id}-{width}-pairing.png")
        created = api(
            "post",
            "/llm/providers",
            data={
                "name": "ChatGPT fixture",
                "provider_type": "chatgpt",
                "api_key": credentials().model_dump_json(),
                "default_model": "account-model",
                "extra_models": [
                    {"id": "account-model", "context_window": 32768, "max_output_tokens": 8192}
                ],
            },
        )
        expect(page.get_by_text("ChatGPT fixture", exact=True)).to_be_visible(timeout=30000)
        api("delete", f"/llm/providers/{created['id']}")
        assert not errors, errors
    context.close()
