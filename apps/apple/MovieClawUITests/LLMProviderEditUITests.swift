import XCTest

/// #1338 隔离端到端回归：针对本地合成 MovieClaw 服务 + 本地模拟 OpenAI 兼容供应商，
/// 验证在 iOS 上仅编辑供应商名称等无关字段时，已配置的连接测试模型（`gpt-6.2-sol`）
/// 不会被清空或回退到目录第一个模型（`gpt-6.1-sol`）。
///
/// 仅在显式开启 `MC_ISOLATED_LLM_EDIT_E2E=1` 且指向本机 `127.0.0.1` 隔离服务时执行，
/// 绝不触碰真实服务器或生产凭据。
final class LLMProviderEditUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"] ?? "" }
    private var username: String { env["MC_TEST_USERNAME"] ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"] ?? "" }

    private func requireIsolatedServer() throws -> URL {
        guard env["MC_ISOLATED_LLM_EDIT_E2E"] == "1",
              let url = URL(string: server),
              url.host == "127.0.0.1" || url.host == "localhost",
              !password.isEmpty
        else {
            throw XCTSkip("需要本机隔离服务（MC_ISOLATED_LLM_EDIT_E2E=1）")
        }
        return url
    }

    private func apiRequest(
        _ method: String,
        _ path: String,
        base: URL,
        token: String? = nil,
        body: [String: Any]? = nil
    ) throws -> [String: Any] {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let sem = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: HTTPURLResponse?
        var resultError: Error?
        URLSession.shared.dataTask(with: req) { data, response, error in
            resultData = data
            resultResponse = response as? HTTPURLResponse
            resultError = error
            sem.signal()
        }.resume()
        XCTAssertEqual(sem.wait(timeout: .now() + 20), .success, "请求超时：\(method) \(path)")
        if let resultError { throw resultError }
        let status = try XCTUnwrap(resultResponse?.statusCode)
        let data = try XCTUnwrap(resultData)
        XCTAssertTrue((200..<300).contains(status), "HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func login(base: URL) throws -> String {
        let res = try apiRequest("POST", "/api/v1/auth/device/login", base: base, body: [
            "username": username,
            "password": password,
            "client": [
                "kind": "ios",
                "installation_id": "ios-e2e-1338",
                "name": "iOS E2E 1338",
            ],
        ])
        let data = try XCTUnwrap(res["data"] as? [String: Any])
        return try XCTUnwrap(data["token"] as? String)
    }

    private func waitProviderSettled(id: Int, base: URL, token: String) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(20)
        var latest: [String: Any] = [:]
        while Date() < deadline {
            let res = try apiRequest("GET", "/api/v1/llm/providers/\(id)", base: base, token: token)
            if let data = res["data"] as? [String: Any] {
                latest = data
                let status = data["status"] as? String
                if status == "active" || status == "failed" {
                    return data
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return latest
    }

    @MainActor
    func testEditingUnrelatedFieldPreservesConfiguredTestModel() throws {
        let base = try requireIsolatedServer()
        continueAfterFailure = false
        let token = try login(base: base)

        let captureBefore = try apiRequest("GET", "/__e2e_1338/capture", base: base)
        let mockBaseUrl = try XCTUnwrap(captureBefore["mock_base_url"] as? String)

        let baseName = "合成中转-\(UUID().uuidString.prefix(6))"
        let editedName = "\(baseName)-已编辑"

        // 构造合成供应商实例：目录第一个是失效模型 gpt-6.1-sol，已配置测试模型是可用的 gpt-6.2-sol
        let createdRes = try apiRequest("POST", "/api/v1/llm/providers", base: base, token: token, body: [
            "name": baseName,
            "provider_type": "openai_compat",
            "base_url": mockBaseUrl,
            "api_key": "sk-synthetic-1338",
            "api_protocol": "openai_responses",
            "default_model": "gpt-6.2-sol",
            "extra_models": [
                ["id": "gpt-6.1-sol", "context_window": 1_050_000, "max_output_tokens": 128_000],
                ["id": "gpt-6.2-sol", "context_window": 1_050_000, "max_output_tokens": 128_000],
            ],
        ])
        let created = try XCTUnwrap(createdRes["data"] as? [String: Any])
        let providerId = try XCTUnwrap(created["id"] as? Int)
        defer { _ = try? apiRequest("DELETE", "/api/v1/llm/providers/\(providerId)", base: base, token: token) }

        let initial = try waitProviderSettled(id: providerId, base: base, token: token)
        XCTAssertEqual(initial["status"] as? String, "active", "初始合成实例使用 gpt-6.2-sol 应测试通过")
        XCTAssertEqual(initial["default_model"] as? String, "gpt-6.2-sol")

        _ = try apiRequest("POST", "/__e2e_1338/reset_capture", base: base)

        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-mcServer", server,
            "-mcUser", username,
            "-mcPass", password,
            "-mcRoute", "/settings/llm",
        ]
        app.launch()

        let row = app.buttons["llm-provider-\(providerId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "应列出合成供应商")
        row.tap()

        XCTAssertTrue(app.staticTexts["gpt-6.2-sol"].waitForExistence(timeout: 10), "详情页应显示已配置的 gpt-6.2-sol")

        let actions = app.buttons["llm-provider-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()

        let editButton = app.buttons["llm-edit-\(providerId)"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10))
        editButton.tap()

        // 仅编辑无关字段（实例名称）
        let nameField = app.textFields["llm-form-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("-已编辑")

        let saveButton = app.buttons["llm-form-save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))
        XCTAssertTrue(saveButton.isEnabled, "仅修改名称时应允许保存")
        saveButton.tap()

        // 等待保存表单关闭，然后核对服务端与模拟供应商收到的实际请求
        let predicate = NSPredicate(format: "exists == false")
        let dismissed = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: saveButton)], timeout: 15)
        XCTAssertEqual(dismissed, .completed, "保存后表单应关闭")

        let after = try waitProviderSettled(id: providerId, base: base, token: token)
        let captureAfter = try apiRequest("GET", "/__e2e_1338/capture", base: base)
        let puts = try XCTUnwrap(captureAfter["captured_puts"] as? [[String: Any]])
        let putBody = try XCTUnwrap(puts.last?["body"] as? [String: Any])
        let mockReqs = try XCTUnwrap(captureAfter["mock_requests"] as? [[String: Any]])
        let testedModels = mockReqs.compactMap { ($0["method"] as? String == "POST") ? ($0["model"] as? String) : nil }

        XCTAssertEqual(putBody["default_model"] as? String, "gpt-6.2-sol", "iOS 提交的 PUT 请求应回传已配置的测试模型")
        XCTAssertEqual(after["name"] as? String, editedName)
        XCTAssertEqual(after["default_model"] as? String, "gpt-6.2-sol", "编辑名称后测试模型不应被冲回 gpt-6.1-sol")
        XCTAssertEqual(after["status"] as? String, "active", "保留 gpt-6.2-sol 后重新测试应保持已连接")
        XCTAssertEqual(testedModels, ["gpt-6.2-sol"], "模拟供应商应只收到 gpt-6.2-sol 的连接测试请求")
        XCTAssertTrue(app.staticTexts["gpt-6.2-sol"].waitForExistence(timeout: 10), "详情页应继续显示 gpt-6.2-sol")
    }
}
