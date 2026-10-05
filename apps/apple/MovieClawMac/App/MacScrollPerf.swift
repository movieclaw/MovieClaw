import AppKit
import QuartzCore

/// 滚动流畅度测量（`-mcPerf YES` 时开启，Release 可用；缺省关闭、零开销）。
///
/// **口径**（对齐 Apple 的 Hitch 定义，docs/perf/macos-scroll-smoothness.md）：
/// - 帧：主线程上的显示链路回调。相邻两次回调的 `timestamp`（垂直同步时刻）之差就是这一帧实际用了多久；
///   主线程被占住时回调跳过若干次垂直同步，差值成倍变大——这正是用户看到的「顿一下」。
/// - 卡顿时间（hitch time）：每帧超出一个刷新周期的部分之和（只计超过 1.5 个周期的帧）；
///   卡顿比（hitch ratio）= 卡顿时间 ÷ 区间时长，单位 ms/s。Apple：<5 好，5～10 可察觉，>10 严重。
/// - 主线程长任务：RunLoop 一次唤醒到下一次休眠之间连续忙的时长，超过一帧的逐个计数。
///
/// 区间（segment）两种来源：压测脚本（`MacScrollBench`）显式开合；真人滚动由滚轮事件自动开合
/// （最后一个滚动事件之后 0.3 秒没有新的就收口），真人用触控板滑也能出同一套数字。
/// 每个区间收口时写一条 `frames` 事件进 PerfTrace 的 JSONL，汇总脚本 `scripts/perf/mac_scroll_report.py`。
@MainActor
final class MacFrameMonitor: NSObject {
    static let shared = MacFrameMonitor()

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var observer: CFRunLoopObserver?
    private var wokeAt: CFTimeInterval = 0
    private var scrollMonitor: Any?
    private var current: Segment?
    /// 每一帧回调时要做的事（压测驱动按帧合成手势）
    var onFrame: ((CFTimeInterval) -> Void)?
    /// 真人滚动自动开区间（压测时关掉：合成事件的尾巴不另算一段）
    var autoSegments = true

    private final class Segment {
        let name: String
        let source: String
        let start = CACurrentMediaTime()
        var intervals: [Double] = []
        var period: Double = 1.0 / 120
        var busy: [Double] = []
        var lastActivity = CACurrentMediaTime()
        var events = 0

        init(name: String, source: String) {
            self.name = name
            self.source = source
        }
    }

    func start() {
        guard PerfTrace.enabled, link == nil else { return }
        // 显示链路挂在主窗口所在的屏幕上（ProMotion 屏 120Hz）；窗口还没出来就先用主屏
        let link = (NSApp.windows.first { $0.isVisible } ?? NSApp.mainWindow)?.displayLink(target: self, selector: #selector(tick(_:)))
            ?? NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link?.add(to: .main, forMode: .common)
        self.link = link

        // 主线程忙了多久：醒来 → 下一次准备休眠
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { [weak self] _, activity in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                guard let self else { return }
                if activity == .afterWaiting {
                    self.wokeAt = now
                } else if self.wokeAt > 0, let segment = self.current {
                    let busy = (now - self.wokeAt) * 1000
                    if busy >= 4 { segment.busy.append(busy) }
                    self.wokeAt = 0
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer

        // 真人滚动：看到滚轮事件就开一个区间（压测脚本自己的区间开着时不另开）
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.noteScroll(event)
            return event
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        if let segment = current {
            let period = link.targetTimestamp - link.timestamp
            if period > 0.002 { segment.period = period }
            if lastTimestamp > 0 { segment.intervals.append((timestamp - lastTimestamp) * 1000) }
            if segment.source == "user", CACurrentMediaTime() - segment.lastActivity > 0.3 { end() }
        }
        lastTimestamp = timestamp
        onFrame?(timestamp)
    }

    private func noteScroll(_ event: NSEvent) {
        if current == nil, autoSegments { begin("user.\(abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? "h" : "v")", source: "user") }
        guard let segment = current else { return }
        segment.events += 1
        segment.lastActivity = CACurrentMediaTime()
    }

    /// 开一个区间（已有区间先收口）
    func begin(_ name: String, source: String = "bench") {
        if current != nil { end() }
        current = Segment(name: name, source: source)
        lastTimestamp = 0
    }

    /// 收口当前区间，写出汇总
    @discardableResult
    func end() -> [String: any Sendable]? {
        guard let segment = current else { return nil }
        current = nil
        let summary = Self.summarize(name: segment.name, source: segment.source, intervals: segment.intervals, period: segment.period,
                                     busy: segment.busy, duration: (CACurrentMediaTime() - segment.start) * 1000)
        // 环境：系统负载与散热状态（同一构建在机器忙时数字会差很多，对比时据此剔除）
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        PerfTrace.record("frames", summary.merging([
            "events": segment.events, "load1": (load[0] * 100).rounded() / 100,
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        ]) { a, _ in a })
        return summary
    }

    /// 一个区间的帧指标（纯函数，单测覆盖）
    nonisolated static func summarize(name: String, source: String, intervals: [Double], period: Double, busy: [Double],
                                      duration: Double) -> [String: any Sendable] {
        let periodMs = period * 1000
        let sorted = intervals.sorted()
        func pct(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
        }
        let late = intervals.filter { $0 > periodMs * 1.5 }
        let hitch = late.reduce(0) { $0 + ($1 - periodMs) }
        let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / periodMs).rounded()) - 1) }
        let span = intervals.reduce(0, +)
        let round2 = { (value: Double) in (value * 100).rounded() / 100 }
        return [
            "seg": name, "source": source,
            "dur_ms": round2(span > 0 ? span : duration), "period_ms": round2(periodMs),
            "frames": intervals.count, "dropped": dropped,
            "drop_pct": round2(span > 0 ? Double(dropped) / (span / periodMs) * 100 : 0),
            "hitch_ms": round2(hitch), "hitch_ratio": round2(span > 0 ? hitch / (span / 1000) : 0),
            "hitches": late.count,
            "p50_ms": round2(pct(0.5)), "p95_ms": round2(pct(0.95)), "p99_ms": round2(pct(0.99)), "max_ms": round2(sorted.last ?? 0),
            "over33": intervals.filter { $0 > 33.4 }.count, "over50": intervals.filter { $0 > 50 }.count,
            "over100": intervals.filter { $0 > 100 }.count,
            "main_busy_pct": round2(span > 0 ? busy.reduce(0, +) / span * 100 : 0),
            "long_tasks": busy.filter { $0 > periodMs }.count, "long_task_max_ms": round2(busy.max() ?? 0),
        ]
    }
}

/// 滚动压测驱动（`-mcPerf YES -mcPerfBench "<脚本>"`）：在进程里按帧合成触控板手势（带 began/changed/ended 与惯性阶段，
/// 与真触控板发来的事件同一种），走事件队列派发，页面的滚动阶段、悬停暂停等逻辑与真人滑动时一样被触发。
///
/// 手势按墙钟时间推进：主线程卡住时下一帧补发这段时间该走的位移（同真触控板把积压的位移合并成一个事件），
/// 卡顿不会让脚本「变慢」从而掩盖卡顿。
///
/// 脚本用分号分隔，每条一个命令：
///
///     size 1440 900          主窗口调成这么大并移到主屏左上（点）
///     tab library-3          侧边栏选中一项（MainTab 的 rawValue）
///     pointer 760 500        把系统光标移到窗口里这一点（左上角原点，点）：真人滑动时指针停在内容上，悬停逻辑也要算进来
///     hpointer 1             指针放到屏上第 N 个横滑行（从上往下数，从 0 起）的中间
///     wait 3                 等几秒
///     seg 名字               开一个测量区间（下一个 seg / end 收口）
///     end                    收口当前区间
///     fling 0 3000           一次轻扫：手指 0.12 秒内以这个速度（点/秒，正 y = 往页面下方看，正 x = 往右看）划过、随后惯性减速
///     pos 名字               记下指针下各层滚动视图的位置（核对确实滚了多远）
///     drag 0 600 2           手指按住匀速拖：速度（点/秒）、时长（秒），停住再抬手，没有惯性
///     top                    滚回顶部（连发大位移，不计入测量）
///     click 640 300          在窗口这一点单击
///     shot 名字              截主窗口 → 容器 Library/Caches/perf/shots/名字.png
///     quit                   退出 App
@MainActor
final class MacScrollBench {
    static let shared = MacScrollBench()
    weak var router: MacRouter?
    private var pointer = CGPoint(x: 760, y: 500)
    private var frameWaiters: [CheckedContinuation<CFTimeInterval, Never>] = []
    private var framesSeen = 0
    private var aborted = false

    func startIfRequested() {
        guard PerfTrace.enabled, let script = UserDefaults.standard.string(forKey: "mcPerfBench"), !script.isEmpty else { return }
        MacFrameMonitor.shared.autoSegments = false
        MacFrameMonitor.shared.onFrame = { [weak self] timestamp in
            guard let self else { return }
            self.framesSeen += 1
            guard !self.frameWaiters.isEmpty else { return }
            let waiters = self.frameWaiters
            self.frameWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: timestamp) }
        }
        let commands = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { @MainActor in
            await FirstFrameGate.wait()
            for command in commands { await run(command) }
        }
    }

    private func nextFrame() async -> CFTimeInterval {
        await withCheckedContinuation { continuation in
            frameWaiters.append(continuation)
            // 锁屏、熄屏时显示链路不再回调：2 秒里一帧都没来就记下中止并退出，不让压测挂住
            let seen = framesSeen
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard framesSeen == seen, !aborted else { return }
                aborted = true
                PerfTrace.record("bench.abort", ["reason": "no display frames (screen locked or asleep?)"])
                MacFrameMonitor.shared.end()
                try? await Task.sleep(for: .seconds(0.3))
                NSApp.terminate(nil)
            }
        }
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    }

    private func run(_ command: String) async {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let numbers = arg.split(separator: " ").compactMap { Double($0) }
        PerfTrace.record("bench.cmd", ["cmd": command])
        switch parts[0] {
        case "size":
            guard numbers.count == 2, let window, let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            window.setFrame(CGRect(x: visible.minX, y: visible.maxY - numbers[1], width: numbers[0], height: numbers[1]),
                            display: true, animate: false)
        case "tab":
            if let tab = MainTab(rawValue: arg) { router?.searchText = ""; router?.select(tab) }
        case "pointer":
            guard numbers.count == 2 else { return }
            pointer = CGPoint(x: numbers[0], y: numbers[1])
            if let global = globalPoint(pointer) { CGWarpMouseCursorPosition(global) }
        case "hpointer":
            // 指针放到屏上第 N 个（从上往下、可见高度够的）横滑行中间
            guard let window, let content = window.contentView else { return }
            var rows: [CGRect] = []
            func collect(_ view: NSView) {
                if let scroll = view as? NSScrollView, let document = scroll.documentView,
                   document.frame.width > scroll.frame.width + 1 {
                    let frame = scroll.convert(scroll.bounds, to: content).intersection(content.bounds)
                    let flipped = CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
                    if flipped.height >= 120 { rows.append(flipped) }
                }
                view.subviews.forEach(collect)
            }
            collect(content)
            rows.sort { $0.minY < $1.minY }
            let index = Int(numbers.first ?? 0)
            guard rows.indices.contains(index) else { return PerfTrace.record("bench.hpointer", ["found": rows.count]) }
            pointer = CGPoint(x: rows[index].midX, y: rows[index].midY)
            if let global = globalPoint(pointer) { CGWarpMouseCursorPosition(global) }
            PerfTrace.record("bench.hpointer", ["found": rows.count, "x": pointer.x, "y": pointer.y])
        case "click":
            // 在窗口这一点（左上角原点）单击：端到端核对点卡片仍能进详情
            guard numbers.count == 2, let window, let content = window.contentView else { return }
            let location = CGPoint(x: numbers[0], y: content.bounds.height - numbers[1])
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let moved = event(.mouseMoved) { window.sendEvent(moved) }
            if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
            }
        case "wait":
            try? await Task.sleep(for: .seconds(numbers.first ?? 1))
        case "seg":
            MacFrameMonitor.shared.begin(arg)
        case "end":
            MacFrameMonitor.shared.end()
        case "fling":
            guard numbers.count == 2 else { return }
            await fling(CGVector(dx: numbers[0], dy: numbers[1]))
        case "drag":
            guard numbers.count == 3 else { return }
            await drag(CGVector(dx: numbers[0], dy: numbers[1]), seconds: numbers[2])
        case "top":
            for _ in 0 ..< 30 { post(CGVector(dx: 0, dy: -4000), phase: 0, momentum: 0) }
            try? await Task.sleep(for: .seconds(0.8))
        case "shot":
            shot(arg.isEmpty ? "bench" : arg)
        case "pos":
            // 指针下各层滚动视图的位置（核对合成手势确实滚动了多远）
            guard let window, let content = window.contentView else { return }
            let local = CGPoint(x: pointer.x, y: content.bounds.height - pointer.y)
            var view = content.hitTest(content.convert(local, to: content.superview))
            var offsets: [String] = []
            while let current = view {
                if let scroll = current as? NSScrollView {
                    let origin = scroll.contentView.bounds.origin
                    let size = scroll.documentView?.frame.size ?? .zero
                    offsets.append("\(Int(origin.x)),\(Int(origin.y)) of \(Int(size.width))×\(Int(size.height))")
                }
                view = current.superview
            }
            PerfTrace.record("bench.pos", ["name": arg, "offsets": offsets.joined(separator: " | ")])
        case "quit":
            MacFrameMonitor.shared.end()
            try? await Task.sleep(for: .seconds(0.5))
            NSApp.terminate(nil)
        default:
            PerfTrace.record("bench.unknown", ["cmd": command])
        }
    }

    // MARK: 手势

    /// 一次轻扫：手指 0.12 秒匀速划过，接着按惯性曲线减速（时间常数 0.5 秒，同 AppKit 的 0.998/ms），速度降到 12 点/秒以下停住。
    ///
    /// 合成的惯性阶段事件（momentumPhase）会被 NSScrollView 忽略（它只认系统手势流里的惯性），实测只滚了手指那一段；
    /// 所以惯性段也按手指持续推动（changed）发出，位移曲线与真惯性一致，页面每帧要做的布局与绘制相同。
    /// 差别只在 SwiftUI 的滚动阶段报 interacting 而不是 decelerating——App 里两者都按 isScrolling 处理
    private func fling(_ velocity: CGVector) async {
        var last = await nextFrame()
        post(.zero, phase: 128, momentum: 0) // mayBegin：手指落下
        let fingerEnd = last + 0.12
        let tau = 0.5
        var speed = velocity
        var first = true
        while hypot(speed.dx, speed.dy) > 12 {
            let now = await nextFrame()
            let dt = now - last
            last = now
            if now <= fingerEnd {
                post(velocity * dt, phase: first ? 1 : 2, momentum: 0)
            } else {
                // 这一帧的位移 = 速度在 dt 内的积分
                let decay = exp(-dt / tau)
                post(speed * (tau * (1 - decay)), phase: 2, momentum: 0)
                speed = speed * decay
            }
            first = false
        }
        post(.zero, phase: 4, momentum: 0)
        logGesture()
    }

    private func drag(_ velocity: CGVector, seconds: Double) async {
        var last = await nextFrame()
        post(.zero, phase: 128, momentum: 0)
        let stop = last + seconds
        var first = true
        while last < stop {
            let now = await nextFrame()
            post(velocity * (now - last), phase: first ? 1 : 2, momentum: 0)
            last = now
            first = false
        }
        post(.zero, phase: 4, momentum: 0)
        logGesture()
    }

    /// 未发出去的小数位移攒着，下次一并发（像素事件只收整数）
    private var carry = CGVector.zero
    private var loggedRouting = false
    private weak var latched: NSView?
    private var track: [String] = []
    private var posted = CGVector.zero
    private var postedCount = 0

    private func logGesture() {
        PerfTrace.record("bench.gesture", ["dx": posted.dx, "dy": posted.dy, "events": postedCount, "track": track.joined(separator: " ")])
        track.removeAll()
        posted = .zero
        postedCount = 0
    }

    /// 合成一个精确滚动事件放进事件队列。`delta` 是「往哪看」的位移（点）：正 y = 往下看，事件里的滚动量与之相反
    private func post(_ delta: CGVector, phase: Int64, momentum: Int64) {
        guard let window, let global = globalPoint(pointer) else { return }
        carry = CGVector(dx: carry.dx + delta.dx, dy: carry.dy + delta.dy)
        let dx = carry.dx.rounded(.towardZero), dy = carry.dy.rounded(.towardZero)
        carry = CGVector(dx: carry.dx - dx, dy: carry.dy - dy)
        posted = CGVector(dx: posted.dx + dx, dy: posted.dy + dy)
        postedCount += 1
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        event.location = global
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let ns = NSEvent(cgEvent: event), let content = window.contentView else { return }
        // 合成事件认不出属于哪个窗口（放进队列会被丢掉，交给窗口派发又按屏幕坐标命中打偏）：
        // 按窗口坐标找到指针下的视图，交给它——同 NSWindow 派发滚轮的路径，沿响应链上交到能滚这个方向的滚动视图。
        // 按帧派发，位移按墙钟补齐，效果同真触控板合并积压的事件
        // 一次手势锁定在手指落下时命中的视图上（同 AppKit 的滚动锁定：手势中途页面关掉命中测试也不改投）
        if phase == 128 || latched == nil {
            let local = CGPoint(x: pointer.x, y: content.bounds.height - pointer.y)
            latched = content.hitTest(content.convert(local, to: content.superview))
        }
        guard let target = latched else { return }
        if phase == 4 { latched = nil }
        if !loggedRouting {
            loggedRouting = true
            var chain: [String] = []
            var view: NSView? = target
            while let current = view, chain.count < 12 { chain.append(String(describing: type(of: current))); view = current.superview }
            PerfTrace.record("bench.routing", ["chain": chain.joined(separator: " < ")])
        }
        target.scrollWheel(with: ns)
        if postedCount % 10 == 0, let scroll = target.enclosingScrollView.flatMap({ $0.documentView?.frame.width ?? 0 > content.bounds.width ? $0.enclosingScrollView : $0 }) {
            track.append("\(Int(posted.dy))→\(Int(scroll.contentView.bounds.origin.y))/\(Int(scroll.documentView?.frame.height ?? 0))")
        }
    }

    /// 窗口内容区坐标（左上角原点）→ 全局显示坐标（主屏左上角原点，CGEvent 用）
    private func globalPoint(_ point: CGPoint) -> CGPoint? {
        guard let window, let content = window.contentView else { return nil }
        let screen = window.convertPoint(toScreen: CGPoint(x: point.x, y: content.bounds.height - point.y))
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: screen.x, y: mainHeight - screen.y)
    }

    // MARK: 截图

    private func shot(_ name: String) {
        guard let window else { return }
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let options = CGWindowImageOption([.bestResolution, .boundsIgnoreFraming]).rawValue
        guard let image = capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber), options)?
            .takeRetainedValue() else { return }
        let dir = caches.appending(path: "perf/shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
    }
}

private func * (vector: CGVector, scale: Double) -> CGVector {
    CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
}
