import AetherEngine
import AVFoundation
import Combine
#if canImport(UIKit)
import UIKit
/// 画面宿主的视图类型：iPhone / Apple TV 是 UIView，Mac 是 NSView（引擎的 AetherPlayerView 同样两边都有）
public typealias AetherPlatformView = UIView
private typealias PlatformFont = UIFont
private typealias PlatformColor = UIColor
#else
import AppKit
public typealias AetherPlatformView = NSView
private typealias PlatformFont = NSFont
private typealias PlatformColor = NSColor
#endif

/// AetherEngine 的封装，是 App 与这个 LGPL 组件之间**唯一**的边界。
///
/// ## 为什么单独做成动态框架（AetherCore.framework）
/// 1. **LGPL 替换边界**：用户可以用自己编译的同名框架替换。
/// 2. **FFmpeg 符号绑定**：AetherEngine 的 FFmpeg 引用在本框架链接时就绑定到自带的 `AetherLib*` 动态框架。
///    一个进程里有两份 FFmpeg 时（2026-09-28 移除 MPV 之前，mpv 还静态打着一份），`avcodec_*` 绑到哪一份
///    由链接决定，绑错了症状像引擎 bug；日后再引入别的 FFmpeg 使用方也不会串。
/// 因此 App 只 import AetherCore、从不直接 import AetherEngine，这层边界不能破。
///
/// ## 这个引擎做什么
/// 「FFmpeg 负责拆，Apple 负责播」：FFmpeg 读原文件、拆出音视频，就地换封装成 HLS 分片，经本机回环地址
/// 交给 AVPlayer；杜比视界、全景声、HDR、画中画都交给系统。AVPlayer 解不了的编码（VP9、VC-1、MPEG-2……）
/// 由引擎自己换到 FFmpeg 软解 + 系统显示层。设计见 docs/design/player-engine.md。
///
/// ## 本类的职责
/// - 把引擎的多路状态（`playbackPhase` / `errorInfo` / 轨道 / 首帧）归约成 App 关心的几个事件；
/// - 画内封字幕（PGS 等图形字幕、SRT/ASS 等文字字幕）：引擎只给出字幕数据，画在哪里、画成什么样由宿主决定，这里按画面矩形摆放；
/// - 汇总诊断读数（通路、解码器、画面格式、取流字节数）。
/// 时间一律是引擎的**源文件时间轴**（秒）：原文件直出时就是文件时间。
@MainActor
public final class AetherPlayback {
    /// 归约后的播放阶段
    public enum Phase: Equatable, Sendable {
        case loading, playing, paused, buffering, ended
    }

    /// 失败的归因。宿主据此决定下一步：取流类原地重开、存储满了收小缓冲重开、片源不在了直接说明，
    /// 只有「解不了」才考虑换播放器（而且一时的问题先原位重开一次）
    public enum FailureCategory: Sendable, Equatable {
        /// 取流失败：断线、令牌失效、服务端 5xx、限流、VOD 源中途断掉
        case network
        /// 服务端对原文件回 404：文件不在了，换什么播放器都一样
        case sourceMissing
        /// 手机存储写满，切好的分片写不进去（内置引擎补丁 P25）
        case storageFull
        /// 解不了。final = 确定解不了（硬件解码器拒绝且本机软解也接不住、杜比视界 P5 在软件通路上表示不了、
        /// 片源格式本机不认），原位重开也没用；否则可能是一时的（引擎楞住、中途出错）
        case decode(final: Bool)
    }

    public struct Failure: Sendable {
        public let message: String
        /// 引擎的稳定错误分类（`PlaybackErrorKind.rawValue`），日志与埋点用
        public let kind: String
        public let category: FailureCategory
    }

    /// 一条音轨 / 字幕轨（id 是容器里的流序号，外挂轨从 100000 起）
    public struct Track: Sendable, Hashable {
        public let id: Int
        public let name: String
        public let codec: String
        public let language: String?
        /// 音轨声道数（2 = 立体声、6 = 5.1、8 = 7.1），字幕为 0
        public let channels: Int
        public let isExternal: Bool
        public let isDefault: Bool
    }

    /// 诊断与看门狗用的读数快照（1 秒刷新一次的引擎遥测 + 当前状态）
    public struct Readouts: Sendable {
        /// 实际在跑的通路：loopback（换封装进 AVPlayer）/ software（软解）/ remoteBypass / none
        public let route: String
        /// 从源（NAS）累计拉到的字节，算加载速度与带宽用
        public let sourceBytesFetched: Int64?
        public let droppedFrames: Int?
        /// 已播放的总帧数（按已播时长 × 帧率估）：只有直连服务端 HLS 时给得出，掉帧比例看门狗据此判断
        public let totalFrames: Int?
        public let averageBitrateBps: Double?
        public let videoBitrateBps: Double?
        /// 给人看的细节行（解码器、画面格式、音频交付方式……）
        public let details: [String]
    }

    public let view: AetherPlatformView
    public var onPhase: ((Phase) -> Void)?
    public var onFailure: ((Failure) -> Void)?
    /// 轨道列表变化（装载完成、外挂轨注册）
    public var onTracksChanged: (() -> Void)?
    /// 第一帧可以上屏
    public var onFirstFrame: (() -> Void)?

    // MARK: 播放体验打点用的信号（docs/design/playback-qoe.md §3）

    /// 起播检查点（引擎的 `startupProgress`，依次是 sourceOpened / containerOpened / streamsProbed /
    /// displayPrepared / routed / sessionConstructed / ready / presenting）：宿主据此把「引擎里」
    /// 那一段起播耗时拆开
    public var onStartupStage: ((String) -> Void)?
    /// 一次跳转的终局（引擎的 `seekEvents`）
    public var onSeekOutcome: ((SeekOutcome) -> Void)?
    public enum SeekOutcome: Sendable, Equatable {
        /// 引擎这边落地了（主力通路：AVPlayer 的跳转完成；软件通路：解复用已重新定位，画面还在路上）
        case landed
        /// 超时没落地
        case stalled
        /// 被更新的跳转取代
        case superseded
        case rejected
    }
    /// 软件通路：新一代（每次跳转都会清空显示队列、开启新一代）的第一帧交到了显示层——跳转后「画面到了」
    /// 的时刻。装载后的第一帧也会触发一次。主线程回调
    public var onSoftwareFrameGeneration: (() -> Void)?

    /// 规格事实：源是什么、实际送出的是什么（「对」的判定材料，服务端按规则表判损失）
    public struct DeliveryFacts: Sendable, Equatable {
        /// loopback / software / remoteBypass / audio / none
        public let route: String
        public let container: String?
        public let videoCodec: String?
        /// 源的画面格式与实际送出的画面格式：sdr / hdr10 / hdr10plus / dolbyvision / hlg
        public let sourceFormat: String
        public let outputFormat: String
        public let dolbyVisionProfile: Int?
        /// 杜比视界转换（profile7to81 = P7 转 P8.1，完整增强层会被丢掉）
        public let dolbyVisionConversion: String?
        /// 音频交付：streamCopy / bridged / decoded / playerManaged / noAudioInSource / droppedNoPipeline / none
        public let audioDelivery: String
        /// 音频解码 / 桥接的说明（如「truehd → EAC3 bridge」「Stream-copy (EAC3+JOC Atmos)」）
        public let audioDecoder: String?
        /// 正在放的音轨：编码、声道、名称（名称里常写着 Atmos / DTS-HD MA）
        public let audioCodec: String?
        public let audioChannels: Int?
        public let audioName: String?
    }

    /// 软件通路交到显示层的帧数（冻帧检测用：时钟在走、这个数不涨就是画面冻住）。其余通路恒为 0
    public var presentedSoftwareFrames: Int { frameCounter.count }
    private let frameCounter = SoftwareFrameCounter()

    private let engine: AetherEngine
    private let playerView = AetherPlayerView()
    private let subtitleView = SubtitleLayerView()
    private var cancellables: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var lastPhase: Phase?
    private var destroyed = false
    /// 最近一次装载的片源（后台拆除后判断还有没有东西可以重建）
    private var lastSource: Source?
    private var rebuildInFlight = false
    /// 字幕的时间轴微调（秒，正数 = 延后），与 App 叠加层同一口径
    private var subtitleDelay: Double = 0

    public init() throws {
        engine = try AetherEngine()
        let container = PlaybackContainerView(playerView: playerView, subtitleView: subtitleView)
        view = container
        engine.bind(view: playerView)
        engine.videoGravity = .resizeAspect
        // 后台继续出声音（与系统播放器一致）；画中画时引擎保持管线不拆
        engine.backgroundPlaybackEnabled = true
        container.onLayout = { [weak self] in self?.refreshSubtitles() }
        observe()
        // 软件通路逐帧回调在解码线程上、不能阻塞：只计数，换代时切回主线程通知一次
        let counter = frameCounter
        let box = WeakPlayback(self)
        engine.setSoftwareVideoFrameTimeObserver { frame in
            guard counter.record(generation: frame.generation) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.onSoftwareFrameGeneration?() } }
        }
    }

    /// 开发期：字幕列表变化时把文字字幕连同 ASS 定位打到控制台（排查字幕摆放用）
    nonisolated(unsafe) public static var logsCues = false

    /// 接管引擎日志：一律进环形缓冲（Release 包也开，播放失败时随播放记录上报最近的若干行，
    /// 见 docs/design/playback-qoe.md §3.5）；`mirror` 时同步打到控制台（开发期，`EngineLog` 默认只进系统日志，
    /// 模拟器排查时看不到）。每行前面带开机以来的秒数（与 App 侧 `[NativeEngine]` 行同一时钟），拆起播各段耗时用。
    /// 回调可能来自任意线程，只做线程安全的写入。引擎本来就会拼好这些行并脱敏，这里只是多存一份
    public static func installLogHandler(mirror: Bool) {
        let ring = logRing
        EngineLog.handler = { line in
            let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
            ring.append("[\(stamp)] \(line)")
            if mirror { FileHandle.standardError.write(Data("[Aether \(stamp)] \(line)\n".utf8)) }
        }
    }

    /// 点播换封装的分片目标时长（秒，引擎补丁 P33，默认 2）。宿主按它把窗口段数折回同样的缓冲时长
    public static var segmentTargetSeconds: Double {
        get { AetherEngine.vodSegmentTargetSeconds }
        set { AetherEngine.vodSegmentTargetSeconds = newValue }
    }

    /// 主力通路跳转吸附关键帧的逐帧解码预算（秒，引擎补丁 P36，默认 0.2；≤ 0 关闭，真机新旧对照用）
    public static var seekSnapDecodeBudgetSeconds: Double {
        get { AetherEngine.seekSnapDecodeBudgetSeconds }
        set { AetherEngine.seekSnapDecodeBudgetSeconds = newValue }
    }

    /// 起播 / 跳转后看缓冲过没过开播线的间隔（秒，引擎补丁 P28，默认 0.025；真机新旧对照用）
    public static var vodStartWitnessIntervalSeconds: Double {
        get { AetherEngine.vodStartWitnessIntervalSeconds }
        set { AetherEngine.vodStartWitnessIntervalSeconds = max(0.01, newValue) }
    }

    /// 起播落点吸附关键帧的逐帧解码预算（秒，引擎补丁 P39，默认 0.05；≤ 0 关闭，真机新旧对照用）
    public static var startSnapDecodeBudgetSeconds: Double {
        get { AetherEngine.startSnapDecodeBudgetSeconds }
        set { AetherEngine.startSnapDecodeBudgetSeconds = newValue }
    }

    /// 预先和源站建好取源连接（引擎补丁 P43）：点播放时调，起播协商回来前把 TCP / TLS 握手做掉。
    /// url 是同一源站上任何一个便宜的地址（MovieClaw 用健康检查），headers 同装载时的
    public nonisolated static func preconnect(url: URL, headers: [String: String] = [:]) {
        AetherEngine.preconnect(url: url, httpHeaders: headers)
    }

    /// MKV 文件头一到就按 SeekHead 把索引（Cues）先取回来（引擎补丁 P49，默认开；真机新旧对照时关掉）
    public static func setPrefetchesMatroskaCues(_ on: Bool) {
        AetherEngine.prefetchesMatroskaCues = on
    }

    /// 读到在途的提前取（尾部预读 / MKV 索引）时，只要还在往回送就一直等（引擎补丁 P53，默认开；对照时关掉）
    public static func setWaitsOnProgressingPrefetch(_ on: Bool) {
        AetherEngine.waitsOnProgressingPrefetch = on
    }

    /// MP4 的 moov 在文件尾时，文件头一到就并行取回来（引擎补丁 P54，默认开；对照时关掉）
    public static func setPrefetchesMP4TailMoov(_ on: Bool) {
        AetherEngine.prefetchesMP4TailMoov = on
    }

    /// 实测线路慢到 4 MB 整块补取在限时内到不齐时，回跳直接重连流式读（引擎补丁 P55，默认开；对照时关掉）
    public static func setSkipsDetourOnSlowLink(_ on: Bool) {
        AetherEngine.skipsDetourOnSlowLink = on
    }

    /// 点播分片边产出边送、分片内每 0.5 秒一个片段（引擎补丁 P57，默认开；对照时关掉）
    public static func setServesSegmentsProgressively(_ on: Bool) {
        AetherEngine.servesSegmentsProgressively = on
    }

    /// 点播媒体播放列表也声明分片各自独立，跳转时 AVPlayer 直接要目标段（引擎补丁 P59，默认开；对照时关掉）
    public static func setDeclaresIndependentMediaSegments(_ on: Bool) {
        AetherEngine.declaresIndependentMediaSegments = on
    }

    /// 服务端给了 MKV 精简索引就用它顶替原索引（引擎补丁 P58，默认开；对照时关掉）
    public static func setUsesHostMatroskaCues(_ on: Bool) {
        AetherEngine.usesHostMatroskaCues = on
    }

    /// 冷打开时文件头先只要 512 KB，索引提前取在途时文件头不超前预读（引擎补丁 P56，默认开；对照时关掉）
    public static func setPrioritizesIndexPrefetch(_ on: Bool) {
        AetherEngine.prioritizesIndexPrefetch = on
    }

    /// MKV 索引预热是否跳到起播点（引擎补丁 P45，默认开；关掉即上游的跳到片中间，真机新旧对照用）
    public static func setCuePrewarmTargetsStart(_ on: Bool) {
        AetherEngine.cuePrewarmTargetsStart = on
    }

    /// 宿主自己管音频会话的类别、策略与多声道支持（引擎补丁 P47）：设为 true 后引擎建实例时不再重设类别
    public static var hostManagesAudioSessionCategory: Bool {
        get { AetherEngine.hostManagesAudioSessionCategory }
        set { AetherEngine.hostManagesAudioSessionCategory = newValue }
    }

    /// 探测流时是否跳过第二条起的 TrueHD（引擎补丁 P34，默认开；真机新旧对照时关掉）
    public static func setParkSecondaryTrueHD(_ on: Bool) {
        AetherEngine.parkSecondaryTrueHDDuringProbe = on
    }

    /// 片源字节缓存写盘是否放后台队列（引擎补丁 P32，默认开；真机新旧对照时关掉）
    public static func setByteCacheWritesInBackground(_ on: Bool) {
        AetherEngine.sourceByteCacheWritesInBackground = on
    }

    /// 引擎日志最近的若干行（最多 `maxBytes` 字节，从新往旧截），播放失败时随记录上报
    public static func recentEngineLog(maxBytes: Int = 32 * 1024) -> String { logRing.snapshot(maxBytes: maxBytes) }

    /// 刷片预取（内置引擎补丁 P39）：把一个片源的若干字节范围（文件头 / 索引 / 起点后几秒，服务端算好给出）
    /// 先写进片源字节缓存。之后用同一个 `cacheKey` 装载时，打开与跳到起点都直接读本机。
    /// 返回这次从源站拉下来的字节数；取消任务即停止，已写进缓存的保留
    public nonisolated static func prefetchSource(url: URL, cacheKey: String,
                                                  ranges: [(offset: Int64, length: Int64)],
                                                  headers: [String: String] = [:]) async -> Int64 {
        let report = await AetherEngine.prefetchSourceRanges(
            url: url, cacheKey: cacheKey,
            ranges: ranges.map { SourceByteRange(offset: $0.offset, length: $0.length) },
            httpHeaders: headers
        )
        return report.fetchedBytes
    }

    private static let logRing = EngineLogRing()

    /// 日志里要打码的秘密（取流令牌）
    public static func redact(_ secret: String) {
        EngineLog.registerSecret(secret)
    }

    // MARK: - 播放控制

    /// 原盘目录里的一个文件（相对原盘根目录的路径、字节数、按 Range 取字节的地址）
    public struct DiscFile: Sendable {
        public let path: String
        public let size: Int64
        public let url: URL

        public init(path: String, size: Int64, url: URL) {
            self.path = path
            self.size = size
            self.url = url
        }
    }

    /// 装载什么（docs/design/disc-direct-play.md）：光盘结构都在本机解析，服务端只按 Range 供字节
    public enum Source: Sendable {
        /// 普通媒体文件
        case file(URL)
        /// 光盘镜像（蓝光 UDF / DVD ISO9660）的原字节：地址没有 .iso 后缀，靠片段标记告诉引擎按镜像读
        case discImage(URL)
        /// 原盘目录（BDMV）：目录清单 + 服务端选中的主播放列表名，引擎按剪辑逐个文件取字节并拼接
        case discFolder(files: [DiscFile], playlist: String?)
    }

    /// 装载并（按需）起播。start 为源文件时间秒数；headers 附在每一次取源请求上
    /// （App 用它带上自己的 User-Agent，服务端的活动页据此认出「MovieClaw iOS」）
    public func load(url: URL, start: Double?, autoplay: Bool, headers: [String: String] = [:]) {
        load(source: .file(url), start: start, autoplay: autoplay, headers: headers)
    }

    /// 外挂字幕文件：装载时交给引擎，由引擎下载、解码、画（ASS 的定位照样生效），画中画时也能换成原生字幕轨
    public struct ExternalSubtitle: Sendable, Equatable {
        public let url: URL
        public let language: String?
        /// 文件格式（srt / ass / ssa / vtt）：取字幕的地址不带扩展名，要明说
        public let format: String

        public init(url: URL, language: String?, format: String) {
            self.url = url
            self.language = language
            self.format = format
        }
    }

    /// audioOrdinal：起播就放第几条音轨（容器里音轨的顺序，从 0 数；内置引擎补丁 P11）。nil = 引擎自己挑。
    /// externalSubtitles：外挂字幕按给出的顺序登记，`subtitleTracks` 里 isExternal 的轨按 id 排序与之一一对应
    /// sourceCacheKey：片源字节缓存的键（内置引擎补丁 P22）——同一个文件在这一场里每个字节只下一次，
    /// 换音轨、回前台的整场重建与往回跳都从本机拿已下过的字节。取流地址每次带新令牌，所以要给稳定的键
    /// forwardSegments / backwardSegments：分片缓存的前后窗口（段数，nil = 引擎默认 10 / 20）。存储紧张时由宿主
    /// 按剩余空间收小，自研引擎照样能放（内置引擎补丁 P25）
    /// matroskaCues：服务端给的 MKV 精简索引（原 Cues 在文件里的位置 + 只含视频轨索引点的整个 Cues 元素，内置引擎
    /// 补丁 P58）。主播放的解复用器读索引时直接用它，原索引不用下载；数据不完整或位置对不上时引擎当没给
    public func load(source: Source, start: Double?, autoplay: Bool, headers: [String: String] = [:],
                     audioOrdinal: Int? = nil, externalSubtitles: [ExternalSubtitle] = [],
                     sourceCacheKey: String? = nil, forwardSegments: Int? = nil, backwardSegments: Int? = nil,
                     matroskaCues: (offset: Int64, data: Data)? = nil) {
        loadTask?.cancel()
        lastPhase = nil
        subtitleView.cues = []
        lastSource = source
        var options = LoadOptions()
        options.sourceCacheKey = sourceCacheKey
        options.forwardBufferSegments = forwardSegments
        options.backwardBufferSegments = backwardSegments
        options.matroskaCues = matroskaCues.flatMap { MatroskaHostCues(offset: $0.offset, data: $0.data) }
        options.autoplay = autoplay
        options.httpHeaders = headers
        // 点播起播时缓冲已够 1.5 秒就不再等 AVPlayer 的码率估计，一次性提前开播（内置引擎补丁 P2）
        options.vodStartsImmediately = true
        // 需要本机重编的音轨（DTS、TrueHD、PCM、MP2 等）：多声道编成 E-AC-3（AirPods / 功放按环绕声放），双声道编成 FLAC（无损）
        options.audioBridgeMode = .surroundCompat
        options.audioTrackOrdinal = audioOrdinal
        options.externalSubtitles = externalSubtitles.map {
            ExternalSubtitleTrack(url: $0.url, language: $0.language, formatHint: $0.format)
        }
        // 内封文字字幕同时声明成原生字幕轨：平时不选（App 自己的字幕层画），画中画时换 AVPlayer 画（见 setPictureInPictureActive）。
        // 读字幕的旁路只在选中原生轨时才跑，平时不花读取与解码
        options.prepareNativeSubtitles = true
        let engine = self.engine
        let mediaSource: MediaSource
        switch source {
        case let .file(url):
            mediaSource = .url(url)
        case let .discImage(url):
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = Demuxer.discImageFragment
            mediaSource = .url(components?.url ?? url)
        case let .discFolder(files, playlist):
            // 原盘目录每个文件一个取流地址：逐个登记到「片源键/文件路径」上，换音轨、往回跳都复用已下过的字节
            if let sourceCacheKey {
                for file in files { AetherEngine.bindSourceCacheKey(url: file.url, key: "\(sourceCacheKey)/\(file.path)") }
            }
            let reader = HTTPDiscDirectoryReader(
                files: files.map { HTTPDiscDirectoryReader.File(path: $0.path, size: $0.size, url: $0.url) },
                preferredPlaylist: playlist,
                httpHeaders: headers
            )
            mediaSource = .custom(reader, formatHint: nil)
        }
        loadTask = Task { [weak self] in
            do {
                // 宿主起播：续播点要逐帧解太久时从前一个关键帧开播（内置引擎补丁 P39）。引擎自己的重建不经这里，原位接上
                engine.snapsNextStartToKeyframe = true
                try await engine.load(source: mediaSource, startPosition: start, options: options)
            } catch is CancellationError {
                // 被新的装载 / 停止取代：不是播放失败
            } catch {
                // 装载失败时引擎同时发布 .error 状态，由状态订阅统一上报；这里兜住没有发布状态的情况
                guard let self, !self.destroyed, !Task.isCancelled else { return }
                if case .error = engine.playbackPhase { return }
                self.report(Failure(message: error.localizedDescription, kind: "loadThrew", category: .decode(final: false)))
            }
        }
    }

    public func play() {
        // 会话在后台被拆掉了（见 `rebuildAfterBackgroundTeardown`）而回前台时没来得及重建：原位置重建并起播
        if tornDownInBackground {
            rebuild(autoplay: true)
            return
        }
        engine.play()
    }

    public func pause() { engine.pause() }

    /// 回前台时调。引擎在后台暂停超过宽限期（上游 #127，15 秒）会拆掉整条视频管线省电，上游约定由宿主在原位置
    /// 重建——不重建的话点播放只会一直转圈，要等 App 的看门狗判「连接断了」整场重连（15 秒以上）。
    /// 重建后保持暂停，画面停在原处；片源字节缓存（引擎补丁 P22）还在，重建不用重下
    /// 返回是否真的开始重建了（播放记录据此区分「回前台要等重建出画」与「画面一直都在」）
    @discardableResult
    public func rebuildAfterBackgroundTeardown() -> Bool {
        guard tornDownInBackground else { return false }
        rebuild(autoplay: false)
        return true
    }

    /// 管线已被后台拆除：引擎处于暂停、却没有任何通路（诊断里显示「未装载」）
    private var tornDownInBackground: Bool {
        !destroyed && lastSource != nil && engine.videoRoute == .none && engine.state == .paused
    }

    private func rebuild(autoplay: Bool) {
        guard !rebuildInFlight else { return }
        rebuildInFlight = true
        let engine = self.engine
        Task { [weak self] in
            do {
                try await engine.reloadAtCurrentPosition { $0.autoplay = autoplay }
                // 被后台拆掉的会话重建时引擎仍按最初装载的「起播」来（实测 autoplay=false 也会把速率设成 1），
                // 回前台要停在原处：重建一返回就补一次暂停，赶在真正出声之前
                if !autoplay { engine.pause() }
            } catch {
                // 同装载失败：引擎发布了 .error 就由状态订阅上报，这里只兜没发布的情况
                var engineReported = false
                if case .error = engine.playbackPhase { engineReported = true }
                if let self, !self.destroyed, !Task.isCancelled, !engineReported {
                    self.report(Failure(message: error.localizedDescription, kind: "rebuildThrew", category: .decode(final: false)))
                }
            }
            self?.rebuildInFlight = false
        }
    }

    public func seek(to seconds: Double) {
        let engine = self.engine
        Task { await engine.seek(to: max(0, seconds)) }
    }

    public func setRate(_ rate: Float) { engine.setRate(rate) }

    /// 放大前向缓冲到「多少秒内容」：线路跟不上片子码率时，让暂停能多攒（引擎补丁 P20）
    public func setForwardBufferDuration(_ seconds: Double) { engine.setForwardBufferDuration(seconds) }

    /// 暂停下载 / 恢复（内置引擎补丁 P23）：计费网络上用户按了暂停时停，恢复播放时解除
    public func setPrefetchSuspended(_ suspended: Bool) { engine.setPrefetchSuspended(suspended) }

    #if os(macOS)
    /// 播放音量（0～1，Mac 版播放器的音量滑块用）：引擎只写给正在出声的那一路，换通路时自动带过去
    public var volume: Float {
        get { engine.volume }
        set { engine.volume = newValue }
    }
    #endif


    // MARK: - 读数

    public var currentTime: Double { engine.currentTime }
    public var duration: Double? { engine.duration > 0 ? engine.duration : nil }
    /// 已缓冲到的源文件时间
    public var bufferedPosition: Double {
        // 直连服务端 HLS：分片由 AVPlayer 自己取，引擎的缓冲读数不涨，改看 AVPlayer 已加载到哪
        // （含当前播放点的那一段的终点；与 currentTime 同是播放项时间）
        if engine.videoRoute == .remoteBypass, let item = engine.currentAVPlayerItem {
            let now = item.currentTime().seconds
            for value in item.loadedTimeRanges {
                let range = value.timeRangeValue
                let start = range.start.seconds
                let end = CMTimeAdd(range.start, range.duration).seconds
                if start <= now + 0.5, end >= now { return end }
            }
            return 0
        }
        return engine.bufferedPosition
    }
    public var isPaused: Bool {
        switch engine.state {
        case .paused, .idle, .ended: true
        default: false
        }
    }

    /// 画面显示尺寸（已计像素宽高比）；还不知道时为 .zero
    public var videoSize: CGSize {
        if let size = engine.softwareDisplaySize { return size }
        let width = Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio
        let height = Double(engine.sourceVideoHeight)
        return width > 0 && height > 0 ? CGSize(width: width, height: height) : .zero
    }

    public func readouts() -> Readouts {
        let telemetry = engine.liveTelemetry
        var details: [String] = []
        details.append("通路 \(Self.routeLabel(engine.videoRoute))")
        if let container = engine.sourceContainerFormat { details.append("容器 \(container)") }
        if let decoder = engine.activeVideoDecoder { details.append("视频 \(decoder)") }
        details.append("画面 \(formatLabel)")
        if let decoder = engine.activeAudioDecoder { details.append("音频 \(decoder)") }
        details.append("音频交付 \(Self.deliveryLabel(engine.audioDelivery))")
        var readouts = Readouts(
            route: engine.videoRoute.rawValue,
            sourceBytesFetched: telemetry?.demuxerBytesFetched,
            droppedFrames: telemetry?.droppedFrameCount,
            totalFrames: nil,
            averageBitrateBps: telemetry?.averageBitrateMbps.map { $0 * 1_000_000 },
            videoBitrateBps: engine.sourceVideoBitrate > 0 ? Double(engine.sourceVideoBitrate) : nil,
            details: details
        )
        // 直连服务端 HLS：字节由 AVPlayer 自己取，引擎的计数不涨，读数改从 AVPlayer 的访问日志来
        // （与系统播放器同一口径），加载速度、带宽、掉帧才有数
        if engine.videoRoute == .remoteBypass, let item = engine.currentAVPlayerItem,
           let events = item.accessLog()?.events, !events.isEmpty {
            let fps = item.tracks.compactMap { $0.currentVideoFrameRate > 0 ? Double($0.currentVideoFrameRate) : nil }.first
            let watched = events.reduce(0.0) { $0 + max(0, $1.durationWatched) }
            let indicated = events.last.map(\.indicatedBitrate).flatMap { $0 > 0 ? $0 : nil }
            readouts = Readouts(
                route: readouts.route,
                sourceBytesFetched: events.reduce(0) { $0 + max(0, $1.numberOfBytesTransferred) },
                droppedFrames: events.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) },
                totalFrames: fps.map { Int(watched * $0) },
                averageBitrateBps: readouts.averageBitrateBps,
                videoBitrateBps: indicated ?? readouts.videoBitrateBps,
                details: readouts.details
            )
        }
        return readouts
    }

    /// 规格事实快照（首帧时取一次、变了再取）
    public func deliveryFacts() -> DeliveryFacts {
        let active = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
        let conversion: String? = switch engine.dolbyVisionConversion {
        case .profile7ToProfile81?: "profile7to81"
        case nil: nil
        }
        return DeliveryFacts(
            route: engine.videoRoute.rawValue,
            container: engine.sourceContainerFormat,
            videoCodec: engine.sourceVideoCodecName,
            sourceFormat: Self.formatKey(engine.sourceVideoFormat),
            outputFormat: Self.formatKey(engine.videoFormat),
            dolbyVisionProfile: engine.sourceDVProfile,
            dolbyVisionConversion: conversion,
            audioDelivery: engine.audioDelivery.rawValue,
            audioDecoder: engine.activeAudioDecoder,
            audioCodec: active?.codec,
            audioChannels: active.map(\.channels),
            audioName: active?.name
        )
    }

    private static func formatKey(_ format: VideoFormat) -> String {
        switch format {
        case .sdr: "sdr"
        case .hdr10: "hdr10"
        case .hdr10Plus: "hdr10plus"
        case .dolbyVision: "dolbyvision"
        case .hlg: "hlg"
        }
    }

    private var formatLabel: String {
        var label = switch engine.videoFormat {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .dolbyVision: "杜比视界"
        case .hlg: "HLG"
        }
        if let profile = engine.sourceDVProfile {
            label += " · 片源 DV P\(profile)"
            if engine.dolbyVisionConversion == .profile7ToProfile81 { label += "（已转 8.1）" }
        }
        return label
    }

    private static func routeLabel(_ route: VideoRoute) -> String {
        switch route {
        case .loopback: "本机换封装 → AVPlayer"
        case .software: "本机软解 → 系统显示层"
        case .remoteBypass: "AVPlayer 直连"
        case .audio: "纯音频"
        case .none: "未装载"
        }
    }

    private static func deliveryLabel(_ delivery: AudioDelivery) -> String {
        switch delivery {
        case .streamCopy: "原样拷贝"
        case .bridged: "本机解码后重编"
        case .decoded: "本机解码"
        case .playerManaged: "系统播放器处理"
        case .noAudioInSource: "片源无音轨"
        case .droppedNoPipeline: "无法输出（静音）"
        case .none: "—"
        }
    }

    // MARK: - 轨道

    public var audioTracks: [Track] { engine.audioTracks.map(Self.track) }
    public var subtitleTracks: [Track] { engine.subtitleTracks.map(Self.track) }
    public var activeAudioTrackID: Int? { engine.activeAudioTrackIndex }

    /// 换音轨：引擎在当前位置重载一次（约 0.5～1 秒黑屏）
    public func selectAudioTrack(id: Int) { engine.selectAudioTrack(index: id) }

    public func selectSubtitleTrack(id: Int) { engine.selectSubtitleTrack(index: id) }

    public func clearSubtitle() {
        engine.clearSubtitle()
        subtitleView.cues = []
        refreshSubtitles()
    }

    public func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = seconds
        refreshSubtitles()
    }

    /// 文字字幕的样式（与 App 的字幕设置同一口径：字号、底边距都是画面高度的百分比）
    public struct TextStyle: Sendable, Equatable {
        public var fontScale: Double = 5.2
        public var bottomPercent: Double = 8
        public var background = false

        public init(fontScale: Double = 5.2, bottomPercent: Double = 8, background: Bool = false) {
            self.fontScale = fontScale
            self.bottomPercent = bottomPercent
            self.background = background
        }
    }

    public func setTextStyle(_ style: TextStyle) {
        subtitleView.textStyle = style
        refreshSubtitles()
    }

    private static func track(_ info: TrackInfo) -> Track {
        Track(id: info.id, name: info.name, codec: info.codec, language: info.language, channels: info.channels,
              isExternal: info.isExternal, isDefault: info.isDefault)
    }

    // MARK: - 画中画 / 生命周期

    /// 主力通路上 AVPlayer 的显示层：宿主用它建画中画控制器（软件通路为 nil）
    public var pictureInPictureLayer: AVPlayerLayer? {
        engine.videoRoute == .software ? nil : engine.nativePlayerLayer
    }

    /// 软件通路（VP9 / MPEG-2 / VC-1 / MPEG-4 由 FFmpeg 软解、系统显示层上屏）的画中画：宿主用它建
    /// 「采样缓冲」式画中画控制器。主力通路为 nil（那边用 `pictureInPictureLayer`）
    public var softwarePictureInPicture: SoftwarePictureInPicture? {
        guard engine.videoRoute == .software, let source = engine.softwarePiPSource else { return nil }
        return SoftwarePictureInPicture(source: source)
    }

    /// 软件通路画中画要的全部东西：显示层，加上小窗向播放方要的四个回答（可播范围、是否暂停、播放/暂停、快进快退）。
    /// 时间都在显示层所挂时钟的「源时间轴」上，这是引擎内部知识，所以由引擎回答
    @MainActor
    public struct SoftwarePictureInPicture {
        fileprivate let source: SoftwarePiPSource
        public var layer: AVSampleBufferDisplayLayer { source.layer }
        public func timeRange() -> CMTimeRange { source.timeRange() }
        public var isPaused: Bool { source.isPaused }
        public func setPlaying(_ playing: Bool) { source.setPlaying(playing) }
        public func skip(by seconds: Double) { source.skip(by: seconds) }
    }

    /// 清掉被杀掉的播放会话留在临时目录里的分片与包缓存、整理跨启动保留的片源字节缓存
    /// （每次 App 启动调一次即可，放后台线程）
    public nonisolated static func sweepStaleCaches() {
        AetherEngine.sweepStaleSessionCaches()
    }

    /// 临时目录所在卷「重要用途可用」的字节数（引擎补丁 P44：带 10 秒缓存，引擎的分片留存预算、片源缓存预算用的同一份）
    public nonisolated static func temporaryFreeBytes() -> Int64? {
        AetherEngine.temporaryVolumeAvailableBytes(importantUsage: true)
    }

    /// 片源字节缓存是否跨启动保留（引擎补丁 P42，默认开）。要在建第一个引擎之前设，真机新旧对照用
    public nonisolated static func setPersistsSourceCache(_ on: Bool) {
        AetherEngine.persistsSourceByteCache = on
    }

    /// 片源字节缓存每块另记一段暂存范围（引擎补丁 P50，默认开）。真机新旧对照用
    public nonisolated static func setSourceCacheKeepsSpareRuns(_ on: Bool) {
        AetherEngine.sourceByteCacheKeepsSpareRuns = on
    }

    /// 启动整理跨启动缓存超额时先缩到只剩文件头尾的元数据、缩完仍超才整条删（引擎补丁 P51，默认开）。真机新旧对照用
    public nonisolated static func setSourceCacheTrimKeepsMetadata(_ on: Bool) {
        AetherEngine.sourceByteCacheTrimKeepsMetadata = on
    }

    /// 删掉跨启动保留的片源字节缓存（引擎补丁 P50）：只能在建第一个引擎之前调，真机对照每次热身前清场用
    public nonisolated static func removePersistedSourceCache() {
        AetherEngine.removePersistedSourceByteCache()
    }

    /// 片源字节缓存的记账立刻落盘（引擎补丁 P42）：App 进后台时调，下次启动续播认得最后几秒下过的字节
    public nonisolated static func flushSourceCacheIndexes() {
        AetherEngine.flushSourceByteCacheIndexes()
    }

    /// 画中画进出要告诉引擎：画中画期间 App 进后台，引擎不能拆管线。
    /// 字幕也跟着换人画：画面进了小窗，App 自己的字幕层画不到那里——主力通路上把当前的内封文字字幕
    /// 换成 AVPlayer 自己渲染的原生字幕轨（装载时 `prepareNativeSubtitles` 声明好的），回到全屏再撤掉；
    /// 软件通路由引擎把字幕合成进小窗的画面（引擎在 `pictureInPictureActive` 里自己处理）
    public func setPictureInPictureActive(_ active: Bool) {
        engine.pictureInPictureActive = active
        if engine.videoRoute != .software {
            engine.setNativeSubtitleRendering(active)
        }
        // 画面在小窗里时，App 里原位置只剩系统的「此视频正以画中画播放」占位：自己的字幕层不能还画在上面
        subtitleView.isHidden = active
    }

    public func destroy() {
        destroyed = true
        onPhase = nil
        onFailure = nil
        onTracksChanged = nil
        onFirstFrame = nil
        onStartupStage = nil
        onSeekOutcome = nil
        onSoftwareFrameGeneration = nil
        engine.setSoftwareVideoFrameTimeObserver(nil)
        loadTask?.cancel()
        cancellables.removeAll()
        engine.stop()
        engine.unbind(view: playerView)
    }

    // MARK: - 事件

    private func observe() {
        // 阶段之外还要看传输实况（isBuffering / state）：`.stalled` 只说明源连接在重连，播没播要看传输（见 handle）。
        // @Published 在写入前发出，combineLatest 拿到的是各自的新值
        engine.$playbackPhase.combineLatest(engine.$isBuffering, engine.$state)
            .sink { [weak self] phase, buffering, state in self?.handle(phase, transportStarved: buffering, transport: state) }
            .store(in: &cancellables)
        engine.$audioTracks.combineLatest(engine.$subtitleTracks)
            .dropFirst()
            .sink { [weak self] _ in
                // @Published 在属性真正写入之前发出：等这一轮写完再读
                Task { @MainActor [weak self] in self?.onTracksChanged?() }
            }
            .store(in: &cancellables)
        engine.$hasFirstFrameReadyForDisplay
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.onFirstFrame?() }
            .store(in: &cancellables)
        engine.$startupProgress
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] progress in self?.onStartupStage?(Self.stageName(progress.checkpoint)) }
            .store(in: &cancellables)
        engine.seekEvents
            .sink { [weak self] event in
                let outcome: SeekOutcome? = switch event.outcome {
                case .began: nil
                case .landed: .landed
                case .stalled: .stalled
                case .superseded: .superseded
                case .rejected: .rejected
                }
                guard let outcome else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.onSeekOutcome?(outcome) }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.onSeekOutcome?(outcome) } }
                }
            }
            .store(in: &cancellables)
        engine.$subtitleCues
            .sink { [weak self] cues in
                guard let self else { return }
                subtitleView.cues = cues.compactMap(OverlayCue.init)
                if Self.logsCues {
                    for cue in cues where cue.text != nil {
                        let place = cue.placement.map { "an=\($0.alignment.map(String.init) ?? "-") pos=\($0.position.map { "\(String(format: "%.2f", $0.x)),\(String(format: "%.2f", $0.y))" } ?? "-")" } ?? "无定位"
                        FileHandle.standardError.write(Data("[AetherCue] \(String(format: "%.2f", cue.startTime))-\(String(format: "%.2f", cue.endTime)) \(place) \(cue.text ?? "")\n".utf8))
                    }
                    // 位图字幕（PGS / VobSub / DVB）没有文字：记下有几张图、画布多大，确认它确实上屏了
                    let bitmaps = cues.filter { $0.text == nil }
                    if let first = bitmaps.first {
                        FileHandle.standardError.write(Data("[AetherCue] \(String(format: "%.2f", first.startTime))-\(String(format: "%.2f", first.endTime)) 位图字幕 \(bitmaps.count) 张\n".utf8))
                    }
                }
                refreshSubtitles()
            }
            .store(in: &cancellables)
        // 字幕跟着显示中的画面走（sourceTime 约 10 次 / 秒）
        engine.clock.$sourceTime
            .sink { [weak self] _ in self?.refreshSubtitles() }
            .store(in: &cancellables)
    }

    private func handle(_ phase: PlaybackPhase, transportStarved: Bool, transport: PlaybackState) {
        guard !destroyed else { return }
        switch phase {
        case .idle:
            return
        case .loading, .seeking, .rebuffering:
            emit(lastPhase == nil ? .loading : .buffering)
        case .stalled:
            // 源连接断了、读取端在重连（或重连次数用完、等生产端重开）。本地已经切好的分片还够播时画面照常在走，
            // 这时报缓冲会让转圈一直盖着正在播的画面（2026-09-27 真机断流演练：服务端停机 21 秒，播放头一秒没停，
            // 转圈转了 21 秒）。只有传输真的吃光了缓冲、或还在起播 / 定位时才报缓冲，其余照传输实况报播放 / 暂停；
            // 缓冲吃光后迟迟不恢复，由控制器的卡顿看门狗判「断粮」原地重开
            if lastPhase == nil || transportStarved || transport == .loading || transport == .seeking {
                emit(lastPhase == nil ? .loading : .buffering)
            } else {
                emit(transport == .paused ? .paused : .playing)
            }
        case .playing:
            emit(.playing)
        case .paused:
            emit(.paused)
        case .ended:
            emit(.ended)
        case let .error(message):
            let info = engine.errorInfo
            let category = Self.category(of: info)
            #if DEBUG
            // 故障注入测试据此核对引擎把失败归成了哪一类
            print("[AetherFailure] kind=\(info?.kind.rawValue ?? "unknown") domain=\(info?.underlyingDomain ?? "-") "
                  + "code=\(info?.underlyingCode.map(String.init) ?? "-") category=\(category) message=\(message)")
            #endif
            report(Failure(message: message, kind: info?.kind.rawValue ?? "unknown", category: category))
        }
    }

    private func emit(_ phase: Phase) {
        guard phase != lastPhase else { return }
        lastPhase = phase
        onPhase?(phase)
    }

    private func report(_ failure: Failure) {
        onFailure?(failure)
    }

    /// 引擎错误 → 归因。引擎在起播那一刻遇到断线、超时，只知道「打不开」（sourceOpenFailed），分不出是网络
    /// 还是格式不认——这一类归成「确定解不了」，由宿主先探一下片源取不取得到再定（取不到就是网络问题）
    static func category(of info: PlaybackErrorInfo?) -> FailureCategory {
        guard let info else { return .decode(final: false) }
        switch info.kind {
        case .storageExhausted:
            return .storageFull
        case .sourceRefused:
            // 令牌过期（401 / 403）、服务端 5xx：换张新令牌原地重开；404 是文件不在了
            return info.underlyingCode == 404 ? .sourceMissing : .network
        case .sourceRateLimited, .sourceCertificateRejected:
            return .network
        case .vodSourceFailed:
            // 带 -22（EINVAL）是「源音频封装不进 fMP4」，不是断线；可能是一时的（例如存储刚写满），先重开一次
            return info.underlyingCode == -22 ? .decode(final: false) : .network
        case .dolbyVisionRequiresHardware, .sourceOpenFailed, .customSourceProbeFailed:
            return .decode(final: true)
        case .nativeItemFailed:
            // AVPlayer 的解码判决：硬件解不了且引擎已试过本机软解（补丁 P24）也接不住，重开一样
            return isDecodeVerdict(domain: info.underlyingDomain, code: info.underlyingCode)
                ? .decode(final: true) : .decode(final: false)
        default:
            return .decode(final: false)
        }
    }

    private static func isDecodeVerdict(domain: String?, code: Int?) -> Bool {
        guard let domain, let code else { return false }
        switch domain {
        case AVFoundationErrorDomain: return [-11833, -11821].contains(code)   // 找不到解码器、解码失败
        case "CoreMediaErrorDomain": return [-12906, -12909, -11833].contains(code)
        default: return false
        }
    }

    // MARK: - 测试钩子（故障注入）

    /// 假装临时目录只剩这么多字节（nil = 读真实值），复现「手机存储快满」（内置引擎补丁 P25）
    public static func setTestVolumeAvailableBytes(_ bytes: Int64?) {
        AetherEngine.volumeAvailableBytesOverrideForTesting = bytes
    }

    /// 接下来这么多秒里写分片一律按「存储已满」失败，复现「播放中存储被写满」
    public static func simulateStorageFull(forSeconds seconds: Double) {
        AetherEngine.simulateStorageFullUntilUptimeForTesting = ProcessInfo.processInfo.systemUptime + seconds
    }

    // MARK: - 字幕

    private func refreshSubtitles() {
        guard !subtitleView.cues.isEmpty || subtitleView.hasVisibleCues else { return }
        subtitleView.update(time: subtitleClock - subtitleDelay, videoRect: videoRect())
    }

    /// 字幕对的是哪根时间轴：内封字幕的时间是容器的源时间轴（TS / 蓝光的 PTS 从几百几千秒起），
    /// 外挂字幕文件的时间从 0 起、对的是片内时间。TS 录像实测源时间轴从 19123 秒起，
    /// 外挂字幕按源时钟比永远对不上、一条都不出
    private var subtitleClock: Double {
        if let active = engine.activeSubtitleTrackIndex,
           engine.subtitleTracks.contains(where: { $0.id == active && $0.isExternal }) {
            return engine.currentTime
        }
        return engine.sourceTime
    }

    /// 画面在容器里的矩形：主力通路直接问 AVPlayerLayer，软件通路按显示尺寸 aspect-fit
    private func videoRect() -> CGRect {
        let bounds = view.bounds
        if engine.videoRoute != .software, let layer = engine.nativePlayerLayer {
            let rect = layer.videoRect
            if rect.width > 1, rect.height > 1 {
                #if canImport(UIKit)
                return view.layer.convert(rect, from: layer)
                #else
                if let host = view.layer { return host.convert(rect, from: layer) }
                #endif
            }
        }
        let size = videoSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}

/// 播放容器：底下是引擎的画面视图，上面叠字幕层，两者都铺满
extension AetherPlayback {
    /// 起播检查点的名字（与引擎 `StartupCheckpoint` 一一对应）
    static func stageName(_ checkpoint: StartupCheckpoint) -> String {
        switch checkpoint {
        case .dispatched: "dispatched"
        case .sourceOpened: "sourceOpened"
        case .containerOpened: "containerOpened"
        case .streamsProbed: "streamsProbed"
        case .displayPrepared: "displayPrepared"
        case .routed: "routed"
        case .sessionConstructed: "sessionConstructed"
        case .ready: "ready"
        case .presenting: "presenting"
        }
    }
}

/// 软件通路逐帧回调里的计数（解码线程写、主线程读）：帧数，以及当前的显示代数
nonisolated private final class SoftwareFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var generation: UInt64?

    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }

    /// 记一帧；这一帧开启了新的一代（跳转或装载后的第一帧）时返回 true
    func record(generation new: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        guard new != generation else { return false }
        generation = new
        return true
    }
}

/// 引擎日志的环形缓冲：最近 300 行，每行最多 400 字（任意线程写）
nonisolated private final class EngineLogRing: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 300

    func append(_ line: String) {
        let trimmed = line.count > 400 ? String(line.prefix(400)) + "…" : line
        lock.lock(); defer { lock.unlock() }
        lines.append(trimmed)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    /// 从最新往回取，直到 `maxBytes`，再按时间正序拼起来
    func snapshot(maxBytes: Int) -> String {
        lock.lock(); let copy = lines; lock.unlock()
        var picked: [String] = []
        var size = 0
        for line in copy.reversed() {
            size += line.utf8.count + 1
            if size > maxBytes { break }
            picked.append(line)
        }
        return picked.reversed().joined(separator: "\n")
    }
}

/// 逐帧回调（@Sendable、跨线程）里要回到宿主时用的弱引用
nonisolated private final class WeakPlayback: @unchecked Sendable {
    weak var value: AetherPlayback?
    init(_ value: AetherPlayback) { self.value = value }
}

private final class PlaybackContainerView: AetherPlatformView {
    var onLayout: (() -> Void)?

    init(playerView: AetherPlatformView, subtitleView: AetherPlatformView) {
        super.init(frame: .zero)
        #if canImport(UIKit)
        backgroundColor = .black
        for child in [playerView, subtitleView] {
            child.frame = bounds
            child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(child)
        }
        subtitleView.isUserInteractionEnabled = false
        #else
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for child in [playerView, subtitleView] {
            child.frame = bounds
            child.autoresizingMask = [.width, .height]
            addSubview(child)
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
    #else
    // 与 UIKit 一致用左上角为原点：字幕的摆放全按「y 从上往下」算
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
    #endif
}

/// 一条要画的字幕：图形字幕是位图 + 位置，文字字幕是纯文本（ASS 样式先按纯文本画，字号、位置、背景随用户设置）
struct OverlayCue {
    enum Content {
        /// 位图、在字幕画布里的位置（0～1）、画布像素尺寸（.zero = 与画面相同）
        case image(CGImage, position: CGRect, canvas: CGSize)
        /// 文字与 ASS 指定的位置：alignment 是 `\an` 小键盘方位（1 左下 … 9 右上），anchor 是 `\pos`（0～1，y 从上往下）
        case text(String, alignment: Int?, anchor: CGPoint?)
    }

    let id: Int
    let start: Double
    let end: Double
    let content: Content

    init?(_ cue: SubtitleCue) {
        id = cue.id
        start = cue.startTime
        end = cue.endTime
        switch cue.body {
        case let .image(image):
            content = .image(image.cgImage, position: image.position, canvas: image.canvasSize)
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            content = .text(trimmed, alignment: cue.placement?.alignment, anchor: cue.placement?.position)
        case let .richText(runs):
            let trimmed = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            content = .text(trimmed, alignment: cue.placement?.alignment, anchor: cue.placement?.position)
        }
    }
}

/// 字幕层：按当前时间挑出该显示的字幕，摆到画面矩形里。
///
/// - 图形字幕：位置是相对字幕画布的 0～1 坐标；画布与画面宽度对齐、垂直居中——裁过黑边的片子画布比画面高，
///   这样字幕仍落在原盘作者放的位置（包括下黑边里）。
/// - 文字字幕：与 App 的 SwiftUI 叠加层（SubtitleOverlay）同一口径——字号是画面高度的百分比、
///   位置是距画面底边的百分比，白字带柔和投影或半透明底框，横竖屏切换都不影响字幕相对画面的样子。
///   ASS 用 `\pos` 指定了位置的（招牌、注释、竖排说明这类特效字）画在它指定的位置，`\an7～9` 的画在顶部，
///   其余对白合成一块放在底部——不然特效字会叠进对白里（真机《如果历史是一群喵》实测）。
final class SubtitleLayerView: AetherPlatformView {
    var cues: [OverlayCue] = []
    var textStyle = AetherPlayback.TextStyle()
    private var imageLayers: [Int: CALayer] = [:]
    private let bottomBlock = TextBlockView()
    private let topBlock = TextBlockView()
    private var anchoredBlocks: [Int: TextBlockView] = [:]

    var hasVisibleCues: Bool { !imageLayers.isEmpty || !bottomBlock.isHidden || !topBlock.isHidden || !anchoredBlocks.isEmpty }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if !canImport(UIKit)
        wantsLayer = true
        #endif
        addSubview(bottomBlock)
        addSubview(topBlock)
    }

    #if !canImport(UIKit)
    override var isFlipped: Bool { true }
    /// 字幕层不接鼠标（同 UIKit 的 isUserInteractionEnabled = false）：点击、悬停都落到下面的播放器控制层
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 开发期（-mcAetherCues YES）：上一次记下的上屏字幕，变了才记一笔
    private var loggedActiveIDs: [Int] = []

    func update(time: Double, videoRect: CGRect) {
        let active = cues.filter { $0.start <= time && time < $0.end }
        if AetherPlayback.logsCues, active.map(\.id) != loggedActiveIDs {
            // 真机无人值守验证时确认字幕确实画上了屏（[AetherCue] 只说明拿到了字幕）
            loggedActiveIDs = active.map(\.id)
            let shown = active.isEmpty ? "清空" : active.map { cue -> String in
                if case let .text(text, _, _) = cue.content { return "「\(text.prefix(24))」" }
                return "位图"
            }.joined(separator: " ")
            FileHandle.standardError.write(Data("[AetherShow] \(String(format: "%.2f", time)) \(shown)\n".utf8))
        }
        updateImages(active, videoRect: videoRect)
        var bottom: [String] = [], top: [String] = []
        var anchored: [(id: Int, text: String, alignment: Int, anchor: CGPoint)] = []
        for cue in active {
            guard case let .text(text, alignment, anchor) = cue.content else { continue }
            if let anchor, anchor.x.isFinite, anchor.y.isFinite {
                anchored.append((cue.id, text, alignment ?? 2, anchor))
            } else if let alignment, (7 ... 9).contains(alignment) {
                top.append(text)
            } else {
                bottom.append(text)
            }
        }
        guard videoRect.width > 0, videoRect.height > 0 else {
            bottomBlock.isHidden = true
            topBlock.isHidden = true
            anchoredBlocks.values.forEach { $0.removeFromSuperview() }
            anchoredBlocks = [:]
            return
        }
        let fontSize = max(12, videoRect.height * textStyle.fontScale / 100)
        let margin = videoRect.height * textStyle.bottomPercent / 100 + fontSize
        // 与 SwiftUI 叠加层一致：底部块的中心在「画面底边往上 bottomPercent，再上移一个字号」处
        bottomBlock.show(Array(bottom.prefix(3)).joined(separator: "\n"), style: textStyle, fontSize: fontSize,
                         maxWidth: videoRect.width * 0.9, anchor: CGPoint(x: videoRect.midX, y: videoRect.maxY - margin), alignment: 5)
        topBlock.show(Array(top.prefix(3)).joined(separator: "\n"), style: textStyle, fontSize: fontSize,
                      maxWidth: videoRect.width * 0.9, anchor: CGPoint(x: videoRect.midX, y: videoRect.minY + margin), alignment: 5)
        let anchoredIDs = Set(anchored.map(\.id))
        for (id, block) in anchoredBlocks where !anchoredIDs.contains(id) {
            block.removeFromSuperview()
            anchoredBlocks[id] = nil
        }
        for cue in anchored {
            let block = anchoredBlocks[cue.id] ?? {
                let created = TextBlockView()
                addSubview(created)
                anchoredBlocks[cue.id] = created
                return created
            }()
            // 特效字比对白小一号：它们多是画面上的注释，不该和对白抢
            let point = CGPoint(x: videoRect.minX + min(max(cue.anchor.x, 0), 1) * videoRect.width,
                                y: videoRect.minY + min(max(cue.anchor.y, 0), 1) * videoRect.height)
            block.show(cue.text, style: textStyle, fontSize: fontSize * 0.8, maxWidth: videoRect.width * 0.6,
                       anchor: point, alignment: cue.alignment)
        }
    }

    private func updateImages(_ active: [OverlayCue], videoRect: CGRect) {
        let activeIDs = Set(active.compactMap { cue -> Int? in
            if case .image = cue.content { return cue.id }
            return nil
        })
        for (id, layer) in imageLayers where !activeIDs.contains(id) {
            layer.removeFromSuperlayer()
            imageLayers[id] = nil
        }
        guard videoRect.width > 0, videoRect.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cue in active {
            guard case let .image(image, position, canvas) = cue.content else { continue }
            let layer: CALayer
            if let existing = imageLayers[cue.id] {
                layer = existing
            } else {
                layer = CALayer()
                layer.contents = image
                layer.contentsGravity = .resize
                layer.magnificationFilter = .linear
                #if canImport(UIKit)
                self.layer.addSublayer(layer)
                #else
                self.layer?.addSublayer(layer)
                #endif
                imageLayers[cue.id] = layer
            }
            layer.frame = Self.frame(position: position, canvas: canvas, in: videoRect)
        }
        CATransaction.commit()
    }

    static func frame(position: CGRect, canvas: CGSize, in videoRect: CGRect) -> CGRect {
        var rect = videoRect
        if canvas.width > 0, canvas.height > 0 {
            let height = videoRect.width * canvas.height / canvas.width
            rect = CGRect(x: videoRect.minX, y: videoRect.midY - height / 2, width: videoRect.width, height: height)
        }
        return CGRect(
            x: rect.minX + position.minX * rect.width,
            y: rect.minY + position.minY * rect.height,
            width: position.width * rect.width,
            height: position.height * rect.height
        )
    }
}

/// 一块字幕文字：白字（柔和投影或半透明底框），按 ASS 小键盘方位把自己对齐到锚点（5 = 锚点在中心）。
/// 文字、样式、位置都没变时不重排（字幕层约每秒刷新 10 次）
final class TextBlockView: AetherPlatformView {
    #if canImport(UIKit)
    private let label = UILabel()
    #else
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
    private var last: (String, AetherPlayback.TextStyle, CGFloat, CGFloat, CGPoint, Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous
        label.numberOfLines = 0
        #else
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.drawsBackground = false
        label.isBezeled = false
        label.alignment = .center
        #endif
        #if canImport(UIKit)
        label.textAlignment = .center
        #endif
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, style: AetherPlayback.TextStyle, fontSize: CGFloat, maxWidth: CGFloat, anchor: CGPoint, alignment: Int) {
        guard !text.isEmpty else {
            isHidden = true
            last = nil
            return
        }
        if let last, last.0 == text, last.1 == style, last.2 == fontSize, last.3 == maxWidth, last.4 == anchor, last.5 == alignment { return }
        last = (text, style, fontSize, maxWidth, anchor, alignment)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = fontSize * 0.1
        var attributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: PlatformColor.white,
            .paragraphStyle: paragraph,
        ]
        if !style.background {
            // 不开背景时靠一层柔和投影压住亮画面。不用文字描边（strokeWidth）：中文字形由互相重叠的
            // 笔画轮廓拼成，描边沿每个轮廓各描一圈，笔画交叉处全是黑缝（真机实测）
            let shadow = NSShadow()
            shadow.shadowColor = PlatformColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        }
        let padH = style.background ? fontSize * 0.35 : 0
        let padV = style.background ? fontSize * 0.12 : 0
        #if canImport(UIKit)
        label.attributedText = NSAttributedString(string: text, attributes: attributes)
        let fitted = label.sizeThatFits(CGSize(width: maxWidth - padH * 2, height: .greatestFiniteMagnitude))
        #else
        label.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        label.preferredMaxLayoutWidth = maxWidth - padH * 2
        let fitted = label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: maxWidth - padH * 2, height: .greatestFiniteMagnitude)) ?? .zero
        #endif
        let size = CGSize(width: min(maxWidth, ceil(fitted.width) + padH * 2), height: ceil(fitted.height) + padV * 2)
        // 小键盘方位：列 1/4/7 左、2/5/8 中、3/6/9 右；行 1-3 底、4-6 中、7-9 顶
        let column = (alignment - 1) % 3, row = (alignment - 1) / 3
        let x = anchor.x - size.width * [0, 0.5, 1][max(0, min(2, column))]
        let y = anchor.y - size.height * [1, 0.5, 0][max(0, min(2, row))]
        frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        label.frame = bounds.insetBy(dx: padH, dy: padV)
        #if canImport(UIKit)
        backgroundColor = style.background ? UIColor.black.withAlphaComponent(0.6) : .clear
        layer.cornerRadius = style.background ? fontSize * 0.2 : 0
        #else
        layer?.backgroundColor = style.background ? NSColor.black.withAlphaComponent(0.6).cgColor : NSColor.clear.cgColor
        layer?.cornerRadius = style.background ? fontSize * 0.2 : 0
        #endif
        isHidden = false
    }
}
