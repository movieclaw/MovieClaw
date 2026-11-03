import SwiftUI
import Testing
@testable import MovieClaw

/// 首页「下拉二楼」的判定：线跟在这次拖动里刷新实际触发的位置后面；只认拖着拉过线后松手；
/// 刷新在拖动中改内边距不影响下拉量；上次进二楼留下的过线不带到下一次。
/// 静止时内容顶边在 116（iPhone 17 Pro 导航栏下沿），刷新转圈撑开 60；刷新触发点按机型取 183 / 274。
struct ReelsFloorTests {
    private let rest: CGFloat = 116

    private func begin(_ floor: ReelsFloor) {
        floor.scrolled(top: rest, inset: rest)
        _ = floor.phaseChanged(from: .idle, to: .interacting)
    }

    private func drag(_ floor: ReelsFloor, to pull: CGFloat) {
        floor.scrolled(top: rest + pull, inset: rest)
    }

    /// 拉到刷新触发点（系统在这时调 `.refreshable`）
    private func refresh(_ floor: ReelsFloor, at pull: CGFloat) {
        drag(floor, to: pull)
        floor.refreshTriggered()
    }

    @Test(arguments: [183, 274] as [CGFloat])
    func releasePastLineEnters(refreshAt: CGFloat) {
        let floor = ReelsFloor()
        begin(floor)
        refresh(floor, at: refreshAt)
        #expect(floor.reveal == 0)
        drag(floor, to: refreshAt + ReelsFloor.armBeyond - 1)
        #expect(!floor.armed)
        drag(floor, to: refreshAt + ReelsFloor.armBeyond + 10)
        #expect(floor.armed)
        #expect(floor.reveal == 1)
        #expect(floor.phaseChanged(from: .interacting, to: .decelerating))
    }

    @Test func refreshDistanceOnlyRefreshes() {
        let floor = ReelsFloor()
        begin(floor)
        refresh(floor, at: 183)
        drag(floor, to: 200)
        #expect(floor.reveal > 0)
        #expect(!floor.phaseChanged(from: .interacting, to: .decelerating))
    }

    /// iPad 上刷新要拉到 274 才触发：之前拉得再远也没有线，不会抢在刷新前面进二楼
    @Test func noLineBeforeRefresh() {
        let floor = ReelsFloor()
        begin(floor)
        drag(floor, to: 260)
        #expect(floor.reveal == 0)
        #expect(!floor.armed)
        #expect(!floor.phaseChanged(from: .interacting, to: .decelerating))
    }

    @Test func pushingBackBelowLineCancels() {
        let floor = ReelsFloor()
        begin(floor)
        refresh(floor, at: 183)
        drag(floor, to: 183 + ReelsFloor.armBeyond + 20)
        drag(floor, to: 183 + ReelsFloor.armBeyond - 20)
        #expect(!floor.armed)
        #expect(!floor.phaseChanged(from: .interacting, to: .decelerating))
    }

    @Test func flingBounceNeverArms() {
        let floor = ReelsFloor()
        // 甩到顶的回弹：不在拖动中，越界再大、刷新也触发了都不算
        floor.scrolled(top: rest + 300, inset: rest)
        floor.refreshTriggered()
        #expect(floor.refreshedAt == nil)
        #expect(!floor.armed)
        #expect(!floor.phaseChanged(from: .decelerating, to: .idle))
    }

    @Test func refreshInsetDuringDragKeepsPull() {
        let floor = ReelsFloor()
        begin(floor)
        refresh(floor, at: 183)
        // 刷新在手指还拖着时触发：系统把转圈的 60 点临时加进内边距
        floor.scrolled(top: rest + 190, inset: rest + 60)
        #expect(floor.pull == 190)
    }

    @Test func nextDragStartsDisarmed() {
        let floor = ReelsFloor()
        begin(floor)
        refresh(floor, at: 183)
        drag(floor, to: 183 + ReelsFloor.armBeyond + 10)
        #expect(floor.phaseChanged(from: .interacting, to: .decelerating))
        drag(floor, to: 0)
        _ = floor.phaseChanged(from: .decelerating, to: .idle)
        // 回来后往上滑列表（顶边没越界，下拉量一直是 0）：松手不能再进二楼
        _ = floor.phaseChanged(from: .idle, to: .interacting)
        #expect(!floor.armed)
        #expect(floor.refreshedAt == nil)
        #expect(!floor.phaseChanged(from: .interacting, to: .decelerating))
    }

    /// 进了片段（首页被盖住）就清掉这一次：返回首页时胶片不再挂着
    @Test func resetHidesStripOnReturn() {
        let floor = ReelsFloor()
        begin(floor)
        refresh(floor, at: 183)
        drag(floor, to: 183 + ReelsFloor.armBeyond + 10)
        #expect(floor.phaseChanged(from: .interacting, to: .decelerating))
        floor.reset()
        #expect(floor.reveal == 0)
        #expect(!floor.armed)
    }
}
