import AppKit
import QuartzCore

/// `-mcPerf YES` 时记录输入到主 RunLoop 下一次空闲的延迟；真正显示上屏与卡顿仍用 Instruments 验证。
enum MacPerformance {
    private static var monitor: Any?

    static func start() {
        guard PerfTrace.enabled, monitor == nil else { return }
        PerfTrace.afterCommit("app.firstCommit")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { event in
            let start = (event.timestamp - PerfTrace.processStart) * 1000
            let kind = event.type == .keyDown ? "key" : "click"
            let received = PerfTrace.now()
            PerfTrace.record("input.received", ["kind": kind, "start": start], at: received)
            PerfTrace.afterCommit("input.commit", ["kind": kind, "start": start, "received": received])
            return event
        }
    }
}
