"""Network settings through Next, real API/SQLite, local HTTP and isolated process restarts."""

import os
import re
import signal
import subprocess
import sys
from contextlib import suppress

import pytest

from . import test_theme_device_class_browser as theme
from .test_i18n_content_browser import _change_language, _snapshot
from .test_library_manage_browser import REPO, WEB, _free_port, _wait_http

browser = theme.browser
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def stack(tmp_path_factory):
    root = tmp_path_factory.mktemp("network-browser")
    ports = set()
    while len(ports) < 3:
        ports.add(_free_port())
    api_port, initial_web_port, default_web_port = ports
    env = {
        **os.environ,
        "DATABASE_URL": f"sqlite+aiosqlite:///{root / 'data.db'}",
        "SECRET_KEY_FILE": str(root / "secret"),
        "SCHEDULER_ENABLED": "false",
        "METADATA_DIR": str(root / "metadata"),
        "LOG_DIR": str(root / "logs"),
        "MOVIECLAW_WEB_PORT_FILE": str(root / "config/web-port"),
        "MOVIECLAW_WEB_PORT": str(default_web_port),
        "MOVIECLAW_CODE_SOURCE": "baseline",
        "E2E_NETWORK_ROOT": str(root),
        "PYTHONPATH": f"{REPO / 'src'}:{REPO}",
        **{
            name: ""
            for key in ("ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY")
            for name in (key, key.lower())
        },
    }
    logs = []
    processes = []
    api_base = f"http://127.0.0.1:{api_port}"

    def stop():
        for process in processes:
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
        for process in processes:
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        processes.clear()

    def start(web_port):
        api_log = (root / f"api-{web_port}.log").open("w")
        web_log = (root / f"web-{web_port}.log").open("w")
        logs.extend([api_log, web_log])
        processes.append(
            subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "uvicorn",
                    "tests.e2e._network_api_launcher:app",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(api_port),
                ],
                cwd=REPO,
                env=env,
                stdout=api_log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        )
        _wait_http(api_base + "/api/v1/auth/bootstrap", 60)
        processes.append(
            subprocess.Popen(
                ["pnpm", "exec", "next", "dev", "--port", str(web_port)],
                cwd=WEB,
                env={
                    **env,
                    "MOVIECLAW_API_PROXY_TARGET": api_base,
                    "NEXT_DIST_DIR": ".next-network-e2e",
                },
                stdout=web_log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        )
        base = f"http://127.0.0.1:{web_port}"
        _wait_http(base + "/login", 120)
        return base

    def restart(web_port):
        stop()
        return start(web_port)

    try:
        yield {
            "base": start(initial_web_port),
            "api": api_base,
            "default_port": default_web_port,
            "root": root,
            "restart": restart,
        }
    finally:
        stop()
        for log in logs:
            log.close()


def test_proxy_mirrors_addresses_and_probe_results(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    assert context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/network"
    shots.mkdir(parents=True, exist_ok=True)

    def api(method, path, **kwargs):
        response = getattr(context.request, method)(base + "/api/v1" + path, **kwargs)
        assert response.ok, response.text()
        return response.json()["data"]

    def saved(action, suffix="/network/config"):
        with page.expect_response(
            lambda response: response.request.method == "PUT" and response.url.endswith(suffix)
        ) as completed:
            action()
        assert completed.value.ok, completed.value.text()
        return completed.value.json()["data"]

    def english():
        text = page.locator("main").inner_text()
        assert not re.search(r"[\u3400-\u9fff]", text), text
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        if page.viewport_size["width"] == 320:
            label = page.get_by_text("Proxy mode", exact=True)
            assert label.bounding_box()["width"] >= 180
            for name in ("Off", "Environment", "Manual"):
                box = page.get_by_role("button", name=name, exact=True).bounding_box()
                assert box["x"] >= 0 and box["x"] + box["width"] <= 320
            rows = page.locator('main div[class*="min-h-[56px]"]')
            overflow = rows.evaluate_all("""rows => rows.flatMap(row => {
                if (row.closest('[inert]')) return [];
                const boundary = row.getBoundingClientRect();
                const text = row.querySelector(':scope > .flex-1');
                const errors = text && text.getBoundingClientRect().width < 180
                    ? [{text: text.innerText.slice(0, 80), problem: 'narrow text'}] : [];
                for (const control of row.querySelectorAll('button, input')) {
                    const box = control.getBoundingClientRect();
                    if (box.width > 2 &&
                        (box.left < boundary.left - 1 || box.right > boundary.right + 1))
                        errors.push({text: control.innerText || control.getAttribute('aria-label'),
                            left: box.left, right: box.right, boundary: boundary.right});
                }
                return errors;
            })""")
            if overflow:
                _snapshot(page, shots / "row-overflow-en.png")
            assert not overflow, overflow

    for theme_id, width in (("silver", 1280), ("silver", 320), ("netflix", 1280), ("netflix", 320)):
        prefs = api("get", "/ui/preferences")
        prefs.update(theme=theme_id, theme_desktop=theme_id, theme_mobile=theme_id, language="en")
        api("put", "/ui/preferences", data=prefs)
        page.set_viewport_size({"width": width, "height": 1000})
        page.goto(base + "/settings/network")
        page.wait_for_function(
            "theme => (document.documentElement.dataset.theme || 'silver') === theme", arg=theme_id
        )
        expect(page.get_by_role("button", name="Manual", exact=True)).to_be_visible()
        english()
        _snapshot(page, shots / f"{theme_id}-{width}-proxy-en.png")
        page.get_by_role("button", name=re.compile("^TMDB mirrors")).click()
        expect(page.get_by_role("textbox", name="TMDB API address", exact=True)).to_be_visible()
        english()
        page.get_by_role(
            "textbox", name="TMDB API address", exact=True
        ).scroll_into_view_if_needed()
        _snapshot(page, shots / f"{theme_id}-{width}-mirrors-en.png")
        page.get_by_role("button", name="Add address", exact=True).click()
        draft = page.get_by_role("textbox", name="Address to add", exact=True)
        draft.fill("invalid-address")
        page.get_by_role("button", name="Save", exact=True).click()
        expect(
            page.get_by_text("The address must start with http:// or https://", exact=True)
        ).to_be_visible()
        draft.fill(f"https://{theme_id}-{width}.example.test")
        page.get_by_role("radio", name="Local (home)", exact=True).click()
        with page.expect_response(
            lambda response: (
                response.request.method == "POST" and response.url.endswith("/server/addresses")
            )
        ) as added:
            page.get_by_role("button", name="Save", exact=True).click()
        assert added.value.ok
        rows = api("get", "/server/addresses")["addresses"]
        item = next(row for row in rows if row["url"] == f"https://{theme_id}-{width}.example.test")
        assert item["kind"] == "lan" and item["source"] == "manual"
        english()
        with page.expect_response(
            lambda response: (
                response.request.method == "POST"
                and response.url.endswith("/server/addresses/remove")
            )
        ):
            page.get_by_role("button", name="Delete " + item["url"], exact=True).click()
        assert not any(
            row["url"] == item["url"] for row in api("get", "/server/addresses")["addresses"]
        )
        external = page.get_by_role("textbox", name="External access address", exact=True)
        external.fill("invalid-address")
        external.press("Enter")
        expect(
            page.get_by_text(
                "Enter a complete address starting with http:// or https://", exact=True
            )
        ).to_be_visible()
        url = f"https://external-{theme_id}-{width}.example.test"
        external.fill(url + "/")
        saved(lambda field=external: field.press("Enter"), "/app/config")
        assert api("get", "/app/config")["external_url"] == url

    prefs = api("get", "/ui/preferences")
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    api("put", "/ui/preferences", data=prefs)
    page.set_viewport_size({"width": 1280, "height": 1000})
    page.goto(base + "/settings/network")
    page.wait_for_function("(document.documentElement.dataset.theme || 'silver') === 'silver'")
    saved(lambda: page.get_by_role("button", name="Off", exact=True).click())
    page.get_by_role("button", name="Manual", exact=True).click()
    proxy = page.get_by_role("textbox", name="Proxy address", exact=True)
    proxy.fill("invalid-address")
    proxy.press("Enter")
    expect(
        page.get_by_text("The address must start with http://, socks5:// or socks5h://", exact=True)
    ).to_be_visible()
    assert api("get", "/network/config")["proxy_mode"] == "off"
    proxy.fill("http://127.0.0.1:1")
    saved(lambda: proxy.press("Enter"))
    assert api("get", "/network/config")["proxy_mode"] == "manual"
    saved(lambda: page.get_by_label("Use proxy for Image sources", exact=True).click())
    assert "image" not in api("get", "/network/config")["proxy_services"]
    page.get_by_role("button", name=re.compile("^TMDB mirrors")).click()
    image = page.get_by_role("textbox", name="TMDB Image address", exact=True)
    image.fill(stack["api"])
    config = saved(lambda: image.press("Enter"))
    assert config["tmdb_image_base_url"] == stack["api"] + "/t/p"
    image_row = page.get_by_text("Image sources", exact=True).locator("../..")
    with page.expect_response(lambda response: response.url.endswith("/network/test")) as tested:
        image_row.get_by_role("button", name="Test", exact=True).click()
    result = tested.value.json()["data"]
    assert result["ok"] and result["message_key"] == "settings.network.responses.http"
    assert result["message_params"]["status"] == 200
    state = context.request.get(stack["api"] + "/__lab/network/state").json()
    assert len(state["probes"]) == 1
    saved(lambda: page.get_by_label("Use proxy for Image sources", exact=True).click())
    with page.expect_response(lambda response: response.url.endswith("/network/test")) as tested:
        image_row.get_by_role("button", name="Test", exact=True).click()
    failure = tested.value.json()["data"]
    assert not failure["ok"] and failure["message_key"] == "settings.network.responses.failed"
    english()
    _snapshot(page, shots / "proxy-failure-en.png")
    saved(lambda: page.get_by_role("button", name="Environment", exact=True).click())
    expect(page.get_by_text("No proxy address found", exact=True)).to_be_visible()
    expect(page.get_by_label("Use proxy for Image sources", exact=True)).to_be_disabled()
    saved(lambda: page.get_by_role("button", name="Tsinghua mirror", exact=True).click())
    assert "tsinghua" in api("get", "/network/config")["pypi_index_url"]
    page.goto(base + "/library")
    page.evaluate("window.networkLanguageMarker = 913")
    _change_language(page, "zh-Hans")
    assert page.evaluate("window.networkLanguageMarker") == 913
    page.goto(base + "/settings/network")
    expect(page.get_by_role("button", name="清华镜像", exact=True)).to_be_visible()
    assert "tsinghua" in api("get", "/network/config")["pypi_index_url"]
    _snapshot(page, shots / "network-zh.png")
    assert not errors, errors
    context.close()


def test_listening_port_confirmation_and_real_isolated_restart(stack, browser):
    from playwright.sync_api import expect

    base = stack["base"]
    context = browser.new_context(locale="en-US", viewport={"width": 1280, "height": 1000})
    response = context.request.post(base + "/api/v1/auth/bootstrap", data=theme.ADMIN)
    assert response.status in (200, 409)
    assert context.request.post(base + "/api/v1/auth/login", data=theme.ADMIN).ok
    prefs = context.request.get(base + "/api/v1/ui/preferences").json()["data"]
    prefs.update(theme="silver", theme_desktop="silver", theme_mobile="silver", language="en")
    assert context.request.put(base + "/api/v1/ui/preferences", data=prefs).ok
    page = context.new_page()
    page.set_default_timeout(20_000)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    shots = REPO / ".tmp-uidev/i18n/network"
    shots.mkdir(parents=True, exist_ok=True)
    port_file = stack["root"] / "config/web-port"

    def state():
        return context.request.get(stack["api"] + "/__lab/network/state").json()

    def config():
        response = context.request.get(base + "/api/v1/app/config")
        assert response.ok, response.text()
        return response.json()["data"]

    page.goto(base + "/settings/network")
    page.wait_for_function("(document.documentElement.dataset.theme || 'silver') === 'silver'")
    port = page.get_by_role("textbox", name="Listening port", exact=True)
    expect(port).to_be_enabled()
    assert config()["web_port"] == stack["default_port"]
    port.fill("")
    port.press("Enter")
    expect(
        page.get_by_text(
            "Enter a port, or select “Restore default” to clear the setting", exact=True
        )
    ).to_be_visible()
    port.fill("70000")
    port.press("Enter")
    expect(page.get_by_text("Port must be an integer from 1 to 65535", exact=True)).to_be_visible()
    port.fill(str(stack["default_port"]))
    port.press("Enter")
    expect(page.get_by_text("This is already the current port", exact=True)).to_be_visible()
    port.fill("8000")
    page.get_by_role("button", name="Change", exact=True).click()
    with page.expect_response(
        lambda r: r.request.method == "PUT" and r.url.endswith("/app/port")
    ) as rejected:
        page.get_by_role("button", name="Confirm change", exact=True).click()
    assert rejected.value.status == 400
    assert state()["restarts"] == [] and not port_file.exists()

    used = {int(base.rsplit(":", 1)[1]), int(stack["api"].rsplit(":", 1)[1]), stack["default_port"]}
    target = _free_port()
    while target in used or target == 8000:
        target = _free_port()
    port.fill(str(target))
    page.get_by_role("button", name="Change", exact=True).click()
    expect(page.get_by_text("You are accessing port", exact=False)).to_be_visible()
    _snapshot(page, shots / "port-mapping-confirm-en.png")
    page.get_by_role("button", name="Cancel", exact=True).click()
    assert state()["restarts"] == [] and not port_file.exists()
    page.set_viewport_size({"width": 320, "height": 1000})
    port.fill(str(target))
    page.get_by_role("button", name="Change", exact=True).click()
    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
    _snapshot(page, shots / "port-mapping-confirm-320-en.png")
    with page.expect_response(
        lambda r: r.request.method == "PUT" and r.url.endswith("/app/port")
    ) as changed:
        page.get_by_role("button", name="Confirm change", exact=True).click()
    assert changed.value.ok
    expect(
        page.get_by_text(
            f"The listening port has changed to {target}. Restarting the app…", exact=True
        )
    ).to_be_visible()
    assert port_file.read_text().strip() == str(target)
    assert state()["restarts"] == [43]
    open_url = f"http://127.0.0.1:{target}"
    expect(page.get_by_role("link", name="Open " + open_url, exact=True)).to_have_attribute(
        "href", open_url
    )
    _snapshot(page, shots / "port-restarting-320-en.png")
    # The callback records the restart request; the test restarts both real processes explicitly.
    base = stack["restart"](target)
    stack["base"] = base
    page.get_by_role("link", name="Open " + open_url, exact=True).click()
    page.wait_for_url(re.compile(re.escape(open_url) + r"(?:/|$)"))
    assert (
        context.request.get(base + "/api/v1/auth/me").json()["data"]["username"]
        == theme.ADMIN["username"]
    )
    page.goto(base + "/settings/network")
    expect(page.get_by_role("textbox", name="Listening port", exact=True)).to_have_value(
        str(target)
    )
    assert config()["web_port_source"] == "setting"
    page.get_by_role(
        "button", name=f"Restore default ({stack['default_port']})", exact=True
    ).click()
    expect(
        page.get_by_text(
            "For Docker port mappings (bridge networking), also change "
            "the container-side port in Compose",
            exact=False,
        )
    ).to_be_visible()
    with page.expect_response(
        lambda r: r.request.method == "PUT" and r.url.endswith("/app/port")
    ) as restored:
        page.get_by_role("button", name="Confirm change", exact=True).click()
    assert restored.value.ok
    assert not port_file.exists() and state()["restarts"] == [43, 43]
    base = stack["restart"](stack["default_port"])
    stack["base"] = base
    page.goto(base + "/settings/network")
    expect(page.get_by_role("textbox", name="Listening port", exact=True)).to_have_value(
        str(stack["default_port"])
    )
    assert config()["web_port_source"] == "env"
    assert context.request.get(base + "/api/v1/auth/me").json()["data"]["role"] == "admin"
    assert state()["restarts"] == [43, 43]
    assert not errors, errors
    context.close()
