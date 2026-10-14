import SwiftUI

/// 滚动意图与几何结果分开：排版改变高度不能被误判为用户离开底部。
struct AgentTranscriptScroll {
    struct Viewport: Equatable {
        var nearBottom = true
        var offscreen = false
    }

    var followsLatest = true
    private(set) var viewport = Viewport()
    private var idle = true

    /// 返回 true 表示需要修复完全越界的位置。拖动 / 惯性期间只记状态，停止时再修复。
    mutating func update(viewport: Viewport) -> Bool {
        self.viewport = viewport
        if idle, viewport.nearBottom { followsLatest = true }
        return restoreIfNeeded()
    }

    mutating func update(phase: ScrollPhase) -> Bool {
        idle = phase == .idle
        if phase == .tracking || phase == .interacting { followsLatest = false }
        if restoreIfNeeded() { return true }
        if idle, !followsLatest { followsLatest = viewport.nearBottom }
        return false
    }

    private mutating func restoreIfNeeded() -> Bool {
        guard idle, viewport.offscreen else { return false }
        followsLatest = true
        return true
    }
}
