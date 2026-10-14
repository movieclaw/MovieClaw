import XCTest

/// 先运行 scripts/agent-companion-lab.py，再设置 TEST_RUNNER_MC_TEST_COMPANION=1 跑此组。
/// iPhone → 真实 API → Agent 工具执行 → SSE → 宠物与对话 UI，全程只使用隔离的本地测试模型。
final class AgentCompanionUITests: XCTestCase {
    private let server = "http://127.0.0.1:18831"
    @MainActor private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MC_TEST_COMPANION"] == "1",
                          "需要先启动独立的小幕验收服务")
        continueAfterFailure = false
    }

    @MainActor private func launch() {
        app.launchArguments = ["--ui-testing", "-mcServer", server, "-mcUser", "admin",
                               "-mcPass", "moon-test-2026", "-mcRoute", "/new"]
        app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 25))
        XCTAssertTrue(pet.exists)
    }

    @MainActor private var input: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "agent-composer-input").firstMatch
    }
    @MainActor private var pet: XCUIElement { app.buttons["agent-companion"] }
    @MainActor private var send: XCUIElement { app.buttons["agent-send"] }

    @MainActor private func waitForPose(_ pose: String, timeout: TimeInterval = 20) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", pose + "-"), object: pet)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: timeout), .completed,
                       "应显示 \(pose)，实际为 \(String(describing: pet.value))")
    }

    @MainActor private func waitForStill(_ pose: String) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", pose + "-still"), object: pet)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 8), .completed,
                       "短动作后应安静停在 \(pose)")
    }

    @MainActor private func assertStill(_ pose: String, seconds: TimeInterval) async throws {
        let until = Date().addingTimeInterval(seconds)
        let location = pet.frame
        while Date() < until {
            XCTAssertEqual(pet.value as? String, pose + "-still", "等待期间不应连续循环动作")
            XCTAssertEqual(pet.frame, location, "安静陪伴时身体不应移动")
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    @MainActor private func ask(_ text: String) {
        XCTAssertTrue(input.isHittable)
        input.tap()
        input.typeText(text)
        XCTAssertTrue(send.isEnabled && send.isHittable)
        send.tap()
        let agree = app.buttons["agent-consent-agree"]
        if agree.waitForExistence(timeout: 1) { agree.tap() }
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

    @MainActor func testSendToolsCompleteAndComposerLayout() {
        launch()
        waitForPose("idle")
        XCTAssertFalse(send.isEnabled)
        XCTAssertLessThan(pet.frame.maxY, input.frame.minY + 4, "爪子在输入框边缘，不能遮挡文字")
        XCTAssertTrue(pet.isHittable)
        pet.tap()
        snapshot("moon-idle")

        input.tap()
        input.typeText("今晚想看一部轻松的电影，请查一下片库")
        waitForPose("attentive")
        XCTAssertLessThan(pet.frame.maxY, app.keyboards.firstMatch.frame.minY)
        snapshot("moon-attentive")
        send.tap()
        let agree = app.buttons["agent-consent-agree"]
        if agree.waitForExistence(timeout: 1) { agree.tap() }
        waitForPose("working")
        XCTAssertTrue(app.buttons["agent-stop"].isHittable, "宠物不能阻挡停止")
        snapshot("moon-working")
        waitForPose("complete", timeout: 30)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "agent-answer-bubble").firstMatch.exists)
        snapshot("moon-complete")
        waitForPose("idle")

        // 宠物回到输入框后，模型和加号操作仍然可用。
        app.buttons["agent-composer-plus"].tap()
        XCTAssertTrue(app.buttons["agent-pick-image"].waitForExistence(timeout: 5))
        snapshot("moon-plus-menu")
    }

    @MainActor func testFailureThenFollowupAndStop() async throws {
        launch()
        ask("[pet-error] 帮我找电影")
        waitForPose("failed", timeout: 35)
        waitForStill("failed")
        try await assertStill("failed", seconds: 4)
        XCTAssertTrue(send.exists)
        snapshot("moon-failed")
        input.tap()
        input.typeText("[pet-stop] 重新查询片库")
        waitForPose("attentive")
        waitForStill("attentive")
        send.tap()
        waitForPose("working")
        app.buttons["agent-stop"].tap()
        waitForPose("idle")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "agent-turn-stopped").firstMatch.waitForExistence(timeout: 10))
        snapshot("moon-stopped")
    }

    @MainActor func testLongTaskSettlesAndOnlyBlinksOccasionally() async throws {
        launch()
        ask("[pet-stop] 慢慢查看片库")
        waitForPose("working")
        waitForStill("working")
        snapshot("moon-working-quiet")
        try await assertStill("working", seconds: 6)

        // 真实长任务中，15～25 秒才有一次短眨眼，不再重复整个啃鱼动作。
        let until = Date().addingTimeInterval(22)
        var blinked = false
        while Date() < until {
            if pet.value as? String == "working-animated" {
                blinked = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(blinked, "长时间等待时应偶尔眨眼")
        waitForStill("working")
        try await assertStill("working", seconds: 2)
        XCUIDevice.shared.press(.home)
        app.activate()
        waitForStill("working")
        try await assertStill("working", seconds: 2)
        app.buttons["agent-stop"].tap()
        waitForPose("idle")
        snapshot("moon-long-task-stopped")
    }

    @MainActor func testReducedMotionAndBackgroundResume() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MC_TEST_REDUCED_MOTION"] == "1",
                          "在开启减少动态效果的独立模拟器上运行")
        launch()
        waitForPose("idle")
        XCTAssertEqual(pet.value as? String, "idle-still")
        ask("[pet-stop] 查看电影")
        waitForPose("working")
        XCTAssertEqual(pet.value as? String, "working-still")
        XCUIDevice.shared.press(.home)
        app.activate()
        waitForPose("working")
        XCTAssertEqual(pet.value as? String, "working-still")
        app.buttons["agent-stop"].tap()
        waitForPose("idle")
        snapshot("moon-reduced-motion")
    }
}
