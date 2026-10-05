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
        XCTAssertEqual(card.frame.width, 196, accuracy: 1)
        XCTAssertEqual(card.frame.height, 196 * 150 / 236, accuracy: 1)
        XCTAssertEqual(card.frame.width / card.frame.height, 236 / 150, accuracy: 0.02)
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
        XCTAssertGreaterThan(cards.count, 1, "测试片库需至少两个类型")
        let nextCard = cards.element(boundBy: 1)
        let nextIdentifier = nextCard.identifier
        let nextX = nextCard.frame.minX
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let swipeStart = origin.withOffset(CGVector(dx: app.frame.width - 30, dy: card.frame.midY))
        let swipeEnd = origin.withOffset(CGVector(dx: app.frame.width - 238, dy: card.frame.midY))
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd, withVelocity: .slow, thenHoldForDuration: 0.3)
        let movedCard = app.buttons[nextIdentifier]
        XCTAssertLessThan(movedCard.frame.minX, nextX, "缩小后的类型行仍可横向浏览")
        XCTAssertTrue(movedCard.isHittable)
        capture(movedCard, name: "iphone-\(kind)-next", directory: env["MC_SHOT_DIR"])
        if cards.count > 2 {
            let thirdIdentifier = cards.element(boundBy: 2).identifier
            swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd, withVelocity: .slow, thenHoldForDuration: 0.3)
            let thirdCard = app.buttons[thirdIdentifier]
            XCTAssertTrue(thirdCard.isHittable)
            capture(thirdCard, name: "iphone-\(kind)-third", directory: env["MC_SHOT_DIR"])
        }
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
