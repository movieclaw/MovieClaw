"""MCP management through Next, the real API/SQLite and HTTP protocol clients."""

import re
import sqlite3

import pytest

from . import test_i18n_ai_settings_browser as ai
from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _snapshot
from .test_library_manage_browser import REPO

pytestmark = pytest.mark.integration
browser = ai.browser
search_provider = ai.search_provider
stack = ai.stack


@pytest.mark.parametrize(
    "theme_id,width", [("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)]
)
def test_endpoint_lifecycle_and_language_preserve_protocol(stack, browser, theme_id, width):  # noqa: F811
    from playwright.sync_api import expect

    expect.set_options(timeout=30000)
    base = stack["base"]
    context = browser.new_context(
        locale="en-US",
        viewport={"width": width, "height": 1000},
        is_mobile=width == 320,
        has_touch=width == 320,
    )
    if not context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok:
        assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    preferences = api("get", "/ui/preferences")
    preferences.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
    api("put", "/ui/preferences", data=preferences)
    api("put", "/app/config", data={"external_url": stack["api_base"]})
    api("put", "/mcp/status", data={"enabled": False})
    slug = f"i18n-{theme_id}-{width}"
    name = f"Author endpoint {theme_id} {width}"
    page = context.new_page()
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(base + "/settings/mcp")
    if theme_id == "netflix":
        expect(page.locator("html")).to_have_attribute("data-theme", "netflix")
    expect(page.get_by_text("No MCP endpoints yet", exact=True)).to_be_visible()
    shots = REPO / ".tmp-uidev/i18n/mcp"
    shots.mkdir(parents=True, exist_ok=True)

    def shot(label):
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        _snapshot(page, shots / f"{theme_id}-{width}-{label}.png")
        page.screenshot(path=str(shots / f"{theme_id}-{width}-{label}.png"), animations="disabled")

    def saved(action, path):
        with page.expect_response(
            lambda r: path in r.url and r.request.method in ("POST", "PUT", "DELETE")
        ) as pending:
            action()
        assert pending.value.ok, pending.value.text()
        return pending.value.json()["data"]

    def stored():
        with sqlite3.connect(stack["data"] / "movieclaw.db") as db:
            return db.execute(
                "SELECT value_json FROM app_setting WHERE namespace='mcp.endpoints'"
            ).fetchone()[0]

    def rpc(token, method="tools/list", params=None):
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2026-07-28",
            "Mcp-Method": method,
        }
        if method == "tools/call":
            headers["Mcp-Name"] = params["name"]
        return context.request.post(
            stack["api_base"] + "/mcp/" + slug,
            headers=headers,
            data={
                "jsonrpc": "2.0",
                "id": 1,
                "method": method,
                "params": {
                    **(params or {}),
                    "_meta": {
                        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                        "io.modelcontextprotocol/clientInfo": {
                            "name": "i18n-browser",
                            "version": "1",
                        },
                        "io.modelcontextprotocol/clientCapabilities": {},
                    },
                },
            },
        )

    def token_field():
        return (
            page.get_by_role("button", name="Copy token", exact=True)
            .locator("..")
            .locator("span[title]")
            .get_attribute("title")
        )

    page.get_by_role("button", name="New endpoint", exact=True).click()
    page.get_by_role("textbox", name="Endpoint name", exact=True).fill(name)
    slug_field = page.get_by_role("textbox", name="URL slug", exact=True)
    slug_field.fill("BAD_slug")
    expect(slug_field).to_have_attribute("aria-invalid", "true")
    expect(
        page.get_by_text(
            "Use lowercase letters, digits and hyphens; do not start or end with a hyphen",
            exact=True,
        )
    ).to_be_visible()
    slug_field.fill(slug)
    page.get_by_placeholder("Search services…", exact=True).fill("jobs")
    expect(page.get_by_role("checkbox")).to_have_count(1)
    page.get_by_role("checkbox").check()
    page.get_by_role("button", name=re.compile("^Collapsed")).click()
    expect(page.locator("main aside")).to_contain_text("1 tool")
    page.get_by_role("button", name=re.compile("^Expanded")).click()
    expect(page.locator("main aside")).to_contain_text("jobs_list")
    page.get_by_role("button", name=re.compile("^Collapsed")).click()
    expect(page.locator("main aside")).not_to_contain_text("jobs_list")
    shot("create")
    created = saved(
        lambda: page.get_by_role("button", name="Create endpoint", exact=True).click(),
        "/mcp/endpoints",
    )
    endpoint_id = created["endpoint"]["id"]
    expect(
        page.get_by_role("heading", name=f"Save the token for “{name}”", exact=True)
    ).to_be_visible()
    token = token_field()
    assert token and token == created["token"]
    address = (
        page.get_by_role("button", name="Copy address", exact=True)
        .locator("..")
        .locator("span[title]")
        .get_attribute("title")
    )
    assert address == stack["api_base"] + "/mcp/" + slug
    expect(page.locator("pre")).to_contain_text(token)
    expect(page.locator("pre")).to_contain_text("--transport http")
    assert token not in stored()
    assert not created["endpoint"]["expand_tools"]
    assert rpc(token).status == 404
    # Token-bearing receipt is deliberately not saved as a screenshot.
    page.get_by_role("button", name="Saved · View endpoint", exact=True).click()
    page.get_by_role("button", name="Run self-check", exact=True).click()
    expect(
        page.get_by_text("Protocol handshake and tool definitions are working", exact=True)
    ).to_be_visible()
    expect(
        page.get_by_text(
            "MCP is disabled globally. All endpoints return HTTP 404 to external clients.",
            exact=True,
        )
    ).to_be_visible()
    page.get_by_role("button", name="All endpoints", exact=True).click()
    saved(lambda: page.get_by_role("switch", name="Enable MCP", exact=True).click(), "/mcp/status")
    listed = rpc(token)
    assert listed.status == 200, listed.text()
    assert [t["name"] for t in listed.json()["result"]["tools"]] == ["jobs"]
    called = rpc(
        token, "tools/call", {"name": "jobs", "arguments": {"command": "list", "params": {}}}
    )
    assert called.status == 200 and not called.json()["result"]["isError"], called.text()
    page.get_by_role("button" if width == 320 else "link", name=re.compile(re.escape(name))).click()
    page.locator("main").get_by_role("button", name=re.compile("^Tools")).click()
    page.locator("main li > button").filter(has_text="jobs").first.click()
    expect(page.get_by_role("button", name="Copy tool name", exact=True)).to_be_visible()
    expect(page.get_by_role("button", name="Copy call example", exact=True)).to_be_visible()
    shot("tools-collapsed")
    search = page.get_by_placeholder("Search tool names or descriptions", exact=True)
    search.fill("no-such-tool")
    expect(page.get_by_text("No tools match “no-such-tool”", exact=True)).to_be_visible()
    page.get_by_role("button", name="Clear search", exact=True).click()
    page.locator("main").get_by_role("button", name="Settings", exact=True).click()
    page.get_by_role("button", name=re.compile("^Expanded")).click()
    changed = saved(
        lambda: page.get_by_role("button", name="Save changes", exact=True).click(),
        f"/mcp/endpoints/{endpoint_id}",
    )
    assert changed["expand_tools"] and changed["services"] == ["jobs"]
    listed = rpc(token)
    assert listed.status == 200, listed.text()
    names = [t["name"] for t in listed.json()["result"]["tools"]]
    assert "jobs_list" in names and all(n.startswith("jobs_") for n in names)
    called = rpc(token, "tools/call", {"name": "jobs_list", "arguments": {}})
    assert called.status == 200 and not called.json()["result"]["isError"], called.text()
    page.locator("main").get_by_role("button", name="Overview", exact=True).click()
    page.get_by_role("button", name=re.compile("^(Run self-check|Check again)$")).click()
    expect(
        page.get_by_text("Protocol, tool definitions and API calls are working", exact=True)
    ).to_be_visible()
    shot("check")
    before = stored()
    previews = []
    for language in ("zh-Hans", "en"):
        page.goto(base + "/settings/appearance")
        control = page.get_by_test_id("language-settings").locator(f'input[value="{language}"]')
        control.check()
        expect(control).to_be_enabled()
        expect(page.locator("html")).to_have_attribute("lang", language)
        page.goto(base + f"/settings/mcp?endpoint={slug}&tab=tools")
        expect(page.get_by_role("heading", name=name, exact=True)).to_be_visible()
        expect(
            page.get_by_placeholder(
                "搜索工具名或说明"
                if language == "zh-Hans"
                else "Search tool names or descriptions",
                exact=True,
            )
        ).to_be_visible()
        previews.append(
            api("post", "/mcp/endpoints/preview", data={"services": ["jobs"], "expand_tools": True})
        )
        assert stored() == before
    assert previews[0] == previews[1]
    assert any(re.search(r"[\u3400-\u9fff]", tool["description"]) for tool in previews[0]["tools"])
    page.locator("main").get_by_role("button", name="Overview", exact=True).click()
    page.get_by_role("button", name="Rotate", exact=True).click()
    rotated = saved(
        lambda: page.get_by_role("button", name="Generate new token", exact=True).click(),
        f"/mcp/endpoints/{endpoint_id}/token",
    )
    expect(page.get_by_role("button", name="Copy token", exact=True)).to_be_visible()
    new_token = token_field()
    assert new_token == rotated["token"] and new_token != token and new_token not in stored()
    assert rpc(token).status == 401
    assert rpc(new_token).status == 200
    page.get_by_role("button", name="Saved · View endpoint", exact=True).click()
    saved(
        lambda: page.get_by_role("switch", name=f"Enable {name}", exact=True).click(),
        f"/mcp/endpoints/{endpoint_id}",
    )
    assert rpc(new_token).status == 404
    saved(
        lambda: page.get_by_role("switch", name=f"Enable {name}", exact=True).click(),
        f"/mcp/endpoints/{endpoint_id}",
    )
    assert rpc(new_token).status == 200
    page.locator("main").get_by_role("button", name="Settings", exact=True).click()
    confirm = page.get_by_role("textbox", name="Enter the endpoint slug to confirm", exact=True)
    confirm.fill("wrong-slug")
    expect(page.get_by_role("button", name="Delete endpoint", exact=True)).to_be_disabled()
    confirm.fill(slug)
    expect(page.get_by_role("button", name="Delete endpoint", exact=True)).to_be_enabled()
    page.get_by_role("button", name="Delete endpoint", exact=True).scroll_into_view_if_needed()
    page.evaluate("window.scrollBy(0, 200)")
    shot("delete")
    saved(
        lambda: page.get_by_role("button", name="Delete endpoint", exact=True).click(),
        f"/mcp/endpoints/{endpoint_id}",
    )
    expect(page.get_by_text("No MCP endpoints yet", exact=True)).to_be_visible()
    assert rpc(new_token).status == 404
    assert not errors, errors
    context.close()
