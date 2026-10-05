import XCTest

/// 只读遥控器验收：类型行焦点、横向移动、确认进入类型墙、菜单返回。
final class TVGenreCardsUITests: XCTestCase {
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
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", try XCTUnwrap(env["MC_TEST_SERVER"]),
                               "-mcUser", try XCTUnwrap(env["MC_TEST_USERNAME"]), "-mcPass", try XCTUnwrap(env["MC_TEST_PASSWORD"])]
        app.launch()
        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 40))
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv-genre-\(kind)-"))
        let first = cards.firstMatch
        for _ in 0 ..< 24 {
            if first.exists && first.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(first.exists && first.hasFocus, "遥控器能抵达类型行")
        capture(first, name: "appletv-\(kind)-geometry", directory: env["MC_SHOT_DIR"])
        XCTAssertEqual(first.frame.width / first.frame.height, 16.0 / 9.0, accuracy: 0.02)
        XCTAssertTrue(abs(first.frame.width - 416 * 1.07) < 2 || abs(first.frame.width - 416) < 2, "实际焦点卡尺寸：\(first.frame)")
        XCTAssertTrue(first.label.contains(kind == "movie" ? "部电影" : "部剧集"))
        Thread.sleep(forTimeInterval: 2)
        capture(first, name: "appletv-\(kind)", directory: env["MC_SHOT_DIR"])
        let second = cards.element(boundBy: 1)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(second.hasFocus, "向右只移动到下一类型")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(first.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.element("tv-row-wall").waitForExistence(timeout: 25), "确认进入筛选墙")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(first.hasFocus, "返回后恢复类型焦点")
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
