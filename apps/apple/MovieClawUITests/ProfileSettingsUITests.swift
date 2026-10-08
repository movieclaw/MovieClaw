import XCTest

/// 所有账号写操作限定在 8130 内存夹具，密码与观看记录不会写入真实服务器。
final class ProfileSettingsUITests: XCTestCase {
    private var probe: SettingsTestAPI!
    @MainActor private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MC_TEST_SETTINGS_FIXTURE"] == "1", env["MC_TEST_SERVER"] == "http://127.0.0.1:8130",
              let password = env["MC_TEST_PASSWORD"] else { throw XCTSkip("需要本地设置夹具") }
        continueAfterFailure = false
        probe = try SettingsTestAPI(server: "http://127.0.0.1:8130", username: "admin", password: password)
        try probe.request("POST", "/e2e/settings/reset", body: ["mode": "profile"])
    }
    @MainActor private func launch(_ route: String = "/settings/profile", large: Bool = false) {
        app.launchArguments = ["--ui-testing", "-mcServer", "http://127.0.0.1:8130", "-mcUser", "admin",
                               "-mcPass", ProcessInfo.processInfo.environment["MC_TEST_PASSWORD"]!, "-mcRoute", route]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
    }
    @MainActor private func tap(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 10)
        for _ in 0..<8 {
            let tab = app.tabBars.firstMatch
            if element.exists, element.isHittable, !tab.exists || !tab.isHittable || !element.frame.intersects(tab.frame) { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.exists && element.isHittable)
        element.tap()
    }
    @MainActor private func replace(_ field: XCUIElement, _ value: String) {
        tap(field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        if let old = field.value as? String, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2))
        }
        if !value.isEmpty { field.typeText(value) }
    }
    @MainActor private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
    private func wait(_ predicate: () throws -> Bool) rethrows {
        for _ in 0..<40 {
            if try predicate() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(try predicate())
    }
    private var writes: [[String: Any]] { (try? probe.getObject("/e2e/settings/state"))?["writes"] as? [[String: Any]] ?? [] }
    private func mode(_ value: String) throws { try probe.request("POST", "/e2e/settings/mode", body: ["mode": value]) }
    @MainActor private func discard() {
        tap(app.buttons["sheet-close"])
        tap(app.alerts.buttons["放弃修改"])
    }

    @MainActor func testNicknameSaveCancelFailureAndMyPageSync() throws {
        launch("/my")
        tap(app.buttons["more-profile-card"])
        XCTAssertFalse(app.secureTextFields["profile-old-password"].exists)
        snapshot("个人信息-账号总览")
        tap(app.buttons["profile-nickname-edit"])
        XCTAssertFalse(app.buttons["profile-nickname-save"].isEnabled)
        let field = app.textFields["profile-nickname-field"]
        replace(field, "  ")
        XCTAssertFalse(app.buttons["profile-nickname-save"].isEnabled)
        replace(field, "周末影迷")
        try mode("profile-failure")
        tap(app.buttons["profile-nickname-save"])
        XCTAssertTrue(app.staticTexts["profile-nickname-error"].waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "周末影迷")
        XCTAssertEqual(try probe.getObject("/auth/me")["nickname"] as? String, "家庭影迷")
        try mode("profile")
        tap(app.buttons["profile-nickname-save"])
        try wait { try probe.getObject("/auth/me")["nickname"] as? String == "周末影迷" }
        XCTAssertTrue(app.staticTexts["profile-nickname-display"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profile-nickname-display"].label, "周末影迷")
        tap(app.navigationBars.buttons.firstMatch)
        XCTAssertTrue(app.buttons["more-profile-card"].label.contains("周末影迷"))
        tap(app.buttons["more-profile-card"])
        tap(app.buttons["profile-nickname-edit"])
        replace(field, "不保存的昵称")
        snapshot("个人信息-昵称编辑")
        let count = writes.count
        discard()
        XCTAssertEqual(writes.count, count)
        XCTAssertEqual(try probe.getObject("/auth/me")["nickname"] as? String, "周末影迷")
    }

    @MainActor func testPasswordValidationFailureRetryAndCurrentSession() throws {
        launch()
        tap(app.buttons["profile-password-edit"])
        XCTAssertFalse(app.buttons["profile-change-password"].isEnabled)
        let old = app.secureTextFields["profile-old-password"]
        let new = app.secureTextFields["profile-new-password"]
        let confirm = app.secureTextFields["profile-confirm-password"]
        tap(old)
        old.typeText(ProcessInfo.processInfo.environment["MC_TEST_PASSWORD"]!)
        tap(new)
        new.typeText("review-password")
        tap(confirm)
        confirm.typeText("wrong")
        XCTAssertFalse(app.buttons["profile-change-password"].isEnabled)
        XCTAssertTrue(app.staticTexts["profile-password-error"].exists)
        replace(confirm, "review-password")
        let paired = app.switches["profile-sign-out-paired"]
        XCTAssertEqual(paired.value as? String, "0")
        tap(paired.switches.firstMatch.exists ? paired.switches.firstMatch : paired)
        try mode("profile-failure")
        tap(app.buttons["profile-change-password"])
        XCTAssertTrue(app.staticTexts["profile-password-error"].waitForExistence(timeout: 10))
        XCTAssertTrue(old.exists && app.buttons["profile-change-password"].isEnabled)
        snapshot("个人信息-密码失败可重试")
        try mode("profile")
        tap(app.buttons["profile-change-password"])
        try wait { writes.filter { $0["path"] as? String == "/auth/password" }.count == 2 }
        XCTAssertTrue(app.buttons["profile-password-edit"].waitForExistence(timeout: 5))
        XCTAssertEqual((writes.last?["body"] as? [String: Any])?["sign_out_paired"] as? Bool, true)
        tap(app.buttons["profile-password-edit"])
        XCTAssertFalse(app.buttons["profile-change-password"].isEnabled)
        XCTAssertEqual(app.switches["profile-sign-out-paired"].value as? String, "0")
        snapshot("个人信息-密码编辑")
        tap(app.buttons["sheet-close"])
        XCTAssertTrue(app.staticTexts["profile-nickname-display"].exists)
    }

    @MainActor func testHistoryAndLogoutConfirmationAndAccountSwitcher() throws {
        launch()
        tap(app.buttons["profile-actions"])
        tap(app.buttons["profile-clear-history"])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        tap(app.alerts.buttons["取消"])
        XCTAssertTrue(writes.isEmpty)
        tap(app.buttons["profile-actions"])
        tap(app.buttons["profile-clear-history"])
        tap(app.alerts.buttons["清空"])
        try wait { writes.contains { $0["path"] as? String == "/playback/history" } }
        XCTAssertEqual((writes.last?["body"] as? [String: Any])?["query"] as? String, "scope=all")
        tap(app.buttons["logout"])
        XCTAssertTrue(app.alerts["退出当前账号？"].waitForExistence(timeout: 5))
        snapshot("个人信息-退出确认")
        tap(app.alerts.buttons["取消"])
        tap(app.buttons["profile-switch-account"])
        XCTAssertTrue(app.navigationBars["切换账号"].waitForExistence(timeout: 5))
        tap(app.buttons["关闭"])
        XCTAssertTrue(app.staticTexts["profile-nickname-display"].exists)
    }

    @MainActor func testAvatarPhotoUpload() throws {
        launch()
        tap(app.buttons["profile-avatar"])
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        snapshot("个人信息-系统相册")
        photo.tap()
        try wait { writes.contains { $0["path"] as? String == "/auth/avatar" } }
        XCTAssertEqual((writes.last?["body"] as? [String: Any])?["jpeg"] as? Bool, true)
        XCTAssertNotNil(try probe.getObject("/auth/me")["avatar_url"] as? String)
        snapshot("个人信息-更换头像")
    }

    @MainActor func testLargeTextNicknameAndPasswordCancel() throws {
        launch(large: true)
        snapshot("个人信息-大字体总览")
        tap(app.buttons["profile-nickname-edit"])
        replace(app.textFields["profile-nickname-field"], "大字号编辑")
        snapshot("个人信息-大字体昵称")
        discard()
        tap(app.buttons["profile-password-edit"])
        snapshot("个人信息-大字体密码")
        tap(app.secureTextFields["profile-old-password"])
        // 大字体下 LabeledContent 纵向排列，输入区位于合并的无障碍元素下半部。
        app.secureTextFields["profile-old-password"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        app.secureTextFields["profile-old-password"].typeText("cancel-only")
        discard()
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor func testSettingsRowGeometryAndSeparators() throws {
        launch()
        XCTAssertTrue(app.buttons["profile-nickname-edit"].waitForExistence(timeout: 10))
        let username = app.cells.containing(.staticText, identifier: "用户名").firstMatch
        let height = username.frame.height
        XCTAssertGreaterThanOrEqual(height, 44)
        for id in ["profile-nickname-edit", "profile-password-edit", "profile-switch-account", "logout"] {
            let row = app.cells.containing(.button, identifier: id).firstMatch
            for _ in 0..<5 where !row.isHittable { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.exists, id)
            XCTAssertEqual(row.frame.height, height, accuracy: 1, id)
        }
        app.swipeDown(velocity: .fast)
        snapshot("设置行-个人信息")
        launch("/settings")
        let settings = app.buttons["settings-devices"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let serverRow = app.cells.containing(.button, identifier: "settings-devices").firstMatch
        XCTAssertEqual(serverRow.frame.height, height, accuracy: 1)
        snapshot("设置行-服务器设置")
        launch("/settings/profile", large: true)
        XCTAssertTrue(app.buttons["profile-nickname-edit"].waitForExistence(timeout: 10))
        snapshot("设置行-大字号")
        XCTAssertGreaterThan(app.cells.containing(.button, identifier: "profile-nickname-edit").firstMatch.frame.height, height)
        launch("/settings", large: true)
        let largeRow = app.buttons["settings-devices"]
        XCTAssertTrue(largeRow.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            if largeRow.isHittable && largeRow.frame.maxY < app.tabBars.firstMatch.frame.minY { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(largeRow.isHittable)
        snapshot("设置行-服务器设置大字号")
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor func testSettingsSubpageLayouts() throws {
        for route in ["devices", "members", "notifications", "cloud", "network", "scrape", "playback", "llm", "mcp", "ai", "app", "im-push", "webhook"] {
            launch("/settings/\(route)")
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10), route)
            for cell in app.cells.allElementsBoundByIndex where cell.isHittable {
                XCTAssertGreaterThanOrEqual(cell.frame.minX, 0, route)
                XCTAssertLessThanOrEqual(cell.frame.maxX, app.frame.width, route)
            }
            snapshot("设置行-\(route)")
        }
        XCTAssertTrue(writes.isEmpty)
    }
}
