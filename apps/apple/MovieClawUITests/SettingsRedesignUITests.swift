import XCTest

/// 七个设置页的交互验收。只允许 8130 内存夹具，真实服务器不会被写入。
final class SettingsRedesignUITests: XCTestCase {
    private var probe: SettingsTestAPI!
    @MainActor private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MC_TEST_SETTINGS_FIXTURE"] == "1", env["MC_TEST_SERVER"] == "http://127.0.0.1:8130",
              let password = env["MC_TEST_PASSWORD"] else { throw XCTSkip("需要本地设置夹具") }
        continueAfterFailure = false
        probe = try SettingsTestAPI(server: "http://127.0.0.1:8130", username: "admin", password: password)
        try reset()
    }

    private func reset(_ mode: String = "connected") throws {
        try probe.request("POST", "/e2e/settings/reset", body: ["mode": mode])
    }

    @MainActor private func launch(_ route: String, largeText: Bool = false) {
        app.launchArguments = ["--ui-testing", "-mcServer", "http://127.0.0.1:8130", "-mcUser", "admin",
                               "-mcPass", ProcessInfo.processInfo.environment["MC_TEST_PASSWORD"]!, "-mcRoute", route]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
    }

    @MainActor private func tap(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 10)
        for _ in 0..<7 {
            let tab = app.tabBars.firstMatch
            if element.exists, element.isHittable, !tab.exists || !tab.isHittable || !element.frame.intersects(tab.frame) { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.exists && element.isHittable, "应能点按：\(element)")
        element.tap()
    }

    @MainActor private func toggle(_ id: String) {
        let row = app.switches[id]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        tap(row.switches.firstMatch.exists ? row.switches.firstMatch : row)
    }

    @MainActor private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ condition: () throws -> Bool) rethrows {
        for _ in 0..<40 {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(try condition())
    }

    private var writes: [[String: Any]] { (try? probe.getObject("/e2e/settings/state"))?["writes"] as? [[String: Any]] ?? [] }

    @MainActor private func discard() {
        tap(app.buttons["sheet-close"])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        tap(app.alerts.buttons["放弃修改"])
    }

    @MainActor func testFanartVerificationAndSourceDragSave() throws {
        launch("/settings/scrape")
        tap(app.buttons["scrape-card-sources"])
        XCTAssertFalse(app.buttons["scrape-save"].exists)
        toggle("scrape-fanart-enabled")
        let key = app.secureTextFields["scrape-fanart-key-input"]
        tap(key)
        key.typeText("fixture-valid-key")
        tap(app.buttons["scrape-fanart-verify"])
        XCTAssertTrue(app.buttons["scrape-fanart-key"].waitForExistence(timeout: 10))
        XCTAssertEqual(try probe.getObject("/scrape/fanart")["configured"] as? Bool, true)
        try wait { try (probe.getObject("/scrape/config")["setting"] as? [String: Any])?["fanart_enabled"] as? Bool == true }
        XCTAssertEqual(Set((writes.last?["body"] as? [String: Any] ?? [:]).keys), ["fanart_enabled"])
        let count = writes.count
        tap(app.buttons["scrape-source-poster"])
        let handle = app.images["scrape-image-source-drag-fanart"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.press(forDuration: 1, thenDragTo: app.images["scrape-image-source-drag-tmdb"])
        XCTAssertEqual(writes.count, count)
        tap(app.buttons["scrape-source-done"])
        try wait { try (probe.getObject("/scrape/config")["setting"] as? [String: Any])?["poster_source_order"] as? [String] == ["fanart", "tmdb"] }
        let body = try XCTUnwrap(writes.last?["body"] as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["poster_source_order"])
        XCTAssertFalse(app.buttons["scrape-source-done"].exists)
        snapshot("Fanart-来源已自动保存")
        tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["scrape-card-poster"])
        XCTAssertTrue(app.buttons["scrape-poster-lang-order-meta"].isEnabled)
        tap(app.buttons["sheet-close"])
        launch("/settings/scrape")
        tap(app.buttons["scrape-card-sources"])
        tap(app.buttons["scrape-source-poster"])
        XCTAssertLessThan(app.images["scrape-image-source-drag-fanart"].frame.minY, app.images["scrape-image-source-drag-tmdb"].frame.minY)
    }

    @MainActor func testFanartConfiguredKeyIsVisibleWithoutReplacingIt() throws {
        try reset("fanart-configured")
        launch("/settings/scrape")
        tap(app.buttons["scrape-card-sources"])
        tap(app.buttons["scrape-fanart-key"])
        let current = app.staticTexts["scrape-fanart-current-key"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.label.contains("••••1234"))
        XCTAssertEqual(app.secureTextFields["scrape-fanart-key-input"].placeholderValue, "输入新的 API Key")
        XCTAssertFalse(app.buttons["scrape-fanart-verify"].isEnabled)
        snapshot("Fanart-已有密钥与更换输入")
        tap(app.buttons["sheet-close"])
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(app.buttons["scrape-save"].exists)
        XCTAssertEqual(try probe.getObject("/scrape/fanart")["key_hint"] as? String, "1234")
        tap(app.buttons["scrape-fanart-key"])
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.label.contains("••••1234"))
    }

    @MainActor func testFanartInvalidKeyAndCancelledChanges() throws {
        try reset("fanart-invalid")
        launch("/settings/scrape")
        tap(app.buttons["scrape-card-sources"])
        tap(app.buttons["scrape-fanart-key"])
        let key = app.secureTextFields["scrape-fanart-key-input"]
        tap(key)
        key.typeText("invalid")
        tap(app.buttons["scrape-fanart-verify"])
        XCTAssertTrue(app.staticTexts["scrape-fanart-key-error"].waitForExistence(timeout: 10))
        XCTAssertEqual(try probe.getObject("/scrape/fanart")["key_hint"] as? String, "1234")
        snapshot("Fanart-验证失败保留输入")
        tap(app.buttons["sheet-close"])
        tap(app.alerts.buttons["放弃输入"])
        toggle("scrape-fanart-enabled")
        try wait { try (probe.getObject("/scrape/config")["setting"] as? [String: Any])?["fanart_enabled"] as? Bool == false }
        tap(app.navigationBars.buttons.firstMatch)
        XCTAssertEqual(Set((writes.last?["body"] as? [String: Any] ?? [:]).keys), ["fanart_enabled"])
    }

    @MainActor func testFanartStatusFailureAndLogoDrag() throws {
        try reset("fanart-status-failure")
        launch("/settings/scrape")
        tap(app.buttons["scrape-card-sources"])
        XCTAssertTrue(app.staticTexts["scrape-fanart-status-error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["scrape-fanart-enabled"].isEnabled)
        try reset("fanart-configured")
        tap(app.buttons["scrape-fanart-retry"])
        XCTAssertTrue(app.buttons["scrape-fanart-key"].waitForExistence(timeout: 10))
        tap(app.navigationBars.buttons.firstMatch)
        tap(app.buttons["scrape-card-logo"])
        let handle = app.images["scrape-logo-lang-drag-en"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.press(forDuration: 1, thenDragTo: app.images["scrape-logo-lang-drag-meta"])
        XCTAssertEqual(writes.count, 0)
        snapshot("Fanart-Logo语言拖拽")
        tap(app.buttons["scrape-save"])
        try wait { try (probe.getObject("/scrape/config")["setting"] as? [String: Any])?["logo_language_priority"] as? [String] == ["en", "meta", "orig", "null"] }
        XCTAssertEqual(Set((writes.last?["body"] as? [String: Any] ?? [:]).keys), ["logo_language_priority"])
    }

    @MainActor func testFanartSourceCancelAndLargeText() throws {
        try reset("fanart-configured")
        launch("/settings/scrape", largeText: true)
        tap(app.buttons["scrape-card-sources"])
        snapshot("Fanart-大字体图片服务")
        tap(app.buttons["scrape-source-poster"])
        tap(app.buttons["scrape-image-source-order-fanart"])
        tap(app.buttons["scrape-image-source-up-fanart"])
        snapshot("Fanart-大字体来源抽屉")
        discard()
        XCTAssertFalse(app.buttons["scrape-save"].exists)
        XCTAssertEqual(writes.count, 0)
    }

    @MainActor func testFanartEachSourceSavesIndependentlyAndFailureRetries() throws {
        try reset("fanart-configured")
        launch("/settings/scrape")
        tap(app.buttons["scrape-card-sources"])
        for (kind, moved, field) in [("backdrop", "fanart", "backdrop_source_order"),
                                    ("logo", "tmdb", "logo_source_order"),
                                    ("seasonPoster", "tmdb", "season_poster_source_order")] {
            tap(app.buttons["scrape-source-\(kind)"])
            tap(app.buttons["scrape-image-source-order-\(moved)"])
            tap(app.buttons["scrape-image-source-up-\(moved)"])
            tap(app.buttons["scrape-source-done"])
            try wait { try (probe.getObject("/scrape/config")["setting"] as? [String: Any])?[field] as? [String] == [moved, moved == "tmdb" ? "fanart" : "tmdb"] }
            XCTAssertEqual(Set((writes.last?["body"] as? [String: Any] ?? [:]).keys), [field])
        }
        tap(app.buttons["scrape-source-poster"])
        tap(app.buttons["scrape-image-source-order-fanart"])
        tap(app.buttons["scrape-image-source-up-fanart"])
        try probe.request("POST", "/e2e/settings/mode", body: ["mode": "save-failure"])
        tap(app.buttons["scrape-source-done"])
        XCTAssertTrue(app.staticTexts["scrape-source-save-error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["scrape-source-done"].exists)
        XCTAssertEqual((try probe.getObject("/scrape/config")["setting"] as? [String: Any])?["poster_source_order"] as? [String], ["tmdb", "fanart"])
        try probe.request("POST", "/e2e/settings/mode", body: ["mode": "connected"])
        tap(app.buttons["scrape-source-done"])
        try wait { try (probe.getObject("/scrape/config")["setting"] as? [String: Any])?["poster_source_order"] as? [String] == ["fanart", "tmdb"] }
        try probe.request("POST", "/e2e/settings/mode", body: ["mode": "save-failure"])
        toggle("scrape-fanart-enabled")
        XCTAssertTrue(app.alerts["保存失败"].waitForExistence(timeout: 10))
        tap(app.alerts.buttons["好"])
        XCTAssertEqual(app.switches["scrape-fanart-enabled"].value as? String, "1")
        XCTAssertEqual((try probe.getObject("/scrape/config")["setting"] as? [String: Any])?["fanart_enabled"] as? Bool, true)
    }

    @MainActor func testFanartKeySavedButEnableFailureCanRetry() throws {
        try reset("save-failure")
        launch("/settings/scrape")
        tap(app.buttons["scrape-card-sources"])
        toggle("scrape-fanart-enabled")
        let key = app.secureTextFields["scrape-fanart-key-input"]
        tap(key)
        key.typeText("fixture-valid-key")
        tap(app.buttons["scrape-fanart-verify"])
        let error = app.staticTexts["scrape-fanart-key-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("密钥已保存"))
        XCTAssertEqual(try probe.getObject("/scrape/fanart")["configured"] as? Bool, true)
        XCTAssertEqual((try probe.getObject("/scrape/config")["setting"] as? [String: Any])?["fanart_enabled"] as? Bool, false)
        try probe.request("POST", "/e2e/settings/mode", body: ["mode": "connected"])
        tap(app.buttons["scrape-fanart-verify"])
        try wait { try (probe.getObject("/scrape/config")["setting"] as? [String: Any])?["fanart_enabled"] as? Bool == true }
        XCTAssertEqual(writes.filter { $0["path"] as? String == "/scrape/fanart" }.count, 1)
        XCTAssertFalse(app.buttons["scrape-fanart-verify"].exists)
    }

    @MainActor func testCloudConnectionDetailsAndDisconnectCancel() throws {
        launch("/settings/cloud")
        tap(app.buttons["cloud-connected"])
        XCTAssertTrue(app.staticTexts["已授予权限"].waitForExistence(timeout: 5))
        snapshot("Cloud-连接详情")
        tap(app.buttons["sheet-close"])
        toggle("cloud-report-stats")
        try wait { try probe.getObject("/cloud")["report_stats"] as? Bool == false }
        tap(app.buttons["cloud-actions"])
        tap(app.buttons["cloud-disconnect"])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        tap(app.alerts.buttons["取消"])
        XCTAssertEqual(try probe.getObject("/cloud")["state"] as? String, "connected")
        XCTAssertFalse(writes.contains { $0["path"] as? String == "/cloud/disconnect" })
        snapshot("Cloud-连接状态")
    }

    @MainActor func testCloudConnectFailureKeepsDraft() throws {
        try reset("cloud-failure")
        launch("/settings/cloud")
        tap(app.buttons["cloud-connect"])
        let field = app.textFields["cloud-instance-name"]
        tap(field)
        field.typeText("客厅服务器")
        tap(app.buttons["cloud-connect-continue"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '验收：暂时无法连接云端'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "客厅服务器")
        snapshot("Cloud-失败保留草稿")
        tap(app.buttons["sheet-close"])
        tap(app.alerts.buttons["放弃"])
        XCTAssertTrue(app.buttons["cloud-connect"].waitForExistence(timeout: 5))
    }

    @MainActor func testCloudPairingOpensApprovalAfterSheetDismisses() throws {
        try reset("pairing")
        launch("/settings/cloud")
        tap(app.buttons["cloud-connect"])
        tap(app.buttons["cloud-connect-continue"])
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成", "关闭"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        snapshot("Cloud-官网批准")
        tap(done)
        XCTAssertTrue(app.staticTexts["cloud-user-code"].waitForExistence(timeout: 8))
        try probe.request("POST", "/e2e/settings/approve")
        XCTAssertTrue(app.buttons["cloud-connected"].waitForExistence(timeout: 10))
        snapshot("Cloud-配对完成")
    }

    @MainActor func testNetworkDraftValidationSaveAndTest() throws {
        let originalMode = try probe.getObject("/network/config")["proxy_mode"] as? String
        launch("/settings/network")
        snapshot("网络-首页")
        tap(app.buttons["network-proxy-settings"])
        tap(app.buttons["network-proxy-mode"])
        tap(app.buttons["手动"])
        let field = app.textFields["network-proxy-url"]
        tap(field)
        field.typeText("invalid")
        XCTAssertFalse(app.buttons["network-editor-save"].isEnabled)
        XCTAssertTrue(writes.isEmpty)
        discard()
        XCTAssertEqual(try probe.getObject("/network/config")["proxy_mode"] as? String, originalMode)
        tap(app.buttons["network-proxy-settings"])
        tap(app.buttons["network-proxy-mode"])
        tap(app.buttons["手动"])
        tap(field)
        field.typeText("socks5h://127.0.0.1:7891")
        tap(app.buttons["network-editor-save"])
        try wait { try probe.getObject("/network/config")["proxy_mode"] as? String == "manual" }
        tap(app.buttons["network-services"])
        tap(app.buttons["network-test-tmdb"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '验收连接成功'")).firstMatch.waitForExistence(timeout: 8))
        snapshot("网络-服务连通性")
    }

    @MainActor func testPlaybackDraftCancelAndSave() throws {
        launch("/settings/playback")
        toggle("playback-trickplay")
        try wait { try probe.getObject("/playback/policy")["trickplay_enabled"] as? Bool == false }
        tap(app.buttons["remote-transcode-settings"])
        toggle("remote-transcode-enabled")
        discard()
        XCTAssertEqual(try probe.getObject("/transcode-worker/config")["enabled"] as? Bool, false)
        tap(app.buttons["remote-transcode-settings"])
        toggle("remote-transcode-enabled")
        snapshot("播放-远程转码设置")
        tap(app.buttons["remote-transcode-save"])
        try wait { try probe.getObject("/transcode-worker/config")["enabled"] as? Bool == true }
        snapshot("播放-首页")
    }

    @MainActor func testScrapeScopedSaveCancelAndLargeText() throws {
        launch("/settings/scrape", largeText: true)
        tap(app.buttons["scrape-card-mirror"])
        XCTAssertFalse(app.buttons["scrape-save"].isEnabled)
        toggle("scrape-mirror_images")
        discard()
        XCTAssertTrue(writes.isEmpty)
        tap(app.buttons["scrape-card-mirror"])
        toggle("scrape-mirror_images")
        snapshot("刮削-目录写入-大字号")
        tap(app.buttons["scrape-save"])
        try wait { !writes.isEmpty }
        let body = try XCTUnwrap(writes.last?["body"] as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["mirror_images", "mirror_nfo", "mirror_episode_thumbs"]))
        XCTAssertEqual(body["mirror_images"] as? Bool, false)
        let setting = try XCTUnwrap(probe.getObject("/scrape/config")["setting"] as? [String: Any])
        XCTAssertEqual(setting["logo_language_priority"] as? [String], ["meta", "en", "orig", "null"])
        XCTAssertEqual(setting["language_priority"] as? [String], [])
        snapshot("刮削-首页-大字号")
    }

    @MainActor func testAISelectionCancelAndSave() throws {
        launch("/settings/ai")
        tap(app.buttons["ai-agent-model"])
        tap(app.buttons["ai-model-option-review-beta"])
        discard()
        XCTAssertEqual(try probe.getObject("/llm/defaults")["agent_model"] as? String, "review-alpha")
        tap(app.buttons["ai-agent-model"])
        tap(app.buttons["ai-model-option-review-beta"])
        snapshot("AI-模型选择")
        tap(app.buttons["ai-model-save"])
        try wait { try probe.getObject("/llm/defaults")["agent_model"] as? String == "review-beta" }
        XCTAssertTrue(app.buttons["ai-subtitle-model"].exists)
        snapshot("AI-首页")
    }

    @MainActor func testProviderDetailsEditAndCancel() throws {
        launch("/settings/llm")
        tap(app.buttons["llm-provider-901"])
        snapshot("模型接入-详情")
        tap(app.buttons["llm-provider-actions"])
        tap(app.buttons["llm-edit-901"])
        XCTAssertFalse(app.buttons["llm-form-save"].isEnabled)
        snapshot("模型接入-编辑")
        tap(app.buttons["sheet-close"])
        XCTAssertTrue(writes.isEmpty)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["llm-create"])
        tap(app.buttons["sheet-close"])
    }

    @MainActor func testMCPDetailsToolsAndDeleteCancel() throws {
        launch("/settings/mcp")
        tap(app.buttons["mcp-endpoint-review"])
        snapshot("MCP-端点详情")
        tap(app.buttons["mcp-detail-tools"])
        XCTAssertTrue(app.staticTexts["mcp-tools-count"].waitForExistence(timeout: 10))
        snapshot("MCP-工具目录")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app.buttons["mcp-detail-actions"])
        tap(app.buttons["mcp-detail-edit"])
        XCTAssertFalse(app.buttons["mcp-form-submit"].isEnabled)
        snapshot("MCP-编辑")
        tap(app.buttons["sheet-close"])
        tap(app.buttons["mcp-detail-actions"])
        tap(app.buttons["mcp-detail-delete"])
        XCTAssertFalse(app.buttons["mcp-delete"].isEnabled)
        tap(app.buttons["sheet-close"])
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor func testFailedSaveRetainsSheetAndPlaybackRollsBack() throws {
        try reset("save-failure")
        launch("/settings/scrape")
        tap(app.buttons["scrape-card-mirror"])
        toggle("scrape-mirror_images")
        tap(app.buttons["scrape-save"])
        XCTAssertTrue(app.descendants(matching: .any)["scrape-save-error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sheet-close"].exists)
        snapshot("刮削-保存失败保留草稿")
        launch("/settings/playback")
        toggle("playback-trickplay")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '验收：保存失败'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["playback-trickplay"].value as? String, "1")
        XCTAssertEqual(try probe.getObject("/playback/policy")["trickplay_enabled"] as? Bool, true)
    }
    @MainActor func testRemainingEditorsAndNavigation() throws {
        launch("/settings/scrape")
        for card in ["metaLanguage", "certCountry", "poster", "backdrop", "quality", "naming"] {
            tap(app.buttons["scrape-card-" + card])
            XCTAssertTrue(app.buttons["scrape-save"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["scrape-save"].isEnabled)
            snapshot("刮削-" + card)
            tap(app.buttons[card == "quality" || card == "naming" ? "scrape-cancel" : "sheet-close"])
        }
        XCTAssertTrue(writes.isEmpty)
        launch("/settings/network")
        tap(app.buttons["network-mirror"])
        XCTAssertTrue(app.textFields["network-mirror-api"].waitForExistence(timeout: 5))
        snapshot("网络-镜像")
        tap(app.buttons["sheet-close"])
        tap(app.buttons["network-external-access"])
        tap(app.buttons["network-external-url-settings"])
        XCTAssertTrue(app.textFields["network-external-url"].waitForExistence(timeout: 5))
        snapshot("网络-外部访问")
        tap(app.buttons["sheet-close"])
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor func testProviderAndMCPEditSave() throws {
        launch("/settings/llm")
        tap(app.buttons["llm-provider-901"])
        tap(app.buttons["llm-provider-actions"])
        tap(app.buttons["llm-edit-901"])
        let key = app.secureTextFields["llm-form-api-key"]
        tap(key)
        key.typeText("fixture-key-not-real")
        tap(app.buttons["llm-form-save"])
        try wait { writes.contains { $0["path"] as? String == "/llm/providers/901" } }
        XCTAssertTrue(app.buttons["llm-provider-actions"].waitForExistence(timeout: 10))
        launch("/settings/mcp?endpoint=review&tab=settings")
        let name = app.textFields["mcp-form-name"]
        tap(name)
        name.typeText("更新")
        let expected = name.value as? String
        tap(app.buttons["mcp-form-submit"])
        try wait {
            let endpoints = try probe.getObject("/mcp/status")["endpoints"] as? [[String: Any]]
            return endpoints?.first?["name"] as? String == expected
        }
        XCTAssertTrue(app.buttons["mcp-detail-actions"].waitForExistence(timeout: 10))
        snapshot("MCP-深链编辑已保存")
    }

    @MainActor func testMCPToolFailureAndRetry() throws {
        try reset("preview-failure")
        launch("/settings/mcp?endpoint=review&tab=tools")
        XCTAssertTrue(app.descendants(matching: .any)["mcp-tools-error"].waitForExistence(timeout: 15))
        snapshot("MCP-工具失败可重试")
        try reset()
        tap(app.buttons["mcp-tools-retry"])
        XCTAssertTrue(app.staticTexts["mcp-tools-count"].waitForExistence(timeout: 10))
    }

}
