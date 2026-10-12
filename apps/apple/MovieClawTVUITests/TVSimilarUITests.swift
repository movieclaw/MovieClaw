import XCTest

/// 详情页「相似推荐」：遥控器往下走到相似推荐一行，按确认进那一部；那一部的相似推荐里有原来那部
/// （同系列 / 同导演的片互为最像）。对着隔离的测试服务器跑，环境变量经 TEST_RUNNER_ 前缀转交：
/// - MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD；
/// - MC_TEST_SIMILAR_ROUTE：起点条目「库id-条目id」（如 1-13：《沙丘》）；
/// - MC_SHOT_DIR：截图同时落盘到这个目录。
final class TVSimilarUITests: XCTestCase {
    @MainActor
    func testSimilarRowOpensItem() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(["MC_TEST_SERVER", "MC_TEST_USERNAME", "MC_TEST_PASSWORD", "MC_TEST_SIMILAR_ROUTE"].allSatisfy { !(env[$0] ?? "").isEmpty },
                          "需提供 MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD / MC_TEST_SIMILAR_ROUTE")
        let route = try XCTUnwrap(env["MC_TEST_SIMILAR_ROUTE"])
        let origin = try XCTUnwrap(route.split(separator: "-").last)
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", try XCTUnwrap(env["MC_TEST_SERVER"]),
                               "-mcUser", try XCTUnwrap(env["MC_TEST_USERNAME"]), "-mcPass", try XCTUnwrap(env["MC_TEST_PASSWORD"]),
                               "-mcTab", "item-\(route)"]
        app.launch()
        XCTAssertTrue(app.element("tv-item-play").waitForExistence(timeout: 30), "没有进入详情页")

        let focusedCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tv-similar-' AND hasFocus == true")).firstMatch
        moveDown(until: focusedCard)
        XCTAssertTrue(focusedCard.exists, "往下走不到相似推荐一行")
        let target = focusedCard.identifier
        XCTAssertNotEqual(target, "tv-similar-\(origin)", "相似推荐里不该有这一部自己")
        Thread.sleep(forTimeInterval: 2)
        snapshot("appletv-similar-row", directory: env["MC_SHOT_DIR"])

        XCUIRemote.shared.press(.select)
        // 进了那一部：它的相似推荐里有原来那部，且没有它自己
        let back = app.element("tv-similar-\(origin)")
        XCTAssertTrue(back.waitForExistence(timeout: 30), "进入的那一部的相似推荐里没有原来那部")
        XCTAssertFalse(app.element(target).exists, "相似推荐里不该有这一部自己")
        moveDown(until: back)
        XCTAssertTrue(back.hasFocus, "第二页往下走不到相似推荐一行")
        Thread.sleep(forTimeInterval: 2)
        snapshot("appletv-similar-next", directory: env["MC_SHOT_DIR"])
    }

    @MainActor
    private func moveDown(until element: XCUIElement) {
        for _ in 0 ..< 10 {
            if element.exists && element.hasFocus { return }
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 0.8)
        }
        // 落到这一行但不是这张卡：往右找
        for _ in 0 ..< 12 {
            if element.exists && element.hasFocus { return }
            XCUIRemote.shared.press(.right)
            Thread.sleep(forTimeInterval: 0.5)
        }
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
