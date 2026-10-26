import SwiftUI

/// 滚动意图与几何结果分开：排版改变高度不能被误判为用户离开底部。
struct AgentTranscriptScroll {
    struct Viewport: Equatable {
        var nearBottom = true
        var offscreen = false
        var atBottom = true
        // 懒加载修正估算高度时，即使上面几个 Bool 不变，也要重新检查贴底。
        var contentHeight: CGFloat = 0
        var visibleHeight: CGFloat = 0
    }

    var followsLatest = true
    private(set) var viewport = Viewport()
    private var idle = true

    /// 返回 true 表示需要校正到最新内容。拖动 / 惯性期间只记状态，停止时再修复。
    mutating func update(viewport: Viewport) -> Bool {
        let resized = self.viewport.visibleHeight != viewport.visibleHeight
        self.viewport = viewport
        if idle, viewport.nearBottom { followsLatest = true }
        return restoreIfNeeded() || (idle && followsLatest && resized)
    }

    mutating func update(phase: ScrollPhase) -> Bool {
        idle = phase == .idle
        if phase == .tracking || phase == .interacting { followsLatest = false }
        if restoreIfNeeded() { return true }
        if idle, !followsLatest { followsLatest = viewport.nearBottom }
        return false
    }

    private mutating func restoreIfNeeded() -> Bool {
        guard idle else { return false }
        if viewport.offscreen {
            followsLatest = true
            return true
        }
        return followsLatest && !viewport.atBottom
    }
}
