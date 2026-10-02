import AetherCore
import AVKit
import UIKit

/// 自研引擎：「FFmpeg 负责拆，Apple 负责播」（内核是 AetherEngine，经 AetherCore 动态框架引入）。
///
/// 为什么要它（docs/design/player-engine.md）：服务端（NAS）大多性能弱，终端越来越强，所以原文件在本机处理——
/// FFmpeg 读 NAS 上的原文件、就地换封装成 HLS 分片，经本机回环地址交给 AVPlayer。
/// 解码、杜比视界、全景声、HDR 色调映射、画中画都由系统完成：MKV / 原盘也能拿到系统播放器的全部能力，
/// NAS 只吐字节、不起 ffmpeg；也不用自己上屏（自绘着色器在 4K HDR 下功耗高、发热掉帧）。
/// AVPlayer 解不了的编码（VP9、VC-1、MPEG-2……）由引擎内部换到 FFmpeg 软解（本机 CPU）+ 系统显示层，
/// 对这里透明；硬件解码器报「解不了」（杜比视界 P5 之类）也会转软解（引擎补丁 P24）。
///
/// 与控制器的分工：
/// - 只放原文件直出（服务端档 0 地址）；要服务端转码的情况仍交给系统播放器引擎放 HLS；
/// - 失败时如实上报，由控制器回落到服务端 HLS（系统播放器）；
/// - 图形字幕（PGS 等）由引擎给出位图、在 AetherCore 里按画面摆放；文字字幕仍走 SwiftUI 叠加层。
/// 自研引擎要装载的光盘源（控制器据会话组装；只有 NativeEngine 直接接触 AetherCore 的类型）
enum NativeDiscSource {
    /// 光盘镜像的原字节地址（ISO）
    case image(URL)
    /// 原盘目录：文件清单 + 服务端选中的主播放列表名
    case folder(files: [NativeDiscFile], playlist: String?)
}

/// 原盘目录里的一个文件：相对原盘根目录的路径、字节数、按 Range 取字节的地址（已带取流令牌）
struct NativeDiscFile {
    let path: String
    let size: Int64
    let url: URL
}

@MainActor
final class NativeEngine: NSObject, PlayerEngine {
    let kind = EngineKind.native
    var onEvent: ((EngineEvent) -> Void)?

    /// 正在直出原文件（目前只用于这种情况，诊断面板显示用）
    let playsOriginalFile: Bool

    private let core: AetherPlayback
    private var lastReported: EngineEvent?
    /// 顶栏「↓」的实时加载速度：对引擎从 NAS 累计拉到的字节做差分（口径同 `LoadingSpeedMeter`）
    private var loadingMeter = LoadingSpeedMeter()
    /// 诊断面板「带宽」与 downlink_bps：没有逐请求计时，样本是每秒一个的加载速度读数
    private var bandwidthMeter = BandwidthMeter()
    private var lastBandwidthSample: TimeInterval?

    /// 轨道列表出来之前就选定的轨：列表出来后补上（音轨要等首帧后再换，起播中途重载会拖慢出画）
    private var pendingAudio: Int?
    /// 起播音轨是不是用户明确要的（见 `selectInitialAudio`）
    private var pendingAudioExplicit = true
    /// 装载前就交代了的明确起播音轨（第几条内封音轨）：交给引擎按序号起播，首帧就是它
    private var loadAudioOrdinal: Int?
    /// 已经向引擎发出装载（之后再交代的起播音轨只能等首帧后重载着换）
    private var loadIssued = false
    /// 片源字节缓存的键（控制器装载前给，见 `PlaybackController.sourceCacheKey`）：同一个文件在 App 这次运行里每个字节只下一次
    var sourceCacheKey: String?
    /// 服务端随会话下发的 MKV 精简索引（控制器装载前给；引擎补丁 P58）：起播时不必再下原索引
    var matroskaCues: (offset: Int64, data: Data)?
    /// 落盘计划（控制器装载前按剩余空间给，见 `NativeStoragePlan`）：存储紧张时收小分片窗口、不开片源字节缓存
    var storagePlan = NativeStoragePlan.normal
    /// 装载时交给引擎的外挂字幕（按引用记顺序：引擎里 isExternal 的轨按 id 排序与之一一对应）
    private var externalSubtitleRefs: [String] = []
    private var pendingExternalSubtitles: [AetherPlayback.ExternalSubtitle] = []
    private var pendingSubtitle: SubtitleOption?
    private var hasPendingSubtitle = false
    private var tracksKnown = false
    private var firstFrameShown = false
    /// 引擎报「在播」时首帧还没上屏（见 handle(_:)）
    private var playingBeforeFirstFrame = false
    /// 播放体验打点：发出了跳转、还在等落点的画面（`EngineEvent.seekPresented`）
    private var awaitingSeekPicture = false
    /// 引擎那边这次跳转已落地（主力通路据此加上「恢复播放」判定画面到了）
    private var seekLanded = false
    /// 最近一次失败的引擎错误类型（`PlaybackErrorKind` 原值），播放记录用
    private(set) var lastFailureKind: String?
    /// 回前台时是否真的重建了管线（后台暂停超过 15 秒会被拆掉）：重建了要等首帧，没重建画面一直都在
    private(set) var rebuiltOnForeground = false

    #if DEBUG
    /// 开发期：状态变化打到控制台并标上距装载的毫秒数（量起播、跳转、换轨耗时）
    private var loadedAt = ContinuousClock.now
    #endif

    private var pipController: AVPictureInPictureController?
    /// 画中画控制器绑的是哪一层（主力通路的 AVPlayerLayer / 软件通路的显示层）：换了层才重建控制器
    private weak var pipLayer: CALayer?
    /// 软件通路的画中画源（控制器是「采样缓冲」式时非空，小窗的时间与播放控制都问它）
    private var softwarePiP: AetherPlayback.SoftwarePictureInPicture?
    private(set) var isPictureInPictureActive = false

    init(playsOriginalFile: Bool) throws {
        self.playsOriginalFile = playsOriginalFile
        Self.prepareEngineEnvironment()
        core = try AetherPlayback()
        super.init()
        Self.sweepStaleCachesOnce()
        core.onPhase = { [weak self] phase in self?.handle(phase) }
        core.onFailure = { [weak self] failure in self?.handle(failure) }
        core.onTracksChanged = { [weak self] in self?.tracksChanged() }
        core.onFirstFrame = { [weak self] in self?.firstFrameReady() }
        core.onStartupStage = { [weak self] stage in self?.onEvent?(.startupStage(stage)) }
        core.onSeekOutcome = { [weak self] outcome in self?.seekOutcome(outcome) }
        core.onSoftwareFrameGeneration = { [weak self] in self?.softwareFrameGeneration() }
    }

    var view: UIView { core.view }

    /// 建自研引擎前的全局准备：接管引擎日志、读开发期开关。刷片页（Features/Reels）自己管引擎实例，
    /// 建之前也调它，与播放器页同一口径
    static func prepareEngineEnvironment() {
        // 引擎日志一律进环形缓冲，播放失败时随播放记录上报（docs/design/playback-qoe.md §3.5）；
        // 开发期 -mcAetherLog YES 同时打到控制台（模拟器排查用）
        #if DEBUG
        AetherPlayback.installLogHandler(mirror: UserDefaults.standard.bool(forKey: "mcAetherLog"))
        // -mcNoPersistentByteCache YES：片源字节缓存不跨启动保留（引擎补丁 P42 之前的行为，真机新旧对照用）。
        // 必须在下面任何一个碰到片源字节缓存的设置之前（共享缓存第一次用到时就按这个开关建好了）
        if UserDefaults.standard.bool(forKey: "mcNoPersistentByteCache") { AetherPlayback.setPersistsSourceCache(false) }
        // -mcPurgeByteCache YES：先删掉跨启动保留的片源字节缓存（实验台每次热身前清场，免得对照两组互相沾光）
        if UserDefaults.standard.bool(forKey: "mcPurgeByteCache") { AetherPlayback.removePersistedSourceCache() }
        // -mcTrimDropsWhole YES：启动整理跨启动缓存超额时直接整条删（引擎补丁 P51 之前的行为，真机新旧对照用）
        AetherPlayback.setSourceCacheTrimKeepsMetadata(!UserDefaults.standard.bool(forKey: "mcTrimDropsWhole"))
        // -mcNoSpareRuns YES：片源字节缓存每块只记一段（引擎补丁 P50 之前的行为，真机新旧对照用）
        AetherPlayback.setSourceCacheKeepsSpareRuns(!UserDefaults.standard.bool(forKey: "mcNoSpareRuns"))
        // -mcAetherCues YES：把文字字幕与 ASS 定位打到控制台
        AetherPlayback.logsCues = UserDefaults.standard.bool(forKey: "mcAetherCues")
        // -mcSyncByteCache YES：片源字节缓存改回在取数线程上同步写盘（引擎补丁 P32 之前的行为，真机新旧对照用）
        AetherPlayback.setByteCacheWritesInBackground(!UserDefaults.standard.bool(forKey: "mcSyncByteCache"))
        // -mcProbeAllTrueHD YES：探测流时第二条起的 TrueHD 也照常探（引擎补丁 P34 之前的行为，真机新旧对照用）
        AetherPlayback.setParkSecondaryTrueHD(!UserDefaults.standard.bool(forKey: "mcProbeAllTrueHD"))
        // -mcSegmentSeconds <秒>：点播分片目标时长（引擎补丁 P33，默认 2；真机对照用），窗口段数在装载时按比例折算
        let segmentSeconds = UserDefaults.standard.double(forKey: "mcSegmentSeconds")
        if segmentSeconds > 0 { AetherPlayback.segmentTargetSeconds = segmentSeconds }
        // -mcSeekSnapBudget <秒>：跳转吸附关键帧的逐帧解码预算（引擎补丁 P36，默认 0.2；0 = 关，真机对照用）
        if UserDefaults.standard.object(forKey: "mcSeekSnapBudget") != nil {
            AetherPlayback.seekSnapDecodeBudgetSeconds = UserDefaults.standard.double(forKey: "mcSeekSnapBudget")
        }
        // -mcCuePrewarmMiddle YES：MKV 索引预热照旧跳到片中间（引擎补丁 P45 之前的行为，真机新旧对照用）
        AetherPlayback.setCuePrewarmTargetsStart(!UserDefaults.standard.bool(forKey: "mcCuePrewarmMiddle"))
        // -mcNoCuesPrefetch YES：MKV 索引照旧由解复用器按需读（引擎补丁 P49 之前的行为，真机新旧对照用）
        AetherPlayback.setPrefetchesMatroskaCues(!UserDefaults.standard.bool(forKey: "mcNoCuesPrefetch"))
        // -mcNoPrefetchProgressWait YES：等在途提前取照旧按往返时长定上限（引擎补丁 P53 之前的行为，慢线路对照用）
        AetherPlayback.setWaitsOnProgressingPrefetch(!UserDefaults.standard.bool(forKey: "mcNoPrefetchProgressWait"))
        // -mcNoMoovPrefetch YES：MP4 尾部 moov 照旧由解复用器按需读（引擎补丁 P54 之前的行为，对照用）
        AetherPlayback.setPrefetchesMP4TailMoov(!UserDefaults.standard.bool(forKey: "mcNoMoovPrefetch"))
        // -mcNoDetourSkip YES：慢线路上回跳照旧先走 4 MB 整块补取（引擎补丁 P55 之前的行为，对照用）
        AetherPlayback.setSkipsDetourOnSlowLink(!UserDefaults.standard.bool(forKey: "mcNoDetourSkip"))
        // -mcNoIndexPriority YES：冷打开时文件头照旧一开始就要 32 MB、与索引提前取并行（引擎补丁 P56 之前的行为，对照用）
        AetherPlayback.setPrioritizesIndexPrefetch(!UserDefaults.standard.bool(forKey: "mcNoIndexPriority"))
        // -mcNoProgressiveSegments YES：分片照旧整段写完再交付给 AVPlayer（引擎补丁 P57 之前的行为，对照用）
        AetherPlayback.setServesSegmentsProgressively(!UserDefaults.standard.bool(forKey: "mcNoProgressiveSegments"))
        // -mcNoHostCues YES：不用服务端给的 MKV 精简索引，照旧下载原索引（引擎补丁 P58 之前的行为，对照用）
        AetherPlayback.setUsesHostMatroskaCues(!UserDefaults.standard.bool(forKey: "mcNoHostCues"))
        // -mcNoMediaIndependent YES：只在主播放列表声明分片独立（引擎补丁 P59 之前的行为，对照用）
        AetherPlayback.setDeclaresIndependentMediaSegments(!UserDefaults.standard.bool(forKey: "mcNoMediaIndependent"))
        // -mcWitnessInterval <秒>：起播 / 跳转后看缓冲过没过开播线的间隔（引擎补丁 P28，默认 0.025，原来 0.1；真机对照用）
        let witness = UserDefaults.standard.double(forKey: "mcWitnessInterval")
        if witness > 0 { AetherPlayback.vodStartWitnessIntervalSeconds = witness }
        // -mcStartSnapBudget <秒>：起播落点吸附关键帧的逐帧解码预算（引擎补丁 P39，默认 0.05；0 = 关，真机对照用）
        if UserDefaults.standard.object(forKey: "mcStartSnapBudget") != nil {
            AetherPlayback.startSnapDecodeBudgetSeconds = UserDefaults.standard.double(forKey: "mcStartSnapBudget")
        }
        #else
        AetherPlayback.installLogHandler(mirror: false)
        #endif
        // 音频会话：iPhone 上由 App 自己管——点播放时就以「长视频」策略设好类别、声明多声道并激活
        // （`PlaybackController.activateAudioSession`），引擎建实例时不再用默认策略重设一遍（引擎补丁 P47）。
        // Apple TV 上交给引擎：它以 `.longFormAudio` 策略只声明不激活，到出声时才激活，HDMI 才能按片源协商出
        // 5.1 / 全景声；提前激活会锁成立体声（上游 #24）
        #if os(tvOS)
        var hostManagesAudio = false
        #else
        var hostManagesAudio = true
        #endif
        #if DEBUG
        // -mcEngineAudioSession YES：照旧由引擎在建实例时设类别（P47 之前的行为，真机新旧对照用）
        if UserDefaults.standard.bool(forKey: "mcEngineAudioSession") { hostManagesAudio = false }
        #endif
        AetherPlayback.hostManagesAudioSessionCategory = hostManagesAudio
    }

    /// 本次启动第一次建自研引擎时清一遍死会话的缓存（被杀掉的播放会话会在临时目录留下 GB 级分片，
    /// 真机一夜的测试攒到 15 GB、把手机写满）
    private static var sweptStaleCaches = false
    /// App 进后台时让片源字节缓存的记账立刻落盘（引擎补丁 P42）：下次启动续播认得这一场最后几秒下过的字节
    private static var backgroundObserver: NSObjectProtocol?
    static func sweepStaleCachesOnce() {
        guard !sweptStaleCaches else { return }
        sweptStaleCaches = true
        DispatchQueue.global(qos: .utility).async { AetherPlayback.sweepStaleCaches() }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in AetherPlayback.flushSourceCacheIndexes() }
    }

    // MARK: - 播放控制

    func load(url: URL, start: Double, autoplay: Bool) {
        load(source: .file(url), start: start, autoplay: autoplay)
    }

    /// 装载光盘（docs/design/disc-direct-play.md）：镜像给原字节地址，原盘目录给文件清单与主播放列表名，
    /// 盘内结构都由引擎在本机解析，服务端只按 Range 供字节
    func load(disc: NativeDiscSource, start: Double, autoplay: Bool) {
        switch disc {
        case let .image(url):
            load(source: .discImage(url), start: start, autoplay: autoplay)
        case let .folder(files, playlist):
            let mapped = files.map { AetherPlayback.DiscFile(path: $0.path, size: $0.size, url: $0.url) }
            load(source: .discFolder(files: mapped, playlist: playlist), start: start, autoplay: autoplay)
        }
    }

    private func load(source: AetherPlayback.Source, start: Double, autoplay: Bool) {
        lastReported = nil
        tracksKnown = false
        firstFrameShown = false
        playingBeforeFirstFrame = false
        loadingMeter.reset()
        bandwidthMeter.reset()
        lastBandwidthSample = nil
        let tokenURL: URL? = switch source {
        case let .file(url), let .discImage(url): url
        case let .discFolder(files, _): files.first?.url
        }
        if let tokenURL, let token = PlaybackAPI.token(in: tokenURL.absoluteString) { AetherPlayback.redact(token) }
        #if DEBUG
        loadedAt = .now
        FileHandle.standardError.write(Data("[NativeEngine \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] 装载 start=\(start)\n".utf8))
        #endif
        // 带上 App 的 User-Agent：服务端按它把这条流登记成「MovieClaw iOS」而不是浏览器
        loadIssued = true
        // 窗口按段计、存储计划按 4 秒一段定的：分片更短（P33 默认 2 秒）时按比例放大段数，缓冲的时长不变
        let scale = Self.segmentWindowScale
        let forward = storagePlan.forwardSegments ?? (scale > 1 ? 10 : nil)
        let backward = storagePlan.backwardSegments ?? (scale > 1 ? 20 : nil)
        core.load(source: source, start: start > 0.5 ? start : nil, autoplay: autoplay,
                  headers: ["User-Agent": APIClient.userAgent], audioOrdinal: loadAudioOrdinal,
                  externalSubtitles: pendingExternalSubtitles,
                  sourceCacheKey: storagePlan.sourceCache ? sourceCacheKey : nil,
                  forwardSegments: forward.map { Int((Double($0) * scale).rounded()) },
                  backwardSegments: backward.map { Int((Double($0) * scale).rounded()) },
                  matroskaCues: matroskaCues)
        emit(.buffering)
    }

    /// 分片目标时长相对 4 秒的倍数（窗口段数按它放大）。后方窗口引擎最多 20 段，2 秒分片时即 40 秒
    private static var segmentWindowScale: Double {
        let seconds = AetherPlayback.segmentTargetSeconds
        return seconds > 0 && seconds < 4 ? 4 / seconds : 1
    }

    /// 恢复播放一律解除「暂停下载」：忘了解除就会在没有前向缓冲的状态下播放
    func play() {
        core.setPrefetchSuspended(false)
        core.play()
    }

    /// 暂停下载 / 恢复（引擎补丁 P23）：计费网络上用户按了暂停时由控制器调
    func setPrefetchSuspended(_ suspended: Bool) { core.setPrefetchSuspended(suspended) }
    func pause() { core.pause() }

    /// 引擎的定位本身就是精确的（主力通路由 AVPlayer 按帧落点），exact 不区分
    func seek(to seconds: Double, exact: Bool) {
        awaitingSeekPicture = true
        seekLanded = false
        core.seek(to: seconds)
    }

    func setRate(_ rate: Float) { core.setRate(rate) }

    // MARK: - 读数

    var currentTime: Double { core.currentTime }
    var duration: Double? { core.duration }
    var bufferedEnd: Double? { core.bufferedPosition > 0 ? core.bufferedPosition : nil }
    var isPaused: Bool { core.isPaused }
    var videoSize: CGSize { core.videoSize }

    func stats() -> EngineStats {
        let readouts = core.readouts()
        let now = ProcessInfo.processInfo.systemUptime
        let loading = loadingMeter.sample(bytes: readouts.sourceBytesFetched, transferSeconds: 0, at: now)
        if let loading, now - (lastBandwidthSample ?? -.infinity) >= 0.9 {
            lastBandwidthSample = now
            bandwidthMeter.push(bps: loading, at: now)
        }
        var details = readouts.details
        details.append(playsOriginalFile ? "直出原文件" : "播放服务端 HLS")
        if isPictureInPictureActive { details.append("画中画中") }
        let time = currentTime
        return EngineStats(
            engine: kind.rawValue,
            downlinkBps: bandwidthMeter.bps,
            loadingBps: loading,
            bitrateBps: readouts.videoBitrateBps ?? readouts.averageBitrateBps,
            droppedFrames: readouts.droppedFrames,
            // 直出原文件时引擎不给总帧数，掉帧比例看门狗不启用（掉帧不是换播放器的理由）；直连服务端流时
            // 从 AVPlayer 访问日志估，持续掉帧就按「这一档放不动」降档，与原来系统播放器放服务端流一致
            totalFrames: readouts.totalFrames,
            bufferedSeconds: max(0, (bufferedEnd ?? time) - time),
            currentTimeSeconds: time,
            details: details
        )
    }

    // MARK: - 音轨

    /// 引擎在当前位置重载一次即可换轨，不用重开服务端会话
    /// 服务端 HLS 里只有选中的那一条音轨：换轨要重开会话
    var canSwitchAudioInPlace: Bool { playsOriginalFile }

    /// 起播音轨：不是用户明确要的轨时，只在语言不同才换。
    ///
    /// 引擎装载时自己挑一条音轨（FFmpeg 的 best stream），和服务端的默认挑选常常不是同一条：
    /// 原盘里 TrueHD 与它内嵌的 AC-3 核心被拆成两路，引擎挑 AC-3 核心、服务端挑 TrueHD。
    /// 同语言的两条轨对用户几乎没区别（默认都是 5.1 杜比），为这点差别在首帧后重载一次要多黑屏
    /// 0.5～1 秒、原盘要多花好几秒（真机《疾速追杀4》起播 14 秒里一半是这次重载），不值得。
    ///
    /// 用户明确要的轨（这次选过、或记着上次换过的）要在装载前交代：引擎探测完按序号直接起播这条轨，
    /// 不必首帧后再重载一次（真机蓝光镜像起播 2.5 → 4.2 秒就是这一次重载）。
    func selectInitialAudio(embeddedIndex: Int, explicit: Bool) {
        if explicit, !loadIssued {
            loadAudioOrdinal = embeddedIndex
            return
        }
        pendingAudioExplicit = explicit
        selectAudio(embeddedIndex: embeddedIndex)
    }

    /// 线路跟不上片子码率（真卡过）之后调：前向缓冲从默认 10 段（约 40 秒）放大到 3 分钟内容，暂停就能多攒。
    /// 3 分钟是用户定的（2026-09-28）：再长，暂停攒满后不看了白下的流量太多（76 Mbit/s 的原片 3 分钟约 1.7 GB）。
    /// 磁盘仍受引擎的留存预算约束（min(2 GiB, 剩余空间 1/4)）。同一个引擎实例只放大一次
    #if DEBUG
    /// 故障注入（开发期）：假装临时目录只剩这么多字节，见 -mcFakeFreeBytes
    static func setTestVolumeAvailableBytes(_ bytes: Int64?) { AetherPlayback.setTestVolumeAvailableBytes(bytes) }
    /// 故障注入（开发期）：接下来这么多秒里写分片一律按「存储已满」失败，见 -mcStorageFullAfter
    static func simulateStorageFull(forSeconds seconds: Double) { AetherPlayback.simulateStorageFull(forSeconds: seconds) }
    #endif

    /// 临时目录所在卷的可用字节（引擎补丁 P44：带 10 秒缓存，与引擎自己的预算同一份）
    nonisolated static func temporaryFreeBytes() -> Int64? {
        AetherPlayback.temporaryFreeBytes()
    }

    /// 预先和源站建好取源连接（引擎补丁 P43）：起播协商还在路上时调，会话回来时第一个取流请求不用再握手
    nonisolated static func preconnect(url: URL) {
        AetherPlayback.preconnect(url: url, headers: ["User-Agent": APIClient.userAgent])
    }

    func growForwardBuffer() {
        // 存储紧张时窗口是按剩余空间收小的，不再放大
        guard !forwardBufferGrown, storagePlan.canGrowForward else { return }
        forwardBufferGrown = true
        core.setForwardBufferDuration(Self.grownForwardBufferSeconds)
    }

    static let grownForwardBufferSeconds: Double = 180
    private var forwardBufferGrown = false

    func selectAudio(embeddedIndex: Int) {
        guard firstFrameShown else { pendingAudio = embeddedIndex; return }
        let audio = core.audioTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }
        guard embeddedIndex < audio.count else { return }
        let target = audio[embeddedIndex].id
        if core.activeAudioTrackID != target { core.selectAudioTrack(id: target) }
    }

    // MARK: - 引擎读到的轨（服务端清单缺轨时补菜单用）

    /// 引擎读到的一条内封轨：菜单标签与默认挑选要用的几样
    struct EmbeddedTrack {
        let language: String?
        /// 解码器名（小写，如 ac3、pgssub、dvbsub）；没有解码器时是编码描述名（如 arib_caption）
        let codec: String
        let channels: Int
        let isDefault: Bool
    }

    /// 内封音轨，按流顺序排：第 N 条 = embedded:N（与服务端探测的编号口径一致）
    var embeddedAudioTracks: [EmbeddedTrack] { Self.embedded(core.audioTracks) }

    /// 内封字幕轨，按流顺序排：第 N 条 = embedded:N
    var embeddedSubtitleTracks: [EmbeddedTrack] { Self.embedded(core.subtitleTracks) }

    /// 正在放的是第几条内封音轨
    var activeEmbeddedAudioIndex: Int? {
        core.audioTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }.firstIndex { $0.id == core.activeAudioTrackID }
    }

    private static func embedded(_ tracks: [AetherPlayback.Track]) -> [EmbeddedTrack] {
        tracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }
            .map { EmbeddedTrack(language: $0.language, codec: $0.codec, channels: $0.channels, isDefault: $0.isDefault) }
    }

    // MARK: - 字幕（引擎画图形字幕，文字字幕交给叠加层）

    func rendersSubtitle(kind: String) -> Bool { playsOriginalFile && kind == "pgs" }

    /// 直出原文件时内封轨（文字与图形）都由引擎画：字幕从播放的读取流里顺带收集，选轨即刻出字。
    /// 走服务端的话，内封文字轨要 NAS 通读整个容器抽出来（大文件几十秒、还会拖慢 NAS），这正是「服务端弱」要避开的。
    /// 装载时交给引擎的外挂文字字幕也由引擎画（服务端只给编码归一成 UTF-8 的原文件，不转格式）：
    /// ASS / SSA 的定位与分层照样生效，画中画时还能换成原生字幕轨。
    /// 放服务端流（用户限了画质）时引擎不拆包、读不到内封轨：文字字幕由叠加层画，图形字幕由服务端压制进画面
    func rendersSubtitle(_ option: SubtitleOption) -> Bool {
        playsOriginalFile && (option.embeddedIndex != nil || option.kind == "pgs" || externalSubtitleRefs.contains(option.ref))
    }

    /// 装载前交代外挂字幕（引用、取原文件的地址、语言）：由引擎下载、解码、画
    func prepareExternalSubtitles(_ subtitles: [(ref: String, url: URL, language: String?)]) {
        guard !loadIssued else { return }
        var refs: [String] = []
        var declared: [AetherPlayback.ExternalSubtitle] = []
        for subtitle in subtitles {
            // 引用是 external:<文件名>，格式看文件名的扩展名；引擎认不得的格式（位图 .sup 等）不交，仍走叠加层
            let format = (subtitle.ref as NSString).pathExtension.lowercased()
            guard ["srt", "ass", "ssa", "vtt"].contains(format) else { continue }
            refs.append(subtitle.ref)
            declared.append(.init(url: subtitle.url, language: subtitle.language, format: format))
        }
        externalSubtitleRefs = refs
        pendingExternalSubtitles = declared
    }

    func selectSubtitle(_ option: SubtitleOption?, url: URL?) {
        guard let option else {
            hasPendingSubtitle = false
            pendingSubtitle = nil
            core.clearSubtitle()
            return
        }
        guard tracksKnown else {
            hasPendingSubtitle = true
            pendingSubtitle = option
            return
        }
        // 内封轨按同类型顺序对位（embedded:N = 第 N 条内封字幕，与服务端探测顺序一致）
        if let index = option.embeddedIndex {
            let embedded = core.subtitleTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }
            if index < embedded.count {
                core.selectSubtitleTrack(id: embedded[index].id)
                return
            }
        }
        // 外挂轨按装载时登记的顺序对位
        if let index = externalSubtitleRefs.firstIndex(of: option.ref) {
            let external = core.subtitleTracks.filter(\.isExternal).sorted { $0.id < $1.id }
            if index < external.count {
                core.selectSubtitleTrack(id: external[index].id)
                return
            }
        }
        core.clearSubtitle()
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        core.setSubtitleDelay(style.offsetSeconds)
        core.setTextStyle(.init(
            fontScale: style.fontScale, bottomPercent: style.bottomPercent, background: style.background
        ))
    }

    // MARK: - 画中画 / 前后台

    var supportsPictureInPicture: Bool {
        #if os(tvOS)
        // Apple TV 首版不做画中画：软解通路的画中画 tvOS 不接受，两条通路体验不一致（docs/design/tvos-app.md §4.3）
        false
        #else
        AVPictureInPictureController.isPictureInPictureSupported()
            && (core.pictureInPictureLayer != nil || core.softwarePictureInPicture != nil)
        #endif
    }

    func togglePictureInPicture() {
        preparePictureInPicture()
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    /// 画中画控制器绑在引擎的显示层上：换引擎、换会话都不需要，原地进出小窗。
    /// 主力通路绑 AVPlayerLayer；软件通路（VP9、MPEG-2、VC-1……）绑采样缓冲显示层，小窗的时间与播放控制
    /// 由引擎回答（`AVPictureInPictureSampleBufferPlaybackDelegate`）——两条通路的画中画都在本机完成，
    /// 不用为画中画换成服务端转码
    private func preparePictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller: AVPictureInPictureController?
        if let layer = core.pictureInPictureLayer {
            if pipController != nil, pipLayer === layer { return }
            controller = AVPictureInPictureController(playerLayer: layer)
            softwarePiP = nil
            pipLayer = layer
        } else if let software = core.softwarePictureInPicture {
            if pipController != nil, pipLayer === software.layer { return }
            controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: software.layer, playbackDelegate: self))
            softwarePiP = software
            pipLayer = software.layer
        } else {
            return
        }
        pipController?.delegate = nil
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        controller?.delegate = self
        pipController = controller
    }

    /// 前后台大多由引擎自己跟随 App 生命周期处理（后台只留声音、画中画时保持管线）。只有一件要宿主做：
    /// 暂停着在后台超过 15 秒，引擎会拆掉视频管线省电（上游 #127），回前台要在原位置重建，否则点播放只会一直转圈
    func setBackgrounded(_ background: Bool) {
        if !background { rebuiltOnForeground = core.rebuildAfterBackgroundTeardown() }
    }

    // MARK: - 播放体验打点的读数（docs/design/playback-qoe.md §3）

    /// 软件通路交到显示层的累计帧数（冻帧检测）；其余通路为 nil
    var presentedFrameCount: Int? { core.readouts().route == "software" ? core.presentedSoftwareFrames : nil }

    /// 规格事实（源是什么、实际送出的是什么）
    func deliveryFacts() -> EngineDeliveryFacts {
        let facts = core.deliveryFacts()
        return EngineDeliveryFacts(
            route: facts.route, container: facts.container, videoCodec: facts.videoCodec,
            sourceFormat: facts.sourceFormat, outputFormat: facts.outputFormat,
            dolbyVisionProfile: facts.dolbyVisionProfile, dolbyVisionConversion: facts.dolbyVisionConversion,
            audioDelivery: facts.audioDelivery, audioDecoder: facts.audioDecoder, audioCodec: facts.audioCodec,
            audioChannels: facts.audioChannels, audioName: facts.audioName
        )
    }

    /// 引擎日志最近的若干行（播放失败时随记录上报）
    static func recentEngineLog() -> String { AetherPlayback.recentEngineLog() }

    func destroy() {
        onEvent = nil
        pipController?.delegate = nil
        pipController = nil
        core.destroy()
    }

    // MARK: - 事件

    private func handle(_ phase: AetherPlayback.Phase) {
        switch phase {
        case .loading, .buffering: emit(.buffering)
        case .playing:
            // 软件通路上时钟先转、画面后到：首帧上屏之前一直报缓冲，转圈不提前收起、起播计时也按首帧算
            if firstFrameShown { emit(.playing) } else { playingBeforeFirstFrame = true }
            // 主力通路：跳转落地之后恢复播放，落点的画面才真的动起来
            if awaitingSeekPicture, seekLanded, core.readouts().route != "software" { seekPictureShown() }
        case .paused: emit(.paused)
        case .ended: emit(.ended)
        }
    }

    private func handle(_ failure: AetherPlayback.Failure) {
        // 引擎的报错是英文；用户看得懂的几种先翻成中文
        let message = failure.message.hasPrefix("Device storage is full")
            ? "手机存储空间不足，视频分片写不进缓存，请清理存储后重试"
            : failure.message
        lastFailureKind = failure.kind
        let cause: EngineFailureCause = switch failure.category {
        case .network: .network
        case .sourceMissing: .sourceMissing
        case .storageFull: .storageFull
        case let .decode(final): final ? .decodeFinal : .decode
        }
        emit(.failed(reason: "自研引擎无法播放（\(message)）", cause: cause))
    }

    private func tracksChanged() {
        tracksKnown = !core.audioTracks.isEmpty || !core.subtitleTracks.isEmpty
        guard tracksKnown else { return }
        if hasPendingSubtitle {
            hasPendingSubtitle = false
            selectSubtitle(pendingSubtitle, url: nil)
        }
        onEvent?(.tracksChanged)
    }

    private func firstFrameReady() {
        firstFrameShown = true
        // 每次出首帧都报（起播、换音轨重载、回前台重建）：不走 emit，不影响播放状态的去重
        onEvent?(.milestone(.firstFrame))
        if playingBeforeFirstFrame {
            playingBeforeFirstFrame = false
            emit(.playing)
        }
        preparePictureInPicture()
        if let pendingAudio {
            self.pendingAudio = nil
            let explicit = pendingAudioExplicit
            pendingAudioExplicit = true
            if explicit || audioLanguageDiffers(fromEmbedded: pendingAudio) {
                selectAudio(embeddedIndex: pendingAudio)
            }
        }
    }

    /// 引擎那边的跳转终局。主力通路：暂停中落地即是画面到了，播放中要等恢复播放（见 handle(_:)）；
    /// 软件通路等新一代的第一帧交到显示层（`softwareFrameGeneration`）
    private func seekOutcome(_ outcome: AetherPlayback.SeekOutcome) {
        guard awaitingSeekPicture else { return }
        switch outcome {
        case .landed:
            seekLanded = true
            guard core.readouts().route != "software" else { return }
            if case .playing? = lastReported {
                seekPictureShown()
            } else if core.isPaused {
                seekPictureShown()
            }
        case .stalled, .rejected:
            awaitingSeekPicture = false
            onEvent?(.seekFailed)
        case .superseded:
            // 更新的跳转接着来：继续等它的落点
            break
        }
    }

    /// 软件通路：新一代的第一帧交到了显示层（跳转后落点那一帧，或装载后的第一帧）
    private func softwareFrameGeneration() {
        guard awaitingSeekPicture else { return }
        seekPictureShown()
    }

    private func seekPictureShown() {
        awaitingSeekPicture = false
        seekLanded = false
        onEvent?(.seekPresented)
    }

    /// 服务端挑的第 N 条内封音轨与引擎正在放的轨语言是否不同（任一方没有语言标记时视为相同，信引擎的挑选）
    private func audioLanguageDiffers(fromEmbedded index: Int) -> Bool {
        let audio = core.audioTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }
        guard index < audio.count, let active = audio.first(where: { $0.id == core.activeAudioTrackID }) else { return false }
        let wanted = audio[index]
        guard wanted.id != active.id, let want = wanted.language?.lowercased(), let have = active.language?.lowercased(),
              !want.isEmpty, !have.isEmpty, want != "und", have != "und" else { return false }
        return want != have
    }

    private func emit(_ event: EngineEvent) {
        switch (event, lastReported) {
        case (.playing, .playing?), (.paused, .paused?), (.buffering, .buffering?), (.ended, .ended?):
            return
        default:
            lastReported = event
            // 软件通路的小窗自己不知道播放状态：状态变了要让它重新来问（播放/暂停键、进度条）
            if softwarePiP != nil { pipController?.invalidatePlaybackState() }
            #if DEBUG
            let elapsed = Int((ContinuousClock.now - loadedAt) / .milliseconds(1))
            let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
            FileHandle.standardError.write(Data("[NativeEngine \(stamp)] \(event) 距装载 \(elapsed) 毫秒 t=\(String(format: "%.2f", currentTime))\n".utf8))
            #endif
            onEvent?(event)
        }
    }
}

extension NativeEngine: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            #if DEBUG
            FileHandle.standardError.write(Data("[PiP] 进入画中画 t=\(String(format: "%.2f", currentTime))\n".utf8))
            #endif
            isPictureInPictureActive = true
            core.setPictureInPictureActive(true)
            onEvent?(.pictureInPicture(true))
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            #if DEBUG
            FileHandle.standardError.write(Data("[PiP] 退出画中画 t=\(String(format: "%.2f", currentTime))\n".utf8))
            #endif
            isPictureInPictureActive = false
            core.setPictureInPictureActive(false)
            onEvent?(.pictureInPicture(false))
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        MainActor.assumeIsolated {
            #if DEBUG
            FileHandle.standardError.write(Data("[PiP] 画中画启动失败：\(error.localizedDescription)\n".utf8))
            #endif
            isPictureInPictureActive = false
            core.setPictureInPictureActive(false)
        }
    }
}

/// 软件通路画中画的播放方：小窗问可播范围、是否暂停，按播放/暂停与快进快退键时回调这里，一律转给引擎。
/// 系统在主线程回调（以防万一不在主线程时同步切回主线程再答）
extension NativeEngine: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        onMain { softwarePiP?.setPlaying(playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        onMain { softwarePiP?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        onMain { softwarePiP?.isPaused ?? true }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        onMain { softwarePiP?.skip(by: skipInterval.seconds) }
        completionHandler()
    }
}
