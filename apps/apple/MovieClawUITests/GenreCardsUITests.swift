import XCTest

/// 只读 NAS 验收：真实首页 → 横向类型卡 → 对应类型墙 → 返回。凭据只由环境传入。
final class GenreCardsUITests: XCTestCase {
    @MainActor
    func testMovieGenreCardAndFilteredWall() throws { try verify(kind: "movie") }

    @MainActor
    func testTVGenreCardAndFilteredWall() throws { try verify(kind: "tv") }

    @MainActor
    private func verify(kind: String) throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(["MC_TEST_SERVER", "MC_TEST_USERNAME", "MC_TEST_PASSWORD"].allSatisfy { !(env[$0] ?? "").isEmpty },
                          "需提供 MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD")
        let server = try XCTUnwrap(env["MC_TEST_SERVER"])
        let user = try XCTUnwrap(env["MC_TEST_USERNAME"])
        let password = try XCTUnwrap(env["MC_TEST_PASSWORD"])
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mcServer", server, "-mcUser", user, "-mcPass", password, "-mcRoute", "/library"]
        app.launch()
        XCTAssertTrue(app.buttons["library-more"].waitForExistence(timeout: 35))
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "genre-tile-\(kind)-"))
        let card = cards.firstMatch
        for _ in 0 ..< 22 {
            if card.exists, card.isHittable, card.frame.minY > 100, card.frame.maxY < app.frame.height - 100 { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(card.exists && card.isHittable, "首页应有可点的类型卡")
        capture(card, name: "iphone-\(kind)-geometry", directory: env["MC_SHOT_DIR"])
        XCTAssertEqual(card.frame.width, 236, accuracy: 1)
        XCTAssertEqual(card.frame.height, 150, accuracy: 1)
        XCTAssertTrue(card.label.contains(kind == "movie" ? "部电影" : "部剧集"))
        XCTAssertFalse(card.label.contains("最近入库"))
        let identifier = card.identifier
        let label = card.label
        // 图片是独立异步请求，给真实 NAS 一次解码和淡入的时间。
        Thread.sleep(forTimeInterval: 2)
        capture(card, name: "iphone-\(kind)", directory: env["MC_SHOT_DIR"])
        card.tap()
        let summary = app.staticTexts["kind-wall-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 25), "类型卡应进入筛选墙")
        let genreName = label.replacingOccurrences(of: "浏览", with: "").components(separatedBy: "，")[0]
        XCTAssertTrue(app.navigationBars[genreName].exists, "墙标题应与点击类型一致")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons[identifier].isHittable, "返回保留原类型行")
        app.terminate()
    }

    @MainActor
    private func capture(_ card: XCUIElement, name: String, directory: String?) {
        let screen = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screen)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory {
            let root = URL(fileURLWithPath: directory)
            try? screen.pngRepresentation.write(to: root.appendingPathComponent("\(name).png"))
            try? card.screenshot().pngRepresentation.write(to: root.appendingPathComponent("\(name)-card.png"))
        }
    }
}
