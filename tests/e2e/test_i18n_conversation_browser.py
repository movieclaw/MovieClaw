"""Real conversation, tool execution, rewriting and forks with isolated API/SQLite/JSONL."""

import hashlib

import pytest

from . import test_i18n_agent_stream_browser as stream
from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_library_manage_browser import REPO

stack = ai.stack
browser = ai.browser
search_provider = ai.search_provider
streaming_provider = stream.streaming_provider
pytestmark = pytest.mark.integration


def test_conversation_tools_rewrite_fork_rename_and_delete(stack, browser, streaming_provider):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(
        locale="en-US",
        viewport={"width": 1280, "height": 1000},
        permissions=["clipboard-read", "clipboard-write"],
    )
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    streaming_provider[1].fail = False
    streaming_provider[1].use_tools = True

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    api(
        "post",
        "/llm/providers",
        data={
            "name": "Conversation Fixture",
            "provider_type": "openai_compat",
            "base_url": streaming_provider[0],
            "api_key": "sk-loopback-only",
            "default_model": "fixture-model",
            "extra_models": [
                {"id": "fixture-model", "context_window": 32768, "max_output_tokens": 8192}
            ],
        },
    )
    skill = stack["data"] / "agent-skills" / "i18n-fixture" / "SKILL.md"
    skill.parent.mkdir(parents=True, exist_ok=True)
    skill.write_text(
        "---\nname: i18n-fixture\ndescription: Local test skill\n---\nKeep responses short.\n"
    )
    page = context.new_page()
    page.set_default_timeout(30000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/conversation"
    shots.mkdir(parents=True, exist_ok=True)

    def transcript(sid):
        return api("get", "/sessions/" + sid)

    def menu(action):
        page.get_by_role("banner").get_by_role("button", name="Session actions", exact=True).click()
        page.get_by_role("button", name=action, exact=True).click()

    def screenshot(name):
        page.locator(".toast-item").evaluate_all("nodes => nodes.forEach(node => node.click())")
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / name)

    for theme_id, width in [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]:
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/new")
        editor = page.get_by_test_id("agent-composer").get_by_role(
            "textbox", name="Message input", exact=True
        )
        expect(editor).to_be_editable()
        editor.fill("/")
        expect(page.get_by_role("listbox", name="Skill shortcuts", exact=True)).to_be_visible()
        expect(page.get_by_text("Use a skill", exact=True)).to_be_visible()
        page.keyboard.press("Escape")
        question = f"Check the {theme_id} {width} conversation fixture."
        editor.fill(question)
        with page.expect_response(
            lambda r: r.request.method == "POST" and r.url.endswith("/api/v1/sessions")
        ) as sent:
            page.get_by_role("button", name="Send", exact=True).click()
        sid = sent.value.json()["data"]["session_id"]
        page.wait_for_url("**/sessions/" + sid)
        if width == 320:
            expect(
                page.get_by_role("navigation", name="Main navigation", exact=True)
            ).to_have_count(0)
        expect(page.get_by_text("Recovered fixture reply", exact=True)).to_be_visible()
        process = page.get_by_role("button", name="Ran 1 command", exact=True)
        expect(process).to_be_visible()
        process.click()
        page.get_by_role("button").filter(has_text="printf").click()
        expect(page.get_by_text("Tool fixture output", exact=True)).to_be_visible()
        page.get_by_role("button", name="Copy", exact=True).last.click()
        assert page.evaluate("navigator.clipboard.readText()") == "Recovered fixture reply"
        screenshot(f"{theme_id}-{width}-tools.png")
        before = transcript(sid)["entries"]

        def edit(question=question):
            page.get_by_text(question, exact=True).hover()
            page.get_by_role("button", name="Edit this question", exact=True).click()

        edit()
        expect(page.get_by_test_id("agent-companion")).to_have_count(0)
        expect(editor).to_have_text(question)
        editor.fill("This replacement must be cancelled first.")
        page.get_by_role("button", name="Send", exact=True).click()
        dialog = page.get_by_role("dialog")
        expect(dialog).to_contain_text("Resubmit this question?")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        assert transcript(sid)["entries"] == before
        page.get_by_role("button", name="Cancel editing", exact=True).click()
        edit()
        editor.fill("Replace the earlier question with this fixture.")
        page.get_by_role("button", name="Send", exact=True).click()
        with page.expect_response(
            lambda r: r.request.method == "POST" and "/retry" in r.url
        ) as retried:
            page.get_by_role("dialog").get_by_role(
                "button", name="Replace and resubmit", exact=True
            ).click()
        assert retried.value.status == 202
        expect(page.get_by_text("Recovered fixture reply", exact=True)).to_be_visible()
        after = transcript(sid)["entries"]
        assert after[0]["message"]["content"] == "Replace the earlier question with this fixture."
        assert before[0]["message_id"] != after[0]["message_id"]
        page.set_viewport_size({"width": 320, "height": 1000})
        menu("Rename")
        dialog = page.get_by_role("dialog")
        expect(dialog).to_contain_text("Rename session")
        title = f"User title {theme_id} {width}"
        dialog.get_by_role("textbox").fill(title)
        with page.expect_response(
            lambda r, sid=sid: r.request.method == "PATCH" and r.url.endswith("/sessions/" + sid)
        ) as renamed:
            dialog.get_by_role("button", name="Confirm", exact=True).click()
        assert renamed.value.ok
        assert transcript(sid)["session"]["title"] == title
        original = next((stack["data"] / "agent-sessions").rglob(sid + ".jsonl"))
        digest = hashlib.sha256(original.read_bytes()).digest()
        menu("Start a new session here")
        page.get_by_role("dialog").get_by_role("button", name="Cancel", exact=True).click()
        assert page.url.endswith("/sessions/" + sid)
        menu("Start a new session here")
        with page.expect_response(
            lambda r, sid=sid: (
                r.request.method == "POST" and r.url.endswith("/sessions/" + sid + "/fork")
            )
        ) as forked:
            page.get_by_role("dialog").get_by_role(
                "button", name="Create session", exact=True
            ).click()
        assert forked.value.ok
        target = forked.value.json()["data"]["session"]["id"]
        page.wait_for_url("**/sessions/" + target)
        expect(
            page.get_by_text(f'Continued with context from "{title}"', exact=True)
        ).to_be_visible()
        expect(
            page.get_by_role("link", name="View original session", exact=True)
        ).to_have_attribute("href", "/sessions/" + sid)
        assert hashlib.sha256(original.read_bytes()).digest() == digest
        assert len(transcript(target)["entries"]) == 1
        expect(page.get_by_role("heading", name=f"Continued: {title}", exact=True)).to_be_visible()
        screenshot(f"{theme_id}-{width}-fork.png")
        if theme_id == "silver" and width == 1280:
            page.evaluate("window.__i18nSessionDocument = 'preserved'")
            target_file = next((stack["data"] / "agent-sessions").rglob(target + ".jsonl"))
            target_digest = hashlib.sha256(target_file.read_bytes()).digest()
            page.set_viewport_size({"width": 1280, "height": 1000})
            for language, expected in [("zh-Hans", f"续：{title}"), ("en", f"Continued: {title}")]:
                _change_language(page, language)
                expect(page.get_by_role("heading", name=expected, exact=True)).to_be_visible()
                assert page.url.endswith("/sessions/" + target)
                assert page.evaluate("window.__i18nSessionDocument") == "preserved"
                assert hashlib.sha256(target_file.read_bytes()).digest() == target_digest
                assert hashlib.sha256(original.read_bytes()).digest() == digest
            page.set_viewport_size({"width": 320, "height": 1000})
        menu("Delete session")
        dialog = page.get_by_role("dialog")
        expect(dialog).to_contain_text("This cannot be undone.")
        dialog.get_by_role("button", name="Cancel", exact=True).click()
        assert transcript(target)["session"]["id"] == target
        menu("Delete session")
        with page.expect_response(
            lambda r, target=target: (
                r.request.method == "DELETE" and r.url.endswith("/sessions/" + target)
            )
        ) as deleted:
            page.get_by_role("dialog").get_by_role(
                "button", name="Delete permanently", exact=True
            ).click()
        assert deleted.value.ok
        assert context.request.get(base + "/api/v1/sessions/" + target).status == 404
        assert hashlib.sha256(original.read_bytes()).digest() == digest
        assert not errors, errors
    # Submit actual skill-only and image-only messages, including the upload/bind path.
    import io
    import sqlite3

    from PIL import Image

    chinese = browser.new_context(locale="zh-CN")
    assert chinese.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    image = io.BytesIO()
    Image.new("RGB", (8, 8), (200, 30, 30)).save(image, format="PNG")
    for count, raw, english in [
        (0, "[技能] 用户未附加说明，按上述技能指令执行。", "[Skill]"),
        (1, "[图片]", "[Image]"),
        (2, "[图片 ×2]", "[Images ×2]"),
    ]:
        page.goto(base + "/new")
        if count:
            page.locator('input[type="file"]').set_input_files(
                [
                    {
                        "name": f"fixture-{n}.png",
                        "mimeType": "image/png",
                        "buffer": image.getvalue(),
                    }
                    for n in range(count)
                ]
            )
        else:
            editor = page.get_by_test_id("agent-composer").get_by_role(
                "textbox", name="Message input", exact=True
            )
            editor.fill("/skill:i18n-fixture")
            page.keyboard.press("Escape")
        with page.expect_response(
            lambda r: r.request.method == "POST" and r.url.endswith("/api/v1/sessions")
        ) as sent:
            page.get_by_role("button", name="Send", exact=True).click()
        sid = sent.value.json()["data"]["session_id"]
        page.wait_for_url("**/sessions/" + sid)
        expect(page.get_by_text("Recovered fixture reply", exact=True)).to_be_visible()
        expect(page.get_by_role("heading", name=english, exact=True)).to_be_visible()
        persisted_english = (
            "[Skill] No extra instructions; follow the selected skill." if count == 0 else english
        )
        assert transcript(sid)["session"]["title"] == persisted_english
        page.reload()
        expect(page.get_by_role("heading", name=persisted_english, exact=True)).to_be_visible()
        if count == 0:
            expect(
                page.locator(".selectable").filter(
                    has_text="No extra instructions; follow the selected skill."
                )
            ).to_be_visible()
        response = chinese.request.get(
            base + "/api/v1/sessions/" + sid, headers={"Accept-Language": "zh-Hans"}
        )
        assert response.json()["data"]["session"]["title"] == raw
        with sqlite3.connect(stack["data"] / "movieclaw.db") as connection:
            assert (
                connection.execute("SELECT title FROM agent_session WHERE id=?", (sid,)).fetchone()[
                    0
                ]
                == raw
            )
        if count == 2:
            screenshot("netflix-320-images.png")
    assert not errors, errors
    chinese.close()
    context.close()
