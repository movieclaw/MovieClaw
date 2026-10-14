import SwiftUI
import Testing
@testable import MovieClaw

@MainActor
struct AgentAIConsentTests {
    @Test func narrowSheetKeepsLargeDisclosureInsideViewport() {
        for textSize in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
            let sheet = AgentAIConsentSheet(
                providers: [String(repeating: "测试模型服务商", count: 10)], onAgree: {}
            ).environment(\.dynamicTypeSize, textSize)
            let host = UIHostingController(rootView: sheet)
            let fitted = host.sizeThatFits(in: CGSize(width: 320, height: 568))
            #expect(fitted.width <= 320.5, "长说明不应撑宽弹窗")
            #expect(fitted.height <= 568.5, "大字体说明应滚动，不能撑出屏幕")
        }
    }
}
