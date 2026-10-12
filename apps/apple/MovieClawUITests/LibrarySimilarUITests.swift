import XCTest

/// 库内条目详情的「相似推荐」：滑到相似推荐一行，点第一张进那一部；那一部的相似推荐里有原来那部
/// （同系列 / 同导演的片互为最像）。对着隔离的测试服务器跑，需要：
/// - MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD；
/// - MC_TEST_SIMILAR_ROUTE：起点条目的站内路径（如 /library/1/item/13：《沙丘》）；
/// - MC_SHOT_DIR（可选）：截图同时落盘到这个目录。
final class LibrarySimilarUITests: XCTestCase {
    @MainActor
    func testSimilarRowOpensItem() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(["MC_TEST_SERVER", "MC_TEST_USERNAME", "MC_TEST_PASSWORD", "MC_TEST_SIMILAR_ROUTE"].allSatisfy { !(env[$0] ?? "").isEmpty },
                          "需提供 MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD / MC_TEST_SIMILAR_ROUTE")
        let route = try XCTUnwrap(env["MC_TEST_SIMILAR_ROUTE"])
        let origin = try XCTUnwrap(route.split(separator: "/").last)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mcServer", try XCTUnwrap(env["MC_TEST_SERVER"]),
                               "-mcUser", try XCTUnwrap(env["MC_TEST_USERNAME"]), "-mcPass", try XCTUnwrap(env["MC_TEST_PASSWORD"]),
                               "-mcRoute", route]
        app.launch()
        addUIInterruptionMonitor(withDescription: "通知权限") { alert in
            let deny = alert.buttons["不允许"]
            if deny.exists { deny.tap(); return true }
            return false
        }

        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library-similar-'"))
        let first = cards.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "详情页没有相似推荐")
        scroll(app, toReveal: first)
        XCTAssertFalse(app.buttons["library-similar-\(origin)"].exists, "相似推荐里不该有这一部自己")
        Thread.sleep(forTimeInterval: 2)
        snapshot("iphone-similar-row", directory: env["MC_SHOT_DIR"])

        first.tap()
        // 进了那一部：它的相似推荐里有原来那部（上一页压在导航栈里，层级里可能还在，不拿「没有自己」断言）
        let back = app.buttons["library-similar-\(origin)"]
        XCTAssertTrue(back.waitForExistence(timeout: 30), "进入的那一部的相似推荐里没有原来那部")
        scroll(app, toReveal: back)
        Thread.sleep(forTimeInterval: 2)
        snapshot("iphone-similar-next", directory: env["MC_SHOT_DIR"])
    }

    @MainActor
    private func scroll(_ app: XCUIApplication, toReveal element: XCUIElement) {
        for _ in 0 ..< 10 where !(element.isHittable && element.frame.maxY < app.frame.maxY - 80) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, "滑不到相似推荐一行")
    }

    @MainActor
    private func snapshot(_ name: String, directory: String?) {
        let screenshot = XCUIScreen.main.screenshot()
        if let directory {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
