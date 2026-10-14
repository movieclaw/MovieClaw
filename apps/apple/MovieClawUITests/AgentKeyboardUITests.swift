import XCTest

/// .venv/bin/python apps/apple/scripts/agent-keyboard-lab.py
/// TEST_RUNNER_MC_TEST_KEYBOARD=1 scripts/test.sh -only-testing:MovieClawUITests/AgentKeyboardUITests
final class AgentKeyboardUITests: XCTestCase {
    @MainActor private let app = XCUIApplication()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MC_TEST_KEYBOARD"] == "1")
        continueAfterFailure = false
    }

    @MainActor private func launch(session: String = "keyboard-fixture") {
        app.launchArguments = ["--ui-testing", "-mcServer", "http://127.0.0.1:18841",
                               "-mcUser", "admin", "-mcPass", "keyboard-test-2026",
                               "-mcRoute", "/sessions/\(session)"]
        app.launch()
    }

    @MainActor func testLargeMarkdownKeyboardCycles() {
        keyboardCycles(session: "keyboard-fixture", lastLabel: "键盘循环验收：最后一段 Markdown。")
    }

    @MainActor func testLongHistoryKeyboardCycles() {
        keyboardCycles(session: "scroll-fixture", lastLabel: "最新消息定位验收：无需滑动即可看到这一句。")
    }

    @MainActor private func keyboardCycles(session: String, lastLabel: String) {
        launch(session: session)
        let last = app.staticTexts[lastLabel]
        XCTAssertTrue(last.waitForExistence(timeout: 30))
        XCTAssertTrue(last.isHittable)
        let input = app.descendants(matching: .any).matching(identifier: "agent-composer-input").firstMatch
        let transcript = app.scrollViews["agent-transcript"]
        let restingY = input.frame.minY
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertLessThan(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
            // 真实手势交互式收起键盘，同时进入历史阅读；不能用测试接口直接改焦点。
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertEqual(input.frame.minY, restingY, accuracy: 1)
            let jump = app.buttons["agent-scroll-latest"]
            if jump.exists { jump.tap() }
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: last)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed)
            let settled = last.frame
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(last.frame.minY, settled.minY, accuracy: 1, "收键盘后不能继续漂移")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(session)-after-keyboard-cycles"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testKeyboardDoesNotPullHistoryToLatest() {
        launch()
        let last = app.staticTexts["键盘循环验收：最后一段 Markdown。"]
        XCTAssertTrue(last.waitForExistence(timeout: 30))
        let transcript = app.scrollViews["agent-transcript"]
        transcript.swipeDown(velocity: .slow)
        transcript.swipeDown(velocity: .slow)
        let jump = app.buttons["agent-scroll-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any).matching(identifier: "agent-composer-input").firstMatch
        for _ in 0..<3 {
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(last.isHittable)
            XCTAssertTrue(jump.exists)
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertFalse(last.isHittable, "收起键盘不能把正在阅读的历史拉到末尾")
            XCTAssertTrue(jump.exists)
        }
        jump.tap()
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: last)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed)
    }
}
