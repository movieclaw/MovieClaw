import Foundation
import Testing
@testable import MovieClaw

struct MacScrollPerfTests {
    private let period = 1.0 / 120

    @Test func smoothFramesHaveNoHitches() {
        let summary = MacFrameMonitor.summarize(name: "s", source: "bench", intervals: Array(repeating: 8.33, count: 120),
                                                period: period, busy: [], duration: 1000)
        #expect(summary["hitches"] as? Int == 0)
        #expect(summary["dropped"] as? Int == 0)
        #expect(summary["hitch_ratio"] as? Double == 0)
    }

    @Test func lateFramesCountTheTimePastOnePeriod() {
        // 一秒里有一帧拖到 3 个周期（掉 2 帧），一帧 1.4 个周期（不算卡顿，但四舍五入不算掉帧）
        let periodMs = period * 1000
        var intervals = Array(repeating: periodMs, count: 116)
        intervals += [periodMs * 3, periodMs * 1.4]
        let summary = MacFrameMonitor.summarize(name: "s", source: "bench", intervals: intervals, period: period, busy: [20, 5],
                                                duration: 1000)
        #expect(summary["hitches"] as? Int == 1)
        #expect(summary["dropped"] as? Int == 2)
        let hitch = summary["hitch_ms"] as? Double ?? 0
        #expect(abs(hitch - periodMs * 2) < 0.02)
        #expect(summary["long_tasks"] as? Int == 1)
        #expect(summary["max_ms"] as? Double == (periodMs * 3 * 100).rounded() / 100)
    }

    @Test func emptySegmentIsZeroNotNaN() {
        let summary = MacFrameMonitor.summarize(name: "s", source: "user", intervals: [], period: period, busy: [], duration: 0)
        #expect(summary["hitch_ratio"] as? Double == 0)
        #expect(summary["p99_ms"] as? Double == 0)
    }
}
