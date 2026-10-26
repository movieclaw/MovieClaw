import XCTest

/// 真实首次发送流程。与小幕验收共用隔离 API，取消前不会创建服务端会话。
final class AgentAIConsentUITests: XCTestCase {
    @MainActor private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MC_TEST_COMPANION"] == "1",
                          "需要启动 scripts/agent-companion-lab.py")
        continueAfterFailure = false
    }

    @MainActor private var input: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "agent-composer-input").firstMatch
    }
    @MainActor private var agree: XCUIElement { app.buttons["agent-consent-agree"] }
    @MainActor private var cancel: XCUIElement { app.buttons["agent-consent-cancel"] }

    @MainActor private func launch(largeText: Bool = false) {
        app.launchArguments = ["--ui-testing", "-mcServer", "http://127.0.0.1:18831",
                               "-mcUser", "admin", "-mcPass", "moon-test-2026", "-mcRoute", "/new",
                               "-mc.agentAIConsent.v1", "NO"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 25))
    }

    @MainActor private func checkActions(largeText: Bool = false) {
        XCTAssertTrue(agree.waitForExistence(timeout: 5))
        XCTAssertTrue(agree.isHittable && cancel.isHittable)
        XCTAssertEqual(agree.frame.width, cancel.frame.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(agree.frame.height, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        if largeText {
            XCTAssertLessThan(agree.frame.maxY, cancel.frame.minY, "大字体时主操作在上方")
            XCTAssertEqual(agree.frame.minX, cancel.frame.minX, accuracy: 1)
        } else {
            XCTAssertLessThan(cancel.frame.maxX, agree.frame.minX, "取消在左，主操作在右")
            XCTAssertEqual(agree.frame.midY, cancel.frame.midY, accuracy: 1)
            XCTAssertLessThanOrEqual(agree.frame.height, 52, "常规字号应使用紧凑的系统按钮高度")
            XCTAssertLessThanOrEqual(cancel.frame.height, 52)
        }
        XCTAssertLessThanOrEqual(app.scrollViews["agent-consent-content"].frame.maxY, agree.frame.minY,
                                 "正文区域必须结束在操作区之前，不能透到按钮下面")
        XCTAssertLessThan(cancel.frame.maxY, app.frame.maxY - 8, "底部操作应避开屏幕边缘")
    }

    @MainActor private func snapshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["MC_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor func testCancelPreservesDraftThenAgreeSendsAndRemembers() {
        launch()
        let message = "今晚想看一部轻松的电影，请查一下片库"
        input.tap()
        input.typeText(message)
        app.buttons["agent-send"].tap()
        checkActions()
        snapshot("ai-consent-standard")
        cancel.tap()
        XCTAssertFalse(agree.exists)
        XCTAssertEqual(input.value as? String, message, "取消必须保留草稿")
        XCTAssertFalse(app.buttons["agent-stop"].exists, "取消不得启动 Agent")

        app.buttons["agent-send"].tap()
        checkActions()
        agree.tap()
        XCTAssertTrue(app.buttons["agent-stop"].waitForExistence(timeout: 10), "同意后才开始发送")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '月夜放映室'")).firstMatch.waitForExistence(timeout: 35))
        // 取消命令行测试覆盖值后，检查同意已持久化，下一次发送不再弹窗。
        app.terminate()
        app.launchArguments.removeLast(2)
        app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("[pet-stop] 再找一部电影")
        app.buttons["agent-send"].tap()
        XCTAssertTrue(app.buttons["agent-stop"].waitForExistence(timeout: 10))
        XCTAssertFalse(agree.exists)
        app.buttons["agent-stop"].tap()
    }

    @MainActor func testAccessibilityTextScrollsWhileActionsStayVisible() {
        launch(largeText: true)
        input.tap()
        input.typeText("查看片库")
        app.buttons["agent-send"].tap()
        checkActions(largeText: true)
        let before = agree.frame
        let disclosure = app.scrollViews["agent-consent-content"]
        XCTAssertTrue(disclosure.exists)
        disclosure.swipeUp()
        XCTAssertEqual(agree.frame, before, "滚动说明不应移动底部按钮")
        checkActions(largeText: true)
        snapshot("ai-consent-large-text")
        cancel.tap()
        XCTAssertEqual(input.value as? String, "查看片库")
    }
}
