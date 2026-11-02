import XCTest
import UIKit

/// scripts/agent-companion-lab.py --port 18954 --preview-fixture；MC_TEST_PREVIEW=1。
final class AgentMessagePreviewUITests: XCTestCase {
    @MainActor func testMarkdownMessagePreview() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MC_TEST_PREVIEW"] == "1")
        continueAfterFailure = false
        for kind in ["whole", "split"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-mcServer", "http://127.0.0.1:18954",
                                   "-mcUser", "admin", "-mcPass", "moon-test-2026",
                                   "-mcRoute", "/sessions/preview-\(kind)"]
            app.launch()
            let bubbles = app.descendants(matching: .any).matching(identifier: "agent-answer-bubble")
            XCTAssertTrue(bubbles.firstMatch.waitForExistence(timeout: 30))
            let scroll = app.scrollViews["agent-transcript"]
            scroll.swipeDown(velocity: .slow)
            let bubble = try XCTUnwrap(bubbles.allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.maxY > 220 && $0.frame.minY < app.frame.height - 250
            }, "没有可长按的回答正文")
            snapshot("\(kind)-message")
            let y = max(180, bubble.frame.minY + 30)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: bubble.frame.midX, dy: y)).press(forDuration: 1)
            XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
            snapshot("\(kind)-preview")
            let preview = app.otherElements["Preview"].firstMatch
            XCTAssertTrue(preview.exists)
            print("Preview \(kind): \(preview.frame), transcript: \(scroll.frame)")
            XCTAssertEqual(preview.frame.width, scroll.frame.width - 56, accuracy: 2,
                           "预览应保持会话的 16pt 两侧边距及助手右侧 24pt 留白")
            XCTAssertLessThanOrEqual(preview.frame.height, scroll.frame.height / 2 + 2)
            XCTAssertEqual(app.collectionViews.buttons.count, 1, "回答菜单应仅保留复制")
            let copy = app.buttons["Copy"]
            XCTAssertTrue(copy.isHittable)
            print("Copy \(kind): \(copy.frame)")
            let clipboardChanges = UIPasteboard.general.changeCount
            copy.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let dismissed = copy.waitForNonExistence(timeout: 5)
            print("Clipboard changes: \(clipboardChanges) -> \(UIPasteboard.general.changeCount)")
            if !dismissed {
                snapshot("\(kind)-copy-not-dismissed")
                print(app.debugDescription)
            }
            XCTAssertTrue(dismissed)
            XCTAssertGreaterThan(UIPasteboard.general.changeCount, clipboardChanges)
            app.terminate()
        }
    }

    @MainActor private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["MC_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
