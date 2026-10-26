"""Real plugin configuration, missing app guidance, upload rejection and AI handoff."""

import io
import json
import re
import sqlite3
import zipfile

import pytest

from . import test_i18n_agent_stream_browser as streaming
from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_subscription_cancel_browser import _run
from .test_library_manage_browser import REPO

browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack
streaming_provider = streaming.streaming_provider
pytestmark = pytest.mark.integration


def _package(identity):
    module = identity.replace("-", "_")
    source = f'''
from typing import Literal
from pydantic import BaseModel, Field, SecretStr
from movieclaw_sdk import plugin
class Config(BaseModel):
    channel: Literal["原始选项", "other"] | None = Field(None, title="Channel")
    recipients: list[str] = Field(default_factory=list, title="Recipients")
    token: SecretStr | None = Field(None, title="Access token")
    spare: SecretStr | None = Field(None, title="Spare token")
@plugin("{identity}", title="Author config", config=Config)
async def apply(ctx):
    pass
'''
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(
            "movieclaw-plugin.toml",
            f'[plugin]\nid="{identity}"\ntitle="Author config"\nversion="1.0.0"\n'
            f'entry="{module}"\nruntime="inline"\nsdk="^1.0"\n',
        )
        archive.writestr(f"{module}/__init__.py", source)
    return buffer.getvalue()


async def _notice(database_url, identity):
    from movieclaw_db.engine import Database
    from movieclaw_db.models import SystemNotice

    database = Database(database_url)
    try:
        async with database.session() as session:
            notice = SystemNotice(
                dedupe_key=identity,
                severity="warning",
                source="plugin",
                title="作者告警 " + identity,
                message="作者原始证据",
                payload={"entry_id": identity, "source_fact": "原始编号"},
            )
            session.add(notice)
            await session.commit()
            await session.refresh(notice)
            return notice.id, notice.title
    finally:
        await database.dispose()


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_owned_auxiliary_copy_with_real_settings_and_handoff(
    stack, browser, streaming_provider, theme_id, width
):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    identity = f"i18n-aux-{theme_id}-{width}"
    context = browser.new_context(
        locale="en-US",
        viewport={"width": width, "height": 1100},
        is_mobile=width == 320,
        has_touch=width == 320,
    )
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    upload = context.request.post(
        base + "/api/v1/app/plugins/packages",
        multipart={
            "file": {
                "name": "author.mcplugin",
                "mimeType": "application/zip",
                "buffer": _package(identity),
            }
        },
    )
    assert upload.ok, upload.text()
    installed = api(
        "post",
        f"/app/plugins/packages/{identity}/approve",
        data={"version": "1.0.0", "operations": [], "allow_inline": True},
    )
    assert installed["status"] == "active"
    preferences = api("get", "/ui/preferences")
    preferences.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=preferences)
    context.add_cookies([{"name": "mc_locale", "value": "en", "url": base}])
    page = context.new_page()
    page.set_default_timeout(30000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/plugins/" + identity)
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_label("Channel", exact=True)).to_be_visible()
    page.wait_for_load_state("networkidle")
    expect(page.get_by_label("Access token", exact=True)).to_have_attribute(
        "placeholder", "Not set"
    )
    page.get_by_label("Channel", exact=True).select_option("原始选项")
    page.get_by_label("Recipients", exact=True).fill("用户频道\nsecond")
    page.get_by_label("Access token", exact=True).fill("fixture-secret-kept")
    with page.expect_response(
        lambda response: (
            response.request.method == "PUT" and response.url.endswith(f"/{identity}/settings")
        )
    ) as saved:
        page.get_by_role("button", name="Save", exact=True).click()
    assert saved.value.ok, saved.value.text()
    submitted = json.loads(saved.value.request.post_data)["values"]
    assert submitted["channel"] == "原始选项"
    assert submitted["recipients"] == ["用户频道", "second"]
    values = api("get", f"/app/plugins/{identity}/settings")
    assert values["values"] == {"channel": "原始选项", "recipients": ["用户频道", "second"]}
    assert values["secrets_set"] == ["token"]
    settings_path = stack["data"] / "plugins/settings" / f"{identity}.json"
    original_settings = settings_path.read_bytes()
    shots = REPO / ".tmp-uidev/i18n/auxiliary"
    shots.mkdir(parents=True, exist_ok=True)
    for language in ("en", "zh-Hans", "en"):
        page.goto(base + "/settings/appearance")
        control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
        control.check()
        expect(control).to_be_enabled()
        page.goto(base + "/settings/plugins/" + identity)
        expect(page.locator("html")).to_have_attribute("lang", language)
        expect(page.get_by_label("Channel", exact=True)).to_have_value("原始选项")
        expect(
            page.get_by_role(
                "option", name="(Not set)" if language == "en" else "（不设置）", exact=True
            )
        ).to_have_count(1)
        expect(page.get_by_label("Recipients", exact=True)).to_have_attribute(
            "placeholder", "One per line" if language == "en" else "每行一个"
        )
        expect(page.get_by_label("Access token", exact=True)).to_have_attribute(
            "placeholder", "Set (leave blank to keep)" if language == "en" else "已设置（留空不改）"
        )
        expect(page.get_by_label("Spare token", exact=True)).to_have_attribute(
            "placeholder", "Not set" if language == "en" else "未设置"
        )
        page.screenshot(
            path=str(shots / f"{theme_id}-{width}-{language}-schema.png"), animations="disabled"
        )
        assert settings_path.read_bytes() == original_settings
        page.goto(base + "/apps/fixture-missing")
        expect(
            page.get_by_text(
                "This page is unavailable" if language == "en" else "这个页面打不开", exact=True
            )
        ).to_be_visible()
        expect(
            page.get_by_role(
                "link",
                name="Open plugin settings" if language == "en" else "去插件设置",
                exact=True,
            )
        ).to_have_attribute("href", "/settings/plugins")
        page.goto(base + "/settings/profile")
        if theme_id == "netflix":
            expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
        for mime_type, message in [
            ("text/plain", "Choose an image file" if language == "en" else "请选择图片文件"),
            (
                "image/png",
                "Could not decode the image. Try another file."
                if language == "en"
                else "图片解码失败，请换一张试试",
            ),
        ]:
            page.locator('input[type="file"]').set_input_files(
                {
                    "name": "作者错误图片.png",
                    "mimeType": mime_type,
                    "buffer": b"invalid image bytes",
                }
            )
            expect(page.get_by_text(message, exact=True)).to_be_visible()
        assert settings_path.read_bytes() == original_settings
    # A member sees the reader-specific missing-app explanation without the admin action.
    member = {"username": f"aux_{theme_id}_{width}", "password": "fixture-member-password"}
    api("post", "/members", data=member)
    reader = browser.new_context(locale="en-US", viewport={"width": width, "height": 1100})
    assert reader.request.post(base + "/api/v1/auth/login", data=member).ok
    reader.add_cookies([{"name": "mc_locale", "value": "en", "url": base}])
    member_page = reader.new_page()
    member_page.goto(base + "/apps/fixture-missing")
    expect(
        member_page.get_by_text(
            "It may have been removed, or the administrator may not have made it "
            "available to members.",
            exact=True,
        )
    ).to_be_visible()
    expect(member_page.get_by_role("link", name="Open plugin settings", exact=True)).to_have_count(
        0
    )
    reader.close()
    # Start a real Agent session from the notice. The model is a loopback HTTP provider.
    streaming_provider[1].fail = False
    for row in api("get", "/llm/providers"):
        api("delete", f"/llm/providers/{row['id']}")
    api(
        "post",
        "/llm/providers",
        data={
            "name": "Loopback handoff",
            "provider_type": "openai_compat",
            "base_url": streaming_provider[0],
            "api_key": "sk-loopback-handoff",
            "default_model": "fixture-model",
            "extra_models": [
                {"id": "fixture-model", "context_window": 32768, "max_output_tokens": 8192}
            ],
        },
    )
    notice_id, title = _run(_notice(stack["database_url"], identity))

    def notice_fact():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return db.execute(
                "SELECT title, message, payload, status FROM system_notice WHERE id=?", (notice_id,)
            ).fetchone()

    original_notice = notice_fact()
    page.goto(base + ("/my" if width == 320 else "/library"))
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    page.get_by_role("button", name=re.compile(r"^(Needs attention|Pending)")).first.click()
    dialog = page.get_by_role("dialog", name="Needs attention", exact=True)
    card = dialog.locator("div.rounded-xl").filter(
        has=page.get_by_role("heading", name=title, exact=True)
    )
    analyze = card.get_by_role("button", name="Ask AI", exact=True)
    expect(analyze).to_be_enabled()
    # Action labels must stay on one line and inside the card, even at 320px.
    card_box = card.bounding_box()
    for button in card.get_by_role("button").all():
        box = button.bounding_box()
        line_height = button.evaluate("el => parseFloat(getComputedStyle(el).lineHeight)")
        padding = button.evaluate(
            "el => parseFloat(getComputedStyle(el).paddingTop)"
            " + parseFloat(getComputedStyle(el).paddingBottom)"
        )
        assert box["height"] <= line_height + padding + 2, button.inner_text()
        assert box["x"] >= card_box["x"]
        assert box["x"] + box["width"] <= card_box["x"] + card_box["width"]
    page.screenshot(path=str(shots / f"{theme_id}-{width}-handoff.png"), animations="disabled")
    with (
        page.expect_response(
            lambda response: response.url.endswith("/api/v1/agent-handoff")
        ) as handoff,
        page.expect_response(
            lambda response: (
                response.url.endswith("/api/v1/sessions") and response.request.method == "POST"
            )
        ) as accepted,
    ):
        analyze.click()
    assert handoff.value.ok and accepted.value.status == 202
    assert json.loads(handoff.value.request.post_data) == {"kind": "notice", "ref": str(notice_id)}
    prompt = handoff.value.json()["data"]["prompt"]
    assert title in prompt and "原始编号" in prompt
    session_id = accepted.value.json()["data"]["session_id"]
    page.wait_for_url("**/sessions/" + session_id)
    expect(page.get_by_text("Recovered fixture reply", exact=True)).to_be_visible()
    transcript = api("get", "/sessions/" + session_id)
    users = [
        entry["message"]["content"]
        for entry in transcript["entries"]
        if entry["message"]["role"] == "user"
    ]
    assert users == [prompt]
    assert notice_fact() == original_notice
    # Simulate missing stream capability at a real HTTP response boundary.
    # Chrome exposes an empty readable stream even on HTTP 204, so that status is insufficient.
    page.evaluate(
        """sessionId => {
        const actualFetch = window.fetch.bind(window);
        window.__auxOriginalFetch = actualFetch;
        window.__auxNoStreamResponses = 0;
        window.fetch = async (...args) => {
            const response = await actualFetch(...args);
            const input = args[0];
            const url = typeof input === "string" ? input : input.url ?? String(input);
            if (new URL(url, location.href).pathname === `/api/v1/sessions/${sessionId}/events`) {
                window.__auxNoStreamResponses++;
                void response.body?.cancel().catch(() => {});
                Object.defineProperty(response, "body", {value: null});
            }
            return response;
        };
    }""",
        session_id,
    )
    editor = page.get_by_test_id("agent-composer").get_by_role("textbox")
    editor.fill("继续检查作者证据")
    page.get_by_role("button", name="Send", exact=True).click()
    expect(
        page.get_by_text("Streaming responses are not supported in this environment", exact=False)
    ).to_be_visible()
    assert page.evaluate("window.__auxNoStreamResponses") == 1
    page.evaluate("window.fetch = window.__auxOriginalFetch")
    page.reload()
    expect(page.get_by_text("Recovered fixture reply", exact=True)).to_have_count(2)
    assert settings_path.read_bytes() == original_settings
    assert notice_fact() == original_notice
    assert any(call.get("stream") for call in streaming_provider[1].calls)
    assert not errors, errors
    context.close()
