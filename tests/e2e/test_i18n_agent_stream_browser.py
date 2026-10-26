"""Send a real conversation through Next, API, SDK, HTTP stream and reader-local SSE."""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

browser = ai.browser
stack = ai.stack
search_provider = ai.search_provider
pytestmark = pytest.mark.integration


@pytest.fixture
def streaming_provider():
    class Handler(BaseHTTPRequestHandler):
        fail = True
        use_tools = False
        calls = []

        def reply(self, body, status=200, content_type="application/json"):
            if not isinstance(body, bytes):
                body = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self.reply(
                {
                    "object": "list",
                    "data": [
                        {
                            "id": "fixture-model",
                            "object": "model",
                            "created": 0,
                            "owned_by": "fixture",
                        }
                    ],
                }
            )

        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            self.calls.append(payload)
            if payload.get("stream"):
                if self.fail:
                    self.reply(
                        {
                            "error": {
                                "message": "Fixture streaming key rejected",
                                "type": "invalid_api_key",
                                "code": "invalid_api_key",
                            }
                        },
                        status=401,
                    )
                    return
                chunks = [
                    {
                        "id": "chat_fixture",
                        "object": "chat.completion.chunk",
                        "created": 0,
                        "model": "fixture-model",
                        "choices": [
                            {
                                "index": 0,
                                "delta": {
                                    "role": "assistant",
                                    "content": "Recovered fixture reply",
                                },
                                "finish_reason": None,
                            }
                        ],
                    },
                    {
                        "id": "chat_fixture",
                        "object": "chat.completion.chunk",
                        "created": 0,
                        "model": "fixture-model",
                        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    },
                ]
                if self.use_tools and payload["messages"][-1]["role"] == "user":
                    chunks[0]["choices"][0]["delta"] = {
                        "role": "assistant",
                        "tool_calls": [
                            {
                                "index": 0,
                                "id": f"call_fixture_{len(self.calls)}",
                                "type": "function",
                                "function": {
                                    "name": "bash",
                                    "arguments": json.dumps(
                                        {"command": "printf 'Tool fixture output'"}
                                    ),
                                },
                            }
                        ],
                    }
                    chunks[1]["choices"][0]["finish_reason"] = "tool_calls"
                body = (
                    "".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks)
                    + "data: [DONE]\n\n"
                )
                self.reply(body.encode(), content_type="text/event-stream")
            else:
                self.reply(
                    {
                        "id": "chat_fixture",
                        "object": "chat.completion",
                        "created": 0,
                        "model": "fixture-model",
                        "choices": [
                            {
                                "index": 0,
                                "message": {"role": "assistant", "content": "Connected"},
                                "finish_reason": "stop",
                            }
                        ],
                        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
                    }
                )

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/v1", Handler
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_actual_stream_error_replay_and_recovery(stack, browser, streaming_provider):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    created = context.request.post(
        base + "/api/v1/llm/providers",
        data={
            "name": "Stream Fixture",
            "provider_type": "openai_compat",
            "base_url": streaming_provider[0],
            "api_key": "sk-loopback-stream",
            "default_model": "fixture-model",
            "extra_models": [
                {"id": "fixture-model", "context_window": 32768, "max_output_tokens": 8192}
            ],
        },
    )
    assert created.ok, created.text()
    page = context.new_page()
    page.set_default_timeout(30000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/new")
    if page.get_by_role("button", name="Get started", exact=True).count():
        page.get_by_role("button", name="Get started", exact=True).click()
    editor = page.get_by_test_id("agent-composer").get_by_role("textbox")
    expect(editor).to_be_editable()
    editor.fill("Please exercise the streaming error fixture.")
    with page.expect_response(
        lambda response: (
            response.request.method == "POST" and response.url.endswith("/api/v1/sessions")
        )
    ) as accepted:
        page.get_by_role("button", name="Send", exact=True).click()
    assert accepted.value.status == 202
    session_id = accepted.value.json()["data"]["session_id"]
    failure = page.get_by_text("Authentication failed", exact=False)
    expect(failure).to_be_visible()
    expect(failure).to_contain_text("Fixture streaming key rejected")
    page.wait_for_url("**/sessions/" + session_id)
    shots = REPO / ".tmp-uidev/i18n/agent-stream"
    shots.mkdir(parents=True, exist_ok=True)
    for width in [1280, 320]:
        page.set_viewport_size({"width": width, "height": 1000})
        _snapshot(page, shots / f"stream-error-{width}.png")
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    # An independent reader receives the same cached event in Chinese.
    chinese = browser.new_context(locale="zh-CN")
    assert chinese.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    translated = chinese.request.get(
        base + f"/api/v1/sessions/{session_id}/events", headers={"Accept-Language": "zh-Hans"}
    )
    assert translated.ok and "认证失败" in translated.text()
    english = context.request.get(base + f"/api/v1/sessions/{session_id}/events")
    assert english.ok and "Authentication failed" in english.text()
    assert "Fixture streaming key rejected" in translated.text()
    chinese.close()
    streaming_provider[1].fail = False
    editor.fill("Please retry after the provider has recovered.")
    page.get_by_role("button", name="Send", exact=True).click()
    expect(page.get_by_text("Recovered fixture reply", exact=True)).to_be_visible()
    assert any(call.get("stream") for call in streaming_provider[1].calls)
    assert not errors, errors
    context.close()
