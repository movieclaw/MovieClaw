"""Real subtitle jobs and files; only the external model is an isolated HTTP fixture."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from . import test_i18n_subtitle_preview_browser as preview
from . import test_library_filtering_browser as inventory
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_i18n_share_artwork_browser import _api
from .test_library_manage_browser import _wait_for

browser = theme.browser
stack = preview.stack
pytestmark = pytest.mark.integration


@pytest.fixture
def model_endpoint():
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def reply(self, data):
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            assert self.path == "/v1/models"
            self.reply({"object": "list", "data": [{"id": "fixture-model", "object": "model"}]})

        def do_POST(self):
            assert self.path == "/v1/chat/completions"
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            calls.append(data)
            messages = data["messages"]
            user = next(
                message["content"] for message in reversed(messages) if message["role"] == "user"
            )
            if "找出其中反复出现的人名" in user:
                text = json.dumps({"items": []})
            elif "翻译下列对白：\n" in user:
                time.sleep(6)  # Expose real persisted progress, not a mocked UI response.
                entries = json.loads(user.split("翻译下列对白：\n", 1)[1])
                bilingual = "双语格式" in messages[0]["content"]
                text = json.dumps(
                    {
                        "items": [
                            {
                                "i": entry["i"],
                                "t": f"Line {entry['i']}\n句{entry['i']}"
                                if bilingual
                                else f"句{entry['i']}",
                            }
                            for entry in entries
                        ]
                    },
                    ensure_ascii=False,
                )
            else:
                text = "pong"
            if data.get("stream"):
                chunks = [
                    {
                        "id": "chatcmpl-fixture",
                        "object": "chat.completion.chunk",
                        "created": 1,
                        "model": "fixture-model",
                        "choices": [
                            {
                                "index": 0,
                                "delta": {"role": "assistant", "content": text},
                                "finish_reason": None,
                            }
                        ],
                    },
                    {
                        "id": "chatcmpl-fixture",
                        "object": "chat.completion.chunk",
                        "created": 1,
                        "model": "fixture-model",
                        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    },
                ]
                body = (
                    "".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks)
                    + "data: [DONE]\n\n"
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.reply(
                {
                    "id": "chatcmpl-fixture",
                    "object": "chat.completion",
                    "created": 1,
                    "model": "fixture-model",
                    "choices": [
                        {
                            "index": 0,
                            "finish_reason": "stop",
                            "message": {"role": "assistant", "content": text},
                        }
                    ],
                    "usage": {"prompt_tokens": 100, "completion_tokens": 100, "total_tokens": 200},
                }
            )

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/v1", calls
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_english_bilingual_generation_and_localized_job_history(stack, browser, model_endpoint):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1000})
    _api(context, base, "post", "/auth/bootstrap", data=inventory.ADMIN)
    endpoint, calls = model_endpoint
    provider = _api(
        context,
        base,
        "post",
        "/llm/providers",
        data={
            "name": "Local fixture",
            "provider_type": "openai_compat",
            "base_url": endpoint,
            "api_key": "isolated-test-key",
            "default_model": "fixture-model",
            "extra_models": [
                {"id": "fixture-model", "context_window": 32768, "max_output_tokens": 8192}
            ],
        },
    )
    _wait_for(
        lambda: (
            _api(context, base, "get", f"/llm/providers/{provider['id']}")["status"] == "active"
        ),
        timeout=30,
        what="local model verification",
    )
    entry = stack["roots"]["movies"] / "某电影 (2020)"
    entry.mkdir()
    video = entry / "某电影.2020.mkv"
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x180:rate=5:duration=120",
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            str(video),
        ],
        check=True,
        timeout=60,
    )
    source = video.with_suffix(".eng.srt")
    source.write_text(
        "\n".join(
            f"{i + 1}\n00:{i * 2 // 60:02}:{i * 2 % 60:02},000 --> "
            f"00:{i * 2 // 60:02}:{i * 2 % 60 + 1:02},500\nReference line {i}\n"
            for i in range(60)
        )
    )
    original = (hashlib.sha256(video.read_bytes()).hexdigest(), source.read_text())
    video.with_suffix(".nfo").write_text(
        "<movie><title>某电影</title><year>2020</year>"
        "<uniqueid type='tmdb' default='true'>300</uniqueid></movie>"
    )
    library = _api(
        context,
        base,
        "post",
        "/libraries",
        data={
            "name": "Subtitle generation",
            "kind": "movie",
            "root_paths": [str(stack["roots"]["movies"])],
            "realtime_watch": False,
        },
    )
    lid = library["id"]
    _wait_for(
        lambda: (
            (row := _api(context, base, "get", f"/libraries/{lid}"))["last_scan"]
            and not row["scanning"]
        ),
        timeout=120,
        what="subtitle source scan",
    )
    item_id = _api(context, base, "get", f"/libraries/{lid}/items")[0]["media_item_id"]
    file_id = _api(context, base, "get", f"/libraries/{lid}/items/{item_id}")["files"][0]["id"]
    page = context.new_page()
    page.set_default_timeout(30_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    detail_url = f"{base}/library/{lid}/item/{item_id}"
    page.goto(detail_url)
    page.get_by_role("button", name="Generate AI subtitles", exact=True).click()
    dialog = page.get_by_role("dialog", name="Generate AI subtitles", exact=True)
    expect(dialog.get_by_text(re.compile("^60 lines of dialogue · About"))).to_be_visible()
    expect(dialog.get_by_text(re.compile("^Creates "))).to_contain_text(
        "某电影.2020.ai-chs.chi.srt"
    )
    expect(dialog.get_by_role("combobox", name="Target language", exact=True)).to_have_value("chs")
    expect(dialog.get_by_role("combobox", name="Reference subtitles", exact=True)).to_have_value(
        f"external:{source.name}"
    )
    dialog.get_by_label("Generate bilingual subtitles", exact=True).check()
    dialog.get_by_role("combobox", name="First line language", exact=True).select_option("eng")
    expect(dialog.get_by_role("combobox", name="Second line language", exact=True)).to_have_value(
        "chs"
    )
    start = dialog.get_by_role(
        "button", name="Generate English + Simplified Chinese bilingual", exact=True
    )
    expect(start).to_be_enabled()
    shots = theme.REPO / ".tmp-uidev/i18n/subtitle-generation"
    shots.mkdir(parents=True, exist_ok=True)
    _snapshot(page, shots / "preflight-en.png")
    page.set_viewport_size({"width": 320, "height": 844})
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    assert dialog.evaluate("element => element.scrollWidth <= element.clientWidth")
    _snapshot(page, shots / "preflight-mobile-en.png")
    start.scroll_into_view_if_needed()
    assert start.evaluate(
        "element => { const r = element.getBoundingClientRect(); "
        "return r.left >= 0 && r.right <= innerWidth; }"
    )
    _snapshot(page, shots / "preflight-mobile-actions-en.png")
    with page.expect_response(
        lambda response: (
            response.request.method == "POST"
            and response.url.endswith(f"/libraries/files/{file_id}/subtitles/generations")
        )
    ) as queued:
        start.click()
    response = queued.value
    assert response.ok, response.text()
    job_id = response.json()["data"]["id"]
    badge = page.get_by_role(
        "button", name=re.compile(r"^English \+ Simplified Chinese bilingual ·")
    )
    badge.click()
    dialog = page.get_by_role("dialog", name="AI subtitle generation status", exact=True)
    expect(dialog.get_by_text("Subtitle generation stages", exact=True)).to_have_count(
        0
    )  # Accessible list label, not visible text.
    expect(
        dialog.get_by_role("list", name="Subtitle generation stages", exact=True)
    ).to_be_visible()
    expect(dialog.get_by_role("button", name="Stop generation", exact=True)).to_be_visible()
    expect(
        dialog.get_by_text(
            re.compile("^(Waiting for the model to return|Translating dialogue with)")
        )
    ).to_be_visible(timeout=15_000)
    _snapshot(page, shots / "progress-mobile-en.png")

    def finished():
        row = _api(context, base, "get", f"/jobs/{job_id}")
        return row if row["status"] in {"succeeded", "failed", "blocked", "cancelled"} else None

    job = _wait_for(
        finished,
        timeout=90,
        what="real subtitle job completion",
    )
    assert job["status"] == "succeeded", job
    assert job["result"]["message"].startswith("Generated ")
    assert job["result"]["source_desc"].startswith("External subtitle ")
    assert job["input_data"]["target_language"] == "eng"
    assert job["input_data"]["secondary_language"] == "chs"
    product = entry / job["result"]["filename"]
    from movieclaw_api.services.subtitle_gen.extract import parse_events

    result = parse_events(product.read_text(), product.name, preserve_linebreaks=True)
    original_events = parse_events(original[1], source.name)
    assert len(result) == 60
    assert [(s, e) for s, e, _ in result] == [(s, e) for s, e, _ in original_events]
    assert all(text == f"Line {i}\n句{i}" for i, (_, _, text) in enumerate(result))
    assert source.read_text() == original[1]
    assert hashlib.sha256(video.read_bytes()).hexdigest() == original[0]
    database = stack["database_url"].removeprefix("sqlite+aiosqlite:///")
    with sqlite3.connect(database) as connection:
        raw = connection.execute(
            "SELECT result, progress FROM job WHERE id = ?", (job_id,)
        ).fetchone()
    saved_result, saved_progress = map(json.loads, raw)
    assert saved_result["message"].startswith("已生成 ")
    assert saved_result["message_key"] == "library.subtitleJob.completed"
    assert saved_result["source_desc"].startswith("外挂 ")
    assert saved_progress["message_key"] == "library.subtitleJob.completed"
    for locale in ("zh-Hans", "en", "zh-Hans"):
        response = context.request.get(
            f"{base}/api/v1/jobs/{job_id}", headers={"Accept-Language": locale}
        )
        localized = response.json()["data"]
        assert localized["result"]["message"].startswith(
            "已生成 " if locale == "zh-Hans" else "Generated "
        )
        assert localized["result"]["source_desc"].startswith(
            "外挂 " if locale == "zh-Hans" else "External subtitle "
        )
    english_events = _api(context, base, "get", f"/jobs/{job_id}/events")["items"]
    progress_events = [
        event["payload"] for event in english_events if event["event_type"] == "progress"
    ]
    assert any(
        event.get("message_key") == "library.subtitleJob.firstBlocks"
        and event["message"].startswith("Waiting for the model")
        for event in progress_events
    )
    # UI language must not change translation prompts, selected targets or output names.
    translation_calls = [
        call
        for call in calls
        if any("翻译下列对白：\n" in message["content"] for message in call["messages"])
    ]
    assert len(translation_calls) == 2
    assert all(
        "第一行只写英语，第二行只写简体中文" in call["messages"][0]["content"]
        for call in translation_calls
    )
    chinese = browser.new_context(
        locale="zh-CN",
        storage_state=context.storage_state(),
        viewport={"width": 320, "height": 844},
    )
    chinese.add_cookies([{"name": "mc_locale", "value": "zh-Hans", "url": base}])
    chinese_page = chinese.new_page()
    chinese_page.goto(detail_url)
    chinese_page.get_by_role("button", name="AI 生成字幕", exact=True).click()
    chinese_dialog = chinese_page.get_by_role("dialog", name="生成 AI 字幕", exact=True)
    expect(chinese_dialog.get_by_text(re.compile("^60 条对白 · 约"))).to_be_visible()
    expect(chinese_dialog.get_by_role("combobox", name="目标语言", exact=True)).to_have_value("chs")
    chinese_dialog.get_by_role(
        "button", name="确认生成简体中文", exact=True
    ).scroll_into_view_if_needed()
    _snapshot(chinese_page, shots / "preflight-mobile-zh.png")
    chinese.close()

    # Replace a local reference with an incomplete subtitle, then test the real failure
    # preflight and the actual Agent handoff payload. This must not call translation.
    source.write_text("1\n00:00:01,000 --> 00:00:02,000\nReplacement dialogue\n")
    dialog.get_by_role("button", name="Close", exact=True).last.click()
    page.get_by_role("button", name="Generate AI subtitles", exact=True).click()
    dialog = page.get_by_role("dialog", name="Generate AI subtitles", exact=True)
    expect(
        dialog.get_by_text("The reference subtitles cannot be translated", exact=True)
    ).to_be_visible()
    expect(dialog.get_by_text(re.compile("^Candidate .*Only 1 dialogue cue"))).to_be_visible()
    expect(dialog.get_by_role("button", name="Check again", exact=True)).to_be_visible()
    _snapshot(page, shots / "incomplete-mobile-en.png")
    with page.expect_response(
        lambda response: (
            response.request.method == "POST" and response.url.endswith("/api/v1/sessions")
        )
    ) as handoff:
        dialog.get_by_role("button", name="Ask the Agent", exact=True).click()
    response = handoff.value
    assert response.ok, response.text()
    prompt = response.request.post_data_json["content"]
    assert prompt.startswith("Help me resolve this MovieClaw AI subtitle generation issue.")
    assert f"File path: {video}" in prompt
    assert "Expected output: English + Simplified Chinese bilingual" in prompt
    assert (
        "Arguments: --target-language eng --secondary-language chs "
        f"--source-candidate-key external:{source.name}" in prompt
    )
    assert "Do not modify the original video file." in prompt
    assert "Only 1 dialogue cue" in prompt
    assert not re.search(
        r"[\u3400-\u9fff]",
        prompt.replace(str(video), "").replace(source.name, "").replace(video.name, ""),
    )
    page.wait_for_url(re.compile("/sessions/"))
    assert (
        len(
            [
                call
                for call in calls
                if any("翻译下列对白：\n" in message["content"] for message in call["messages"])
            ]
        )
        == 2
    )
    page.goto(f"{base}/settings/appearance")
    with page.expect_response(
        lambda response: (
            "/api/v1/jobs?" in response.url
            and response.request.headers.get("accept-language") == "zh-Hans"
        ),
        timeout=6000,
    ) as refreshed:
        page.get_by_test_id("language-settings").locator('input[value="zh-Hans"]').check()
    expect(page.locator("html")).to_have_attribute("lang", "zh-Hans")
    assert refreshed.value.ok
    # An active-only response may be empty; the history request must also use the new locale.
    jobs_response = context.request.get(
        f"{base}/api/v1/jobs/{job_id}", headers={"Accept-Language": "zh-Hans"}
    )
    assert jobs_response.json()["data"]["result"]["message"].startswith("已生成 ")
    assert not errors
    context.close()
