"""Owned IM drivers and real binding/push flows through loopback HTTP, Next and SQLite."""

import json
import re
import sqlite3
import threading
import time
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider


@pytest.fixture(scope="module")
def im_http():
    class Handler(BaseHTTPRequestHandler):
        mode = "wait"
        qr_count = 0
        updates = []
        sent = []

        def reply(self):
            cls = type(self)
            path = urlsplit(self.path)
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            body = json.loads(raw) if raw else {}
            if path.path.endswith("get_bot_qrcode"):
                cls.qr_count += 1
                result = {
                    "qrcode": f"qr-{cls.qr_count}",
                    "qrcode_img_content": f"https://qr.invalid/{cls.qr_count}",
                }
            elif path.path.endswith("get_qrcode_status"):
                code = parse_qs(path.query).get("verify_code", [""])[0]
                result = {"status": cls.mode}
                if code == "73":
                    result = {
                        "status": "confirmed",
                        "ilink_bot_id": "wechat-fixture",
                        "bot_token": "fixture-wechat-secret",
                        "ilink_user_id": "fixture-user",
                        "baseurl": f"http://127.0.0.1:{self.server.server_port}/weixin",
                    }
            elif path.path.endswith("getupdates"):
                time.sleep(0.2)
                result = {"ret": 0, "msgs": [], "get_updates_buf": "fixture-cursor"}
            elif path.path.endswith("getMe"):
                result = {"ok": True, "result": {"id": 1234, "username": "fixture_bot"}}
            elif path.path.endswith("getUpdates"):
                time.sleep(0.2)
                updates, cls.updates = cls.updates, []
                result = {"ok": True, "result": updates}
            elif path.path.endswith("sendMessage"):
                cls.sent.append(("telegram", body["text"]))
                result = {"ok": True, "result": {"message_id": len(cls.sent)}}
            elif path.path.endswith("sendmessage"):
                cls.sent.append(("weixin", body["msg"]["item_list"][0]["text_item"]["text"]))
                result = {"ret": 0}
            elif path.path.startswith("/feishu/"):
                cls.sent.append(("feishu", body["content"]["text"]))
                result = {"code": 0, "msg": "success"}
            else:
                result = {"ret": 0, "ok": True, "result": True}
            encoded = json.dumps(result).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            with suppress(BrokenPipeError, ConnectionResetError):
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
        server.server_close()
        thread.join(5)


@pytest.fixture(scope="module")
def stack(tmp_path_factory, search_provider, im_http):  # noqa: F811
    yield from ai.stack.__wrapped__(tmp_path_factory, search_provider)


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_owned_im_binding_pairing_push_and_unlink(stack, browser, im_http, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    upstream, gateway = im_http
    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    response = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not response.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        reply = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert reply.ok, reply.text()
        return reply.json()["data"]

    for row in api("get", "/channels")["accounts"]:
        api("delete", f"/channels/{row['channel_id']}/accounts/{row['account_id']}")
    gateway.mode, gateway.updates = "wait", []
    gateway.sent.clear()
    assert context.request.post(base + "/api/v1/__lab/im/upstream", data={"url": upstream}).ok
    if not api("get", "/llm/providers"):
        api(
            "post",
            "/llm/providers",
            data={
                "name": "Fixture AI",
                "provider_type": "openai_compat",
                "base_url": upstream + "/v1",
                "api_key": "fixture-ai-key",
                "default_model": "fixture-model",
                "extra_models": [
                    {"id": "fixture-model", "context_window": 32768, "max_output_tokens": 8192}
                ],
            },
        )
    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    page = context.new_page()
    page.set_default_timeout(30000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/im-push")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    shots = REPO / ".tmp-uidev/i18n/im-channels"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(name, *, allow_source=False):
        expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
        if not allow_source:
            assert not re.search(r"[\u3400-\u9fff]", page.locator("main").inner_text())
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-{name}.png")

    def add(name):
        page.get_by_role("button", name="Add channel", exact=True).click()
        expect(page.get_by_role("menu")).to_have_css("opacity", "1")
        assert not re.search(r"[\u3400-\u9fff]", page.get_by_role("menu").inner_text())
        shot("add-menu")
        page.get_by_role("menuitem", name=re.compile("^Add " + name + " channel")).click()
        return page.get_by_role("dialog")

    expect(page.get_by_text("No linked channels yet", exact=True)).to_be_visible()
    shot("empty")
    dialog = add("Telegram")
    dialog.get_by_label("Bot Token", exact=False).fill("bad")
    dialog.get_by_role("button", name="Get pairing code", exact=True).click()
    expect(dialog.get_by_text("Enter the bot token", exact=True)).to_be_visible()
    shot("validation")
    dialog.get_by_label("Bot Token", exact=False).fill("fixture-token-123")
    dialog.get_by_role("button", name="Get pairing code", exact=True).click()
    expect(dialog.get_by_text("Valid for 10 minutes.", exact=False)).to_be_visible()
    pair = dialog.locator("p.select-all").inner_text().strip()
    assert re.fullmatch(r"\d{6}", pair)
    assert api("get", "/channels")["accounts"] == []
    shot("pairing")
    gateway.updates = [
        {
            "update_id": 101,
            "message": {
                "message_id": 101,
                "chat": {"id": 42, "type": "private"},
                "from": {"id": 42},
                "text": pair,
            },
        }
    ]
    expect(page.get_by_role("dialog")).to_have_count(0)
    expect(page.get_by_text("Running", exact=True)).to_be_visible()
    shot("linked")
    page.get_by_role("button", name="Send", exact=True).click()
    expect(page.locator(".toast-item")).to_contain_text("Sent to 1 account")
    assert any(
        service == "telegram" and "This is a test push" in text for service, text in gateway.sent
    )
    shot("test-sent")

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return db.execute("SELECT * FROM channel_account ORDER BY id").fetchall()

    before = stored()
    if width == 1280:
        marker = page.evaluate("window.__imDoc = Math.random()")
        for language in ("zh-Hans", "en"):
            page.get_by_role(
                "button",
                name="Appearance and language" if language == "zh-Hans" else "外观与语言",
                exact=True,
            ).click()
            control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
            control.check()
            expect(control).to_be_enabled()
            expect(page.locator("html")).to_have_attribute("lang", language)
            page.get_by_role(
                "button", name="IM 推送" if language == "zh-Hans" else "IM push", exact=True
            ).click()
            expect(
                page.get_by_role(
                    "button", name="解绑" if language == "zh-Hans" else "Unlink", exact=True
                )
            ).to_be_visible()
            assert page.evaluate("window.__imDoc") == marker
            assert stored() == before
    page.get_by_role("button", name="Unlink", exact=True).click()
    page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
    assert stored() == before
    page.get_by_role("button", name="Unlink", exact=True).click()
    with page.expect_response(
        lambda r: r.request.method == "DELETE" and "/channels/telegram/accounts/" in r.url
    ):
        page.get_by_role("dialog").get_by_role("button", name="Unlink", exact=True).click()
    expect(page.get_by_text("No linked channels yet", exact=True)).to_be_visible()
    assert api("get", "/channels")["accounts"] == []

    dialog = add("WeChat")
    expect(dialog.get_by_text("Waiting for scan", exact=True)).to_be_visible()
    shot("qr")
    gateway.mode = "expired"
    expect(dialog.get_by_role("button", name="Start again", exact=True)).to_be_visible()
    expect(
        dialog.get_by_text("The QR code has expired repeatedly. Start linking again", exact=True)
    ).to_be_visible()
    shot("qr-expired")
    gateway.mode = "wait"
    dialog.get_by_role("button", name="Start again", exact=True).click()
    expect(dialog.get_by_text("Waiting for scan", exact=True)).to_be_visible()
    gateway.mode = "need_verifycode"
    field = dialog.get_by_placeholder("WeChat pairing code", exact=True)
    expect(field).to_be_visible()
    assert field.evaluate("""element => {
        const style = getComputedStyle(element);
        const context = document.createElement('canvas').getContext('2d');
        context.font = style.font;
        return context.measureText(element.placeholder).width <= element.clientWidth
            - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    }""")
    field.fill("11")
    dialog.get_by_role("button", name="Confirm", exact=True).click()
    expect(dialog.get_by_text("Incorrect pairing code. Enter it again", exact=True)).to_be_visible()
    shot("qr-input")
    field.fill("73")
    dialog.get_by_role("button", name="Confirm", exact=True).click()
    expect(page.get_by_role("dialog")).to_have_count(0)
    expect(page.get_by_text("Running", exact=True)).to_be_visible()
    shot("wechat-linked")
    rows = api("get", "/channels")["accounts"]
    assert len(rows) == 1 and rows[0]["bound_user_id"] == "fixture-user"
    assert "fixture-wechat-secret" not in repr(stored())
    api("delete", f"/channels/weixin/accounts/{rows[0]['account_id']}")
    assert not errors, errors
    context.close()


@pytest.mark.parametrize("theme_id,width", [("silver", 1280), ("netflix", 320)])
def test_push_only_form_binding_without_an_ai_provider(stack, browser, im_http, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    upstream, gateway = im_http
    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": width, "height": 1000})
    bootstrap = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    if not bootstrap.ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    for row in api("get", "/channels")["accounts"]:
        api("delete", f"/channels/{row['channel_id']}/accounts/{row['account_id']}")
    for provider in api("get", "/llm/providers"):
        api("delete", f"/llm/providers/{provider['id']}")
    gateway.sent.clear()
    assert context.request.post(base + "/api/v1/__lab/im/upstream", data={"url": upstream}).ok
    prefs = api("get", "/ui/preferences")
    prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=prefs)
    page = context.new_page()
    page.goto(base + "/settings/im-push")
    expect(page.get_by_text("No linked channels yet", exact=True)).to_be_visible()
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    page.get_by_role("button", name="Add channel", exact=True).click()
    expect(page.get_by_role("menuitem")).to_have_count(1)
    page.get_by_role("menuitem", name=re.compile("^Add Feishu channel")).click()
    dialog = page.get_by_role("dialog", name="Link Feishu")
    dialog.get_by_label("Webhook URL", exact=False).fill("http://invalid.example/hook")
    dialog.get_by_role("button", name="Finish linking", exact=True).click()
    expect(
        dialog.get_by_text("Invalid Webhook URL: enter a complete https:// link", exact=True)
    ).to_be_visible()
    assert gateway.sent == []
    shots = REPO / ".tmp-uidev/i18n/im-channels"
    shots.mkdir(parents=True, exist_ok=True)
    _snapshot(page, shots / f"{theme_id}-{width}-webhook-validation.png")
    dialog.get_by_label("Webhook URL", exact=False).fill(
        "https://open.feishu.cn/open-apis/bot/v2/hook/fixture-hook"
    )
    dialog.get_by_role("button", name="Finish linking", exact=True).click()
    expect(dialog).to_have_count(0)
    expect(page.get_by_text("Running", exact=True)).to_be_visible()
    # The plugin's stored default account name remains source data; UI labels are translated.
    body = page.locator("main").inner_text().replace("飞书群机器人", "")
    assert not re.search(r"[\u3400-\u9fff]", body)
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    expect(page.locator(".toast-item")).to_have_count(0, timeout=15000)
    _snapshot(page, shots / f"{theme_id}-{width}-webhook-linked.png")
    assert any(service == "feishu" and "MovieClaw" in text for service, text in gateway.sent)
    page.get_by_role("button", name="Send", exact=True).click()
    expect(page.locator(".toast-item")).to_contain_text("Sent to 1 account")
    assert any(
        service == "feishu" and "This is a test push" in text for service, text in gateway.sent
    )
    row = api("get", "/channels")["accounts"][0]
    assert row["display_name"] == "飞书群机器人"
    api("delete", f"/channels/feishu/accounts/{row['account_id']}")
    context.close()
