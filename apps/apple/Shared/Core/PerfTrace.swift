import Foundation
import NukeUI
import os
import QuartzCore
import SwiftUI

/// 页面打开速度打点：开发期的测量工具，只在 Debug 构建里记录，并且要以 `-mcPerf YES` 启动。
///
/// **口径**（对齐业界：Apple 的首帧 400ms / Hang、Android 的 TTID / TTFD、Web 的 LCP、国内 APM 的「页面秒开」）：
/// - 起点 `t0`：冷启动 = 内核记录的进程创建时刻（含 dyld 与 main 之前）；切页签 = 选中页签的那一刻。
/// - 首帧 `firstFrame`（TTID）：页面第一次随 Core Animation 事务提交出去。
/// - 数据就绪 `dataReady`：页面要显示的数据全部渲染上屏——不再有转圈、骨架或「稍后插进来」的行。
/// - 视觉完成 `visualComplete`（TTFD，主指标）：数据就绪，且首屏里出现的每张图都已显示（失败也算结束）。
///   用户感受到的「打开完了」是这一刻；接口快不等于页面快。
///
/// 另外逐个记录接口请求（本机排队等连接、TTFB、下载、解码耗时、是否在主线程解码）与图片来源
/// （内存 / 磁盘 / 网络），把一次慢打开拆到具体环节。
///
/// 事件逐行写入 App 容器 `Library/Caches/perf/trace-<进程号>.jsonl`，时间 `t` 都是距进程创建的毫秒数；
/// 同时打一份 os_log（subsystem `io.movieclaw.perf`）。汇总脚本见 `scripts/perf/ios_open_report.py`。
/// Release 构建里这些函数都是空的。
enum PerfTrace {
    #if DEBUG
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "mcPerf")
    #else
    nonisolated static let enabled = false
    #endif

    // MARK: 时间基准

    /// 进程创建时刻（CACurrentMediaTime 口径，秒）：内核的进程启动时间（墙钟）换算到单调时钟
    nonisolated static let processStart: CFTimeInterval = {
        let mono = CACurrentMediaTime()
        let wall = Date().timeIntervalSince1970
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return mono }
        let start = info.kp_proc.p_un.__p_starttime
        return mono - (wall - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000))
    }()

    /// 墙钟与单调时钟之差：把 URLSession 指标里的 Date 换算成距进程创建的毫秒
    private nonisolated static let wallMinusMono = Date().timeIntervalSince1970 - CACurrentMediaTime()

    /// 此刻距进程创建的毫秒数
    nonisolated static func now() -> Double { (CACurrentMediaTime() - processStart) * 1000 }

    /// main 开始（App 初始化）的时刻，距进程创建的毫秒数。模拟器上 main 之前的 dyld 加载要 1.5~3 秒且波动大，
    /// `-mcPerfScript` 的切页时刻从这里算
    static var mainStart: Double = 0

    static func markMain() {
        mainStart = now()
        record("app.init", at: mainStart)
    }

    nonisolated static func ms(_ date: Date?) -> Double? {
        date.map { ($0.timeIntervalSince1970 - wallMinusMono - processStart) * 1000 }
    }

    // MARK: 写出

    private nonisolated static let queue = DispatchQueue(label: "io.movieclaw.perf")
    private nonisolated static let logger = Logger(subsystem: "io.movieclaw.perf", category: "trace")
    /// 同一份事件也打成 Points of Interest 信号点：Instruments 的时间轴上与 CPU 采样对得上
    private nonisolated static let signposter = OSSignposter(subsystem: "io.movieclaw.perf", category: .pointsOfInterest)
    private nonisolated static let file: FileHandle? = {
        guard enabled, let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appending(path: "perf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "trace-\(getpid()).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    /// 记一条事件（任意线程）；`at` 缺省为此刻
    nonisolated static func record(_ event: String, _ fields: [String: any Sendable] = [:], at time: Double? = nil) {
        guard enabled else { return }
        let t = time ?? now()
        if event != "net", event != "decode" {
            signposter.emitEvent("perf", "\(event, privacy: .public) \((fields["page"] as? String) ?? "", privacy: .public)")
        }
        queue.async {
            var object: [String: Any] = fields
            object["t"] = (t * 100).rounded() / 100
            object["ev"] = event
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            file?.write(data + Data("\n".utf8))
            logger.notice("\(String(decoding: data, as: UTF8.self), privacy: .public)")
        }
    }

    /// 记下「这一轮界面更新提交出去」的时刻：挂一个一次性的 RunLoop 观察者，排在 Core Animation
    /// 提交事务（beforeWaiting，order 2000000）之后
    static func afterCommit(_ event: String, _ fields: [String: any Sendable] = [:], then: (@MainActor (Double) -> Void)? = nil) {
        guard enabled else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { _, _ in
            let t = now()
            record(event, fields, at: t)
            MainActor.assumeIsolated { then?(t) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // MARK: 页面打开

    /// 一次页面打开：从触发（冷启动 / 切页签）到视觉完成
    private final class Open {
        let id: Int
        let page: String
        let trigger: String
        let t0: Double
        var firstFrame = false
        var dataReady = false
        var finished = false
        /// 首屏里出现过的图（探针编号 → 是否已结束）
        var images: [Int: Bool] = [:]
        var sources: [String: Int] = [:]

        init(id: Int, page: String, trigger: String, t0: Double) {
            self.id = id
            self.page = page
            self.trigger = trigger
            self.t0 = t0
        }

        var fields: [String: any Sendable] { ["open": id, "page": page, "trigger": trigger, "t0": (t0 * 100).rounded() / 100] }
    }

    private static var opens: [String: Open] = [:]
    private static var openCount = 0

    /// 页面打开的起点：切到页签（`trigger: "tab"`）或冷启动落在这个页签（`"launch"`，起点记进程创建）
    static func pageBegan(_ page: String, trigger: String, at t0: Double? = nil) {
        guard enabled else { return }
        openCount += 1
        let open = Open(id: openCount, page: page, trigger: trigger, t0: t0 ?? now())
        // 被新的一次打开顶替（例如冷启动落点先经过一次切页签）：旧的不再计时、也不报超时。
        // 起点不单独写事件，随后续事件的 open 字段带出，被顶替的那次就不会出现在记录里
        opens[page]?.finished = true
        opens[page] = open
        // 20 秒还没完成就收口，记下卡在哪
        let id = open.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            guard let current = opens[page], current.id == id, !current.finished else { return }
            current.finished = true
            record("page.timeout", current.fields.merging([
                "firstFrame": current.firstFrame, "dataReady": current.dataReady,
                "pendingImages": current.images.values.filter { !$0 }.count,
            ]) { a, _ in a })
        }
    }

    /// 页面根视图出现：下一次提交即首帧
    static func pageAppeared(_ page: String) {
        guard enabled, let open = opens[page], !open.firstFrame else { return }
        open.firstFrame = true
        afterCommit("page.firstFrame", open.fields)
    }

    /// 页面数据全部渲染上屏（页面在数据齐了的那次更新里调用）
    static func pageDataReady(_ page: String) {
        guard enabled, let open = opens[page], !open.dataReady else { return }
        open.dataReady = true
        afterCommit("page.dataReady", open.fields) { _ in checkComplete(open) }
    }

    /// 页面数据的一次阶段性到达（看清是一次到齐还是分几拨插进来）
    static func pageStage(_ page: String, _ stage: String) {
        guard enabled, let open = opens[page], !open.dataReady else { return }
        record("page.stage", open.fields.merging(["stage": stage]) { a, _ in a })
    }

    private static func checkComplete(_ open: Open) {
        guard open.dataReady, !open.finished, opens[open.page] === open,
              !open.images.values.contains(false) else { return }
        open.finished = true
        var fields = open.fields
        fields["images"] = open.images.count
        for (source, count) in open.sources { fields["img_\(source)"] = count }
        afterCommit("page.visualComplete", fields)
    }

    // MARK: 图片

    private static var probeCount = 0

    fileprivate static func nextProbeID() -> Int {
        probeCount += 1
        return probeCount
    }

    /// 一张图出现在首屏里（页面打开尚未完成时才计入）
    fileprivate static func imageVisible(_ probe: Int, page: String?, done: Bool, source: String?) {
        guard let page, let open = opens[page], !open.finished, open.images[probe] == nil else { return }
        open.images[probe] = done
        if done, let source { open.sources[source, default: 0] += 1 }
    }

    /// 一张图显示出来（或失败）
    fileprivate static func imageDone(_ probe: Int, page: String?, source: String) {
        guard let page, let open = opens[page], !open.finished, open.images[probe] == false else { return }
        open.images[probe] = true
        open.sources[source, default: 0] += 1
        checkComplete(open)
    }

    /// 图片滑出首屏 / 被拆掉还没加载完：不再等它
    fileprivate static func imageGone(_ probe: Int, page: String?) {
        guard let page, let open = opens[page], !open.finished, open.images[probe] == false else { return }
        open.images[probe] = nil
        checkComplete(open)
    }
}

// MARK: - 接口请求指标

extension PerfTrace {
    /// 接口请求的任务级代理：请求结束时把 URLSession 的分段时间记下来
    nonisolated final class NetworkMetrics: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NetworkMetrics()

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let last = metrics.transactionMetrics.last else { return }
            let fetch = PerfTrace.ms(last.fetchStartDate) ?? 0
            let sent = PerfTrace.ms(last.connectStartDate ?? last.requestStartDate) ?? fetch
            var fields: [String: any Sendable] = [
                "path": task.originalRequest?.url.map { $0.path + ($0.query.map { "?\($0)" } ?? "") } ?? "",
                "session": session.sessionDescription ?? "",
                "start": ((PerfTrace.ms(metrics.taskInterval.start) ?? fetch) * 100).rounded() / 100,
                "queue": ((sent - fetch) * 100).rounded() / 100,
                "reused": last.isReusedConnection,
                "bytes": last.countOfResponseBodyBytesReceived,
                "status": (last.response as? HTTPURLResponse)?.statusCode ?? 0,
            ]
            if let request = PerfTrace.ms(last.requestStartDate), let response = PerfTrace.ms(last.responseStartDate) {
                fields["ttfb"] = ((response - request) * 100).rounded() / 100
            }
            if let response = PerfTrace.ms(last.responseStartDate), let end = PerfTrace.ms(last.responseEndDate) {
                fields["download"] = ((end - response) * 100).rounded() / 100
            }
            PerfTrace.record("net", fields, at: PerfTrace.ms(last.responseEndDate))
        }
    }

    /// 接口响应解码耗时（在哪个线程解的）
    nonisolated static func decoded(_ path: String, bytes: Int, started: Double) {
        guard enabled else { return }
        let end = now()
        record("decode", ["path": path, "bytes": bytes, "ms": ((end - started) * 100).rounded() / 100, "main": pthread_main_np() != 0], at: end)
    }
}

// MARK: - 视图接入

private struct PerfPageKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// 视图所在的页签（图片探针据此把图算进对应页面的打开）
    var perfPage: String? {
        get { self[PerfPageKey.self] }
        set { self[PerfPageKey.self] = newValue }
    }
}

/// 图片探针：记下这张图有没有出现在首屏、什么时候显示出来、来自内存 / 磁盘 / 网络
private struct PerfImageProbe: ViewModifier {
    let hasURL: Bool
    let done: Bool
    let source: String?
    @Environment(\.perfPage) private var page
    @State private var id = PerfTrace.nextProbeID()
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { proxy in
                let frame = proxy.frame(in: .global)
                return frame.width > 1 && frame.height > 1 && frame.intersects(PerfImageProbe.screen)
            } action: { isVisible in
                guard hasURL, isVisible, !visible else { return }
                visible = true
                PerfTrace.imageVisible(id, page: page, done: done, source: source)
            }
            .onChange(of: done) { _, finished in
                guard visible, finished else { return }
                PerfTrace.imageDone(id, page: page, source: source ?? "network")
            }
            .onDisappear {
                if visible, !done { PerfTrace.imageGone(id, page: page) }
            }
    }

    private static let screen: CGRect = {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 402, height: 874)
    }()
}

extension View {
    /// 让这张图参与「视觉完成」的判定（首屏里出现的图都显示出来，页面才算打开完）
    @ViewBuilder
    func perfImage(_ url: URL?, _ state: LazyImageState) -> some View {
        #if DEBUG
        if PerfTrace.enabled {
            let done = state.image != nil || state.error != nil
            let source: String? = state.error != nil ? "failed"
                : done ? (try? state.result?.get().cacheType).flatMap { $0 == .memory ? "memory" : "disk" } ?? "network" : nil
            modifier(PerfImageProbe(hasURL: url != nil, done: done, source: source))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
