import SwiftUI
import Testing
@testable import MovieClaw

@MainActor
struct AgentTranscriptScrollTests {
    @Test func repairsInitialLayoutGapWhileFollowingLatest() {
        var scroll = AgentTranscriptScroll()
        let repair = scroll.update(viewport: .init(nearBottom: false, atBottom: false))
        #expect(repair, "首次排版仍有可见内容，但未到底部时也必须校正")
    }

    @Test func repairsSmallGapAndRepeatedLazyHeightChanges() {
        var scroll = AgentTranscriptScroll()
        // 距底部不足 120pt 不展示跳转按钮，但仍然需要准确贴底。
        let first = AgentTranscriptScroll.Viewport(atBottom: false, contentHeight: 1_000)
        let second = AgentTranscriptScroll.Viewport(atBottom: false, contentHeight: 1_200)
        #expect(first != second)
        let repairFirst = scroll.update(viewport: first)
        let repairSecond = scroll.update(viewport: second)
        let repairAligned = scroll.update(viewport: .init(contentHeight: 1_200))
        #expect(repairFirst)
        #expect(repairSecond)
        #expect(!repairAligned, "贴底后不能继续发滚动请求")
    }

    @Test func waitsForProgrammaticScrollToFinishBeforeRepairingGap() {
        var scroll = AgentTranscriptScroll()
        let animating = scroll.update(phase: .animating)
        let layout = scroll.update(viewport: .init(nearBottom: false, atBottom: false))
        let idle = scroll.update(phase: .idle)
        #expect(!animating)
        #expect(!layout)
        #expect(idle)
    }

    @Test func safeAreaResizeRealignsLatestButPreservesHistory() {
        var scroll = AgentTranscriptScroll()
        _ = scroll.update(viewport: .init(visibleHeight: 600))
        let composerAppeared = scroll.update(viewport: .init(visibleHeight: 727))
        #expect(composerAppeared, "输入区安全区生效后要重新定位，不能复用首次的滚动请求")
        _ = scroll.update(phase: .interacting)
        _ = scroll.update(viewport: .init(nearBottom: false, atBottom: false, visibleHeight: 727))
        _ = scroll.update(phase: .idle)
        let keyboardAppeared = scroll.update(viewport: .init(nearBottom: false, atBottom: false, visibleHeight: 400))
        #expect(!keyboardAppeared)
    }

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
        let result8 = scroll.update(viewport: .init(nearBottom: false, offscreen: false, atBottom: false))
        #expect(!result8)
        let result9 = scroll.update(phase: .idle)
        #expect(!result9)
        #expect(!scroll.followsLatest)
    }

    @Test func layoutGrowthKeepsIntentButUserReadingHistoryDoesNot() {
        var scroll = AgentTranscriptScroll()
        let result10 = scroll.update(viewport: .init(nearBottom: false, atBottom: false))
        #expect(result10)
        _ = scroll.update(phase: .animating)
        _ = scroll.update(phase: .idle)
        #expect(scroll.followsLatest, "估算高度变化不能取消首次贴底")
        _ = scroll.update(phase: .interacting)
        _ = scroll.update(phase: .idle)
        #expect(!scroll.followsLatest)
        let historyGrowth = scroll.update(viewport: .init(nearBottom: false, atBottom: false, contentHeight: 2_000))
        #expect(!historyGrowth)
        #expect(!scroll.followsLatest, "流式增长不能抢走历史阅读位置")
        _ = scroll.update(phase: .interacting)
        _ = scroll.update(viewport: .init(nearBottom: true))
        _ = scroll.update(phase: .idle)
        #expect(scroll.followsLatest, "用户回到底部后恢复跟随")
    }
}
