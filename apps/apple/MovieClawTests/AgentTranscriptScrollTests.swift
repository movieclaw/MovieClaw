import SwiftUI
import Testing
@testable import MovieClaw

@MainActor
struct AgentTranscriptScrollTests {
    @Test func repairsOvershootWhenScrollingStopsWithoutAnotherGeometryChange() {
        var scroll = AgentTranscriptScroll()
        let result1 = scroll.update(phase: .animating)
        #expect(!result1)
        let result2 = scroll.update(viewport: .init(nearBottom: true, offscreen: true))
        #expect(!result2)
        // 旧实现只在几何 Bool 改变时检查；此时 Bool 不再改变，整页会一直空白。
        let result3 = scroll.update(phase: .idle)
        #expect(result3)
        #expect(scroll.followsLatest)
    }

    @Test func doesNotFightDraggingOrDeceleration() {
        var scroll = AgentTranscriptScroll()
        let result4 = scroll.update(phase: .tracking)
        #expect(!result4)
        #expect(!scroll.followsLatest)
        let result5 = scroll.update(phase: .interacting)
        #expect(!result5)
        let result6 = scroll.update(viewport: .init(nearBottom: false, offscreen: true))
        #expect(!result6)
        let result7 = scroll.update(phase: .decelerating)
        #expect(!result7)
        let result8 = scroll.update(viewport: .init(nearBottom: false, offscreen: false))
        #expect(!result8)
        let result9 = scroll.update(phase: .idle)
        #expect(!result9)
        #expect(!scroll.followsLatest)
    }

    @Test func layoutGrowthKeepsIntentButUserReadingHistoryDoesNot() {
        var scroll = AgentTranscriptScroll()
        let result10 = scroll.update(viewport: .init(nearBottom: false))
        #expect(!result10)
        _ = scroll.update(phase: .animating)
        _ = scroll.update(phase: .idle)
        #expect(scroll.followsLatest, "估算高度变化不能取消首次贴底")
        _ = scroll.update(phase: .interacting)
        _ = scroll.update(phase: .idle)
        #expect(!scroll.followsLatest)
        _ = scroll.update(viewport: .init(nearBottom: false))
        #expect(!scroll.followsLatest, "流式增长不能抢走历史阅读位置")
        _ = scroll.update(phase: .interacting)
        _ = scroll.update(viewport: .init(nearBottom: true))
        _ = scroll.update(phase: .idle)
        #expect(scroll.followsLatest, "用户回到底部后恢复跟随")
    }
}
