"""AI defaults and web search through real Next/API/SQLite and loopback HTTP providers."""

import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from tests.api.test_llm import model_gateway  # noqa: F401

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO, WEB, _free_port, _wait_http

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def search_provider():
    class Handler(BaseHTTPRequestHandler):
        requests = []

        def reply(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            key = (
                self.headers.get("Authorization")
                or self.headers.get("x-api-key")
                or self.headers.get("X-Subscription-Token", "")
            )
            self.requests.append((self.path, key, body))
            status = 401 if "bad-key" in key else 429 if "rate-key" in key else 200
            data = (
                {"error": "invalid key" if status == 401 else "rate limited"}
                if status != 200
                else {
                    "results": [
                        {
                            "title": "Fixture sample",
                            "url": "https://example.com/sample",
                            "content": "Fixture summary",
                            "text": "Fixture summary",
                        }
                    ],
                    "web": {
                        "results": [
                            {
                                "title": "Fixture sample",
                                "url": "https://example.com/sample",
                                "description": "Fixture summary",
                            }
                        ]
                    },
                }
            )
            encoded = json.dumps(data).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        do_GET = reply
        do_POST = reply

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", Handler
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


@pytest.fixture(scope="module")
def stack(tmp_path_factory, search_provider):
    from movieclaw_api.core.config import Settings

    root = tmp_path_factory.mktemp("ai-settings-browser")
    data = root / "data"
    data.mkdir()
    paths = {
        "data_dir": ".",
        "metadata_dir": "metadata",
        "people_images_dir": "metadata/people",
        "image_cache_dir": "cache/images",
        "trickplay_cache_dir": "cache/playback-trickplay",
        "playback_subs_cache_dir": "cache/playback-subs",
        "reels_cache_dir": "cache/reels",
        "reels_clips_dir": "cache/reels-clips",
        "offline_exports_dir": "cache/offline-exports",
        "playback_cues_cache_dir": "cache/playback_cues",
        "audio_fingerprint_dir": "cache/audio-fingerprints",
        "subtitle_gen_cache_dir": "cache/subtitle_gen",
        "transcode_dir": "transcodes",
        "log_dir": "logs",
        "media_dir": "uploads",
        "secret_key_file": ".secret_key",
        "site_configs_dir": "site-configs",
        "agent_workspace_dir": "agent-workspace",
        "agent_sessions_dir": "agent-sessions",
        "agent_skills_dir": "agent-skills",
        "updates_dir": "updates",
        "web_port_file": "config/web-port",
    }
    env = {
        **os.environ,
        **{Settings.model_fields[key].alias: str(data / value) for key, value in paths.items()},
        "DATABASE_URL": f"sqlite+aiosqlite:///{data / 'movieclaw.db'}",
        "SCHEDULER_ENABLED": "false",
        "E2E_SEARCH_UPSTREAM": search_provider[0],
        "PYTHONPATH": f"{REPO / 'src'}:{REPO}",
    }
    api_port, web_port = _free_port(), _free_port()
    logs = [(root / name).open("w") for name in ("api.log", "web.log")]
    api = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "tests.e2e._ai_settings_api_launcher:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(api_port),
        ],
        cwd=REPO,
        env=env,
        stdout=logs[0],
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    web = subprocess.Popen(
        ["pnpm", "exec", "next", "dev", "--port", str(web_port)],
        cwd=WEB,
        env={
            **env,
            "MOVIECLAW_API_PROXY_TARGET": f"http://127.0.0.1:{api_port}",
            "NEXT_DIST_DIR": ".next-ai-settings-e2e",
        },
        stdout=logs[1],
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        _wait_http(f"http://127.0.0.1:{api_port}/api/v1/auth/bootstrap", 60)
        base = f"http://127.0.0.1:{web_port}"
        _wait_http(base + "/login", 120)
        yield {
            "base": base,
            "api_base": f"http://127.0.0.1:{api_port}",
            "root": root,
            "data": data,
            "database_url": env["DATABASE_URL"],
        }
    finally:
        for process in (web, api):
            if process.poll() is None:
                with suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
        for process in (web, api):
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        for log in logs:
            log.close()


def test_ai_defaults_and_search_configuration(stack, browser, search_provider, model_gateway):  # noqa: F811
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/ai-settings"
    shots.mkdir(parents=True, exist_ok=True)
    model = {
        "id": "fixture-model",
        "context_window": 32768,
        "max_output_tokens": 8192,
        "supports_tools": True,
        "supports_thinking": True,
        "thinking_control": {"kind": "effort", "levels": ["low", "high"], "supports_off": True},
    }
    slash_model = {"id": "org/model", "context_window": 32768, "max_output_tokens": 8192}

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def stored_search():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as connection:
            return connection.execute(
                "SELECT value_json FROM app_setting WHERE namespace=?", ("agent.web_search",)
            ).fetchone()[0]

    def shot(path):
        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(node => node.click())")
        _snapshot(page, path)

    def select_default(control, value):
        with page.expect_response(
            lambda response: (
                response.request.method == "PUT" and response.url.endswith("/api/v1/llm/defaults")
            )
        ) as saved:
            control.select_option(value)
        assert saved.value.ok, saved.value.text()

    def english():
        assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")

    def language(value):
        viewport = page.viewport_size
        page.set_viewport_size({"width": 1280, "height": 1000})
        english = page.locator("html").get_attribute("lang") == "en"
        page.get_by_role(
            "button", name="Appearance and language" if english else "外观与语言", exact=True
        ).click()
        page.get_by_test_id("language-settings").locator(f'input[value="{value}"]').check()
        expect(page.locator("html")).to_have_attribute("lang", value)
        page.get_by_role(
            "button", name="AI 设定" if value == "zh-Hans" else "AI preferences", exact=True
        ).click()
        page.set_viewport_size(viewport)

    def search_menu(action):
        page.get_by_role("button", name="More web search actions", exact=True).click()
        page.get_by_role("menuitem", name=action, exact=True).click()

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        for provider in api("get", "/llm/providers"):
            assert api("delete", f"/llm/providers/{provider['id']}") == {"remote_revoked": True}
        api("delete", "/llm/web-search")
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/ai")
        expect(page.get_by_text("No models available yet", exact=True)).to_be_visible()
        expect(
            page.get_by_role("link", name="Connect an AI provider", exact=True)
        ).to_have_attribute("href", "/settings/llm")
        english()
        for name, models in (("Fixture A", [model, slash_model]), ("Fixture B", [model])):
            api(
                "post",
                "/llm/providers",
                data={
                    "name": name,
                    "provider_type": "openai_compat",
                    "base_url": model_gateway[0],
                    "api_key": "sk-local-fixture-key-1234",
                    "default_model": "fixture-model",
                    "extra_models": models,
                },
            )
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            providers = api("get", "/llm/providers")
            if all(provider["status"] == "active" for provider in providers):
                break
            time.sleep(0.1)
        assert all(provider["status"] == "active" for provider in providers), providers
        options = api("get", "/llm/models", headers={"Accept-Language": "en"})
        assert {option["label"] for option in options} == {
            "fixture-model (Fixture A)",
            "fixture-model (Fixture B)",
            "org/model",
        }
        assert any(option["ref"] == "Fixture A/org/model" for option in options)
        reader = browser.new_context(locale="zh-CN")
        try:
            assert reader.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
            response = reader.request.get(
                base + "/api/v1/llm/models", headers={"Accept-Language": "zh-Hans"}
            )
            assert response.ok and response.headers["content-language"] == "zh-Hans"
            raw = response.json()["data"]
        finally:
            reader.close()
        assert [option["ref"] for option in raw] == [option["ref"] for option in options]
        assert any(option["label"] == "fixture-model（Fixture A）" for option in raw)
        page.reload()
        agent = page.get_by_role("combobox", name="Default agent model", exact=True)
        subtitle = page.get_by_role("combobox", name="Default subtitle model", exact=True)
        expect(agent).to_have_value("Fixture A/fixture-model")
        select_default(agent, "Fixture B/fixture-model")
        expect(page.locator(".toast-item").last).to_contain_text("AI preferences saved")
        select_default(subtitle, "Fixture A/org/model")
        expect(subtitle).to_have_value("Fixture A/org/model")
        assert api("get", "/llm/defaults")["subtitle_model"] == "Fixture A/org/model"
        english()
        shot(shots / f"{theme_id}-{width}-defaults-en.png")

        assert context.request.post(base + "/api/v1/__lab/ai/stale-defaults").ok
        page.reload()
        expect(
            page.get_by_text(re.compile('The previous selection "retired-agent-model"'))
        ).to_be_visible()
        english()
        shot(shots / f"{theme_id}-{width}-stale-en.png")
        select_default(agent, "Fixture B/fixture-model")
        expect(page.locator(".toast-item").last).to_contain_text("AI preferences saved")
        saved = api("get", "/llm/defaults")
        assert saved["agent_model"] == "Fixture B/fixture-model"
        assert saved["subtitle_model"] == "Fixture A/fixture-model"

        page.get_by_role("button", name="Connect", exact=True).click()
        dialog = page.get_by_role("dialog", name="Connect web search", exact=True)
        expect(dialog.get_by_role("button", name="Verify and save", exact=True)).to_be_disabled()
        expect(
            dialog.get_by_role("radio", name=re.compile("^Tavily Search designed for AI agents"))
        ).to_be_visible()
        key = dialog.get_by_label("API Key", exact=True)
        key.fill("tavily-fixture-key-1234")
        dialog.get_by_role("button", name="Show API key", exact=True).click()
        expect(key).to_have_attribute("type", "text")
        dialog.get_by_role("button", name="Hide API key", exact=True).click()
        expect(key).to_have_attribute("type", "password")
        english()
        if width == 320:
            hint = dialog.locator("form p").filter(
                has_text="A search request tests the key before saving"
            )
            assert hint.bounding_box()["width"] >= 220
            assert dialog.locator("footer").bounding_box()["height"] <= 100
        shot(shots / f"{theme_id}-{width}-search-editor-en.png")
        before = len(search_provider[1].requests)
        dialog.get_by_role("button", name="Verify and save", exact=True).click()
        expect(dialog).to_have_count(0)
        assert len(search_provider[1].requests) == before + 1
        assert api("get", "/llm/web-search")["key_hint"] == "1234"
        expect(page.get_by_text("Key ending in 1234", exact=True)).to_be_visible()
        encrypted = stored_search()
        assert json.loads(encrypted)["api_key"].startswith("enc::")
        assert "tavily-fixture-key-1234" not in encrypted
        page.get_by_role("button", name="Edit", exact=True).click()
        dialog = page.get_by_role("dialog", name="Edit web search", exact=True)
        key = dialog.get_by_label("API Key", exact=True)
        assert key.input_value() == ""
        dialog.get_by_role("radio", name=re.compile("^Exa Semantic search")).click()
        expect(
            dialog.get_by_text("A different search provider needs its own key.", exact=True)
        ).to_be_visible()
        key.fill("bad-key-fixture-4321")
        before = len(search_provider[1].requests)
        dialog.get_by_role("button", name="Verify and save", exact=True).click()
        expect(
            dialog.get_by_text(
                "The API key is invalid or lacks permission. Check it and paste it again.",
                exact=True,
            )
        ).to_be_visible()
        assert len(search_provider[1].requests) == before + 1
        assert api("get", "/llm/web-search")["provider"] == "tavily"
        key.fill("rate-key-fixture-4321")
        before = len(search_provider[1].requests)
        dialog.get_by_role("button", name="Verify and save", exact=True).click()
        expect(
            dialog.get_by_text(re.compile("The search service reached its rate or quota limit"))
        ).to_be_visible()
        assert len(search_provider[1].requests) == before + 2
        assert api("get", "/llm/web-search")["key_hint"] == "1234"
        assert stored_search() == encrypted
        english()
        shot(shots / f"{theme_id}-{width}-search-failed-en.png")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        search_menu("Retest connection")
        expect(page.locator(".toast-item").last).to_contain_text(
            "Connected successfully. Sample result: Fixture sample"
        )
        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(node => node.click())")
        page.evaluate("window.__aiLanguageMarker = 'same-document'")
        language("zh-Hans")
        expect(page.get_by_text("密钥末四位 1234", exact=True)).to_be_visible()
        language("en")
        expect(page.get_by_text("Key ending in 1234", exact=True)).to_be_visible()
        assert page.evaluate("window.__aiLanguageMarker") == "same-document"
        assert api("get", "/llm/web-search")["key_hint"] == "1234"
        english()
        search_menu("Disable web search")
        expect(page.get_by_role("dialog")).to_contain_text(
            "The saved API key will be removed from this server"
        )
        page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
        assert api("get", "/llm/web-search")["configured"]
        search_menu("Disable web search")
        page.get_by_role("dialog").get_by_role("button", name="Disable", exact=True).click()
        expect(page.get_by_role("button", name="Connect", exact=True)).to_be_visible()
        assert not api("get", "/llm/web-search")["configured"]
        assert json.loads(stored_search())["api_key"] == ""
    assert any(
        path == "/v1/chat/completions" and payload["model"] == "fixture-model"
        for path, payload, _ in model_gateway[1]
    )
    assert not errors, errors
    context.close()


def test_provider_deletion_uses_revocation_facts(stack, browser):
    from playwright.sync_api import expect
    from tests.llm.unit.test_chatgpt import credentials

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    for confirmed in (True, False):
        assert context.request.post(
            base + f"/api/v1/__lab/ai/revocation/{str(confirmed).lower()}"
        ).ok
        created = context.request.post(
            base + "/api/v1/llm/providers",
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
        assert created.ok, created.text()
        provider_id = created.json()["data"]["id"]
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            rows = context.request.get(base + "/api/v1/llm/providers").json()["data"]
            row = next(value for value in rows if value["id"] == provider_id)
            if row["status"] == "active":
                break
            time.sleep(0.1)
        assert row["status"] == "active", row
        page.goto(base + "/settings/llm")
        page.get_by_role("button", name='More actions for "ChatGPT fixture"', exact=True).click()
        page.get_by_role("menuitem", name="Delete…", exact=True).click()
        with page.expect_response(
            lambda response, target=provider_id: (
                response.request.method == "DELETE"
                and response.url.endswith(f"/llm/providers/{target}")
            )
        ) as deleted:
            page.get_by_role("dialog").get_by_role("button", name="Delete", exact=True).click()
        assert deleted.value.ok
        result = deleted.value.json()
        assert result["data"] == {"remote_revoked": confirmed}
        expect(page.get_by_text("ChatGPT fixture", exact=True)).to_have_count(0)
        if confirmed:
            assert result["message"] == "Deleted"
            expect(page.get_by_role("dialog")).to_have_count(0)
        else:
            dialog = page.get_by_role("dialog")
            expect(dialog).to_contain_text("ChatGPT connection removed")
            expect(dialog).to_contain_text("Remote revocation is unconfirmed")
            dialog.get_by_role("button", name="Got it", exact=True).click()
        rows = context.request.get(base + "/api/v1/llm/providers").json()["data"]
        assert all(value["id"] != provider_id for value in rows)
    context.close()
