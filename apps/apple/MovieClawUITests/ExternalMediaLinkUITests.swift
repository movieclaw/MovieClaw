import XCTest

/// 两处详情页 → 系统外链。需指定 MC_TEST_EXTERNAL_LIBRARY_ROUTE（含豆瓣 ID 的库内条目）。
/// MC_TEST_EXTERNAL_APP_BUNDLE 可指向注册 douban scheme 的模拟器测试 App；未指定时验证 Safari 回退。
final class ExternalMediaLinkUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor
    private func verifyDoubanLink(route: String) throws {
        guard let password = env["MC_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("需要 MC_TEST_PASSWORD 与提供豆瓣详情的测试服务器")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mcServer", env["MC_TEST_SERVER"] ?? "http://localhost:3000",
                               "-mcUser", env["MC_TEST_USERNAME"] ?? "admin", "-mcPass", password, "-mcRoute", route]
        app.launch()
        // 系统首次通知权限弹窗可能遮挡详情。
        addUIInterruptionMonitor(withDescription: "通知权限") { alert in
            let deny = alert.buttons["不允许"]
            if deny.exists { deny.tap(); return true }
            return false
        }
        let link = app.buttons["豆瓣 ↗"].firstMatch
        for _ in 0..<15 {
            if link.exists && link.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(link.waitForExistence(timeout: 15) && link.isHittable, "详情底部应有豆瓣链接")
        link.tap()
        let bundle = env["MC_TEST_EXTERNAL_APP_BUNDLE"] ?? "com.apple.mobilesafari"
        let target = XCUIApplication(bundleIdentifier: bundle)
        XCTAssertTrue(target.wait(for: .runningForeground, timeout: 15), "链接应打开目标 App 或回退浏览器")
        if bundle != "com.apple.mobilesafari" {
            let url = target.staticTexts["received-url"]
            XCTAssertTrue(url.waitForExistence(timeout: 5))
            XCTAssertEqual(url.label, "douban://douban.com/movie/\(env["MC_TEST_EXTERNAL_DOUBAN_ID"] ?? "1292052")")
            XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").state == .runningForeground)
        } else {
            let address = target.textFields.firstMatch
            XCTAssertTrue(address.waitForExistence(timeout: 10))
            address.tap()
            // 豆瓣会把移动端网页重定向到 m.douban.com/movie/subject/{id}/。
            let subjectAddress = target.textFields.matching(NSPredicate(
                format: "value CONTAINS %@ AND value CONTAINS %@", "douban.com", "subject/\(env["MC_TEST_EXTERNAL_DOUBAN_ID"] ?? "1292052")"
            )).firstMatch
            XCTAssertTrue(subjectAddress.waitForExistence(timeout: 5), "应回退到相同影片的网页：\(target.textFields.debugDescription)")
        }
        target.terminate()
    }

    @MainActor
    func testDiscoverDoubanLink() throws {
        try verifyDoubanLink(route: env["MC_TEST_EXTERNAL_MEDIA_ROUTE"] ?? "/media/douban/1292052")
    }

    @MainActor
    func testLibraryDoubanLink() throws {
        guard let route = env["MC_TEST_EXTERNAL_LIBRARY_ROUTE"], !route.isEmpty else {
            throw XCTSkip("需要 MC_TEST_EXTERNAL_LIBRARY_ROUTE")
        }
        try verifyDoubanLink(route: route)
    }
}
