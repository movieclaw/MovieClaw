"""模型接入的浏览器流程；需运行 Web 开发服务并设置 MOVIECLAW_WEB_TEST_URL。

浏览器的 API 请求转发给真实 FastAPI TestClient，配置保存在临时数据库；
模型请求经过真实 OpenAI SDK 与本机 HTTP 上游，无需外部账号。
"""

from __future__ import annotations

import json
import os
from urllib.parse import urlsplit

import pytest
from tests.api.test_llm import client, model_gateway  # noqa: F401

from movieclaw_llm.protocols import PROTOCOLS
from movieclaw_llm.protocols.openai_responses import OpenAIResponsesProtocol


@pytest.mark.integration
@pytest.mark.parametrize("width", [1440, 390])
def test_model_setup_in_browser(client, model_gateway, monkeypatch, tmp_path, width):  # noqa: F811
    web_url = os.environ.get("MOVIECLAW_WEB_TEST_URL")
    if not web_url:
        pytest.skip("设置 MOVIECLAW_WEB_TEST_URL 后运行浏览器验证")
    playwright = pytest.importorskip("playwright.sync_api")
    c, _ = client
    gateway_url, upstream = model_gateway
    monkeypatch.setitem(PROTOCOLS, "openai_responses", OpenAIResponsesProtocol)
    writes = []

    def api(route):
        request = route.request
        path = urlsplit(request.url).path
        if path == "/api/v1/jobs/stream":
            route.fulfill(status=200, body="", content_type="text/event-stream")
            return
        if path == "/api/v1/auth/bootstrap":
            data = {"initialized": True}
        elif path == "/api/v1/auth/me":
            data = {
                "username": "tester",
                "nickname": "tester",
                "avatar_url": None,
                "role": "admin",
                "capabilities": {
                    "allow_subscribe": True,
                    "allow_search": True,
                    "allow_direct_download": True,
                },
            }
        else:
            payload = request.post_data_json if request.post_data else None
            if path.startswith("/api/v1/llm") and request.method in ("POST", "PUT"):
                writes.append((path, payload))
            response = c.request(request.method, path, json=payload)
            route.fulfill(
                status=response.status_code,
                body=response.content,
                content_type=response.headers.get("content-type", "application/json"),
            )
            return
        route.fulfill(json={"success": True, "code": "OK", "message": "success", "data": data})

    with playwright.sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": width, "height": 1000})
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.route("**/api/v1/**", api)
        try:
            page.goto(f"{web_url}/settings/llm")
            page.get_by_role("button", name="接入供应商", exact=True).click()
            page.get_by_label("供应商", exact=True).select_option("openai")
            page.get_by_placeholder("https://api.openai.com/v1").fill(gateway_url)
            page.get_by_placeholder("sk-…", exact=True).fill("sk-browser-test")
            page.get_by_role("button", name="从端点获取模型列表").click()
            page.get_by_label("端点模型列表").select_option("gpt-6-luna")
            assert page.get_by_label("连接测试模型").input_value() == "gpt-6-luna"
            page.get_by_role("button", name="保存并测试连接").click()
            playwright.expect(page.get_by_text("已连接", exact=True)).to_be_visible()
            saved = c.get("/api/v1/llm/providers").json()["data"][0]
            assert saved["default_model"] == "gpt-6-luna"
            assert saved["status"] == "active"
            assert upstream[1][0] == "/v1/responses"

            # 编辑不会把用户选择重置为旗舰模型；留空密钥的查询仍可成功。
            page.get_by_role("button", name="编辑", exact=True).click()
            assert page.get_by_label("连接测试模型").input_value() == "gpt-6-luna"
            page.get_by_role("button", name="从端点获取模型列表").click()
            playwright.expect(page.get_by_text("端点返回 2 个模型。", exact=True)).to_be_visible()
            assert writes[-1][1]["api_key"] is None

            page.locator("summary").filter(has_text="高级设置").click()
            page.get_by_label("API 协议", exact=True).select_option("openai_chat")
            assert page.locator('#llm-test-model option[value="gpt-6-astra"]').count() == 0
            assert page.locator('#llm-test-model option[value="gpt-6.1-sol"]').count() == 0
            page.get_by_label("API 协议", exact=True).select_option("openai_responses")

            # 未知模型不猜测参数；仅声明推理强度，也能添加到官方实例。
            page.get_by_label("端点模型列表").select_option("my-local-model")
            page.get_by_placeholder("131072", exact=True).fill("131072")
            page.get_by_placeholder("8192", exact=True).fill("8192")
            control = page.locator("select").filter(has=page.locator('option[value="effort"]'))
            control.select_option("effort")
            page.get_by_label("低", exact=True).check()
            page.get_by_label("高", exact=True).check()
            page.get_by_role("button", name="添加到目录", exact=True).click()
            page.get_by_label("连接测试模型").select_option("my-local-model")
            page.screenshot(path=str(tmp_path / f"llm-form-{width}.png"), full_page=True)
            assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
            page.get_by_role("button", name="保存并测试连接").click()
            playwright.expect(page.get_by_text("已连接", exact=True)).to_be_visible()
            saved = c.get("/api/v1/llm/providers").json()["data"][0]
            assert saved["default_model"] == "my-local-model"
            assert saved["extra_models"][0]["thinking_levels"] == ["low", "high"]
            assert saved["extra_models"][0]["max_thinking_tokens"] is None

            # 同名 Kimi 在百炼与官方有不同规格，借用必须按选中的渠道取值。
            page.get_by_role("button", name="接入供应商", exact=True).click()
            page.get_by_label("供应商", exact=True).select_option("openai_compat")
            page.get_by_placeholder("http://192.168.1.5:8000/v1").fill(gateway_url)
            page.get_by_placeholder("sk-…", exact=True).fill("sk-compat-test")
            page.get_by_label("添加模型").select_option(
                json.dumps(["kimi", "kimi-k3"], separators=(",", ":"))
            )
            assert page.get_by_label("连接测试模型").input_value() == "kimi-k3"
            page.get_by_role("button", name="保存并测试连接").click()
            playwright.expect(page.get_by_role("button", name="编辑", exact=True)).to_have_count(2)
            rows = c.get("/api/v1/llm/providers").json()["data"]
            assert rows[1]["extra_models"][0]["thinking_control"]["kind"] == "effort"
            assert rows[1]["extra_models"][0]["default_output_tokens"] == 131072
            assert rows[1]["extra_models"][0]["max_output_tokens"] == 1048576
            assert not errors, errors
        finally:
            browser.close()
