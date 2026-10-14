import XCTest

/// 真实 App → 本地 HTTP 夹具 → 页面切换、详情跳转、会话操作与分页。
final class PersonalSpaceUITests: XCTestCase {
    @MainActor private lazy var app = XCUIApplication()
    private let server = "http://127.0.0.1:18842"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MC_TEST_PERSONAL_SPACE"] == "1",
                          "需要启动 tests/e2e/personal_space_fixture.py")
        continueAfterFailure = false
        var request = URLRequest(url: URL(string: server + "/e2e/reset")!)
        request.httpMethod = "POST"
        let done = expectation(description: "重置内存夹具")
        URLSession.shared.dataTask(with: request) { _, _, error in
            XCTAssertNil(error)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
    }

    @MainActor private func launch(user: String = "admin", large: Bool = false, reset: Bool = true) {
        app.launchArguments = ["--ui-testing", "-mcServer", server, "-mcUser", user,
                               "-mcPass", "fixture-only", "-mcRoute", "/my"]
        if reset { app.launchArguments += ["--reset-state"] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["more-profile-card"].waitForExistence(timeout: 25), app.debugDescription)
    }

    @MainActor private func tap(_ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), id)
        for _ in 0..<6 where !button.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(button.isHittable, id)
        button.tap()
    }

    @MainActor private func back() { app.navigationBars.buttons.firstMatch.tap() }

    @MainActor private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["MC_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor func testNavigationAndServerNotices() {
        launch()
        let title = app.navigationBars["我的"].staticTexts["我的"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertLessThan(title.frame.minX, app.frame.width / 3, "与其他根页面一致的左侧原生标题")
        let rows = app.buttons.matching(identifier: "more-session-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(rows.firstMatch.images.count, 0, "会话行只含标题与时间")
        XCTAssertLessThan(rows.firstMatch.frame.minY, app.frame.height * 0.6, "首屏应尽早显示会话")
        XCTAssertTrue(app.buttons["open-scanner"].isHittable)
        snapshot("personal-space-conversations")
        tap("more-profile-card")
        XCTAssertTrue(app.staticTexts["profile-nickname-display"].waitForExistence(timeout: 10))
        back()
        XCTAssertTrue(title.waitForExistence(timeout: 10), "返回后恢复原生导航标题")
        tap("more-tab-downloads")
        XCTAssertFalse(rows.firstMatch.exists)
        XCTAssertTrue(app.buttons["offline-settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["已下载"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["offline-storage-summary"].exists)
        XCTAssertFalse(app.buttons["more-downloads"].exists, "下载页签直接呈现管理内容")
        XCTAssertTrue(app.buttons["more-profile-card"].exists, "仍停在我的页面")
        snapshot("personal-space-downloads")
        tap("offline-settings")
        let cellular = app.buttons["使用蜂窝网络下载"]
        XCTAssertTrue(cellular.waitForExistence(timeout: 5))
        XCTAssertTrue(cellular.isEnabled)
        cellular.tap()
        tap("offline-settings")
        XCTAssertTrue(cellular.waitForExistence(timeout: 5))
        cellular.tap() // 还原设置，并收起菜单。
        tap("more-tab-server")
        XCTAssertTrue(app.buttons["more-update"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["more-notices"].waitForExistence(timeout: 10))
        let notices = app.buttons["more-notices"]
        let update = app.buttons["more-update"]
        snapshot("personal-space-server")
        XCTAssertEqual(notices.frame.minY, update.frame.minY, accuracy: 1, "服务器提醒并排对齐")
        XCTAssertEqual(notices.frame.width, update.frame.width, accuracy: 1)
        XCTAssertLessThan(notices.frame.maxX, update.frame.minX, "两个入口之间留有间隔")
        tap("more-notices")
        XCTAssertTrue(app.staticTexts["测试站点需要重新登录"].waitForExistence(timeout: 10))
        back()
        tap("more-settings")
        XCTAssertTrue(app.staticTexts["settings-description"].waitForExistence(timeout: 10))
        back()
        tap("more-update")
        XCTAssertTrue(app.buttons["app-actions"].waitForExistence(timeout: 10))
        tap("app-changelog")
        XCTAssertTrue(app.staticTexts["个人页验收更新说明"].waitForExistence(timeout: 10))
    }

    @MainActor func testQuickInputLeavesSettingsBottomReachable() {
        launch()
        tap("more-profile-card")
        let logout = app.buttons["logout"]
        XCTAssertTrue(logout.waitForExistence(timeout: 10))
        for _ in 0..<3 { app.swipeUp(velocity: .slow) }
        let input = app.descendants(matching: .any)["agent-composer-input"].firstMatch
        XCTAssertTrue(input.exists)
        snapshot("quick-profile-bottom")
        XCTAssertLessThan(logout.frame.maxY, input.frame.minY - 12, "退出登录应能完整滚到输入框上方")
        XCTAssertTrue(logout.isHittable)
        logout.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        back()
        tap("more-tab-server")
        tap("more-settings")
        let about = app.buttons["settings-about"]
        for _ in 0..<6 { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(about.exists && about.isHittable)
        snapshot("quick-settings-bottom")
        XCTAssertLessThan(about.frame.maxY, input.frame.minY - 12, "设置列表最后一项不能被输入框遮挡")
        about.tap()
        XCTAssertTrue(app.navigationBars["关于"].waitForExistence(timeout: 5))
        XCTAssertTrue(input.exists, "直接导航进入子页面仍保留快捷输入")
        for _ in 0..<3 { app.swipeUp(velocity: .slow) }
        let footer = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '影视资料与图片由你的服务器'")).firstMatch
        XCTAssertTrue(footer.exists)
        XCTAssertLessThan(footer.frame.maxY, input.frame.minY - 12, "多层导航后的说明文字也应完整可见")
        back()
        back()
        XCTAssertTrue(app.buttons["more-profile-card"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .textField).matching(identifier: "agent-composer-input").count, 1)
    }

    @MainActor func testQuickInputLeavesLargeTextProfileBottomReachable() {
        launch(large: true)
        tap("more-profile-card")
        XCTAssertTrue(app.navigationBars["个人信息"].waitForExistence(timeout: 5))
        let logout = app.buttons["logout"]
        for _ in 0..<8 { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(logout.waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any)["agent-composer-input"].firstMatch
        XCTAssertTrue(logout.isHittable && input.exists)
        XCTAssertLessThan(logout.frame.maxY, input.frame.minY - 12, "大字号下退出按钮仍须完整可见")
        snapshot("quick-profile-bottom-large-text")
    }

    @MainActor func testConversationActionsAndPagination() {
        launch()
        let row = app.buttons.matching(identifier: "more-session-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["今天"].exists)
        let next = app.buttons.matching(identifier: "more-session-row").element(boundBy: 1)
        XCTAssertGreaterThanOrEqual(row.frame.height, 44, "紧凑会话仍保留完整点击区域")
        XCTAssertLessThanOrEqual(next.frame.midY - row.frame.midY, 48, "单行会话应紧凑排列")
        snapshot("personal-space-compact-conversations")
        row.swipeLeft()
        XCTAssertTrue(app.buttons["重命名"].waitForExistence(timeout: 5))
        app.buttons["重命名"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["删除会话"].waitForExistence(timeout: 5))
        app.buttons["删除会话"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        let last = app.buttons.matching(NSPredicate(format: "identifier == 'more-session-row' AND label CONTAINS '会话 24'" )).firstMatch
        for _ in 0..<10 {
            if last.exists && last.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(last.exists && last.isHittable, "继续加载第二页会话")
        XCTAssertTrue(app.staticTexts["更早"].exists)
        snapshot("personal-space-pagination")
    }

    @MainActor func testMemberAndRestrictedCapabilities() {
        launch(user: "member")
        XCTAssertFalse(app.buttons["more-tab-conversations"].exists)
        XCTAssertTrue(app.buttons["offline-settings"].waitForExistence(timeout: 10))
        tap("more-tab-server")
        XCTAssertFalse(app.buttons["more-update"].exists)
        XCTAssertFalse(app.buttons["more-notices"].exists)
        snapshot("personal-space-member")
        launch(user: "restricted")
        XCTAssertFalse(app.buttons["more-tab-downloads"].exists)
        XCTAssertFalse(app.buttons["more-tab-server"].exists, "单一内容不显示切换栏")
        XCTAssertTrue(app.buttons["more-settings"].exists)
    }

    @MainActor func testAccessibilityTextKeepsSectionControlsUsable() {
        launch(large: true)
        for section in ["conversations", "downloads", "server"] {
            let button = app.buttons["more-tab-" + section]
            XCTAssertTrue(button.exists)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.width)
            tap("more-tab-" + section)
        }
        snapshot("personal-space-large-text")
        let settings = app.buttons["more-settings"]
        for _ in 0..<6 where !settings.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(settings.isHittable)
        let update = app.buttons["more-update"]
        for _ in 0..<6 where !update.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(update.isHittable)
        XCTAssertLessThanOrEqual(update.frame.maxX, app.frame.width - 16)
        snapshot("personal-space-server-large-refined")
    }

    /// 多条存档覆盖实际阅读场景：下载中、长片名、电影/剧集、滚动到容量面板和超大字号。
    @MainActor func testDownloadsReadingLayout() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MC_TEST_PERSONAL_DOWNLOADS_GALLERY"] == "1",
                          "先运行 seed_personal_downloads.py --gallery")
        launch(reset: false)
        tap("more-tab-downloads")
        XCTAssertTrue(app.buttons["offline-downloading-90051"].waitForExistence(timeout: 10))
        snapshot("personal-space-downloads-refined-top")
        let row = app.cells.containing(.any, identifier: "offline-storage-item-9003").firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable)
        XCTAssertGreaterThanOrEqual(row.frame.height, 90, "海报应保持完整的 2:3 比例")
        let title = row.staticTexts["碟中谍：致命清算（上）与漫长的最终任务"]
        XCTAssertTrue(title.exists)
        XCTAssertGreaterThan(title.frame.height, 30, "长标题可以自然换行")
        XCTAssertLessThanOrEqual(title.frame.maxX, row.frame.maxX - 20)
        snapshot("personal-space-downloads-refined-list")
        let summary = app.descendants(matching: .any)["offline-storage-summary"].firstMatch
        for _ in 0..<3 { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(summary.isHittable)
        let composer = app.descendants(matching: .any)["agent-composer-input"].firstMatch
        XCTAssertTrue(composer.exists)
        XCTAssertLessThanOrEqual(summary.frame.maxY + 16, composer.frame.minY,
                                 "容量面板与底部输入栏之间保留可见留白")
        snapshot("personal-space-downloads-refined-bottom")

        app.terminate()
        launch(large: true, reset: false)
        tap("more-tab-downloads")
        for _ in 0..<10 where !row.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable)
        XCTAssertGreaterThan(title.frame.height, 60, "辅助字号下长标题不强制截断")
        XCTAssertGreaterThanOrEqual(title.frame.minX, row.frame.minX)
        XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.width - 20)
        snapshot("personal-space-downloads-refined-large-text")
        for _ in 0..<10 {
            if summary.exists && summary.frame.maxY + 16 <= composer.frame.minY { break }
            app.swipeUp(velocity: .slow)
        }
        snapshot("personal-space-downloads-refined-large-storage")
        XCTAssertTrue(summary.isHittable)
        // 合并朗读的可访问区域包含整行；视觉面板的内缩另由截图检查。
        XCTAssertGreaterThanOrEqual(summary.frame.minX, 0)
        XCTAssertLessThanOrEqual(summary.frame.maxX, app.frame.width)
        XCTAssertLessThanOrEqual(summary.frame.maxY + 16, composer.frame.minY)
    }

    /// 用独立模拟器中的真实本机存档验证列表动作；不接触真机下载。
    @MainActor func testEmbeddedDownloadsActionsAndReturn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MC_TEST_PERSONAL_DOWNLOADS_SEEDED"] == "1",
                          "先运行 tests/e2e/seed_personal_downloads.py")
        launch(reset: false)
        tap("more-tab-downloads")
        let row = app.cells.containing(.any, identifier: "offline-storage-item-9001").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["more-profile-card"].exists)
        snapshot("personal-space-inline-downloaded")
        row.tap()
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["more-tab-downloads"].exists)
        back()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["more-tab-downloads"].isSelected, "影片详情返回后仍显示下载内容")
        row.swipeLeft()
        tap("删除")
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '删除（释放'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let cancel = app.buttons["取消"]
        if cancel.exists { cancel.tap() } else { app.otherElements["PopoverDismissRegion"].firstMatch.tap() }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.exists, "取消删除保留本机副本")
        row.press(forDuration: 1)
        tap("删除下载")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "确认删除立即更新当前页签")
        XCTAssertTrue(app.buttons["more-tab-downloads"].isSelected)
        snapshot("personal-space-inline-deleted")

        // 首页下载提示等现有链接仍可打开独立下载页。
        app.terminate()
        app.launchArguments[app.launchArguments.count - 1] = "/my/downloads"
        app.launch()
        XCTAssertTrue(app.navigationBars["下载"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(identifier: "offline-settings").count, 1)
        XCTAssertTrue(app.descendants(matching: .any)["offline-storage-summary"].exists)
    }
}
