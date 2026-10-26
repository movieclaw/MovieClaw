import XCTest

/// 资源结果甩到底不能被弹回（分组 / 列表）：使用 seed_torrent_group_scroll.py 的隔离快照。
/// MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD 指向该测试实例。
final class TorrentGroupScrollUITests: XCTestCase {
    @MainActor
    func testGroupedResultsScrollToBottom() throws {
        try run(list: false)
    }

    @MainActor
    func testListResultsScrollToBottom() throws {
        try run(list: true)
    }

    @MainActor
    private func run(list: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["MC_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("需要隔离测试实例及「分组滚动」快照")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "-mcServer", env["MC_TEST_SERVER"] ?? "http://localhost:3000",
            "-mcUser", env["MC_TEST_USERNAME"] ?? "admin", "-mcPass", password,
            "-mcRoute", "/library",
        ]
        app.launch()
        let search = app.navigationBars.buttons["open-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        let resourceMode = app.segmentedControls.buttons["资源"]
        XCTAssertTrue(resourceMode.waitForExistence(timeout: 30))
        resourceMode.tap()
        let history = app.buttons.matching(NSPredicate(format: "identifier == 'history-row' AND label CONTAINS '分组滚动'")).firstMatch
        guard history.waitForExistence(timeout: 15) else {
            throw XCTSkip("缺少「分组滚动」快照")
        }
        history.tap()
        XCTAssertTrue(app.buttons["torrent-group"].firstMatch.waitForExistence(timeout: 15))
        if list {
            app.buttons["torrent-view-menu"].tap()
            app.buttons["列表"].firstMatch.tap()
        }

        let last = app.buttons.matching(NSPredicate(format: "identifier == 'torrent-row' AND label CONTAINS '未识别样本 3'")).firstMatch
        let window = app.windows.firstMatch.frame
        for _ in 0 ..< 40 {
            app.swipeUp(velocity: .fast)
            if last.exists, last.frame.maxY <= window.maxY, last.frame.minY >= window.minY { break }
        }
        // 再往下甩几次、停稳后，最后一行仍应留在屏幕里（弹回时会被推出视口）
        for _ in 0 ..< 3 { app.swipeUp(velocity: .fast) }
        sleep(3)
        shot("分组到底")
        XCTAssertTrue(last.exists, "最后一行应已渲染")
        XCTAssertLessThanOrEqual(last.frame.maxY, window.maxY, "最后一行应在屏幕内：\(last.frame) / \(window)")
        XCTAssertGreaterThanOrEqual(last.frame.minY, window.minY)
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "资源分组-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
