import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 引擎给出的规格事实（`NativeEngine` 从 AetherCore 映射过来：控制器不直接碰 AetherCore 的类型）
struct EngineDeliveryFacts: Equatable {
    var route: String
    var container: String?
    var videoCodec: String?
    var sourceFormat: String
    var outputFormat: String
    var dolbyVisionProfile: Int?
    var dolbyVisionConversion: String?
    var audioDelivery: String
    var audioDecoder: String?
    var audioCodec: String?
    var audioChannels: Int?
    var audioName: String?
}

/// 一次播放的记录（docs/design/playback-qoe.md）。
///
/// ## 为什么要有它
/// 播放体验的北极星是「无打扰播放率」：一次播放从点下到离开，有没有让用户等太久（快）、被打断（稳）、
/// 拿到打了折扣的规格或被猜错了音轨字幕（对）。原来 App 只在播放正常结束时报一行快照：起播从请求算起、
/// 跳转耗时不上报、失败与出画前就退出的播放一条都不报——恰好漏掉最糟的那一批。
///
/// ## 一次播放的边界
/// 打开播放器（或切到这一集）到离开这一集。断线重连、原位重开、降级、换画质都在同一次里，编号不变；
/// 切集、错误页上点「重试」是新的一次。
///
/// ## 与服务端的分工
/// 用户点下那一刻生成编号 `id`，随会话请求带给服务端（服务端先建「已开始」、写进取流令牌，取流统计按它归集）；
/// 离开时由 `PlaybackReportQueue` 上报完整记录。**这里只记原始事实**：跳转分位、非自愿中断、可避免的规格损失、
/// 北极星都由服务端按规则判定（规则只放一处，改了不用改 App）。
///
/// ## 计时口径（§1.3）
/// 一律从用户动作算到画面出现，用单调时钟；停在用户手里的等待（确认转码弹窗）单独记、不算进起播。
/// 卡顿不含起播与跳转：按「用户想看、画面已出、没在跳转，播放头却不走」判，引擎报不报缓冲都算。
@MainActor
final class PlaybackRecord {
    enum Origin: String {
        case tap
        case autoNext = "auto_next"
        case deeplink
        case retry
    }

    /// 跳转从哪来（分组看「按键 / 拖动」哪种慢）
    enum SeekSource: String {
        case button, scrub, gesture, remote, auto, restart, unknown
    }

    /// 最多保留的条目数（与服务端上限一致，超出的不再记）
    private static let maxItems = 50
    private static let maxTimeline = 200

    let id: String
    let origin: Origin
    let unit: PlaybackUnit
    /// 实验室场景名（启动参数 -mcLab）；空 = 真实使用
    let lab: String
    /// 当前时刻（单调时钟）。测试时换成可以手动拨动的时钟
    private let now: () -> ContinuousClock.Instant
    private let startedAt: ContinuousClock.Instant

    // MARK: 会话与通路（控制器在各节点填）

    var libraryFileId: Int?
    var tier = -1
    var degradedFrom: Int?
    var engine = ""
    var hwBackend = ""
    /// loopback / software / remote_bypass / server_remux / server_transcode
    var route = ""
    /// 起播位置（毫秒）与是不是续播（续播后马上往远处跳 = 续播位置猜错了）
    var startPositionMs = 0
    var resumed = false

    // MARK: 快

    private(set) var firstFrameAt: ContinuousClock.Instant?
    private var playingAt: ContinuousClock.Instant?
    private var userWaitStartedAt: ContinuousClock.Instant?
    private var userWaitMs = 0
    private var startupMarks: [String: Int] = [:]
    private var engineStages: [String: Int] = [:]
    private var serverTimings: [[String: Int]] = []

    struct Seek: Codable {
        var seq: Int
        var source: String
        var fromMs: Int
        var toMs: Int
        /// 发起时落点在前向缓冲里
        var buffered: Bool
        var paused: Bool
        /// 换会话式的跳转（落点在会话已转出的区间外、或会话正在重开）
        var restart: Bool
        var atMs: Int
        /// 到画面出现的毫秒数
        var ms: Int?
        /// landed / superseded / failed / abandoned
        var outcome: String
    }

    private var seeks: [Seek] = []
    private var openSeek: (index: Int, startedAt: ContinuousClock.Instant)?
    private var scrubStartedAt: ContinuousClock.Instant?
    private var seekSeq = 0

    struct Switch: Codable {
        /// audio / subtitle / quality / resume
        var kind: String
        var from: String?
        var to: String?
        var atMs: Int
        var ms: Int?
    }

    private var switches: [Switch] = []
    private var openSwitch: (index: Int, startedAt: ContinuousClock.Instant)?

    // MARK: 稳

    struct Interruption: Codable {
        /// rebuffer / freeze / reconnect / error / engine_failure / fallback / system
        var kind: String
        var atMs: Int
        var ms: Int?
        var cause: String?
        var detail: String?
    }

    private var interruptions: [Interruption] = []
    private var stallOpen: (startedAt: ContinuousClock.Instant, atMs: Int, cause: String)?
    private var lastPlayheadMs: Int?
    private var lastAdvanceAt: ContinuousClock.Instant?
    /// 跳转落地、播放头还没重新走起来：从落地算起 `resumeGrace` 内不判卡顿。软件通路的播放时间每 250 毫秒才发布一次、
    /// 这里也每 250 毫秒采一次，外加时钟放开后音频预滚约 0.3 秒，画面照常在出、播放头却要 0.6～0.8 秒才看得出在走，
    /// 按 0.5 秒线会误报（真机 22 部全量里软件通路每批 2～3 次，全是这个）。宽限过了还不走，从落地那一刻起算卡顿
    private var awaitingResumeSince: ContinuousClock.Instant?
    static let resumeGrace: Duration = .milliseconds(1500)
    private var freezeOpen: (startedAt: ContinuousClock.Instant, atMs: Int)?
    private var lastFrameCount: Int?
    private var lastFramePlayheadMs: Int?
    private var reconnectOpen: (startedAt: ContinuousClock.Instant, atMs: Int, reason: String)?
    private(set) var rebufferCount = 0
    private(set) var rebufferMs = 0
    private(set) var sawFreeze = false

    var errorKind = ""
    var errorCategory = ""
    var errorStage = ""

    // MARK: 对

    struct Delivery: Codable, Equatable {
        struct Video: Codable, Equatable {
            var sourceFormat: String?
            var outputFormat: String?
            var codec: String?
            var dolbyVisionProfile: Int?
            var dolbyVisionConversion: String?
        }

        struct Audio: Codable, Equatable {
            var sourceCodec: String?
            var sourceChannels: Int?
            var sourceLossless: Bool?
            var sourceAtmos: Bool?
            /// stream_copy / bridged / decoded / server_copy / server_transcode / muted……
            var delivery: String?
            var outputCodec: String?
            var atmosKept: Bool?
        }

        struct Subtitle: Codable, Equatable {
            /// engine / overlay / burned / none
            var mode: String
        }

        struct Output: Codable, Equatable {
            /// speaker / bluetooth / wired / airplay / hdmi / other
            var audioRoute: String
            var displayHdr: Bool
        }

        var route: String
        var tier: Int
        var userCapped: Bool
        var fallbackReason: String?
        var video: Video
        var audio: Audio
        var subtitle: Subtitle
        var output: Output
    }

    private(set) var delivery: Delivery?
    private var deliveryHistory = 0

    struct Behavior: Codable {
        /// audio_change / subtitle_change / quality_change / resume_seek / quick_exit / retry / reenter
        var kind: String
        var atMs: Int
        var sinceFirstFrameMs: Int?
        var from: String?
        var to: String?
        /// 说明播放器猜错了（进北极星）；其余只作诊断
        var misguess: Bool
    }

    private var behaviors: [Behavior] = []
    private var audioChanged = false
    private var subtitleChanged = false

    // MARK: 资源与时间线

    private var thermalMax = 0
    private var thermalStart: Int?
    private var batteryStart: Int?
    private var batteryEnd: Int?
    private var lowPower = false
    private var memoryPeakMB = 0
    private var cpuSum = 0.0
    private var cpuSamples = 0
    private var downlinkPeakBps: Double?

    struct Event: Codable {
        var atMs: Int
        var kind: String
        var text: String
    }

    private var timeline: [Event] = []

    init(
        unit: PlaybackUnit, origin: Origin, startedAt: ContinuousClock.Instant? = nil,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        id = UUID().uuidString.lowercased()
        self.unit = unit
        self.origin = origin
        self.now = now
        self.startedAt = startedAt ?? now()
        lab = UserDefaults.standard.string(forKey: "mcLab") ?? ""
        if let previous = Self.lastExit, previous.mediaItemId == unit.mediaItemId,
           now() - previous.at < .seconds(60) {
            behaviors.append(Behavior(kind: "reenter", atMs: 0, misguess: false))
        }
        sampleResources()
        event("start", "开始（\(origin.rawValue)）")
    }

    /// 距这次播放开始的毫秒数
    func elapsedMs(_ instant: ContinuousClock.Instant? = nil) -> Int {
        max(0, Int(((instant ?? now()) - startedAt) / .milliseconds(1)))
    }

    private func ms(since start: ContinuousClock.Instant) -> Int {
        max(0, Int((now() - start) / .milliseconds(1)))
    }

    private var sinceFirstFrameMs: Int? { firstFrameAt.map { ms(since: $0) } }

    // MARK: - 时间线

    func event(_ kind: String, _ text: String) {
        guard timeline.count < Self.maxTimeline else { return }
        timeline.append(Event(atMs: elapsedMs(), kind: kind, text: text))
    }

    // MARK: - 快：起播

    func beginUserWait() {
        if userWaitStartedAt == nil { userWaitStartedAt = now() }
        event("user_wait", "等用户确认")
    }

    func endUserWait() {
        guard let since = userWaitStartedAt else { return }
        userWaitMs += ms(since: since)
        userWaitStartedAt = nil
    }

    /// 首帧（每次出首帧都会来：第一次是起播，之后结束换轨 / 回前台 / 重连的计时）
    func noteFirstFrame() {
        if firstFrameAt == nil {
            firstFrameAt = now()
            // 起播同跳转落地：首帧上屏后播放头要 0.6～0.8 秒才看得出在走（软件通路 250 毫秒发布一次 + P30 停钟），
            // 给同样的起步宽限。NTSC DVD 镜像两批都记了一次起播「卡顿」774～814 毫秒，引擎时钟其实在走
            awaitingResumeSince = firstFrameAt
            event("first_frame", "首帧出画")
        }
        closeSwitch()
        closeReconnect()
        if let open = openSeek, seeks[open.index].restart { closeSeek(outcome: "landed") }
    }

    func notePlaying() {
        if playingAt == nil { playingAt = now() }
    }

    func noteEngineStage(_ name: String) {
        if engineStages[name] == nil { engineStages[name] = elapsedMs() }
    }

    func noteStartupMarks(_ marks: [(name: String, ms: Int)]) {
        for mark in marks where startupMarks[mark.name] == nil { startupMarks[mark.name] = mark.ms }
    }

    func noteServerTiming(_ timings: [String: Int]) {
        guard !timings.isEmpty, serverTimings.count < 10 else { return }
        serverTimings.append(timings)
    }

    // MARK: - 快：跳转

    /// 拖进度条途中（画面跟随）：连续拖动以第一次拖动为起点
    func noteScrubActivity() {
        if scrubStartedAt == nil { scrubStartedAt = now() }
    }

    func beginSeek(source: SeekSource, fromMs: Int, toMs: Int, buffered: Bool, paused: Bool, restart: Bool) {
        if openSeek != nil { closeSeek(outcome: "superseded") }
        let start = (source == .scrub ? scrubStartedAt : nil) ?? now()
        scrubStartedAt = nil
        seekSeq += 1
        // 续播之后马上往远处跳：续播位置不是用户要的
        if resumed, source != .auto, let since = sinceFirstFrameMs, since <= 30_000, abs(toMs - fromMs) > 120_000 {
            addBehavior(Behavior(kind: "resume_seek", atMs: elapsedMs(), sinceFirstFrameMs: since,
                                 from: "\(fromMs)", to: "\(toMs)", misguess: true))
        }
        guard seeks.count < Self.maxItems else { return }
        seeks.append(Seek(seq: seekSeq, source: source.rawValue, fromMs: fromMs, toMs: toMs, buffered: buffered,
                          paused: paused, restart: restart, atMs: elapsedMs(start), ms: nil, outcome: "pending"))
        openSeek = (seeks.count - 1, start)
        event("seek", "跳转 #\(seekSeq) \(fromMs / 1000) → \(toMs / 1000) 秒（\(source.rawValue)\(buffered ? "·缓冲内" : "")\(restart ? "·换会话" : "")）")
    }

    var seekInFlight: Bool { openSeek != nil }

    /// 落点的画面到了
    func seekPresented() -> Int? {
        closeSeek(outcome: "landed")
    }

    @discardableResult
    func closeSeek(outcome: String) -> Int? {
        guard let open = openSeek else { return nil }
        openSeek = nil
        let spent = ms(since: open.startedAt)
        seeks[open.index].ms = spent
        seeks[open.index].outcome = outcome
        if outcome == "landed" { awaitingResumeSince = now() }
        event("seek_\(outcome)", "跳转 #\(seeks[open.index].seq) \(outcome) \(spent) 毫秒")
        #if DEBUG
        let seek = seeks[open.index]
        if outcome == "landed" {
            FileHandle.standardError.write(Data(
                "[SeekTrace] \(seek.fromMs / 1000) → \(seek.toMs / 1000) 秒（\(seek.buffered ? "缓冲内" : "缓冲外")\(seek.restart ? "·换会话" : "")\(seek.paused ? "·暂停中" : "")·\(seek.source)）耗时 \(spent) 毫秒\n".utf8))
        }
        #endif
        return spent
    }

    // MARK: - 快：换轨 / 回前台

    func beginSwitch(kind: String, from: String?, to: String?) {
        closeSwitch()
        guard switches.count < Self.maxItems else { return }
        switches.append(Switch(kind: kind, from: from, to: to, atMs: elapsedMs(), ms: nil))
        openSwitch = (switches.count - 1, now())
        event("switch", "\(kind) \(from ?? "-") → \(to ?? "-")")
    }

    /// 结束当前的换轨计时（新轨出声 / 新画面出来）；`immediate` = 不用重载，即刻生效
    func closeSwitch(immediate: Bool = false) {
        guard let open = openSwitch else { return }
        openSwitch = nil
        let spent = immediate ? 0 : ms(since: open.startedAt)
        switches[open.index].ms = spent
        event("switch_done", "\(switches[open.index].kind) 生效 \(spent) 毫秒")
    }

    // MARK: - 稳：卡顿 / 冻帧 / 重连 / 错误

    /// 每 250 毫秒采一次播放头。`active` = 用户想看、画面已出、没在跳转、没在后台：这时播放头 0.5 秒不走就是卡顿
    func samplePlayhead(_ positionMs: Int, active: Bool, cause: () -> String) {
        let now = self.now()
        defer { lastPlayheadMs = positionMs }
        // 保险：迟迟等不到结果的换轨（15 秒）作废、跳转（30 秒）记为超时——结束事件万一丢了，
        // 不能让它们一直挡着卡顿检测
        if let open = openSwitch, now - open.startedAt > .seconds(15) {
            openSwitch = nil
            event("switch_timeout", "\(switches[open.index].kind) 15 秒没等到生效，作废")
        }
        if let open = openSeek, now - open.startedAt > .seconds(30) {
            closeSeek(outcome: "timeout")
        }
        // 首帧之前是起播，等待算在首帧耗时里，不判卡顿
        guard active, firstFrameAt != nil, openSeek == nil, openSwitch == nil else {
            closeStall()
            lastAdvanceAt = now
            if active == false { awaitingResumeSince = nil }
            return
        }
        if let last = lastPlayheadMs, positionMs != last {
            closeStall()
            lastAdvanceAt = now
            awaitingResumeSince = nil
            return
        }
        if let landedAt = awaitingResumeSince {
            guard now - landedAt >= Self.resumeGrace else { return }
            awaitingResumeSince = nil
            stallOpen = (landedAt, elapsedMs(landedAt), cause())
            return
        }
        guard stallOpen == nil, let since = lastAdvanceAt, now - since >= .milliseconds(500) else { return }
        stallOpen = (since, elapsedMs(since), cause())
    }

    private func closeStall() {
        guard let open = stallOpen else { return }
        stallOpen = nil
        let spent = ms(since: open.startedAt)
        rebufferCount += 1
        rebufferMs += spent
        addInterruption(Interruption(kind: "rebuffer", atMs: open.atMs, ms: spent, cause: open.cause))
        event("rebuffer", "卡顿 \(spent) 毫秒（\(open.cause)）")
    }

    /// 每秒采一次软件通路的送帧计数：播放头在走、这一秒一帧都没交到显示层就是画面冻住
    func sampleFrames(presented: Int?, positionMs: Int, active: Bool) {
        defer {
            lastFrameCount = presented
            lastFramePlayheadMs = positionMs
        }
        guard active, let presented, let lastCount = lastFrameCount, let lastPlayhead = lastFramePlayheadMs else {
            closeFreeze()
            return
        }
        let advanced = positionMs - lastPlayhead >= 800
        if presented > lastCount || !advanced {
            closeFreeze()
        } else if freezeOpen == nil {
            let start = now() - .seconds(1)
            freezeOpen = (start, elapsedMs(start))
        }
    }

    private func closeFreeze() {
        guard let open = freezeOpen else { return }
        freezeOpen = nil
        let spent = ms(since: open.startedAt)
        sawFreeze = true
        addInterruption(Interruption(kind: "freeze", atMs: open.atMs, ms: spent))
        event("freeze", "画面冻住 \(spent) 毫秒")
    }

    func beginReconnect(reason: String) {
        if reconnectOpen == nil { reconnectOpen = (now(), elapsedMs(), reason) }
        event("reconnect", "重连：\(reason)")
    }

    var reconnecting: Bool { reconnectOpen != nil }

    private func closeReconnect() {
        guard let open = reconnectOpen else { return }
        reconnectOpen = nil
        addInterruption(Interruption(kind: "reconnect", atMs: open.atMs, ms: ms(since: open.startedAt), detail: open.reason))
    }

    /// 错误页（用户看得见的失败）
    func noteError(message: String, kind: String?, category: String, stage: String) {
        errorKind = kind ?? ""
        errorCategory = category
        errorStage = stage
        addInterruption(Interruption(kind: "error", atMs: elapsedMs(), cause: category, detail: message))
        event("error", "错误页：\(message)")
    }

    /// 引擎报的失败（不一定让用户看到：多半被重连、原位重开接住）
    func noteEngineFailure(reason: String, kind: String?, cause: String) {
        addInterruption(Interruption(kind: "engine_failure", atMs: elapsedMs(), cause: cause,
                                     detail: [kind, reason].compactMap { $0 }.joined(separator: "：")))
        event("engine_failure", "引擎失败（\(cause)）：\(reason)")
    }

    func noteFallback(reason: String) {
        addInterruption(Interruption(kind: "fallback", atMs: elapsedMs(), detail: reason))
        event("fallback", "改走服务端流：\(reason)")
    }

    /// 来电、Siri 打断，耳机拔出（不算我们的中断，只看恢复得对不对）
    func noteSystem(_ text: String) {
        addInterruption(Interruption(kind: "system", atMs: elapsedMs(), detail: text))
        event("system", text)
    }

    private func addInterruption(_ item: Interruption) {
        guard interruptions.count < Self.maxItems else { return }
        interruptions.append(item)
    }

    // MARK: - 对

    func noteDelivery(_ snapshot: Delivery) {
        guard snapshot != delivery else { return }
        if delivery != nil {
            event("delivery", "规格变化：\(snapshot.route) · 视频 \(snapshot.video.outputFormat ?? "-") · 音频 \(snapshot.audio.delivery ?? "-")")
        }
        delivery = snapshot
        deliveryHistory += 1
    }

    /// 用户换音轨：首帧后 30 秒内第一次换掉自动选的轨 = 猜错了
    func noteAudioChange(from: String?, to: String) {
        let since = sinceFirstFrameMs
        let misguess = !audioChanged && (since.map { $0 <= 30_000 } ?? true)
        audioChanged = true
        addBehavior(Behavior(kind: "audio_change", atMs: elapsedMs(), sinceFirstFrameMs: since, from: from, to: to, misguess: misguess))
    }

    func noteSubtitleChange(from: String?, to: String?) {
        let since = sinceFirstFrameMs
        let misguess = !subtitleChanged && (since.map { $0 <= 30_000 } ?? true)
        subtitleChanged = true
        addBehavior(Behavior(kind: "subtitle_change", atMs: elapsedMs(), sinceFirstFrameMs: since, from: from, to: to ?? "off", misguess: misguess))
    }

    func noteBehavior(_ kind: String, from: String? = nil, to: String? = nil) {
        addBehavior(Behavior(kind: kind, atMs: elapsedMs(), sinceFirstFrameMs: sinceFirstFrameMs, from: from, to: to, misguess: false))
    }

    private func addBehavior(_ behavior: Behavior) {
        guard behaviors.count < Self.maxItems else { return }
        behaviors.append(behavior)
        event(behavior.kind, "\(behavior.kind) \(behavior.from ?? "-") → \(behavior.to ?? "-")\(behavior.misguess ? "（猜错）" : "")")
    }

    // MARK: - 资源（每 10 秒一次）

    func sampleResources(downlinkBps: Double? = nil) {
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 0
        }
        if thermalStart == nil { thermalStart = thermal }
        thermalMax = max(thermalMax, thermal)
        #if os(iOS)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let battery = device.batteryLevel < 0 ? nil : Int((device.batteryLevel * 100).rounded())
        if batteryStart == nil { batteryStart = battery }
        batteryEnd = battery ?? batteryEnd
        #endif
        lowPower = lowPower || ProcessInfo.processInfo.isLowPowerModeEnabled
        memoryPeakMB = max(memoryPeakMB, Int(DeviceVitals.footprintMB()))
        let cpu = DeviceVitals.processCPU()
        if cpu >= 0 {
            cpuSum += cpu
            cpuSamples += 1
        }
        if let downlinkBps { downlinkPeakBps = max(downlinkPeakBps ?? 0, downlinkBps) }
    }

    // MARK: - 收尾

    /// 结局：看完 / 中途退出 / 出画前退出 / 失败 / 异常退出
    enum Outcome: String {
        case watched, exited, failed, abnormalExit = "abnormal_exit"
        case exitBeforeStart = "exit_before_start"
    }

    struct Context: Codable {
        var appVersion: String
        var os: String
        var model: String
        var network: String
        var interface: String
        var metered: Bool
        var downlinkMbps: Double?
        var origin: String
        var lab: String
    }

    /// 上报用的完整记录。`outcome` 为 nil 时按当前状态判（异常退出标记里存的是这时的快照）
    func payload(
        outcome: Outcome, network: PlaybackNetwork, positionMs: Int, durationMs: Int?, watchedMs: Int,
        droppedFrames: Int?, totalFrames: Int?, logTail: String?
    ) -> API.PlaybackMetricPayload {
        var detail = Detail(
            startup: .init(
                marks: startupMarks, engineStages: engineStages, serverTimings: serverTimings,
                startPositionMs: startPositionMs, resumed: resumed
            ),
            seeks: seeks, switches: switches, interruptions: interruptions, delivery: delivery,
            behaviors: behaviors,
            context: Context(
                appVersion: Self.appVersion, os: Self.osVersion, model: Self.model,
                network: network.rawValue, interface: NetworkCost.shared.interface,
                metered: NetworkCost.shared.isMetered,
                downlinkMbps: downlinkPeakBps.map { ($0 / 10_000).rounded() / 100 },
                origin: origin.rawValue, lab: lab
            ),
            resources: .init(
                thermalStart: thermalStart, thermalMax: thermalMax, batteryStart: batteryStart, batteryEnd: batteryEnd,
                lowPower: lowPower, memoryPeakMb: memoryPeakMB,
                cpuAvg: cpuSamples > 0 ? (cpuSum / Double(cpuSamples)).rounded() : nil
            ),
            timeline: timeline,
            end: .init(positionMs: positionMs, durationMs: durationMs)
        )
        // 还开着的卡顿 / 冻帧 / 跳转 / 换轨：算到离开这一刻
        if let open = stallOpen {
            detail.interruptions.append(Interruption(kind: "rebuffer", atMs: open.atMs, ms: ms(since: open.startedAt), cause: open.cause))
        }
        if let open = freezeOpen {
            detail.interruptions.append(Interruption(kind: "freeze", atMs: open.atMs, ms: ms(since: open.startedAt)))
        }
        if let open = reconnectOpen {
            // 重连到离开都没接回来（最后落到错误页、或用户等不及退出了）
            detail.interruptions.append(Interruption(kind: "reconnect", atMs: open.atMs, ms: ms(since: open.startedAt),
                                                     detail: open.reason))
        }
        if let open = openSeek {
            detail.seeks[open.index].ms = ms(since: open.startedAt)
            detail.seeks[open.index].outcome = "abandoned"
        }
        let firstFrameMs = firstFrameAt.map { max(0, elapsedMs($0) - userWaitMs) }
        let playingMs = playingAt.map { max(0, elapsedMs($0) - userWaitMs) }
        return API.PlaybackMetricPayload(
            libraryFileId: libraryFileId, tier: tier, degradedFrom: degradedFrom, engine: engine, hwBackend: hwBackend,
            ttffMs: firstFrameMs, rebufferMs: rebufferMs + (stallOpen.map { ms(since: $0.startedAt) } ?? 0),
            rebufferCount: rebufferCount + (stallOpen == nil ? 0 : 1),
            seekCount: seeks.count, droppedFrames: droppedFrames, totalFrames: totalFrames, watchedMs: watchedMs,
            attemptId: id, outcome: outcome.rawValue, mediaItemId: unit.mediaItemId,
            seasonNumber: unit.isEpisode ? unit.season : nil, episodeNumber: unit.isEpisode ? unit.episode : nil,
            origin: origin.rawValue, client: ClientPlatform.kind, labScenario: lab, route: route, networkClass: network.rawValue,
            interface: NetworkCost.shared.interface, appVersion: Self.appVersion,
            firstFrameMs: firstFrameMs, playingMs: playingMs, userWaitMs: userWaitMs,
            errorKind: errorKind, errorCategory: errorCategory, errorStage: errorStage,
            detail: Self.json(detail), logTail: logTail
        )
    }

    /// 离开时判结局：出过画且放到了片尾附近算看完；没出画按有没有落到错误页分失败 / 出画前退出
    func outcome(phaseIsError: Bool, phaseIsEnded: Bool, positionMs: Int, durationMs: Int?) -> Outcome {
        if phaseIsError { return .failed }
        guard firstFrameAt != nil else { return .exitBeforeStart }
        if phaseIsEnded { return .watched }
        if let durationMs, durationMs > 0, positionMs >= durationMs - max(60_000, durationMs / 20) { return .watched }
        return .exited
    }

    /// 离开这次播放：记下快速退出与「最近一次离开」（下一次 60 秒内又进同一部 = 重进）
    func noteLeaving() {
        if let since = sinceFirstFrameMs, since < 10_000 { noteBehavior("quick_exit") }
        Self.lastExit = (unit.mediaItemId, now())
        event("leave", "离开")
    }

    private static var lastExit: (mediaItemId: Int, at: ContinuousClock.Instant)?

    // MARK: - 序列化

    private struct Detail: Codable {
        struct Startup: Codable {
            var marks: [String: Int]
            var engineStages: [String: Int]
            var serverTimings: [[String: Int]]
            var startPositionMs: Int
            var resumed: Bool
        }

        struct Resources: Codable {
            var thermalStart: Int?
            var thermalMax: Int
            var batteryStart: Int?
            var batteryEnd: Int?
            var lowPower: Bool
            var memoryPeakMb: Int
            var cpuAvg: Double?
        }

        struct End: Codable {
            var positionMs: Int
            var durationMs: Int?
        }

        var startup: Startup
        var seeks: [Seek]
        var switches: [Switch]
        var interruptions: [Interruption]
        var delivery: Delivery?
        var behaviors: [Behavior]
        var context: Context
        var resources: Resources
        var timeline: [Event]
        var end: End
    }

    /// 明细按 snake_case 编成 JSON，再转成接口的通用 JSON 值（服务端按这些键读，见 services/playback/qoe.py）
    private static func json(_ detail: Detail) -> [String: API.JSONValue] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(detail),
              let value = try? JSONDecoder().decode([String: API.JSONValue].self, from: data) else { return [:] }
        return value
    }

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version)(\(build))"
    }()

    /// 系统版本号（iOS / tvOS 取 UIDevice，与历史记录同一写法；Mac 取进程信息）
    static var osVersion: String {
        #if canImport(UIKit)
        UIDevice.current.systemVersion
        #else
        ClientPlatform.osVersion
        #endif
    }

    static let model: String = {
        #if os(macOS)
        return APIClient.machineModel
        #endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()
}

extension PlaybackRecord {
    /// 规格快照：引擎事实 + 会话计划 + 当前输出（「对」的判定材料，损失由服务端按规则表判，见 playback-qoe.md §5.6）
    static func makeDelivery(
        facts: EngineDeliveryFacts?, session: API.PlaybackSessionView, playsOriginalFile: Bool, route: String,
        userCapped: Bool, fallbackReason: String?, subtitleMode: String, currentAudio: String?
    ) -> Delivery {
        let decision = session.decision
        // 源的音轨：自研引擎直出时以引擎正在放的为准，服务端流看会话计划与服务端的轨清单
        let track = decision.audioTracks.first { $0.ref == (currentAudio ?? decision.audio?.trackRef) }
        let sourceCodec = (playsOriginalFile ? facts?.audioCodec : nil) ?? track?.codec
        let sourceChannels = (playsOriginalFile ? facts?.audioChannels : nil) ?? track?.channels
        // 全景声 / DTS-HD MA 只写在轨名与解码器说明里（「Stream-copy (EAC3+JOC Atmos)」）
        let names = [facts?.audioName, facts?.audioDecoder].compactMap { $0?.lowercased() }
        let atmos = names.contains { $0.contains("atmos") || $0.contains("joc") }
        let lossless = Self.isLossless(codec: sourceCodec, names: names)
        var audioDelivery: String?
        var outputCodec: String?
        var atmosKept: Bool?
        if playsOriginalFile, let facts {
            audioDelivery = Self.snake(facts.audioDelivery)
            switch facts.audioDelivery {
            case "streamCopy":
                outputCodec = sourceCodec
                if atmos { atmosKept = true }
            case "bridged":
                // 桥接的输出格式写在解码器说明里（「truehd → EAC3 bridge」「… → FLAC」）
                let label = facts.audioDecoder?.lowercased() ?? ""
                outputCodec = label.contains("flac") ? "flac" : (label.contains("eac3") || label.contains("e-ac-3") ? "eac3" : nil)
                if atmos { atmosKept = false }
            case "decoded":
                // 软件通路本机解码成 PCM，交给系统输出
                outputCodec = "pcm"
                if atmos { atmosKept = false }
            case "droppedNoPipeline":
                audioDelivery = "muted"
            default:
                break
            }
        } else if let plan = decision.audio {
            audioDelivery = plan.action == "copy" ? "server_copy" : "server_transcode"
            outputCodec = plan.action == "copy" ? sourceCodec : plan.codec
            if atmos { atmosKept = plan.action == "copy" }
        }
        let sourceFormat = playsOriginalFile ? facts?.sourceFormat : Self.formatKey(session.source?.hdr)
        var outputFormat = facts?.outputFormat
        if !playsOriginalFile, decision.video?.toneMap == true { outputFormat = "sdr" }
        return Delivery(
            route: route,
            tier: decision.tier ?? -1,
            userCapped: userCapped,
            fallbackReason: fallbackReason,
            video: .init(
                sourceFormat: sourceFormat, outputFormat: outputFormat,
                codec: (playsOriginalFile ? facts?.videoCodec : nil) ?? session.source?.videoCodec,
                dolbyVisionProfile: facts?.dolbyVisionProfile, dolbyVisionConversion: facts?.dolbyVisionConversion
            ),
            audio: .init(
                sourceCodec: sourceCodec, sourceChannels: sourceChannels, sourceLossless: lossless,
                sourceAtmos: atmos, delivery: audioDelivery, outputCodec: outputCodec, atmosKept: atmosKept
            ),
            subtitle: .init(mode: subtitleMode),
            output: .init(audioRoute: Self.audioRoute(), displayHdr: AVPlayer.eligibleForHDRPlayback)
        )
    }

    /// 无损音轨：TrueHD、FLAC、ALAC、PCM，以及 DTS-HD MA（名称里写着 MA）
    static func isLossless(codec: String?, names: [String]) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        if ["truehd", "mlp", "flac", "alac"].contains(codec) || codec.hasPrefix("pcm") { return true }
        if codec.hasPrefix("dts") { return names.contains { $0.contains("dts-hd ma") || $0.contains("hd ma") || $0.contains(" ma") } }
        return false
    }

    /// 台账的 HDR 标记 → 画面格式键
    static func formatKey(_ hdr: String?) -> String {
        switch hdr?.lowercased() {
        case nil, "": "sdr"
        case let value? where value.contains("dolby"): "dolbyvision"
        case let value? where value.contains("hlg"): "hlg"
        case let value? where value.contains("10+"): "hdr10plus"
        default: "hdr10"
        }
    }

    /// 当前音频输出：speaker / bluetooth / wired / airplay / hdmi / other
    static func audioRoute() -> String {
        #if os(macOS)
        // Mac 没有音频会话可问输出口，统一记 other
        return "other"
        #else
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType else { return "other" }
        switch port {
        case .builtInSpeaker, .builtInReceiver: return "speaker"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "bluetooth"
        case .headphones, .usbAudio, .lineOut: return "wired"
        case .airPlay: return "airplay"
        case .HDMI: return "hdmi"
        default: return "other"
        }
        #endif
    }

    /// streamCopy → stream_copy（与服务端、其余字段同一写法）
    private static func snake(_ value: String) -> String {
        value.reduce(into: "") { result, char in
            if char.isUppercase {
                result += "_" + char.lowercased()
            } else {
                result.append(char)
            }
        }
    }
}
