import XCTest
import UIKit

/// scripts/agent-companion-lab.py --scroll-fixture：真实 API 回放 120 轮混排长会话。
final class AgentScrollUITests: XCTestCase {
    @MainActor private let app = XCUIApplication()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MC_TEST_SCROLL"] == "1")
        continueAfterFailure = false
    }

    @MainActor private func launch(session: String = "scroll-fixture") {
        app.launchArguments = ["--ui-testing", "-mcServer", "http://127.0.0.1:18831",
                               "-mcUser", "admin", "-mcPass", "moon-test-2026",
                               "-mcRoute", "/sessions/\(session)"]
        app.launch()
    }

    @MainActor private var latest: XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS '最新消息定位验收'")).firstMatch
    }

    @MainActor private func assertLatestVisible() {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: latest)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed,
                       "不触摸消息列也必须直接看到最新内容，不能只检查元素存在")
        XCTAssertFalse(app.buttons["agent-scroll-latest"].exists)
    }

    @MainActor func testPetDoesNotDarkenMessagesBehindIt() throws {
        launch(session: "pet-backdrop-fixture")
        assertLatestVisible()
        let pet = app.buttons["agent-companion"]
        XCTAssertTrue(pet.isHittable)
        let transcript = app.scrollViews["agent-transcript"]
        for index in 0..<2 {
            if index > 0 { transcript.swipeDown(velocity: .slow) }
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "pet-backdrop-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MC_SHOT_DIR"] {
                try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("pet-backdrop-\(index).png"))
            }
            // 进入时的消息末尾有正常留白；翻到长回复中间后再检查像素。
            guard index > 0 else { continue }
            // 长回复的气泡铺满宠物后方；轮廓外的原始灰底不能被底部渐隐压成黑色。
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let scale = CGFloat(image.width) / app.frame.width
            let sample = CGRect(x: pet.frame.minX - 32, y: pet.frame.maxY - 28, width: 24, height: 16)
            print("Pet backdrop sample: \(sample), screenshot scale: \(scale)")
            let crop = try XCTUnwrap(image.cropping(to: CGRect(x: sample.minX * scale, y: sample.minY * scale,
                                                               width: sample.width * scale, height: sample.height * scale)))
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            let darkest = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) }.min() ?? 0
            XCTAssertGreaterThanOrEqual(darkest, 28, "宠物旁的气泡底色应保持约 36/255，不应出现黑色渐隐")
            let brightest = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) }.max() ?? 0
            XCTAssertGreaterThanOrEqual(brightest, 200, "宠物轮廓外的白色正文也应清晰，不应被滚动边缘模糊")
        }
    }

    @MainActor func testGlassComposerKeepsDraftWhileHistoryScrollsUnderIt() {
        launch()
        assertLatestVisible()
        let input = app.descendants(matching: .any).matching(identifier: "agent-composer-input").firstMatch
        let transcript = app.scrollViews["agent-transcript"]
        input.tap()
        input.typeText("玻璃输入框验收：这段草稿应始终清晰、保留。")
        for index in 0..<3 {
            transcript.swipeDown(velocity: .slow)
            XCTAssertTrue(input.isHittable)
            XCTAssertEqual(input.value as? String, "玻璃输入框验收：这段草稿应始终清晰、保留。")
            XCTAssertTrue(app.buttons["agent-send"].isHittable)
            let screenshot = app.screenshot()
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = "glass-composer-scroll-\(index)"
            shot.lifetime = .keepAlways
            add(shot)
            if let directory = ProcessInfo.processInfo.environment["MC_SHOT_DIR"] {
                try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("glass-composer-scroll-\(index).png"))
            }
        }
        // 不发送测试草稿；再次聚焦验证 safeAreaBar 内的输入控件仍可编辑。
        input.tap()
        input.typeText("继续输入")
        XCTAssertTrue((input.value as? String)?.contains("继续输入") == true)
        app.terminate()
    }

    @MainActor func testLongHistoryOpensWithoutTouchAndReturnsToLatest() {
        for attempt in 0..<3 {
            launch()
            assertLatestVisible()
            let initialBottom = latest.frame.maxY
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "long-history-entry-\(attempt)"
            shot.lifetime = .keepAlways
            add(shot)

            let scroll = app.scrollViews["agent-transcript"]
            scroll.swipeDown(velocity: .slow)
            let jump = app.buttons["agent-scroll-latest"]
            XCTAssertTrue(jump.waitForExistence(timeout: 5))
            // 查看历史后不应被延迟的首次定位抢回底部。
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(jump.exists)
            XCTAssertFalse(latest.isHittable)
            jump.tap()
            assertLatestVisible()
            XCTAssertEqual(initialBottom, latest.frame.maxY, accuracy: 2,
                           "首次进入应与手动回到最新停在相同位置，不能只露出最后一段")
            app.terminate()
        }
    }

    @MainActor func testStoppedLongAnswerKeepsHorizontalGutterOnEntry() {
        launch(session: "scroll-stopped-fixture")
        assertLatestVisible()
        XCTAssertTrue(app.staticTexts["agent-turn-stopped"].exists)
        let transcript = app.scrollViews["agent-transcript"]
        let initialX = latest.frame.minX
        let initialBottom = app.staticTexts["agent-turn-stopped"].frame.maxY
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "stopped-answer-before-touch"
        before.lifetime = .keepAlways
        add(before)

        transcript.swipeDown(velocity: .slow)
        let jump = app.buttons["agent-scroll-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        assertLatestVisible()
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "stopped-answer-after-scroll"
        after.lifetime = .keepAlways
        add(after)
        XCTAssertGreaterThanOrEqual(initialX - transcript.frame.minX, 30,
                                    "首次进入也应保留 16pt 外边距和气泡内部留白")
        XCTAssertEqual(initialX, latest.frame.minX, accuracy: 1,
                       "手动滑动不应改变消息的横向位置")
        XCTAssertEqual(initialBottom, app.staticTexts["agent-turn-stopped"].frame.maxY, accuracy: 2,
                       "末尾状态也应在首次进入时完整贴底")
        app.terminate()
    }
    @MainActor func testStreamingDoesNotPullUserAwayFromHistory() {
        launch(session: "scroll-stream-fixture")
        assertLatestVisible()
        let input = app.descendants(matching: .any).matching(identifier: "agent-composer-input").firstMatch
        input.tap()
        assertLatestVisible()
        input.typeText("滚动验收新问题：请查看片库")
        app.buttons["agent-send"].tap()
        let agree = app.buttons["agent-consent-agree"]
        if agree.waitForExistence(timeout: 1) { agree.tap() }
        XCTAssertTrue(app.buttons["agent-stop"].waitForExistence(timeout: 10))
        let question = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '滚动验收新问题'")).firstMatch
        XCTAssertTrue(question.isHittable, "发送应滚到新问题")
        let scroll = app.scrollViews["agent-transcript"]
        scroll.swipeDown(velocity: .slow)
        scroll.swipeDown(velocity: .slow)
        let jump = app.buttons["agent-scroll-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["agent-send"].waitForExistence(timeout: 35))
        XCTAssertTrue(jump.exists, "流式完成也不能把正在翻历史的用户拉回底部")
        XCTAssertFalse(question.isHittable)
        jump.tap()
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '月夜放映室'")).firstMatch
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: answer)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed)
        XCTAssertFalse(jump.exists)
    }

}
