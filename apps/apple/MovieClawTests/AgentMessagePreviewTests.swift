import SwiftUI
import Testing
import UIKit
@testable import MovieClaw

@MainActor
struct AgentMessagePreviewTests {
    @Test func longMarkdownKeepsBubbleWidthWithinPreviewHeight() {
        let text = (1...30).map { "## Recommendation \($0)\n\n" + String(repeating: "A film worth watching. ", count: 15) + "\n\n- Story\n- Photography" }.joined(separator: "\n\n")
        for size in [CGSize(width: 346, height: 300), CGSize(width: 280, height: 180)] {
            let host = UIHostingController(rootView: AgentAnswerBubblePreview(text: text, size: size))
            let fitted = host.sizeThatFits(in: CGSize(width: 1000, height: 10000))
            #expect(abs(fitted.width - size.width) < 1)
            #expect(abs(fitted.height - size.height) < 1)
        }
    }

    @Test func shortReplyDoesNotExpandToHeightLimit() {
        let host = UIHostingController(rootView: AgentAnswerBubblePreview(text: "Hello", size: CGSize(width: 100, height: 300)))
        let fitted = host.sizeThatFits(in: CGSize(width: 1000, height: 10000))
        #expect(abs(fitted.width - 100) < 1)
        #expect(fitted.height < 100)
    }
}
