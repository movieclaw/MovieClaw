import AVFoundation
import AVKit
import SwiftUI

/// 播放控制器：会话协议 + 状态机 + 引擎编排（对应 Web `components/player/video-player.tsx` 与 `lib/player/machine.ts`）。
///
/// ## 起播链路
/// 「决策 → 开会话 → 挂引擎 → 缓冲 → 出画」四段异步，中间随时可能插进来 seek、换轨、降档、切集。
/// 为此每次「去后端要一个能播的地址」都带一个递增的 `attempt` 序号：响应回来时序号已被超越
/// （用户又换了参数/退出了），就把刚拉起的会话当场掐掉，绝不让它变成占着转码名额的孤儿。
///
/// ## 引擎选择（全自动，用户不选；docs/design/player-engine.md §3 兜底阶梯）
/// 自研引擎解决本机能解决的一切（2026-09-28 用户拍板，MPV 已整个移除）：直出原文件，App 内换封装进系统播放器，
/// 画中画、杜比视界、全景声都由系统负责，NAS 只供字节；硬解不了的编码由引擎自己在本机软解。
/// 阶梯只有两级，力保不降级（2026-09-28 用户要求，见 `FailurePolicy`）：网络慢、断线不换引擎（等片源回来原地重开），
/// 片源不在了直接说明，存储写满收小缓冲重开，一时的问题原位重开一次，确定解不了才走第 2 级：
/// 1. 自研引擎（原文件直出，硬解 → 引擎自己软解）；
/// 2. 服务端 HLS + 系统播放器（NAS / Mac Worker 换封装或转码）：逐级降档，最后中文报错。
/// 用户限了画质、且片源比上限高时由服务端压码率，转出的 HLS 仍由自研引擎直连放（`serverStreamOnNative`）。
/// 手机存储快满不再换播放器，按剩余空间收小分片窗口（`NativeStoragePlan`）。
/// 画质、音轨、字幕按片记（`QualityMemory` 与服务端观看状态）。没有引擎选项、也没有强制引擎的开关。
///
/// ## 时间轴
/// 引擎只认「流时间」。文件时间 = `originMs` + 流时间：原文件直出与 VOD 播放列表（timeline=file）
/// 的参照点是 0；旧式会话相对列表（timeline=session）的参照点是会话起点 `start_ms`。
@MainActor
@Observable
final class PlaybackController {
    enum Phase: Equatable {
        case idle, deciding, sessionStarting, buffering, playing, degrading, consent, error, ended

        /// 转圈该不该显示：起播四段与降档重来都算「还没出画」
        var isBusy: Bool { [.deciding, .sessionStarting, .buffering, .degrading].contains(self) }

        /// 转圈时说清楚卡在哪一段（文案同 Web busyLabel）
        var busyLabel: String {
            switch self {
            case .deciding: "正在判断播放方式…"
            case .sessionStarting: "正在准备视频流…"
            case .degrading: "这一档放不出来，正在降档重试…"
            default: "正在缓冲…"
            }
        }
    }

    // MARK: 输入

    let request: PlayRequest
    let scope: PlaybackAPI

    // MARK: 条目与单元

    private(set) var info: API.PlaybackItemView?
    private(set) var episodes: [API.EpisodeView] = []
    private(set) var unit: PlaybackUnit
    private(set) var infoError: String?

    // MARK: 状态机

    private(set) var phase: Phase = .idle
    private(set) var session: API.PlaybackSessionView?
    /// 等用户拍板的决策（同意弹窗）
    private(set) var pendingDecision: API.PlaybackDecisionView?
    private(set) var errorMessage: String?
    private(set) var errorSuggestion: String?
    private var failedTiers: [Int] = []
    private var failureCount = 0
    private var attempt = 0
    private var consentGranted = false

    // MARK: 引擎

    private(set) var engine: (any PlayerEngine)?
    /// 当前会话在服务端的 id（自研引擎直出原文件时会立即释放服务端会话，此时为 nil）
    private(set) var activeSessionId: String?
    private(set) var playsOriginalFile = false
    private(set) var originMs = 0
    /// 自研引擎本单元解不了（连引擎自己的软解、原位重开都不行）：改走服务端流。只有「解不了」才设它，
    /// 网络问题从不设（`FailurePolicy`）
    private var nativeFailed = false
    /// 自研引擎一时出问题时先原位重开的额度（`NativeRetryBudget`）
    private var nativeRetries = NativeRetryBudget()
    /// 存储写满后重开：本单元往后都用最小的分片窗口、不开片源字节缓存（`NativeStoragePlan.minimal`）
    private var forceMinimalStorage = false
    /// 探片源取不取得到用的地址（原文件 / 镜像的取流地址，原盘目录里第一个文件），见 `SourceProbe`
    private var sourceProbeURL: URL?
    /// 正在处理上一次失败（探片源、等片源回来）：这期间引擎再报的失败、看门狗再判的都不再处理，新请求发出时清掉
    private var failureInFlight = false
    /// 用户是否想要播放（程序性暂停——换流、换轨——不改它）
    private(set) var wantsPlay = true
    /// 心跳发现会话没了、但用户正暂停着：等他点播放再重开
    private var deadSession = false

    // MARK: 选择与偏好

    private(set) var subtitles = SubtitleTracks()
    private(set) var selectedSubtitle: String?
    private var subtitleTouched = false
    /// 用户按暂停时正卡着（在转圈）：那是想攒缓冲，暂停期间照常下载（见 `applyPausedPrefetchPolicy`）
    private var pausedWhileStalled = false
    private var networkCostObserver: NSObjectProtocol?
    /// 起播时记着的字幕（续播记忆 / 分享页本地记忆）：清单里一时没有这条（光盘镜像要等引擎读出轨）时，补轨后再认
    private var rememberedSubtitle: String?
    private var requestedSubtitle: String?
    private var requestedAudio: String?
    private(set) var audioOptions: [AudioOption] = []
    private(set) var currentAudio: String?
    var subtitleStyle = PlayerPreferences.subtitleStyle {
        didSet {
            PlayerPreferences.subtitleStyle = subtitleStyle
            engine?.applySubtitleStyle(subtitleStyle)
        }
    }
    /// 画质上限（nil = 自动）：按这部片、当前网络环境记（`QualityMemory`）
    private(set) var quality: Int?
    /// 画质是这次打开时从记忆里取的、用户还没动过：开播提示要点明
    private var qualityFromMemory = false
    /// 开播提示「已沿用上次的选择」只在打开播放器后第一次出画时判一次（自动连播下一集不再提示）
    private var memoryNoticeChecked = false
    /// 播放时的网络环境（在家直连 / 在外面），画质记忆按它分开
    let network: PlaybackNetwork

    // MARK: 实时读数

    private(set) var positionMs = 0
    private(set) var durationMs: Int?
    private(set) var bufferedEndMs: Int?
    private(set) var paused = true
    /// 顶栏右侧与起播/缓冲转圈下方那行「↓」：网络此刻的加载速度（口径见 `LoadingSpeedMeter`）——
    /// 在下载就是实际下载速度，没在下载就是「0 KB/s」；引擎还没有读数时为 nil、不显示。
    /// 每秒按最新读数刷新，换引擎 / 换集时清掉，不沿用上一个引擎的旧值
    private(set) var speedLabel: String?
    private(set) var pipActive = false
    private(set) var notice: String?
    /// 反复卡顿时的换低画质提议（`QualitySuggestion`）：界面给一张不打断播放的卡，换不换由用户定
    private(set) var qualityOffer: QualitySuggestion.Offer?
    private(set) var holdSpeedActive = false
    /// 倍速刚结束的追赶宽限期：这之前不判直通掉帧（见 `endHoldSpeed`）
    private var frameDropGraceUntil: Date?
    private(set) var trickplay: API.TrickplayView?
    private(set) var serverDiagnostics: API.PlaybackDiagnosticsView?
    var diagnosticsOpen = false {
        didSet { restartDiagnosticsPolling() }
    }
    var nextDismissed = false
    /// 连续自动播了几集：跨集保留（换集不换控制器），用户点屏幕 / 播放暂停 / 换集等任何操作都清零（`noteUserActivity`），
    /// 到 `SkipSegments.autoNextMaxStreak` 就不再自动播
    private(set) var autoNextStreak = 0
    /// 本次倒计时走了多少（0...1）；暂停时停住，关掉卡片 / 拖出片尾 / 换集归零
    private(set) var autoNextProgress: Double = 0

    // MARK: 片段模式（刷片的「全屏观看」，见 `PlaybackClip`）

    /// 只放这一段；nil = 正常放整片。「看全片」（`leaveClip`）原地清掉它
    private(set) var clip: PlaybackClip?

    /// 时间轴起点（文件毫秒）：进度条、时间、锁屏进度都相对它显示。整片是 0，片段模式是片段起点。
    /// 内部读数（`positionMs`、跳转、字幕）始终是文件时间，只有显示换算到时间轴上
    var timelineStartMs: Int { clip?.startMs ?? 0 }

    /// 时间轴长度：整片是片长，片段模式是这一段的长度（片长未知时为 nil）
    var timelineDurationMs: Int? { clip.map { $0.endMs - $0.startMs } ?? durationMs }

    /// 文件时间 → 时间轴上的位置（片段模式下从 0 起、不超过片段长度）
    func timelineMs(fromFileMs fileMs: Int) -> Int {
        guard let clip else { return fileMs }
        return min(max(0, fileMs - clip.startMs), clip.endMs - clip.startMs)
    }

    // MARK: 内部

    private var startMsOverride: Int?
    private var overrideConsumed = false
    private var reportedStart = false
    private var lastDownlinkBps: Double?
    private var qoe = QoE()
    /// 这次播放的记录（docs/design/playback-qoe.md）：切集、错误页上重试时新建，离开时上报（所有结局都报）
    private var record: PlaybackRecord?
    /// 这次播放开始时已累计的观看时长（重试不清 `qoe`，每次播放只算自己的）
    private var recordWatchedBaseline = 0
    /// 每秒一跳：10 秒刷一次资源读数与「正在播放」标记
    private var recordTick = 0
    private var audioSessionObservers: [NSObjectProtocol] = []
    /// 起播分段计时（首帧一出上报一次，见 PlaybackStartupTrace.swift）
    private var trace = StartupTrace()
    /// 用户点播放的时刻：第一个单元的计时从这里算起（之后切集、重开从各自发请求算起）
    private var tappedAt: ContinuousClock.Instant?
    /// 卡顿归因 / 掉帧看门狗（每秒一个样本，见 PlaybackWatchdogs.swift）
    private var stallWatch = StallWatch()
    private var qualitySuggestion = QualitySuggestion()
    private var qualityOfferTask: Task<Void, Never>?
    private var frameDrops = FrameDropTracker()
    /// 同档网络重开的次数上限（见 NetworkRestartBudget）
    private var networkRestarts = NetworkRestartBudget()
    private var prematureEnd = PrematureEndGuard()
    private var reconnectBackoff = ReconnectBackoff()
    /// 已发出、还没落地的 seek：这段等待不算卡顿（QoE 口径同 Web qoe.ts），看门狗也不把它当停顿
    private var seekStartedAt: Date?
    private var backgrounded = false
    /// 拖动跟随：上一次真的跟过去的时刻与排队中的后沿落地
    private var lastScrubFollowAt = Date.distantPast
    private var scrubFollowTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    /// 在后台跑的起播协商（决策 → 开会话），见 `PlaybackAPI.negotiate`
    private var negotiationTask: Task<PlaybackAPI.Negotiation, Error>?
    private var pingTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var trickplayTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private let nowPlaying = NowPlayingBridge()
    private var closed = false
    /// 上报串行队列：start / progress / stop 按发出顺序到达。各自独立的 Task 可能乱序——
    /// stop 先到、进度后到，服务端会把刚结束的会话「复活」，还多开一行永远不收口的播放日志
    private var reportQueue: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init(request: PlayRequest, api: APIClient, requestedAt: ContinuousClock.Instant? = nil) {
        self.request = request
        tappedAt = requestedAt
        // 播放请求走独立连接池，不排在页面请求后面（见 APIClient.playbackSession）
        let playbackAPI = APIClient(server: api.server, token: api.token, session: APIClient.playbackSession)
        scope = PlaybackAPI(api: playbackAPI, shareSlug: request.shareSlug)
        unit = PlaybackUnit(mediaItemId: request.mediaItemId, season: request.season ?? 0, episode: request.episode ?? 0)
        clip = request.clip
        startMsOverride = request.startSeconds.map { Int($0 * 1000) }
        network = PlaybackNetwork.current(server: api.server)
        // 分享访客不记（进度都只记本机、按分享隔离），其余按「这部片 + 网络环境」取上次的画质；
        // 片段模式用片段自己的画质（`ReelsQuality`，竖屏刷片时选的那档），不算「沿用上次」
        if let clip = request.clip {
            quality = clip.maxHeight
        } else {
            quality = request.shareSlug == nil ? QualityMemory.quality(mediaItemId: request.mediaItemId, network: network) : nil
            qualityFromMemory = quality != nil
        }
    }

    // MARK: - 生命周期

    /// 起播已经开始（`start()` 只跑一次：点播放时路由就提前调了，播放器视图出现时不再重复）
    private(set) var started = false
    /// 播放器视图已经接管这个控制器（第一次出现）。之后再出现是系统重建视图（旋转等），接回即可
    var viewAttached = false

    /// 开发期：起播路径上主线程各步的时刻（距点击的毫秒数），找「会话回来到装载引擎」这段慢在哪
    func startupDiag(_ label: String) {
        #if DEBUG
        if let ms = trace.elapsedMs { print("[StartupDiag] \(label) \(ms) 毫秒") }
        #endif
    }

    /// 已经退出（`close()` 过）：路由据此不把它当成还在播的控制器
    var isClosed: Bool { closed }

    /// 播放器视图第一次出现。起播分段里记一个「弹出」：提前起播后它与起播协商并行，不再挡在请求前面
    func noteViewAppeared() {
        trace.mark("弹出")
    }

    /// 开始播放：加载条目信息（不挡起播）、开始第一个单元。点播放时由路由提前调（见 `Router.startPlaybackEarly`），
    /// 没有提前调的（旧入口）在播放器视图出现时调
    func start() {
        guard !started else { return }
        started = true
        let appearedAt = ContinuousClock.now
        // 上次没能收尾的播放（闪退、被系统杀掉）先转进上报队列：必须赶在这次写「正在播放」标记之前
        if scope.telemetry { PlaybackReportQueue.recoverAbnormalExit() }
        // 激活音频会话要和系统媒体服务打交道，真机上可能卡主线程几十毫秒：放到后台，
        // 起播协商与引擎读文件头都比它慢，出声之前一定已经就绪。
        // Apple TV 不在这里激活：起播前就激活会把 HDMI 按那一刻的状态锁成立体声，5.1 / 全景声被降混
        // （上游 #24）。电视上由引擎声明类别、到出声时再激活（见 NativeEngine 的音频会话说明）
        #if os(iOS)
        Task.detached { Self.activateAudioSession() }
        #endif
        // 先发起播请求，锁屏信息、远程控制这些杂事放在后面：它们不挡出画，却会把请求往后推几十毫秒
        startUnit(unit)
        trace.mark("出现", at: appearedAt)
        startupDiag("起播请求已发出")
        Task { await loadInfo() }
        nowPlaying.attach(to: self)
        // App 被结束（在后台播放时被划掉、被系统回收）：同步补发一次 stop（同网页 pagehide 的 sendBeacon），
        // 否则续播点停在最后一次心跳、活动页还挂着一个几分钟后才过期的「幽灵」会话
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportTermination() }
        }
        // 暂停期间网络变了（出门从 Wi-Fi 换到蜂窝、开关低数据模式）：按新网络重判要不要停下载
        networkCostObserver = NotificationCenter.default.addObserver(
            forName: .networkCostChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPausedPrefetchPolicy() }
        }
        observeAudioSessionForRecord()
        startTickLoop()
        startupDiag("start 完成")
    }

    /// 来电 / Siri 打断、耳机拔插：记进播放记录（不算我们的中断，看恢复得对不对）；输出变了规格快照跟着变
    private func observeAudioSessionForRecord() {
        let center = NotificationCenter.default
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { self?.record?.noteSystem(began ? "音频被系统打断（来电 / Siri 等）" : "系统打断结束") }
        })
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.record?.noteSystem("音频输出变为 \(PlaybackRecord.audioRoute())")
                self?.updateRecordDelivery()
            }
        })
    }

    /// 退出播放器：补一次停止上报与质量快照、释放服务端会话、销毁引擎
    func close() {
        guard !closed else { return }
        closed = true
        endRecord()
        leaveUnit()
        startTask?.cancel()
        tickTask?.cancel()
        diagnosticsTask?.cancel()
        trickplayTask?.cancel()
        noticeTask?.cancel()
        engine?.destroy()
        engine = nil
        nowPlaying.detach()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let networkCostObserver { NotificationCenter.default.removeObserver(networkCostObserver) }
        networkCostObserver = nil
        audioSessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        audioSessionObservers = []
        terminationObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func loadInfo() async {
        do {
            info = try await scope.item(request.mediaItemId)
            nowPlaying.update(controller: self)
        } catch is CancellationError {
        } catch {
            // 条目信息拿不到几乎必然意味着会话也开不了（同一套可见性判据）：同 Web player-page，
            // 整页换成原因 + 「返回」，停掉正在起的播放
            infoError = error.localizedDescription
            attempt += 1
            startTask?.cancel()
            engine?.pause()
            record?.noteError(message: error.localizedDescription, kind: nil, category: "item_info", stage: recordStage)
            endRecord(forceOutcome: .failed)
            leaveUnit()
            return
        }
        await loadEpisodes()
    }

    private func loadEpisodes() async {
        guard unit.isEpisode else { episodes = []; return }
        episodes = (try? await scope.episodes(unit.mediaItemId, season: unit.season)) ?? []
        nowPlaying.update(controller: self)
    }

    // MARK: - 单元切换

    /// 开始播放一个单元（首次进入、上一集/下一集）
    func startUnit(_ next: PlaybackUnit) {
        let seasonChanged = next.season != unit.season
        endRecord()
        if engine != nil || session != nil { leaveUnit() }
        unit = next
        retire(engine)
        engine = nil
        speedLabel = nil
        session = nil
        activeSessionId = nil
        pendingDecision = nil
        subtitles = SubtitleTracks()
        selectedSubtitle = nil
        subtitleTouched = false
        rememberedSubtitle = nil
        requestedAudio = nil
        requestedSubtitle = nil
        audioOptions = []
        currentAudio = nil
        trickplay = nil
        durationMs = nil
        bufferedEndMs = nil
        nextDismissed = false
        autoNextProgress = 0
        qualitySuggestion = QualitySuggestion()
        dismissQualityOffer()
        nativeFailed = false
        nativeRetries.reset()
        forceMinimalStorage = false
        sourceProbeURL = nil
        failedTiers = []
        failureCount = 0
        networkRestarts.reset()
        reconnectBackoff.reset()
        prematureEnd.reset()
        consentGranted = false
        deadSession = false
        wantsPlay = true
        qoe = QoE()
        trace = StartupTrace()
        // 第一个单元从用户点播放算起（含播放器弹出），之后的切集从发请求算起
        beginRecord(origin: .tap, at: tappedAt)
        if let tappedAt {
            trace.begin(at: tappedAt)
            self.tappedAt = nil
        }
        resetWatchdogs()
        // `startSeconds` 只覆盖进入播放器的第一个单元；其余交给服务端按观看状态定起点
        var start: Int? = overrideConsumed ? nil : startMsOverride
        overrideConsumed = true
        if start == nil, let slug = scope.shareSlug, let local = ShareLocalProgress.read(slug, next) {
            // 分享访客的续播点只在本机
            start = local.positionMs
        }
        positionMs = start ?? 0
        request(startMs: start, phase: .deciding)
        if seasonChanged { Task { await loadEpisodes() } }
        nowPlaying.update(controller: self)
    }

    /// 离开当前单元：停止上报（带轨记忆）+ 质量快照 + 释放会话
    private func leaveUnit() {
        pingTask?.cancel()
        progressTask?.cancel()
        if reportedStart {
            reportedStart = false
            let unit = self.unit, position = positionMs, audio = audioMemory, subtitle = subtitleMemory, duration = durationMs
            let fileId = reportedFileId
            let scope = self.scope
            enqueueReport {
                await scope.progress(unit, event: "stop", positionMs: position, durationMs: duration, audio: audio, subtitle: subtitle,
                                     fileId: fileId)
                NotificationCenter.default.post(name: .playbackStopReported, object: nil, userInfo: ["mediaItemId": unit.mediaItemId])
            }
        }
        if let activeSessionId {
            let scope = self.scope
            Task { await scope.stop(activeSessionId) }
        }
        activeSessionId = nil
    }

    // MARK: - 上一集 / 下一集

    /// 下一集只在**本季且有在位文件**里找——缺集要跳过（同 Web player-page）
    var nextEpisode: API.EpisodeView? {
        // 片段模式只放这一集里的一段：不出「即将播放」、不换集（「看全片」之后恢复）
        guard unit.isEpisode, clip == nil else { return nil }
        return episodes.filter { $0.episodeNumber > unit.episode && $0.owned }.min { $0.episodeNumber < $1.episodeNumber }
    }

    var previousEpisode: API.EpisodeView? {
        guard unit.isEpisode, clip == nil else { return nil }
        return episodes.filter { $0.episodeNumber < unit.episode && $0.owned }.max { $0.episodeNumber < $1.episodeNumber }
    }

    var currentEpisode: API.EpisodeView? { episodes.first { $0.episodeNumber == unit.episode } }

    func episodeLabel(_ episode: API.EpisodeView?) -> String? {
        guard unit.isEpisode else { return nil }
        let number = episode?.episodeNumber ?? unit.episode
        let code = String(format: "S%02dE%02d", unit.season, number)
        if let name = episode?.name, !name.isEmpty { return "\(code) · \(name)" }
        return code
    }

    var title: String { info?.title ?? "正在播放" }

    func playNext() {
        guard let next = nextEpisode else { return }
        startUnit(PlaybackUnit(mediaItemId: unit.mediaItemId, season: unit.season, episode: next.episodeNumber))
    }

    func playPrevious() {
        noteUserActivity()
        guard let previous = previousEpisode else { return }
        startUnit(PlaybackUnit(mediaItemId: unit.mediaItemId, season: unit.season, episode: previous.episodeNumber))
    }

    // MARK: - 自动播下一集（Netflix 同款，对照 Web video-player 的 autoNext）

    /// 认出了片尾、卡片在显示、没到连播上限：卡片倒计时，走满自动换集
    var autoNextArmed: Bool {
        showsUpNext && SkipSegments.autoNextArmed(session?.segments, at: positionMs, streak: autoNextStreak)
    }

    /// 倒计时走一步：卡片显示期间由界面每 0.1 秒调一次（卡片收起，循环随之停）。
    /// 暂停时不走；播完（`ended`）照走——片尾短于倒计时时不能卡在最后一帧
    func advanceAutoNext(by seconds: Double) {
        guard autoNextArmed else {
            autoNextProgress = 0
            return
        }
        guard !paused || phase == .ended else { return }
        autoNextProgress = min(1, autoNextProgress + seconds * 1000 / Double(SkipSegments.autoNextMs))
        guard autoNextProgress >= 1 else { return }
        autoNextProgress = 0
        autoNextStreak += 1
        playNext()
    }

    /// 有人在操作：不算「没人管的连播」，连播计数清零
    func noteUserActivity() {
        if autoNextStreak != 0 { autoNextStreak = 0 }
    }

    /// 片尾 40 秒内（或已播完）显示「即将播放」卡片。
    /// 服务端认出了一直放到结尾的片尾（docs/design/skip-intro.md）时，进了片尾就提前给，不必等到最后 40 秒，
    /// 并倒计时自动播下一集（`autoNextArmed`）
    var showsUpNext: Bool {
        guard nextEpisode != nil, !nextDismissed else { return false }
        return SkipSegments.shouldShowUpNext(
            session?.segments, at: positionMs, durationMs: durationMs, ended: phase == .ended
        )
    }

    // MARK: - 跳过片头 / 片尾

    /// 当前位置该给的「跳过」按钮：片头、广告、预告、其他段、非结尾片尾。区间是服务端整季比对认出来的、
    /// 随会话下发，这里只管按位置用。与「即将播放」卡片不同时出现（占同一个角落）；片段模式、已播完、
    /// 报错 / 要用户同意时都不给
    var skipSegment: API.PlaybackSegmentView? {
        guard clip == nil, phase != .ended, phase != .error, phase != .consent, !showsUpNext else { return nil }
        return SkipSegments.active(session?.segments, at: positionMs)
    }

    /// 点「跳过」：直接跳到这一段结束处
    func skipCurrentSegment() {
        noteUserActivity()
        guard let segment = skipSegment else { return }
        seek(toFileMs: segment.endMs, source: .button)
    }

    // MARK: - 起播（决策 / 降档 / 换会话）

    /// 去后端要一个能播的地址。phase：deciding（新请求）/ sessionStarting（换会话）/ degrading（降档）
    private func request(startMs: Int?, phase next: Phase) {
        attempt += 1
        failureInFlight = false
        let myAttempt = attempt
        phase = next
        errorMessage = nil
        errorSuggestion = nil
        pendingDecision = nil
        engine?.pause()
        if qoe.requestedAt == nil { qoe.requestedAt = Date() }
        record?.event("request", "请求播放地址（\(next)）")
        trace.begin()
        startTask?.cancel()
        negotiationTask?.cancel()
        // 请求内容在这里（主线程）一次算好，网络往返交给独立任务立刻发出、在后台整段跑完：
        // 播放器刚弹出时主线程忙着排版和转场，等主线程空出来再发请求要多排队一两百毫秒
        let inputs = negotiationInputs(startMs: startMs)
        trace.mark("算好请求")
        let scope = self.scope
        let negotiation = Task.detached { try await scope.negotiate(inputs) }
        negotiationTask = negotiation
        startTask = Task { [weak self] in
            await self?.performRequest(negotiation, startMs: startMs, attempt: myAttempt)
        }
        var preconnect = wantsNative
        #if DEBUG
        // -mcNoPreconnect YES：不预连取源连接（引擎补丁 P43 之前的行为，真机新旧对照用）
        if UserDefaults.standard.bool(forKey: "mcNoPreconnect") { preconnect = false }
        #endif
        if preconnect, let health = scope.streamURL("/api/v1/health") {
            // 取流地址要等会话回来才有，但源站就是这台服务器：先让引擎的取源连接把 TCP / TLS 握手做掉（引擎补丁 P43）。
            // 建请求在主线程上也要几毫秒（第一次还要建会话），放后台
            Task.detached(priority: .userInitiated) { NativeEngine.preconnect(url: health) }
        }
        // 会话回来后定落盘计划要用可用空间，这个查询在主线程上约 17 毫秒：趁等响应在后台先查好
        NativeStoragePlan.refreshFreeBytesInBackground()
    }

    /// 进入播放器时的单元（`request.fileId` 只属于它）
    private var initialUnit: PlaybackUnit {
        PlaybackUnit(mediaItemId: request.mediaItemId, season: request.season ?? 0, episode: request.episode ?? 0)
    }

    private func sessionBody(capability: API.ClientCapabilityIn, startMs: Int?, forNative: Bool) -> API.PlaybackSessionRequest {
        API.PlaybackSessionRequest(
            // 指定版本只对进入播放器的那个单元有效：切到别的集还带着它，会去请求上一集的文件
            fileId: unit == initialUnit ? request.fileId : nil,
            mediaItemId: unit.mediaItemId,
            seasonNumber: unit.season,
            episodeNumber: unit.episode,
            capability: capability,
            failedTiers: failedTiers.isEmpty ? nil : failedTiers,
            audioTrack: requestedAudio,
            // 自研引擎自己画图形字幕，永远不需要服务端烧录；显式传 off 挡住记忆轨触发的烧录
            subtitleTrack: forNative ? "off" : requestedSubtitle,
            maxHeight: quality,
            downlinkBps: lastDownlinkBps.map { Int($0) },
            startMs: startMs,
            // 播放记录的编号（分享访客不上报遥测，也不带）：服务端据此建「已开始」、写进取流令牌
            attemptId: scope.telemetry ? record?.id : nil,
            client: scope.telemetry ? ClientPlatform.kind : nil
        )
    }

    /// 起播协商的输入（选引擎的规则见类注释；各请求体与能力快照都在主线程算好）：
    /// 自研引擎能放原文件就申报全解码（服务端直接给档 0 原文件地址、不起 ffmpeg）；限了画质时按系统播放器的能力
    /// 申报，让服务端按上限转码。服务端流交给谁放见 `serverStreamOnNative`
    private func negotiationInputs(startMs: Int?) -> PlaybackAPI.NegotiationInputs {
        PlaybackAPI.NegotiationInputs(
            mode: wantsNative ? .native : .system,
            native: sessionBody(capability: PlayerCapability.native(), startMs: startMs, forNative: true),
            system: sessionBody(capability: PlayerCapability.avPlayer(), startMs: startMs, forNative: false),
            prepareSystemAsset: !serverStreamOnNative
        )
    }

    /// 服务端流也由自研引擎放（2026-09-28 用户拍板）：用户主动限画质时，服务端按上限转码出的 HLS 交给自研引擎
    /// 直连（引擎的 remoteBypass 通路，AVPlayer 直接取服务端 HLS），画中画、诊断、暂停策略与直出原文件同一套，
    /// 体验一致。只有自研引擎本单元已确定解不了（`nativeFailed`）时，才换系统播放器放服务端流
    private var serverStreamOnNative: Bool { !nativeFailed }

    private func performRequest(_ negotiation: Task<PlaybackAPI.Negotiation, Error>, startMs: Int?, attempt myAttempt: Int) async {
        do {
            let result = try await withTaskCancellationHandler {
                try await negotiation.value
            } onCancel: {
                negotiation.cancel()
            }
            let session = result.session
            guard myAttempt == attempt, !closed else {
                // 请求已被超越：响应里可能带着刚拉起的转码会话，此后没人认领，当场掐掉
                if let sid = session.sessionId { await scope.stop(sid) }
                return
            }
            trace.mark("开始请求", at: result.startedAt)
            trace.mark("会话", at: result.sessionAt)
            record?.noteServerTiming(result.serverTiming)
            await handleSession(
                session, useNative: result.useNative, requestedStartMs: startMs,
                preparedAsset: result.preparedAsset
            )
        } catch is CancellationError {
        } catch {
            guard myAttempt == attempt else { return }
            if phase == .sessionStarting, reportedStart, Self.isTransient(error), let delay = reconnectBackoff.nextDelay() {
                // 播放中重开时服务端暂时连不上（多半在重启）：隔几秒自动再试，不直接落到错误页
                log("reconnect-retry", ["reason": .string(error.localizedDescription), "delay_s": .int(Int(delay))])
                record?.beginReconnect(reason: error.localizedDescription)
                flash("连接中断，正在重连…")
                try? await Task.sleep(for: .seconds(delay))
                guard myAttempt == attempt, !closed else { return }
                request(startMs: positionMs, phase: .sessionStarting)
                return
            }
            fail(error.localizedDescription, suggestion: nil, category: Self.isTransient(error) ? "network" : "server")
        }
    }

    /// 服务端暂时连不上的那类失败：连接不上 / 超时 / 网关回 502、503、504（后端重启时反向代理的表现）。
    /// 409（管理员结束了播放）、404、401 这类是明确的拒绝，重试没有意义
    private static func isTransient(_ error: Error) -> Bool {
        switch error as? APIError {
        case .network, .timeout: true
        case let .http(status, _, _): [502, 503, 504].contains(status)
        default: error is URLError
        }
    }

    private func handleSession(
        _ session: API.PlaybackSessionView, useNative: Bool, requestedStartMs: Int?,
        preparedAsset: AVURLAsset? = nil
    ) async {
        startupDiag("会话处理开始")
        let decision = session.decision
        switch decision.outcome {
        case "consent":
            if let requestedSubtitle, requestedSubtitle != "off" {
                // 烧录撞上软件转码同意：自动退回旁挂渲染，不打断观看（同 Web）。
                // 图形字幕系统播放器画不了，菜单里不能还挂着选中态、画面上却什么都没有
                let dropped = subtitles.options.first { $0.ref == requestedSubtitle }
                self.requestedSubtitle = "off"
                if dropped?.kind == "pgs" {
                    selectedSubtitle = nil
                    subtitleTouched = true
                    flash("图形字幕需要服务端转码压制，当前未开启软件转码，已关闭字幕")
                }
                request(startMs: positionMs, phase: .sessionStarting)
                return
            }
            if consentGranted {
                fail("软件转码开关已保存，但服务端仍在请求开启确认",
                     suggestion: "开关可能没有生效（例如服务端刚重启）。请退出重试；若反复出现，请查看服务端日志排查。")
                return
            }
            pendingDecision = decision
            phase = .consent
            record?.beginUserWait()
            return
        case "rejected":
            fail(decision.reason, suggestion: decision.suggestion, category: "rejected")
            return
        default:
            consentGranted = false
        }
        guard let fileId = decision.fileId else {
            fail("服务端没有给出可播放的文件", suggestion: nil)
            return
        }

        // 旧会话（换轨/换画质/降档之前那条）：新会话已就位，释放它
        if let old = activeSessionId, old != session.sessionId {
            let scope = self.scope
            Task { await scope.stop(old) }
        }

        // 3. 决定地址与时间轴
        var url: URL?
        var original = false
        // 申报了全解码却拿到非档 0 的计划：服务端没有单个原文件可拉（多剪辑原盘之类），照它给的 HLS 放
        let noSingleFile = useNative && decision.tier != 0
        // 光盘直推（docs/design/disc-direct-play.md）：自研引擎申报了读光盘，服务端才会带这个标记
        let discKind = useNative ? decision.disc : nil
        if useNative, !noSingleFile, discKind == "folder" {
            // 原盘目录直推：地址是目录清单，引擎按清单逐个文件取字节，服务端不起任何进程
            url = scope.streamURL(session.streamUrl)
            original = true
            activeSessionId = nil
        } else if useNative, !noSingleFile, let token = PlaybackAPI.token(in: session.streamUrl) {
            // 自研引擎直出原文件：服务端为 remux/音频转码起的会话用不上，立刻释放
            url = scope.streamURL("/api/v1/playback/files/\(fileId)/stream?token=\(token)")
            original = true
            if let sid = session.sessionId { let scope = self.scope; Task { await scope.stop(sid) } }
            activeSessionId = nil
        } else if useNative || serverStreamOnNative {
            // 自研引擎放服务端流：没有单个原文件可拉时，或用户限了画质（服务端转码）。引擎自带直放远程 HLS 的通路；
            // 吃不带字幕组的 stream_url：文字字幕由叠加层画，免得 AVPlayer 再画一份
            url = scope.streamURL(session.streamUrl)
            activeSessionId = session.sessionId
        } else {
            // 系统播放器放 VOD 吃 master 列表（WEBVTT 字幕组让画中画 / 隔空播放时由系统渲染字幕），其余用 stream_url
            url = PlaybackAPI.systemPlayerURL(session, server: scope.api.server)
            activeSessionId = session.sessionId
        }
        guard let url else {
            fail("服务端没有给出播放地址", suggestion: nil)
            return
        }
        playsOriginalFile = original || decision.tier == 0
        originMs = (playsOriginalFile || session.timeline == "file") ? 0 : session.startMs
        if let record {
            if record.tier < 0 {
                // 这次播放的第一个会话：起播位置与是不是续播（服务端按观看状态定的起点）
                record.startPositionMs = session.startMs
                record.resumed = requestedStartMs == nil && session.startMs > 0
            }
            record.tier = decision.tier ?? -1
            record.degradedFrom = decision.degradedFrom
            record.libraryFileId = fileId
            record.hwBackend = session.hwBackend ?? ""
            record.event("session", "会话：档 \(decision.tier ?? -1)\(original ? " 原文件" : " 服务端流")\(decision.degradedFrom.map { "（从档 \($0) 降下）" } ?? "")")
        }
        if requestedStartMs == nil || positionMs == 0 { positionMs = session.startMs }
        if let duration = session.watch?.durationMs { durationMs = duration }
        self.session = session

        // 4. 轨道
        subtitles = SubtitleTracks.plan(decision.subtitles, urls: session.subtitleUrls)
        audioOptions = AudioOption.plan(decision.audioTracks)
        #if DEBUG
        // 开发期：真机无人值守验证时从控制台核对轨道是否都认出来了
        print("[Tracks] 音轨 \(audioOptions.count)：\(audioOptions.map { "\($0.ref)\($0.isDefault ? "*" : "")\($0.unavailableReason != nil ? "✕" : "")" }.joined(separator: " ")) ｜ 字幕 \(subtitles.options.count)：\(subtitles.options.map { "\($0.ref)(\($0.kind))" }.joined(separator: " "))")
        #endif
        currentAudio = requestedAudio ?? decision.audio?.trackRef
        if let burned = decision.video?.burnSubtitle {
            selectedSubtitle = burned
        } else if !subtitleTouched {
            var remembered = scope.shareSlug.flatMap { ShareLocalProgress.read($0, unit)?.subtitleTrack } ?? session.watch?.subtitleTrack
            #if DEBUG
            // 开发期：-mcSubtitle <轨引用>（embedded:N / external:文件名 / off）指定起播字幕，对照两个引擎的字幕渲染用
            if let forced = UserDefaults.standard.string(forKey: "mcSubtitle") { remembered = forced }
            #endif
            rememberedSubtitle = remembered
            selectedSubtitle = subtitles.initialSelection(remembered: remembered)
        }

        // 原盘目录：挂引擎之前先把目录清单拉下来——引擎要靠它按剪辑逐个文件取字节
        var discFiles: [NativeDiscFile]?
        if discKind == "folder" {
            let requestedAt = attempt
            do {
                discFiles = try await discFolderFiles(fileId: fileId, listing: url)
            } catch {
                guard requestedAt == attempt, !closed else { return }
                // 清单是向服务器要的：连不上是网络问题（隔几秒重开，不换播放器），404 是文件不在了，其余才算本机放不了
                if Self.isTransient(error), let delay = reconnectBackoff.nextDelay() {
                    flash("连接中断，正在重连…")
                    try? await Task.sleep(for: .seconds(delay))
                    guard requestedAt == attempt, !closed else { return }
                    request(startMs: positionMs, phase: .sessionStarting)
                    return
                }
                if case let .http(status, _, _) = error as? APIError, status == 404 {
                    failSourceMissing()
                    return
                }
                nativeFallback(reason: "原盘目录清单读取失败：\(error.localizedDescription)")
                return
            }
            // 拉清单期间用户退出、或已经发起了新的请求：这份结果作废
            guard requestedAt == attempt, !closed else { return }
        }

        #if DEBUG
        // 真机测吞吐用：-mcNetBench YES 时先对原文件地址测 1 / 2 / 4 条连接的读取速度再起播（见 NetBench）
        if UserDefaults.standard.bool(forKey: "mcNetBench"), playsOriginalFile, discKind == nil {
            await NetBench.run(url: url)
        }
        #endif

        // 5. 挂引擎
        trace.mark("建引擎")
        // 起播要缓冲是正常的：换低画质的提示从这里重新给 10 秒宽限
        qualitySuggestion.restartGrace()
        let newEngine: any PlayerEngine
        if useNative || serverStreamOnNative {
            // 自研引擎：直出原文件，或服务端流（没有单个原文件可拉、用户限了画质时，引擎按 AVPlayer 直连放）
            do {
                newEngine = try NativeEngine(playsOriginalFile: original)
            } catch {
                nativeFallback(reason: error.localizedDescription)
                return
            }
        } else {
            let avEngine = AVPlayerEngine()
            // 起播协商时已经为这个地址建好、在加载的资源：直接接上，不再从头读
            if let preparedAsset, preparedAsset.url == url { avEngine.prepare(preparedAsset) }
            newEngine = avEngine
        }
        retire(engine)
        engine = newEngine
        record?.engine = newEngine.kind.rawValue
        speedLabel = nil
        newEngine.onEvent = { [weak self, weak newEngine] event in
            guard let self, let newEngine, self.engine === newEngine else { return }
            self.handleEngineEvent(event)
        }
        newEngine.applySubtitleStyle(subtitleStyle)
        resetWatchdogs()
        let startSeconds = Double(max(0, positionMs - originMs)) / 1000
        // 起播音轨：用户这次选过、或服务端挑的不是容器默认轨（记着的、沿用上一集的、默认轨策略挑的原声）
        // → 装载时就交代给引擎，首帧就是它，不会先放容器默认轨（比如国语配音）再中途重载换过去；
        // 服务端挑的就是容器默认轨时只是默认挑选，引擎可以按实际更合适的同语言轨放
        var initialAudio: (index: Int, explicit: Bool)?
        // 光盘镜像与 DVD 目录的轨以引擎读到的为准（见 adoptEngineTracks）：服务端决策里的音轨序号对不上引擎的
        let engineOwnsDiscTracks = discKind == "image" || (discKind == "folder" && session.source?.container == "dvd")
        if original, !engineOwnsDiscTracks,
           let chosen = decision.audio?.trackRef,
           let index = AudioOption(ref: chosen, label: "", isDefault: false).embeddedIndex {
            // 容器没标默认轨（蓝光原盘的 m2ts 就不标）时，直出放的是第一条
            let containerDefault = audioOptions.first(where: \.isDefault)?.ref ?? audioOptions.first?.ref
            let explicit = requestedAudio != nil || chosen != containerDefault
            initialAudio = (index, explicit)
        } else if original, engineOwnsDiscTracks,
                  let index = (requestedAudio ?? session.watch?.audioTrack).flatMap({ AudioOption(ref: $0, label: "", isDefault: false).embeddedIndex }) {
            // 光盘镜像 / DVD 目录：服务端读不了盘内结构；这次选过或记着的轨（引擎的第 N 条）照样交给引擎
            initialAudio = (index, true)
        }
        if let initialAudio, newEngine is NativeEngine {
            // 自研引擎要在装载前交代：明确要的轨由引擎按序号直接起播，免得首帧后再重载一次
            newEngine.selectInitialAudio(embeddedIndex: initialAudio.index, explicit: initialAudio.explicit)
        }
        if let native = newEngine as? NativeEngine, original {
            native.sourceCacheKey = Self.sourceCacheKey(fileId: fileId, size: session.source?.sizeBytes)
            // MKV 精简索引（引擎补丁 P58）：服务端缓存里有就随会话下发，起播时不必再下原索引
            native.matroskaCues = session.matroskaCues.flatMap { cues in
                Data(base64Encoded: cues.data).map { (offset: Int64(cues.offset), data: $0) }
            }
            #if DEBUG
            // 开发期：-mcDebugMatroskaCues <文件 id>:<偏移>:<base64>，服务端还没下发精简索引时由实验台注入（P58 对照用）
            if native.matroskaCues == nil, let spec = UserDefaults.standard.string(forKey: "mcDebugMatroskaCues") {
                let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count == 3, Int(parts[0]) == fileId, let offset = Int64(parts[1]),
                   let data = Data(base64Encoded: parts[2]) {
                    native.matroskaCues = (offset: offset, data: data)
                }
            }
            #endif
            native.storagePlan = NativeStoragePlan.make(
                freeBytes: NativeStoragePlan.temporaryFreeBytes,
                bitrateBps: session.source?.bitRate.map(Double.init),
                forceMinimal: forceMinimalStorage
            )
            sourceProbeURL = discFiles?.first?.url ?? url
            #if DEBUG
            // 开发期：-mcFakeFreeBytes 同时交给引擎（分片留存预算、片源缓存预算按它算），复现「手机存储快满」
            let fake = UserDefaults.standard.integer(forKey: "mcFakeFreeBytes")
            NativeEngine.setTestVolumeAvailableBytes(fake > 0 ? Int64(fake) : nil)
            print("[StoragePlan] 可用 \(NativeStoragePlan.temporaryFreeBytes.map { "\($0 >> 20) MB" } ?? "未知") → \(native.storagePlan)")
            #endif
        } else {
            sourceProbeURL = nil
        }
        if let native = newEngine as? NativeEngine, original {
            // 外挂字幕交给引擎画：取服务端的原文件（编码归一成 UTF-8、不转格式），ASS 定位保留，画中画也有字幕
            native.prepareExternalSubtitles(subtitles.options.filter { !$0.path.isEmpty && $0.ref.hasPrefix("external:") }
                .compactMap { option in scope.streamURL(option.path).map { (ref: option.ref, url: $0, language: option.language) } })
        }
        if let native = newEngine as? NativeEngine, discKind == "image" {
            native.load(disc: .image(url), start: startSeconds, autoplay: wantsPlay)
        } else if let native = newEngine as? NativeEngine, let discFiles {
            native.load(disc: .folder(files: discFiles, playlist: decision.discPlaylist),
                        start: startSeconds, autoplay: wantsPlay)
        } else {
            newEngine.load(url: url, start: startSeconds, autoplay: wantsPlay)
        }
        startupDiag("装载已发出")
        trace.mark("引擎")
        if let initialAudio, !(newEngine is NativeEngine) {
            newEngine.selectInitialAudio(embeddedIndex: initialAudio.index, explicit: initialAudio.explicit)
        }
        applySubtitleToEngine()
        applySystemSubtitle()
        phase = .buffering
        deadSession = false
        startPingLoop()
        loadTrickplay(fileId: fileId, token: PlaybackAPI.token(in: session.streamUrl))
        restartDiagnosticsPolling()
        nowPlaying.update(controller: self)
    }

    /// 画质上限真的在限：片源比上限高（还不知道片源多高时按在限算）。上限不低于片源等于没限，照样由自研引擎直出原文件
    private var qualityLimited: Bool {
        guard let quality else { return false }
        return (Self.height(of: session?.source?.resolution) ?? .max) > quality
    }

    /// 片源字节缓存的键（内置引擎补丁 P22）：取流地址每次都带新令牌，用「文件 id + 大小」认同一个文件——
    /// 断线重连、换引擎实例都换了地址，缓存照样接得上；文件在 NAS 上被换掉时大小一变，就是另一份缓存
    static func sourceCacheKey(fileId: Int, size: Int?) -> String {
        "file-\(fileId)-\(size ?? 0)"
    }

    /// 「2160p」「1080i」→ 2160 / 1080
    private static func height(of resolution: String?) -> Int? {
        resolution.flatMap { Int($0.filter(\.isNumber)) }
    }

    /// 片源不在了（服务端对原文件回 404）：换什么播放器都一样，直接说明
    private func failSourceMissing() {
        fail("服务器上找不到这个文件", suggestion: "文件可能被移动、删除，或存放它的磁盘没有挂上。检查后点「重试」。",
             category: "source_missing")
    }

    private func fail(_ message: String, suggestion: String?, category: String = "unknown") {
        #if DEBUG
        print("[PlayerError] \(message)｜\(suggestion ?? "-")")
        #endif
        record?.noteError(message: message, kind: (engine as? NativeEngine)?.lastFailureKind, category: category, stage: recordStage)
        engine?.pause()
        phase = .error
        errorMessage = message
        errorSuggestion = suggestion
        session = nil
    }

    /// 原盘目录清单（`/playback/files/{id}/disc?token=`）→ 引擎要的文件列表（各文件地址已带取流令牌）
    private func discFolderFiles(fileId: Int, listing: URL) async throws -> [NativeDiscFile] {
        guard let token = PlaybackAPI.token(in: listing.absoluteString) else {
            throw APIError.decoding("目录清单地址缺少取流令牌")
        }
        let view = try await scope.api.playbackFileDiscList(fileId: fileId, token: token)
        return view.files.compactMap { file in
            scope.streamURL(file.url).map { NativeDiscFile(path: file.path, size: Int64(file.size), url: $0) }
        }
    }

    /// 这次该不该用自研引擎：默认就用，它是兜底阶梯的第一级（docs/design/player-engine.md §3）。
    /// 不用的情况只有两种：本单元确定在本机解不了（网络问题从不算）；用户限了画质（服务端转码）。
    /// 手机存储快满不再换播放器：按剩余空间收小分片窗口（`NativeStoragePlan`，2026-09-27 真机可用 197 MB 时
    /// 《他是谁》起播失败即此，原来的做法是低于 512 MB 直接走服务端流）
    private var wantsNative: Bool {
        !nativeFailed && !qualityLimited
    }

    /// 自研引擎在本机放不了（连引擎自己的软解也不行）：本单元改走服务端 HLS + 系统播放器
    private func nativeFallback(reason: String) {
        record?.noteFallback(reason: reason)
        #if DEBUG
        print("[EngineFallback] 自研引擎 → 服务端流：\(reason)")
        // 引擎测试不许起服务端转码（转码器上会留下记录）：-mcNoServerFallback YES 时停在错误页
        if UserDefaults.standard.bool(forKey: "mcNoServerFallback") {
            fail("自研引擎放不了：\(reason)", suggestion: "测试开关 -mcNoServerFallback 拦下了改走服务端流", category: "decode")
            return
        }
        #endif
        nativeFailed = true
        log("engine-fallback", [
            "from": .string("native"), "reason": .string(reason),
            "media_item_id": .int(unit.mediaItemId),
        ])
        flash("本机解不了这个文件，改由服务端转换后播放")
        request(startMs: positionMs, phase: .sessionStarting)
    }

    /// 换下旧引擎（切集、换会话、回落）
    private func retire(_ old: (any PlayerEngine)?) {
        old?.destroy()
    }

    // MARK: - 用户操作：重试 / 同意

    func retry() {
        // 错误页上点重试：上一次播放以失败收尾，这是新的一次
        record?.noteBehavior("retry")
        endRecord()
        beginRecord(origin: .retry, at: nil)
        failedTiers = []
        failureCount = 0
        networkRestarts.reset()
        reconnectBackoff.reset()
        nativeRetries.reset()
        request(startMs: positionMs, phase: .deciding)
    }

    /// 同意弹窗「开启并播放」：写入全局开关后重新决策
    func grantConsent() async throws {
        let saved = try await scope.api.playbackPolicySet(body: API.PlaybackPolicyPayload(softwareTranscodeEnabled: true))
        // 保存接口回显的是落库后的取值：不是 true 说明开关根本没生效，不能假装成功
        guard saved.softwareTranscodeEnabled else {
            throw APIError.http(status: 500, message: "软件转码开关保存后未生效，请重试或查看服务端日志", code: nil)
        }
        consentGranted = true
        record?.endUserWait()
        request(startMs: positionMs, phase: .deciding)
    }

    // MARK: - 引擎事件

    private func handleEngineEvent(_ event: EngineEvent) {
        switch event {
        case .playing:
            let wasPaused = paused
            paused = false
            record?.notePlaying()
            if let since = seekStartedAt {
                qoe.lastSeekMs = Int(Date().timeIntervalSince(since) * 1000)
                seekStartedAt = nil
            }
            // 系统播放器不报「落点画面到了」：以恢复播放为准（自研引擎等 `.seekPresented`）
            if engine?.kind == .avPlayer, let spent = record?.seekPresented() { qoe.lastSeekMs = spent }
            guard [.buffering, .playing, .ended].contains(phase) else { return }
            if phase == .buffering, qoe.bufferingSince != nil { qoe.endRebuffer() }
            phase = .playing
            failureCount = 0
            networkRestarts.reachedPlaying()
            reconnectBackoff.reset()
            if !memoryNoticeChecked {
                // 出画这一刻提示（转圈时提示会被忽略）
                memoryNoticeChecked = true
                if let notice = rememberedChoiceNotice() {
                    flash(notice)
                    #if DEBUG
                    print("[MemoryNotice] \(notice)")
                    #endif
                }
                #if DEBUG
                // 开发期：-mcFakeQualityOffer <秒> 出画 N 秒后弹一张换画质提议卡，截图验界面用（不点就不会真的转码）
                let fakeOfferDelay = UserDefaults.standard.integer(forKey: "mcFakeQualityOffer")
                if fakeOfferDelay > 0 {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(fakeOfferDelay))
                        self?.qualityOffer = .init(measuredBps: 54_000_000, requiredBps: 76_000_000, maxHeight: 1080)
                        print("[QualityOffer] 模拟提议已弹出")
                    }
                }
                #endif
            }
            if !trace.has("播放") {
                trace.mark("播放")
                reportStartupIfComplete()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.reportStartupIfComplete(force: true)
                }
            }
            if !reportedStart {
                // 片段模式不写观看记录：一直不报「开始」，之后的进度、停止也就都不报（它们都认 reportedStart）
                if clip == nil { reportStart() }
            } else if wasPaused {
                // 只在从暂停恢复时补报一次；缓冲结束、状态抖动回到播放不报（10 秒一次的进度循环照常）——
                // 否则引擎状态一抖就一秒几十条上报（系统播放器起播时实测 20 秒 160 多条）
                sendProgress(paused: false)
            }
        case .paused:
            paused = true
            seekStartedAt = nil
            if engine?.kind == .avPlayer, let spent = record?.seekPresented() { qoe.lastSeekMs = spent }
            // 引擎已就绪却停在「缓冲」（暂停中拖动、以暂停状态起播）：回到正常态，否则转圈不消、10 秒心跳也停发，
            // 活动页几分钟后就把这个会话丢了
            if phase == .buffering, engine?.duration != nil {
                if qoe.bufferingSince != nil { qoe.endRebuffer() }
                phase = .playing
            }
            // 换会话 / 降档时控制器自己按的暂停（request 里的 engine.pause）不上报：那不是用户暂停
            if reportedStart, !phase.isBusy { sendProgress(paused: true) }
        case .buffering:
            if phase == .playing {
                phase = .buffering
                // seek 造成的等待是「跳转耗时」，不是卡顿（同 Web qoe.ts 口径）
                if seekStartedAt == nil { qoe.beginRebuffer() }
            }
            if holdSpeedActive, (engine?.bufferedEnd ?? 0) - (engine?.currentTime ?? 0) < 1 {
                // 倍速吃光了前向缓冲：退回原速
                endHoldSpeed()
                flash("缓冲跟不上，已退出 2 倍速")
            }
        case .ended:
            guard [.buffering, .playing].contains(phase) else { return }
            if prematureEnd.shouldResume(positionMs: positionMs, durationMs: durationMs) {
                // 离片尾还远就报播完：取流断了（直出遇上服务端重启就可能这样），从当前位置重开，
                // 不进「已播完」——否则弹出「即将播放下一集」并把进度报成停在半路
                log("premature-end", [
                    "engine": .string(engine?.kind.rawValue ?? ""), "position_ms": .int(positionMs),
                    "duration_ms": durationMs.map { .int($0) } ?? .null,
                ])
                request(startMs: positionMs, phase: .sessionStarting)
                return
            }
            phase = .ended
            paused = true
            record?.event("ended", "播完")
            // 引擎报「播完」不一定真到了片尾（断流也可能报 eof）：离片尾 5 秒内才吸附到片长，
            // 否则按真实位置上报——片长会让服务端直接标「已看」
            if let durationMs, durationMs - positionMs <= 5000 { positionMs = durationMs }
            if reportedStart { sendProgress(paused: true) }
        case let .failed(reason, cause):
            record?.noteEngineFailure(reason: reason, kind: (engine as? NativeEngine)?.lastFailureKind, cause: "\(cause)")
            engineReportedFailure(reason: reason, cause: cause)
        case let .pictureInPicture(active):
            pipActive = active
            record?.event("pip", active ? "进入画中画" : "退出画中画")
        case .tracksChanged:
            adoptEngineTracks()
        case let .milestone(milestone):
            switch milestone {
            case .ready: trace.mark("就绪")
            case .seeked: trace.mark("定位")
            case .firstFrame:
                trace.mark("首帧")
                record?.noteFirstFrame()
                updateRecordDelivery()
            }
            reportStartupIfComplete()
        case let .startupStage(name):
            record?.noteEngineStage(name)
        case .seekPresented:
            if let spent = record?.seekPresented() { qoe.lastSeekMs = spent }
        case .seekFailed:
            record?.closeSeek(outcome: "failed")
        }
    }

    /// 首帧上屏且已开始播放：把起播分段上报一次（服务端日志一行「起播分段」，开发期同时打控制台）。
    /// 引擎给不出首帧信号时（极少数流），开始播放 3 秒后照样报，只是缺「首帧」一项
    private func reportStartupIfComplete(force: Bool = false) {
        guard trace.has("播放"), force || trace.has("首帧"), let marks = trace.finish() else { return }
        record?.noteStartupMarks(marks.map { ($0.name, $0.ms) })
        var detail: [String: API.JSONValue] = [
            "engine": .string(engine?.kind.rawValue ?? ""),
            "tier": session?.decision.tier.map { .int($0) } ?? .null,
            "original": .bool(playsOriginalFile),
            "start_ms": .int(positionMs),
            "media_item_id": .int(unit.mediaItemId),
            "file_id": session?.decision.fileId.map { .int($0) } ?? .null,
        ]
        for mark in marks { detail[mark.name] = .int(mark.ms) }
        #if DEBUG
        print("[StartupTrace] \(engine?.kind.rawValue ?? "-") 档 \(session?.decision.tier ?? -1) \(playsOriginalFile ? "原文件" : "服务端流")：\(StartupTrace.summary(marks))")
        #endif
        log("startup", detail)
    }

    /// 引擎报的失败。自研引擎直出原文件时报「解不了」，先探一下片源取不取得到：起播那一刻断线、超时，
    /// 引擎只知道「打不开」（故障注入实测：取流被拒 6 秒就被当成解不了、改走了服务端流）；404 是文件不在了
    private func engineReportedFailure(reason: String, cause: EngineFailureCause) {
        guard !failureInFlight, [.buffering, .playing, .ended].contains(phase), session != nil else { return }
        guard engine?.kind == .native, playsOriginalFile, cause == .decode || cause == .decodeFinal,
              let probeURL = sourceProbeURL else {
            engineFailed(reason: reason, cause: cause)
            return
        }
        failureInFlight = true
        let failedAttempt = attempt
        Task { [weak self] in
            let verdict = await SourceProbe.check(probeURL)
            guard let self, failedAttempt == self.attempt, !self.closed else { return }
            self.failureInFlight = false
            switch verdict {
            case .reachable:
                self.engineFailed(reason: reason, cause: cause)
            case .missing:
                self.engineFailed(reason: reason, cause: .sourceMissing)
            case let .unreachable(why):
                self.engineFailed(reason: "取不到片源（\(why)）：\(reason)", cause: .network)
            }
        }
    }

    /// 播放链路失败：按 `FailurePolicy` 走——网络问题等片源回来原地重开，一时的问题原位重开，
    /// 确定解不了才换播放器 / 降档；线路慢不会走到这里
    private func engineFailed(reason: String, cause: EngineFailureCause) {
        guard !failureInFlight, [.buffering, .playing, .ended].contains(phase), let session else { return }
        log("playback-error", [
            "engine": .string(engine?.kind.rawValue ?? ""), "reason": .string(reason),
            "tier": session.decision.tier.map { .int($0) } ?? .null,
        ])
        let nativeOriginal = engine?.kind == .native && playsOriginalFile
        let response = FailurePolicy.decide(FailurePolicy.Input(
            engine: engine?.kind ?? .avPlayer,
            cause: cause,
            playsOriginalFile: playsOriginalFile,
            restartAllowed: cause == .network && networkRestarts.allowRestart(),
            // 额度只在真要用时才扣
            nativeRetryAllowed: nativeOriginal && (cause == .decode || cause == .storageFull) && nativeRetries.allowRetry()
        ))
        #if DEBUG
        print("[EngineFailed] engine=\(engine?.kind.rawValue ?? "-") cause=\(cause) original=\(playsOriginalFile) → \(response)｜\(reason)")
        #endif
        switch response {
        case .reconnect:
            // 断线、token 过期、服务端重启：同引擎、同片源原地重开（新会话 = 新 token）。原文件直出先等片源取得到
            // （awaitSourceThenReconnect）；服务端还没起来时重开请求本身会失败，按退避重试（ReconnectBackoff），见 performRequest
            log("network-restart", ["reason": .string(reason), "attempt": .int(networkRestarts.consecutive)])
            record?.beginReconnect(reason: reason)
            if nativeOriginal, let probeURL = sourceProbeURL {
                awaitSourceThenReconnect(reason: reason, probeURL: probeURL)
            } else {
                request(startMs: positionMs, phase: .sessionStarting)
            }
        case .retryNative:
            log("native-retry", ["reason": .string(reason)])
            record?.event("native_retry", "原位重开：\(reason)")
            flash("播放出了点问题，正在原位重开")
            request(startMs: positionMs, phase: .sessionStarting)
        case .retryNativeLowStorage:
            log("native-retry", ["reason": .string(reason), "low_storage": .bool(true)])
            record?.event("native_retry", "存储不足，收小缓存重开：\(reason)")
            forceMinimalStorage = true
            flash("手机存储空间不足，已减小缓存后继续播放")
            request(startMs: positionMs, phase: .sessionStarting)
        case .failSourceMissing:
            log("source-missing", ["reason": .string(reason)])
            failSourceMissing()
        case .failNetwork:
            log("network-restart-exhausted", ["reason": .string(reason)])
            fail("连接中断，重连了几次都没成功（\(reason)）", suggestion: "检查网络后点「重试」，会从刚才的位置接着放。",
                 category: "network")
        case .fallbackToServerStream:
            nativeFallback(reason: reason)
        case .stepDownTier:
            if cause == .network {
                // 服务端流连续重开都没能出画：「网络」归因多半不对，按这一档放不了往下走
                log("network-restart-exhausted", ["reason": .string(reason)])
            }
            stepDownTier(reason: reason, session: session)
        }
    }

    /// 原文件直出断了：等片源取得到再原位重开（每次重开都是新会话、新取流令牌）。片源一直取不到就按
    /// 2、4、8、15、15、15 秒的间隔再探（约 1 分钟），还不行落错误页让用户重试——换服务端流要一样的线路
    private func awaitSourceThenReconnect(reason: String, probeURL: URL) {
        failureInFlight = true
        let myAttempt = attempt
        phase = .sessionStarting
        flash("连接中断，正在重连…")
        Task { [weak self] in
            var backoff = ReconnectBackoff()
            while true {
                let verdict = await SourceProbe.check(probeURL)
                guard let self, myAttempt == self.attempt, !self.closed else { return }
                switch verdict {
                case .reachable:
                    self.request(startMs: self.positionMs, phase: .sessionStarting)
                    return
                case .missing:
                    self.failureInFlight = false
                    self.failSourceMissing()
                    return
                case let .unreachable(why):
                    guard let delay = backoff.nextDelay() else {
                        self.failureInFlight = false
                        self.log("network-restart-exhausted", ["reason": .string(why)])
                        self.fail("连接中断，重连了几次都没成功（\(why)）", suggestion: "检查网络后点「重试」，会从刚才的位置接着放。",
                                  category: "network")
                        return
                    }
                    #if DEBUG
                    print("[SourceProbe] 取不到片源（\(why)），\(Int(delay)) 秒后再试")
                    #endif
                    try? await Task.sleep(for: .seconds(delay))
                    guard myAttempt == self.attempt, !self.closed else { return }
                }
            }
        }
    }

    /// 服务端这一档放不了：逐级降档；连败两次说明「逐级试」的假设不成立，兜底档以下全标失败一步到位
    private func stepDownTier(reason: String, session: API.PlaybackSessionView) {
        guard let tier = session.decision.tier else {
            fail(reason, suggestion: nil)
            return
        }
        var accumulated = Set(failedTiers)
        accumulated.insert(tier)
        if failureCount + 1 >= 2 { (0 ..< 4).forEach { accumulated.insert($0) } }
        failedTiers = accumulated.sorted()
        failureCount += 1
        if tier >= 4 {
            fail(reason, suggestion: "可以换一个版本重试；若反复出现，请打开「⋯ → 播放诊断」查看原因。", category: "decode")
            return
        }
        request(startMs: positionMs, phase: .degrading)
    }

    // MARK: - 播放控制

    func togglePlay() {
        noteUserActivity()
        guard let engine else { return }
        if phase == .ended {
            seek(toFileMs: timelineStartMs, source: .restart)
            wantsPlay = true
            engine.play()
            return
        }
        if engine.isPaused {
            wantsPlay = true
            // 用户暂停攒过缓冲再接着看：卡顿提示从恢复这一刻重新计
            qualitySuggestion.restartGrace()
            if deadSession {
                // 会话在暂停期间被回收了：从当前位置重开
                request(startMs: positionMs, phase: .sessionStarting)
                return
            }
            engine.play()
        } else {
            wantsPlay = false
            // 卡着的时候按暂停，多半是想攒缓冲：照常往前下（线路慢时前向缓冲已放大到 3 分钟，见 P20）
            pausedWhileStalled = phase == .buffering
            engine.pause()
            applyPausedPrefetchPolicy()
        }
    }

    /// 暂停时要不要连下载也停（2026-09-28 用户拍板：按网络类型决定）：计费网络（蜂窝、个人热点、低数据模式）上停，
    /// 暂停着不看了就不会白下；Wi-Fi 上照常攒到前向窗口，不花钱，恢复后更稳；卡着时按的暂停照常下。
    /// 恢复播放时 `NativeEngine.play()` 一律解除。暂停期间网络变了（出门从 Wi-Fi 换到蜂窝）再判一次
    private func applyPausedPrefetchPolicy() {
        guard !wantsPlay, let engine else { return }
        engine.setPrefetchSuspended(!pausedWhileStalled && NetworkCost.shared.isMetered)
    }

    func play() { if engine?.isPaused == true { togglePlay() } }
    func pause() { if engine?.isPaused == false { togglePlay() } }

    /// 相对跳转（±10 秒按钮、双击、锁屏遥控）：按关键帧，快
    func seek(by seconds: Double, source: PlaybackRecord.SeekSource = .unknown) {
        seek(toFileMs: positionMs + Int(seconds * 1000), exact: false, source: source)
    }

    /// 跳到文件时间（毫秒）。`source` 进播放记录（按键 / 拖动 / 锁屏……分开看哪种慢）
    func seek(toFileMs raw: Int, exact: Bool = true, source: PlaybackRecord.SeekSource = .unknown) {
        // 先夹进片长之内：越过片尾的落点会开出一个什么也转不出来的会话
        var target = max(0, raw)
        if let durationMs, durationMs > 1000 { target = min(target, durationMs - 1000) }
        if let clip { target = Self.clamp(target, into: clip) }
        scrubFollowTask?.cancel()
        let buffered = bufferedEndMs.map { target >= positionMs && target <= $0 } ?? false
        guard let engine, session != nil, phase != .sessionStarting, phase != .deciding, phase != .degrading else {
            // 会话正在重开的空档：改走换会话，新会话直接从目标位置起
            if phase.isBusy, session == nil, phase != .deciding || positionMs > 0 {
                record?.beginSeek(source: source, fromMs: positionMs, toMs: target, buffered: false, paused: !wantsPlay, restart: true)
                positionMs = target
                request(startMs: target, phase: .sessionStarting)
            }
            return
        }
        if session?.timeline == "session", activeSessionId != nil, !withinSessionBuffer(target) {
            // 旧式会话相对列表只覆盖已转出的部分：落点在区间外才换会话，区间内原地跳（同 Web planSeek）
            record?.beginSeek(source: source, fromMs: positionMs, toMs: target, buffered: false, paused: engine.isPaused, restart: true)
            positionMs = target
            request(startMs: target, phase: .sessionStarting)
            return
        }
        record?.beginSeek(source: source, fromMs: positionMs, toMs: target, buffered: buffered, paused: engine.isPaused, restart: false)
        positionMs = target
        if phase == .ended { phase = .buffering }
        seekStartedAt = Date()
        qualitySuggestion.restartGrace()
        stallWatch.reset()
        frameDrops.reset()
        engine.seek(to: Double(target - originMs) / 1000, exact: exact)
    }

    /// 落点是否在当前会话已转出的区间里（会话起点 ~ 已缓冲尾）
    private func withinSessionBuffer(_ fileMs: Int) -> Bool {
        guard let bufferedEndMs else { return false }
        return fileMs >= originMs && fileMs <= bufferedEndMs
    }

    // MARK: 拖动跟随

    /// 拖动进度条途中让画面跟着手指走（对应 Web scrub-follow.ts）：跳转便宜时（落点在缓冲里）10Hz 跟随，
    /// 原文件直出拖出缓冲时只在手指停住后跟一次，其余情况松手才跳。跟随不计入 seek 次数，松手那次才算
    func scrubFollow(toFileMs raw: Int) {
        guard let engine, session != nil, [.playing, .buffering, .ended].contains(phase) else { return }
        let target = clip.map { Self.clamp(raw, into: $0) } ?? raw
        // 连续拖动的跳转耗时以第一次拖动为起点（松手那次 seek 结束计时）
        record?.noteScrubActivity()
        let reachable = target >= originMs
        let cheap = target >= positionMs - 1000 && target <= (bufferedEndMs ?? 0)
        let now = Date()
        let plan = ScrubFollow.plan(
            nowMs: Int(now.timeIntervalSince1970 * 1000),
            lastFollowMs: Int(lastScrubFollowAt.timeIntervalSince1970 * 1000),
            cheap: cheap, reachable: reachable, settleOnly: playsOriginalFile
        )
        scrubFollowTask?.cancel()
        switch plan {
        case .skip:
            return
        case .follow:
            lastScrubFollowAt = now
            engine.seek(to: Double(target - originMs) / 1000, exact: false)
        case let .deferred(ms):
            scrubFollowTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(ms))
                guard let self, !Task.isCancelled, let engine = self.engine else { return }
                self.lastScrubFollowAt = Date()
                engine.seek(to: Double(target - self.originMs) / 1000, exact: false)
            }
        }
    }

    // MARK: 长按 2 倍速

    /// 现在能不能起长按倍速（同 Web canHoldSpeed：暂停时不行，松手按轻点处理）
    var canHoldSpeed: Bool { engine.map { !$0.isPaused } ?? false && phase == .playing }

    func beginHoldSpeed() -> Bool {
        guard let engine, !engine.isPaused, phase == .playing else { return false }
        holdSpeedActive = true
        engine.setRate(2)
        frameDrops.reset()
        return true
    }

    func endHoldSpeed() {
        guard holdSpeedActive else { return }
        holdSpeedActive = false
        engine?.setRate(1)
        // 倍速期间视频被音频甩在后面，回到原速后引擎还要丢几秒帧才追平（真机 4K 60 帧约 6 秒）：
        // 这段不判掉帧，宽限期过后从头统计
        frameDrops.reset()
        frameDropGraceUntil = Date().addingTimeInterval(8)
    }

    // MARK: 画中画

    /// 画中画按钮显不显示：自研引擎两条通路（主力通路的 AVPlayerLayer、软件通路的显示层）与系统播放器都原地进出；
    /// 显示层还没就绪时先不显示，等它就绪，不为画中画改拉服务端流（那会让 NAS 起转码）
    /// 片段模式不给画中画：小窗里是系统自己的进度条，只认整部片的时长，与「这一段」的时间轴对不上
    var pictureInPictureAvailable: Bool { clip == nil && engine?.supportsPictureInPicture ?? false }

    func togglePictureInPicture() {
        guard let engine, engine.supportsPictureInPicture else { return }
        engine.togglePictureInPicture()
    }

    // MARK: - 音轨 / 字幕 / 画质 / 引擎

    /// 换音轨：自研引擎直出原文件时原地切换；否则带着当前位置重开会话（服务端流的音轨在开会话时就定死了）
    func selectAudio(_ ref: String) {
        let previous = currentAudio
        requestedAudio = ref
        if ref != previous {
            record?.noteAudioChange(from: previous, to: ref)
            // 新音轨出声才算换完：自研引擎原地重载后出首帧、服务端流是新会话的首帧（见 noteFirstFrame）
            record?.beginSwitch(kind: "audio", from: previous, to: ref)
        }
        if let engine, engine.canSwitchAudioInPlace, let index = AudioOption(ref: ref, label: "", isDefault: false).embeddedIndex {
            engine.selectAudio(embeddedIndex: index)
            currentAudio = ref
            sendProgress(paused: engine.isPaused)
            return
        }
        guard ref != (session?.decision.audio?.trackRef) else {
            record?.closeSwitch(immediate: true)
            return
        }
        wantsPlay = true
        request(startMs: positionMs, phase: .sessionStarting)
    }

    /// 换音轨是否需要重开会话（菜单里据此显示提示）
    var audioSwitchRestarts: Bool { !(engine?.canSwitchAudioInPlace ?? false) }

    /// 当前正在服务端烧录的字幕轨
    var burnedSubtitle: String? { session?.decision.video?.burnSubtitle }

    /// 当前选中的字幕轨
    private var selectedOption: SubtitleOption? {
        selectedSubtitle.flatMap { ref in subtitles.options.first { $0.ref == ref } }
    }

    /// 当前字幕由引擎自己画：自研引擎画它读到的内封轨与交给它的外挂字幕（见 `NativeEngine.rendersSubtitle`）；
    /// 系统播放器只放服务端流，文字字幕由叠加层用系统字体画，图形字幕由服务端压制进画面
    var engineRendersSubtitles: Bool {
        guard let engine, let option = selectedOption else { return false }
        return engine.rendersSubtitle(option)
    }

    /// 选图形字幕要服务端压制进画面（放服务端流时，不论哪个引擎），菜单里提前说明代价
    var graphicSubtitlesBurnIn: Bool { engine?.kind == .avPlayer || (engine != nil && !playsOriginalFile) }

    func selectSubtitle(_ ref: String?) {
        if ref != selectedSubtitle {
            record?.noteSubtitleChange(from: selectedSubtitle, to: ref)
            record?.beginSwitch(kind: "subtitle", from: selectedSubtitle, to: ref)
        }
        // 不用重开会话的切换即刻生效；要服务端压制 / 撤下压制的等新会话首帧
        defer {
            if phase != .sessionStarting { record?.closeSwitch(immediate: true) }
            updateRecordDelivery()
        }
        subtitleTouched = true
        selectedSubtitle = ref
        let target = ref.flatMap { ref in subtitles.options.first { $0.ref == ref } }
        if engine?.kind == .native, playsOriginalFile {
            // 自研引擎直出原文件：字幕交给引擎画（在 applySubtitleToEngine 里分流）
            applySubtitleToEngine()
            if burnedSubtitle != nil {
                // 自研引擎在放烧录过的服务端流：撤下烧录
                requestedSubtitle = "off"
                request(startMs: positionMs, phase: .sessionStarting)
            }
            if reportedStart { sendProgress(paused: paused) }
            return
        }
        applySystemSubtitle()
        let wantBurn = target?.kind == "pgs"
        if !wantBurn, burnedSubtitle == nil {
            // 纯文本切换，叠加层搞定
            if reportedStart { sendProgress(paused: paused) }
            return
        }
        if wantBurn, burnedSubtitle == ref { return }
        // 图形字幕（PGS）：系统播放器渲染不了，服务端转码压制进画面（约一秒切换）
        requestedSubtitle = ref ?? "off"
        wantsPlay = true
        request(startMs: positionMs, phase: .sessionStarting)
    }

    /// 把当前字幕对应到 master 字幕组的下标，交给 AVPlayer 在画中画 / 隔空播放时由系统渲染。
    /// master 字幕组按会话字幕计划的顺序只收文本类（vtt/ass），与服务端 `_master_subtitle_tracks` 一致
    private func applySystemSubtitle() {
        guard let avPlayer = engine as? AVPlayerEngine else { return }
        guard session?.masterUrl != nil, session?.timeline == "file", burnedSubtitle == nil, let ref = selectedSubtitle,
              let plans = session?.decision.subtitles else {
            avPlayer.systemSubtitleIndex = nil
            return
        }
        let textPlans = plans.filter { ["vtt", "ass"].contains($0.kind) }
        avPlayer.systemSubtitleIndex = textPlans.firstIndex { $0.trackRef == ref }
    }

    /// 叠加层要渲染的文本字幕（两个引擎通用）：ASS 由服务端转成 VTT 纯文本。
    /// 隔空播放时字幕由系统画在电视上，本机叠加层收起
    var overlaySubtitleURL: URL? {
        guard !engineRendersSubtitles, burnedSubtitle == nil, !((engine as? AVPlayerEngine)?.systemSubtitlesActive ?? false),
              let ref = selectedSubtitle,
              let option = subtitles.options.first(where: { $0.ref == ref }), option.kind != "pgs" else { return nil }
        return scope.streamURL(option.path + "&format=vtt" + clipWindowQuery(for: option))
    }

    /// 片段模式（刷片横过来的全屏）只要片段前后这一小段的内封字幕：整轨抽取要 NAS 通读整个文件，
    /// 大文件几十秒，片段等不到就放弃、抽取随之取消，字幕永远出不来。窗口与刷片竖屏同口径
    /// （服务端 `SUBTITLE_PREROLL_MS` / `SUBTITLE_TAIL_MS`）；退出片段模式看全片时回到整轨
    private func clipWindowQuery(for option: SubtitleOption) -> String {
        guard let clip, option.embeddedIndex != nil else { return "" }
        return "&start_ms=\(max(0, clip.startMs - 10_000))&end_ms=\(clip.endMs + 5_000)"
    }

    /// 把引擎自己画的字幕交给引擎；其余一律让引擎关掉字幕、由叠加层画
    private func applySubtitleToEngine() {
        guard let engine else { return }
        let own = selectedOption.flatMap { engine.rendersSubtitle($0) ? $0 : nil }
        engine.selectSubtitle(own, url: own.flatMap { scope.streamURL($0.path) })
        #if DEBUG
        print("[Tracks] 字幕选择 \(selectedSubtitle ?? "off") → \(own != nil ? "引擎画" : (selectedOption != nil ? "叠加层画" : "关闭"))")
        #endif
    }

    /// 自研引擎读到、服务端清单里没有的轨补进菜单（docs/design/disc-direct-play.md「轨道」）。
    ///
    /// 菜单本来按服务端的探测结果列轨，可服务端读不了光盘镜像的盘内结构（ISO 的音轨、字幕清单都是空的），
    /// DVB / ARIB / VobSub 这类图形字幕它也不提供。自研引擎自己读容器、自己画内封字幕，这些轨对它和服务端
    /// 认得的轨没有区别：引用仍是 embedded:N（第 N 条内封轨，与服务端探测顺序一致），选轨、记忆、上报照旧。
    /// 换到别的引擎时会话重开、清单按服务端重建，补进来的轨随之消失
    private func adoptEngineTracks() {
        guard let native = engine as? NativeEngine else { return }
        // 光盘镜像：服务端的清单只是它对整个镜像的猜测（实测《聪明的一休》DVD 镜像把菜单 VOB 里的音轨也算上，
        // 报 3 条音轨，主片其实只有 1 条），以引擎读到的主片轨为准。DVD 目录同理：服务端不读 IFO，
        // 探测结果与引擎按 IFO 选出的正片标题未必是同一组 VOB
        let discImage = session?.decision.disc == "image"
            || (session?.decision.disc == "folder" && session?.source?.container == "dvd")
        var changed = subtitles.adoptEngineSubtitles(native.embeddedSubtitleTracks, replacingEmbedded: discImage)
        if changed, !subtitleTouched, selectedSubtitle == nil, burnedSubtitle == nil,
           let pick = subtitles.initialSelection(remembered: rememberedSubtitle) {
            selectedSubtitle = pick
            applySubtitleToEngine()
        }
        if audioOptions.isEmpty || discImage {
            // 记着的音轨（上次在这张盘上换过的）装载前已按序号交给引擎（见 handleSession 里的 initialAudio）
            let options = AudioOption.engineOptions(native.embeddedAudioTracks)
            if options != audioOptions {
                audioOptions = options
                changed = true
            }
            if discImage, let index = native.activeEmbeddedAudioIndex { currentAudio = "embedded:\(index)" }
        }
        if currentAudio == nil, let index = native.activeEmbeddedAudioIndex {
            currentAudio = "embedded:\(index)"
        }
        #if DEBUG
        if changed {
            print("[Tracks] 引擎补轨：音轨 \(audioOptions.count)：\(audioOptions.map { "\($0.ref)=\($0.label)" }.joined(separator: " / ")) ｜ 字幕 \(subtitles.options.count)：\(subtitles.options.map { "\($0.ref)=\($0.label)" }.joined(separator: " / ")) ｜ 选中 \(selectedSubtitle ?? "off") ｜ 当前音轨 \(currentAudio ?? "-")")
        }
        #endif
    }

    /// 上报用的字幕记忆：只报用户这次动过的（"off" = 用户明确关掉）。自动开着的字幕、
    /// 文件没有默认字幕所以没开，都不是用户的选择，不报；不报时服务端保持原记忆不动
    private var subtitleMemory: String? {
        guard subtitleTouched else { return nil }
        return selectedSubtitle ?? "off"
    }

    func selectQuality(_ maxHeight: Int?) {
        if maxHeight != quality {
            record?.noteBehavior("quality_change", from: quality.map(String.init) ?? "auto", to: maxHeight.map(String.init) ?? "auto")
            record?.beginSwitch(kind: "quality", from: quality.map(String.init), to: maxHeight.map(String.init))
        }
        // 视频直通且源不超所选档时不用重开：即刻生效
        defer { if phase != .deciding { record?.closeSwitch(immediate: true) } }
        qualityFromMemory = false
        if clip != nil {
            // 片段模式：记回片段的画质（竖屏也按它放），不写正片的按片记忆；选「自动」就是原画
            ReelsQuality.remember(maxHeight, server: scope.api.server)
        } else if scope.shareSlug == nil {
            // 上限不低于片源等于没限：记成「自动」，下次打开照样由自研引擎直出原文件
            let sourceHeight = Self.height(of: session?.source?.resolution) ?? .max
            let limiting = maxHeight.flatMap { $0 < sourceHeight ? $0 : nil }
            QualityMemory.remember(limiting, mediaItemId: unit.mediaItemId, network: network)
        }
        switchQuality(to: maxHeight)
    }

    /// 换到某个画质上限（不碰任何记忆）：语义是上限，视频直通且源不超所选档就不用重开
    private func switchQuality(to maxHeight: Int?) {
        guard maxHeight != quality else { return }
        quality = maxHeight
        let copying = session?.decision.video?.action == "copy"
        let height = Int(engine?.videoSize.height ?? 0)
        if copying, maxHeight == nil || (height > 0 && height <= maxHeight!) { return }
        wantsPlay = true
        failedTiers = []
        failureCount = 0
        request(startMs: positionMs, phase: .deciding)
    }

    /// 每秒一次，只在用户想看时喂（暂停、后台都不算；等首帧、等跳转落点也喂——一次等太久就该提示）；条件满足就给一次提议
    private func feedQualitySuggestion(engine: any PlayerEngine, stats: EngineStats) {
        guard wantsPlay, !backgrounded, [.buffering, .playing].contains(phase), session != nil else { return }
        let seeking = seekStartedAt != nil
        qualitySuggestion.tick(stalled: phase == .buffering || seeking, seeking: seeking, loadingBps: stats.loadingBps)
        let bitrate = stats.bitrateBps ?? session?.source?.bitRate.map(Double.init)
        // 真卡住了、而且这一秒的加载速度确实比片子码率慢（线路跟不上，不是一时抖动）：放大自研引擎的前向缓冲，
        // 之后暂停就能一直攒（引擎补丁 P20）。线路够快时不放大，免得在蜂窝网上白白多下几个 G
        if phase == .buffering, !seeking, let native = engine as? NativeEngine, let bitrate,
           let speed = stats.loadingBps, speed > 0, speed < bitrate * QualitySuggestion.linkMargin {
            native.growForwardBuffer()
        }
        guard qualityOffer == nil, !qualitySuggestion.offered else { return }
        let sourceHeight = Self.height(of: session?.source?.resolution)
        let currentHeight = quality.map { cap in sourceHeight.map { min($0, cap) } ?? cap } ?? sourceHeight
        guard let offer = qualitySuggestion.offer(streamBitrate: bitrate, currentHeight: currentHeight) else { return }
        log("quality-suggestion", [
            "measured_bps": .int(Int(offer.measuredBps)), "required_bps": .int(Int(offer.requiredBps)),
            "suggested_height": .int(offer.maxHeight), "engine": .string(engine.kind.rawValue),
        ])
        qualityOffer = offer
        #if DEBUG
        print("[QualityOffer] 提议已弹出：实测 \(Int(offer.measuredBps / 1000)) kbps、需要 \(Int(offer.requiredBps / 1000)) kbps，"
            + "推荐 \(offer.maxHeight)p，当前这段已等 \(qualitySuggestion.waitSeconds) 秒")
        // 实验台（faultlab 的 slow-link）：-mcAcceptQualityOffer YES 弹出即接受，验证点「改用」后切到服务端转码
        if UserDefaults.standard.bool(forKey: "mcAcceptQualityOffer") {
            acceptQualityOffer()
            return
        }
        #endif
        // 20 秒没理会就收起（本单元不再提）：它只是个建议，不该一直挡着画面
        qualityOfferTask?.cancel()
        qualityOfferTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.qualityOffer = nil
        }
    }

    #if DEBUG
    /// 开发期：暂停攒缓冲演练（PlayerScreen 的 -mcBufferDrill）不等真卡顿，直接放大前向缓冲
    func debugGrowForwardBuffer() { (engine as? NativeEngine)?.growForwardBuffer() }

    /// 开发期：模拟一次断线重连（PlayerScreen 的 -mcAutoReconnect）：新会话、新令牌、新的引擎实例，
    /// 验证片源字节缓存跨引擎实例接得上
    func debugReconnect() {
        log("network-restart", ["reason": .string("debug"), "attempt": .int(0)])
        request(startMs: positionMs, phase: .sessionStarting)
    }
    #endif

    /// 接受提议：改用推荐的画质（服务端转码）
    func acceptQualityOffer() {
        guard let offer = qualityOffer else { return }
        log("quality-suggestion-accepted", ["suggested_height": .int(offer.maxHeight)])
        dismissQualityOffer()
        selectQuality(offer.maxHeight)
    }

    /// 继续当前画质（或自动收起）
    func dismissQualityOffer() {
        qualityOfferTask?.cancel()
        qualityOfferTask = nil
        qualityOffer = nil
    }

    // MARK: - 前后台

    func setBackgrounded(_ background: Bool) {
        backgrounded = background
        record?.event(background ? "background" : "foreground", background ? "切到后台" : "回到前台")
        if !background { record?.beginSwitch(kind: "resume", from: nil, to: nil) }
        // 切后台先把当前位置报上去：之后 App 可能被挂起、被系统回收，等不到下一次心跳（同网页 visibilitychange）
        if background, reportedStart { sendProgress(paused: engine?.isPaused) }
        // 后台时引擎主动丢帧 / 不出画，回来先清窗口，免得误判卡顿与掉帧
        resetWatchdogs()
        if !background { qualitySuggestion.restartGrace() }
        engine?.setBackgrounded(background)
        if !background, !((engine as? NativeEngine)?.rebuiltOnForeground ?? false) {
            // 管线没被拆：画面一直都在，回前台即刻可看；拆过的要等重建后的首帧（见 noteFirstFrame）
            record?.closeSwitch(immediate: true)
        }
        // 切后台时刷一次「正在播放」标记：暂停着被系统回收是正常退出，不是异常
        markRecordActive()
        if !background, let activeSessionId {
            // 回前台先探一次活：后台期间心跳可能被系统挂起、会话已被回收
            Task { await ping(activeSessionId) }
        }
    }

    // MARK: - 片段模式

    /// 片段放到终点：停在这里（可重播，或「看全片」接着放整部）
    private func reachClipEnd() {
        if holdSpeedActive { endHoldSpeed() }
        engine?.pause()
        wantsPlay = false
        paused = true
        phase = .ended
    }

    /// 「看全片」：原地退出片段模式，从当前位置接着放整部——同一个引擎、不重开会话；
    /// 从这一刻起照常记观看进度（报「开始」，之后按正常播放的节奏报）
    func leaveClip() {
        guard clip != nil else { return }
        clip = nil
        nowPlaying.update(controller: self)
        // 片段的画质只管片段（2026-09-30 用户要求两份记忆互不影响）：转成看整部就回到这部片自己的画质记忆，
        // 与片段的不同才重开一次流（新流从当前位置接着放，播放后照常报「开始」）
        let own = scope.shareSlug == nil ? QualityMemory.quality(mediaItemId: unit.mediaItemId, network: network) : nil
        if own != quality {
            switchQuality(to: own)
            if phase == .deciding { return }
        }
        if phase == .ended {
            // 停在片段终点：接着往下放
            phase = .playing
            wantsPlay = true
            engine?.play()
        } else if engine?.isPaused == true {
            wantsPlay = true
            engine?.play()
        }
        // 已经在放：引擎不会再报一次「开始播放」，这里补报；暂停着的等恢复播放时由引擎事件报
        if phase == .playing, engine?.isPaused == false, !reportedStart { reportStart() }
    }

    /// 片段模式的跳转落点：夹在片段之内，离终点留半秒（落在终点上会立刻判「放完」）
    private static func clamp(_ fileMs: Int, into clip: PlaybackClip) -> Int {
        min(max(fileMs, clip.startMs), max(clip.startMs, clip.endMs - 500))
    }

    // MARK: - 心跳 / 进度

    /// 报「开始播放」并开始 10 秒一次的进度上报（每个单元一次）
    private func reportStart() {
        reportedStart = true
        let unit = self.unit, audio = audioMemory, subtitle = subtitleMemory, fileId = reportedFileId
        let scope = self.scope
        enqueueReport { [weak self] in
            let state = await scope.progress(unit, event: "start", positionMs: nil, audio: audio, subtitle: subtitle, fileId: fileId)
            self?.handleProgressResponse(state)
        }
        startProgressLoop()
    }

    private func startPingLoop() {
        pingTask?.cancel()
        guard let sessionId = activeSessionId else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
                await self?.ping(sessionId)
            }
        }
    }

    private func ping(_ sessionId: String) async {
        let alive = await scope.ping(sessionId)
        // nil = 这次请求本身失败（断网/5xx），不能据此判定会话没了
        guard alive == false, sessionId == activeSessionId else { return }
        guard [.playing, .buffering].contains(phase) else { return }
        if engine?.isPaused == true, !wantsPlay {
            // 用户自己暂停着：不替他白烧一路转码，等他点播放再重开
            deadSession = true
            return
        }
        request(startMs: positionMs, phase: .sessionStarting)
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                guard let self, self.phase == .playing else { continue }
                self.sendProgress(paused: self.engine?.isPaused)
            }
        }
    }

    private func sendProgress(paused: Bool?) {
        guard reportedStart else { return }
        let unit = self.unit, position = positionMs, audio = audioMemory, subtitle = subtitleMemory, duration = durationMs
        let fileId = reportedFileId
        let scope = self.scope
        enqueueReport { [weak self] in
            let state = await scope.progress(unit, event: "progress", positionMs: position, durationMs: duration, paused: paused,
                                             audio: audio, subtitle: subtitle, fileId: fileId)
            self?.handleProgressResponse(state)
        }
    }

    private func enqueueReport(_ work: @escaping @MainActor () async -> Void) {
        let previous = reportQueue
        reportQueue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// App 即将被结束：同步补发 stop（最多等 1.5 秒）
    private func reportTermination() {
        // 播放记录先落盘（进程马上要退出，发送留给下次启动补发）
        endRecord(terminating: true)
        guard reportedStart else { return }
        reportedStart = false
        scope.stopBeforeTermination(unit, positionMs: positionMs, durationMs: durationMs, audio: audioMemory, subtitle: subtitleMemory,
                                    fileId: reportedFileId)
    }

    /// 上报用的音轨记忆：只报用户点选的（刚换了音轨、新会话还没建好就退出时也要记住）。
    /// 服务端默认挑选、自研引擎按设备自己挑的同语言轨都不报——报了会被当成用户的选择记下，
    /// 以后默认策略改了这部片也跟不上，还会被带到别的设备上（docs/design/jellyfin-subtitle.md §3.3）
    private var audioMemory: String? { requestedAudio }

    /// 上报时带上正在放的版本：多版本时服务端据此判断报上来的轨是不是这个版本的默认挑选
    private var reportedFileId: Int? { session?.decision.fileId }

    /// 管理员在活动页结束了本次播放：退出并说明（服务端同时进入拒绝窗口，不能走「会话没了就重开」）
    private func handleProgressResponse(_ state: API.PlaybackStateView?) {
        guard state?.endedByAdmin == true, phase != .error else { return }
        engine?.pause()
        leaveUnit()
        fail("管理员已结束本次播放", suggestion: "稍后可以重新开始播放；观看进度已经保存。")
    }

    // MARK: - 读数循环（4Hz 位置 / 1Hz 速度）

    private func startTickLoop() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tickPosition()
                tick += 1
                if tick % 4 == 0 { self.tickSecond() }
            }
        }
    }

    private func tickPosition() {
        defer { sampleRecordPlayhead() }
        guard let engine, session != nil, [.buffering, .playing].contains(phase) else { return }
        let stream = engine.currentTime
        let file = originMs + Int(stream * 1000)
        // 起播 seek 落地前引擎报的是 0：别让进度条先闪回片头
        if !(stream < 0.05 && positionMs > 2000 && phase == .buffering) { positionMs = file }
        if let duration = engine.duration, durationMs == nil || session?.decision.disc != nil {
            // 光盘源以引擎为准：台账时长不可信（ISO 是 ffprobe 碰巧嗅探到盘内字节得出的，《公司的力量》
            // 被记成 4 秒，跳转被夹到 3 秒），引擎读 MPLS / IFO 得到的才是真实片长
            durationMs = originMs + Int(duration * 1000)
        }
        bufferedEndMs = engine.bufferedEnd.map { originMs + Int($0 * 1000) }
        paused = engine.isPaused
        if phase == .playing, !engine.isPaused { qoe.tickWatched() } else { qoe.pauseWatched() }
        if let clip, phase == .playing, !engine.isPaused, positionMs >= clip.endMs { reachClipEnd() }
    }

    private func tickSecond() {
        guard let engine else { return }
        let stats = engine.stats()
        speedLabel = Self.formatLoadingSpeed(stats.loadingBps)
        // 带宽估计另记：申报给服务端的 downlink_bps 要的是线路能力，缓冲满了也保持上次实测值
        if let downlink = stats.downlinkBps { lastDownlinkBps = downlink }
        // 不拿「加载速度低于码率」直接预警（网页有，App 去掉，用户决定）：缓冲攒满后引擎暂停下载，读数掉到接近 0，
        // 临时抖一下也会触发，而播放本身并没有卡。线路慢也不自动转码（2026-09-28 用户拍板）：只缓冲，
        // 反复真卡住时才提示一次换低画质（见 QualitySuggestion），换不换由用户定
        runWatchdogs(engine: engine, stats: stats)
        feedQualitySuggestion(engine: engine, stats: stats)
        nowPlaying.updatePosition(controller: self)
        record?.sampleFrames(presented: (engine as? NativeEngine)?.presentedFrameCount, positionMs: positionMs,
                             active: recordWatching && phase == .playing)
        recordTick += 1
        if recordTick % 10 == 0 {
            record?.sampleResources(downlinkBps: lastDownlinkBps)
            markRecordActive()
        }
        #if DEBUG
        // 开发期：每 10 秒一行设备体征（引擎能耗对比用，口径见 DeviceVitals）
        vitalsTick += 1
        if vitalsTick % 10 == 0 {
            print("[Vitals] \(engine.kind.rawValue) t=\(Int(engine.currentTime)) \(DeviceVitals.line())")
        }
        #endif
    }

    #if DEBUG
    private var vitalsTick = 0
    /// -mcFakeStallAfter 期间看门狗看到的「定住的」播放头
    private var debugFrozenTime: Double?
    #endif

    private func resetWatchdogs() {
        stallWatch.reset()
        frameDrops.reset()
    }

    /// 每秒一次：卡顿归因（解码卡死 / 连接断了；线路慢不算失败）与直通掉帧。命中就走 `engineFailed` 的兜底规则
    private func runWatchdogs(engine: any PlayerEngine, stats: EngineStats) {
        guard session != nil, [.buffering, .playing].contains(phase), !backgrounded, !failureInFlight else { return }
        let deadLimit = playsOriginalFile ? StallWatch.directDeadSeconds : StallWatch.serverDeadSeconds
        var watchedTime = engine.currentTime
        var ahead = max(0, (engine.bufferedEnd ?? engine.currentTime) - engine.currentTime)
        #if DEBUG
        // 开发期故障注入：-mcFakeStallAfter "<开播后秒>,<持续秒>" 让看门狗看到「缓冲够却不走」，验证解码卡死后的
        // 原位重开（真实的引擎楞住在模拟器上造不出来）
        let fakeStall = (UserDefaults.standard.string(forKey: "mcFakeStallAfter") ?? "").split(separator: ",").compactMap { Double($0) }
        if fakeStall.count == 2, let since = qoe.requestedAt,
           (fakeStall[0] ..< fakeStall[0] + fakeStall[1]).contains(Date().timeIntervalSince(since)) {
            if debugFrozenTime == nil { print("[AutoTest] 模拟画面卡住 \(Int(fakeStall[1])) 秒") }
            watchedTime = debugFrozenTime ?? watchedTime
            debugFrozenTime = watchedTime
            ahead = max(ahead, 5)
        } else {
            debugFrozenTime = nil
        }
        #endif
        switch stallWatch.sample(time: watchedTime, bufferedAhead: ahead, paused: engine.isPaused,
                                 ended: phase == .ended, seeking: seekStartedAt != nil,
                                 receiving: (stats.loadingBps ?? 0) > 0, deadLimit: deadLimit) {
        case .ok:
            break
        case .nudge:
            log("stall-nudge", ["position_ms": .int(positionMs)])
            record?.event("stall_nudge", "卡住不走，推一下播放头")
            engine.seek(to: engine.currentTime + StallWatch.nudgeStep, exact: true)
            engine.play()
        case .decodeStalled:
            engineFailed(reason: StallWatch.reason(.decodeStalled, deadLimit: deadLimit), cause: .decode)
            return
        case .dead:
            engineFailed(reason: StallWatch.reason(.dead, deadLimit: deadLimit), cause: .network)
            return
        }
        // 掉帧只在视频直通时判：转码档已经是 h264，再掉帧说明连转码产物都放不动，继续降档只会更糟
        let copying = playsOriginalFile || session?.decision.video?.action == "copy"
        #if DEBUG
        // 开发期：每 5 秒打一行帧统计（真机无人值守验证时从控制台读，不用人看画面）
        if phase == .playing, UserDefaults.standard.bool(forKey: "mcFrameStatsEverySecond") || Int(engine.currentTime) % 5 == 0 {
            let loading = stats.loadingBps.map { String(format: "%.0fMbps", $0 / 1_000_000) } ?? "-"
            print("[FrameStats] \(engine.kind.rawValue) t=\(Int(engine.currentTime)) 掉帧=\(stats.droppedFrames ?? -1) 帧=\(stats.totalFrames ?? -1) 缓冲=\(Int(stats.bufferedSeconds))s 加载=\(loading) \(stats.details.joined(separator: " | "))")
        }
        #endif
        if let grace = frameDropGraceUntil, grace > Date() {
            frameDrops.reset()
            return
        }
        // 长按 2 倍速时引擎按音频节奏主动丢帧跟上（4K 60 帧就是每秒 120 帧），掉帧是预期内的，不能判成
        // 「直通放不动」——真机实测一按倍速 3 秒就被判掉帧、白白换成了服务端转码
        guard copying, phase == .playing, !engine.isPaused, seekStartedAt == nil, !holdSpeedActive,
              let dropped = stats.droppedFrames, let total = stats.totalFrames else { return }
        if let ratio = frameDrops.sample(dropped: dropped, total: total), ratio >= FrameDropTracker.ratio {
            frameDrops.reset()
            engineFailed(reason: "直通播放持续掉帧（\(Int((ratio * 100).rounded()))%），正在换转码重试", cause: .decode)
        }
    }

    /// 加载速度的文案：没在加载时明确写「0 KB/s」（要让人一眼看出现在没在下），还没有读数时返回 nil 不显示
    static func formatLoadingSpeed(_ bps: Double?) -> String? {
        guard let bps, bps.isFinite, bps >= 0 else { return nil }
        return formatBandwidth(bps) ?? "0 KB/s"
    }

    /// bps → 「3.2 MB/s」（用户对下载速度的直觉来自下载器，一律 MB/s，进位 1024；同 Web formatBandwidth）
    static func formatBandwidth(_ bps: Double?) -> String? {
        guard let bps, bps.isFinite, bps > 0 else { return nil }
        let bytes = bps / 8
        let mb = bytes / (1024 * 1024)
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        let kb = bytes / 1024
        return kb < 1 ? "0 KB/s" : "\(Int(kb.rounded())) KB/s"
    }

    // MARK: - 诊断 / 缩略图

    private func restartDiagnosticsPolling() {
        diagnosticsTask?.cancel()
        serverDiagnostics = nil
        guard diagnosticsOpen, let sessionId = activeSessionId, let token = PlaybackAPI.token(in: session?.streamUrl) else { return }
        diagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 诊断是旁路信息：服务端瞬时不可用时保留上一份快照
                if let snapshot = try? await self.scope.diagnostics(sessionId, token: token) {
                    self.serverDiagnostics = snapshot
                }
                // 2 秒一次（同 Web）：诊断是旁路信息，不值得更密地打 NAS
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 进度条缩略图索引：开会话时服务端才在后台生成，没就绪就隔一阵再问（最多几次，失败无所谓）
    private func loadTrickplay(fileId: Int, token: String?) {
        trickplayTask?.cancel()
        guard let token else { return }
        trickplayTask = Task { [weak self] in
            for _ in 0 ..< 6 {
                guard let self else { return }
                if let index = try? await self.scope.api.playbackFileTrickplay(fileId: fileId, token: token), index.ready {
                    self.trickplay = index
                    return
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// 诊断面板「传输」节的 QoE 行：上次跳转耗时、卡顿次数与累计时长（卡顿不含 seek 造成的等待）
    var qoeLive: (lastSeekMs: Int?, rebufferCount: Int, rebufferMs: Int) {
        let ongoing = qoe.bufferingSince.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        return (qoe.lastSeekMs, qoe.rebufferCount, qoe.rebufferMs + ongoing)
    }

    // MARK: - 提示

    /// 这次沿用了哪些**不是默认**的记忆（画质、音轨、字幕），拼成开播提示；都是默认的返回 nil。
    ///
    /// 服务端每次进度上报都会把正在放的轨记下来，「记着」不等于「用户选过」：记着的和默认挑选一致就不提
    private func rememberedChoiceNotice() -> String? {
        guard let session else { return nil }
        // 画质是上限：源本来就不超过这一档，限了等于没限，不提
        let qualityLimit = qualityFromMemory && qualityLimited ? quality : nil
        var audio: String?
        if requestedAudio == nil, let remembered = session.watch?.audioTrack, remembered == currentAudio,
           remembered != AudioOption.defaultRef(in: audioOptions),
           let option = audioOptions.first(where: { $0.ref == remembered }) {
            audio = RememberedChoices.shortLabel(option.label, among: audioOptions.map(\.label))
        }
        var subtitle: String?
        if !subtitleTouched, burnedSubtitle == nil, rememberedSubtitle != nil,
           selectedSubtitle != subtitles.initialSelection(remembered: nil) {
            if let ref = selectedSubtitle {
                subtitle = subtitles.options.first { $0.ref == ref }
                    .map { RememberedChoices.shortLabel($0.label, among: subtitles.options.map(\.label)) }
            } else {
                subtitle = "关闭"
            }
        }
        return RememberedChoices.notice(quality: qualityLimit, network: network, audio: audio, subtitle: subtitle)
    }

    // MARK: - 播放记录（docs/design/playback-qoe.md）

    /// 新的一次播放：切集（含进入播放器的第一个单元）、错误页上重试
    private func beginRecord(origin: PlaybackRecord.Origin, at instant: ContinuousClock.Instant?) {
        // 片段模式不留播放记录：刷片有自己的事件（docs/design/reels.md §5），混进来会把「无打扰播放率」算偏
        guard scope.telemetry, clip == nil else { return }
        PlaybackReportQueue.recoverAbnormalExit()
        record = PlaybackRecord(unit: unit, origin: origin, startedAt: instant)
        recordWatchedBaseline = qoe.watchedMs
        recordTick = 0
    }

    /// 结束这次播放并上报（所有结局都报）。`terminating` = App 马上退出，只落盘不发送
    private func endRecord(forceOutcome: PlaybackRecord.Outcome? = nil, terminating: Bool = false) {
        guard let record else { return }
        self.record = nil
        record.noteLeaving()
        qoe.flushWatched()
        let outcome = forceOutcome ?? record.outcome(
            phaseIsError: phase == .error, phaseIsEnded: phase == .ended, positionMs: positionMs, durationMs: durationMs
        )
        let payload = recordPayload(record, outcome: outcome)
        #if DEBUG
        print("[PlaybackRecord] \(record.id) 结局=\(outcome.rawValue) 首帧=\(payload.firstFrameMs.map(String.init) ?? "-") 毫秒 跳转 \(payload.seekCount ?? 0) 次 卡顿 \(payload.rebufferCount ?? 0) 次/\(payload.rebufferMs ?? 0) 毫秒 错误=\(record.errorKind.isEmpty ? "-" : record.errorKind)")
        #endif
        if terminating {
            PlaybackReportQueue.markActive(payload, api: scope.api)
        } else {
            PlaybackReportQueue.submit(payload, api: scope.api)
        }
    }

    private func recordPayload(_ record: PlaybackRecord, outcome: PlaybackRecord.Outcome) -> API.PlaybackMetricPayload {
        let stats = engine?.stats()
        // 失败、画面冻过才附引擎日志尾巴（平常不报）
        let wantsLog = outcome == .failed || outcome == .abnormalExit || record.sawFreeze || !record.errorKind.isEmpty
        return record.payload(
            outcome: outcome, network: network, positionMs: positionMs, durationMs: durationMs,
            watchedMs: max(0, qoe.watchedMs - recordWatchedBaseline),
            droppedFrames: stats?.droppedFrames, totalFrames: stats?.totalFrames,
            logTail: wantsLog && engine?.kind == .native ? NativeEngine.recentEngineLog() : nil
        )
    }

    /// 刷新「正在播放」标记：这次播放要是没能正常收尾（闪退、被系统杀掉），下次启动据此补报。
    /// 在后台且暂停着时写成「中途退出」：那时被系统回收是正常的
    private func markRecordActive() {
        guard let record else { return }
        let outcome: PlaybackRecord.Outcome = backgrounded && !wantsPlay ? .exited : .abnormalExit
        PlaybackReportQueue.markActive(recordPayload(record, outcome: outcome), api: scope.api)
    }

    /// 用户在看：画面出过、想看、不在后台
    private var recordWatching: Bool {
        record?.firstFrameAt != nil && wantsPlay && !backgrounded && !closed
    }

    /// 每 250 毫秒：播放头 0.5 秒不走就是卡顿（引擎报不报缓冲都算；跳转、换轨中的等待不算）
    private func sampleRecordPlayhead() {
        guard let record else { return }
        let active = recordWatching && [.buffering, .playing, .sessionStarting, .degrading, .deciding].contains(phase)
        record.samplePlayhead(positionMs, active: active) { [self] in
            if record.reconnecting { return "reconnect" }
            if phase == .sessionStarting || phase == .degrading || phase == .deciding { return "restart" }
            guard let stats = engine?.stats() else { return "unknown" }
            if stats.bufferedSeconds >= 3 { return "decode" }
            return (stats.loadingBps ?? 0) > 0 ? "slow_network" : "network"
        }
    }

    /// 规格快照（首帧、换字幕、音频输出变化时刷新）
    private func updateRecordDelivery() {
        guard let record, let session, engine != nil else { return }
        let native = engine as? NativeEngine
        let facts = native?.deliveryFacts()
        let route: String = if playsOriginalFile {
            facts?.route == "software" ? "software" : "loopback"
        } else {
            (session.decision.tier ?? 0) >= 2 ? "server_transcode" : "server_remux"
        }
        record.route = route
        let subtitleMode = if burnedSubtitle != nil {
            "burned"
        } else if selectedSubtitle == nil {
            "none"
        } else {
            engineRendersSubtitles ? "engine" : "overlay"
        }
        record.noteDelivery(PlaybackRecord.makeDelivery(
            facts: facts, session: session, playsOriginalFile: playsOriginalFile, route: route,
            userCapped: qualityLimited, fallbackReason: nativeFailed ? "native_failed" : nil,
            subtitleMode: subtitleMode, currentAudio: currentAudio
        ))
    }

    /// 失败发生在哪一段：还没开成会话 / 开了会话还没出画 / 播放中
    private var recordStage: String {
        if record?.firstFrameAt != nil { return "playback" }
        return session == nil ? "negotiation" : "startup"
    }

    /// 客户端事件日志（服务端按天日志）：一律带上播放编号，与服务端的「播放会话就绪」「首片供给」等行串起来
    private func log(_ event: String, _ detail: [String: API.JSONValue]) {
        var detail = detail
        if let id = record?.id { detail["attempt_id"] = .string(id) }
        scope.clientLog(event, detail)
    }

    func flash(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    #if os(iOS)
    nonisolated private static func activateAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        // 多声道（5.1 / 全景声经 HDMI、AirPlay 原样送出）：原来由引擎建实例时声明，现在类别只由这里设（引擎补丁 P47）
        try? audio.setSupportsMultichannelContent(true)
        try? audio.setActive(true)
    }
    #endif
}

/// 诊断面板的实时读数（对应 Web `lib/player/qoe.ts` 的归约结果）与观看时长。
/// 上报用的完整记录在 `PlaybackRecord`（docs/design/playback-qoe.md）
private struct QoE {
    var requestedAt: Date?
    /// 最近一次 seek 从发出到重新出画的耗时（诊断面板「上次跳转 x 秒」）
    var lastSeekMs: Int?
    var rebufferCount = 0
    var rebufferMs = 0
    var watchedMs = 0
    var bufferingSince: Date?
    private var watchingSince: Date?

    mutating func beginRebuffer() {
        rebufferCount += 1
        bufferingSince = Date()
    }

    mutating func endRebuffer() {
        if let since = bufferingSince { rebufferMs += Int(Date().timeIntervalSince(since) * 1000) }
        bufferingSince = nil
    }

    mutating func tickWatched() {
        if watchingSince == nil { watchingSince = Date() }
    }

    mutating func pauseWatched() {
        flushWatched()
    }

    mutating func flushWatched() {
        if let since = watchingSince { watchedMs += Int(Date().timeIntervalSince(since) * 1000) }
        watchingSince = nil
    }
}
