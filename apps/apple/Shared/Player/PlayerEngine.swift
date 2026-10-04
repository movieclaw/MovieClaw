import SwiftUI

/// 实际在跑的播放引擎。
enum EngineKind: String {
    /// 系统播放器：放服务端流（用户限了画质、或自研引擎在本机解不了时）
    case avPlayer = "avplayer"
    /// 自研引擎（AetherEngine）：直读原文件，本机换封装成 HLS 交给 AVPlayer（杜比视界、全景声、画中画都由系统完成），
    /// 硬解不了的编码由引擎自己软解
    case native

    var label: String {
        switch self {
        case .avPlayer: "系统播放器（AVPlayer）"
        case .native: "自研引擎（AetherEngine）"
        }
    }
}

/// 引擎失败的归因：网络问题只原地重开，解不了才换引擎 / 降档（规则见 `FailurePolicy`）。
/// 线路慢不是失败，看门狗不报（见 `StallWatch`）。
enum EngineFailureCause: Equatable {
    /// 解不了，但可能是一时的：引擎楞住、有数据却不出画、持续掉帧、中途出错——自研引擎先原位重开一次，
    /// 再失败才改走服务端流（`FailurePolicy`）
    case decode
    /// 确定解不了：硬件解码器拒绝且本机软解也接不住、片源格式本机不认——重开也一样，直接改走服务端流
    case decodeFinal
    /// 取流失败（断线、超时、token 过期、服务端中断）：这一档没毛病，等片源取得到了原地重开，不换播放器、不降档
    case network
    /// 片源不在了（服务端对原文件回 404）：换什么播放器都一样，直接说明
    case sourceMissing
    /// 手机存储写满、切好的分片写不进去：收小缓冲原位重开（内置引擎补丁 P25）
    case storageFull
}

/// 引擎 → 控制器的事件。时间类读数不走事件，由控制器按需读 `currentTime` 等属性。
enum EngineEvent {
    /// 开始出画 / 恢复播放
    case playing
    case paused
    /// 缓冲中（起播、seek 后、缺粮）
    case buffering
    case ended
    case failed(reason: String, cause: EngineFailureCause)
    /// 画中画进出
    case pictureInPicture(Bool)
    /// 引擎读到的轨道列表出来了 / 变了（只有自研引擎报：服务端看不到的轨由它补进菜单，见 `PlaybackController.adoptEngineTracks`）
    case tracksChanged
    /// 起播里程碑（只用于分段计时，见 `StartupTrace`）。自研引擎每次出首帧都报 `.firstFrame`（换音轨、
    /// 回前台重建之后也会再报一次），播放记录据此结束「换轨 / 回前台」的计时
    case milestone(EngineMilestone)
    /// 引擎内部的起播检查点（自研引擎：打开片源、识别容器、探测轨道……，见 `AetherPlayback.onStartupStage`）
    case startupStage(String)
    /// 跳转后落点的画面到了（自研引擎报；主力通路是 AVPlayer 在落点恢复播放 / 暂停中跳转完成，
    /// 软件通路是落点那一帧交到显示层）。播放记录的跳转耗时以它为终点（docs/design/playback-qoe.md §1.3）
    case seekPresented
    /// 跳转超时没落地 / 被拒
    case seekFailed
}

/// 引擎内部的起播里程碑：控制器只看得到「开始播放」，慢在引擎哪一步要靠这几个点区分
enum EngineMilestone: String {
    /// 拿到了能开始定位与解码的东西：AVPlayer 的 readyToPlay（文件头 / 播放列表已读）
    case ready
    /// 起播点定位完成（续播 seek 落地）
    case seeked
    /// 第一帧上屏：AVPlayerLayer 的 isReadyForDisplay
    case firstFrame
}

/// 引擎的实时读数（诊断面板「传输」与遥测用）
struct EngineStats {
    var engine: String
    /// 带宽（bps，传输期速率，口径见 `BandwidthMeter`）：线路能跑多快，缓冲满了停下来也保持最近一次实测值。
    /// 给服务端 downlink_bps 与诊断面板「带宽」用；样本不够时为 nil
    var downlinkBps: Double?
    /// 此刻的加载速度（bps，墙钟速率：最近一两秒实际收到的字节 ÷ 时长）。在下载就是实际下载速度，没在下载就是 0；
    /// 引擎还给不出读数时为 nil。顶栏与转圈下方那行「↓」只用它（口径见 `LoadingSpeedMeter`）
    var loadingBps: Double?
    /// 当前流的码率（bps）
    var bitrateBps: Double?
    var droppedFrames: Int?
    var totalFrames: Int?
    var bufferedSeconds: Double
    var currentTimeSeconds: Double
    /// 额外的引擎细节行（解码器、渲染方式等）
    var details: [String] = []
}

/// 实时加载速度计（系统播放器用；自研引擎对它从 NAS 累计拉到的字节做差分，同一口径）。
///
/// 口径（2026-09-27 用户定）：播放器上那行「↓」只报网络此刻在加载多快——在下载就是实际下载速度，
/// 没在下载（缓冲满了、暂停后缓冲够了）就是 0。这是下载器与国内视频 App「网速」的常规口径；
/// Web 同口径（`lib/player/bandwidth.ts` 的 LOADING_WINDOW_MS，两端 2026-09-27 一起从「带宽」改过来）。
///
/// 算法：对 AVPlayer 访问日志里累计收到的字节数（numberOfBytesTransferred 求和）做差分，窗口 2 秒。
/// - 为什么是 2 秒不是 1 秒：这个计数不是逐包更新，HLS 下会攒一会儿再一次记上几百 KB～1MB，
///   1 秒窗口会把这一坨算进同一秒，读数忽高忽低。本机限速实验（1MB/s、6 秒分片）对照服务器实际传输：
///   原始计数用 1 秒窗口平均误差 0.20MB/s，2 秒窗口 0.10MB/s；换成本类接真引擎端到端复测，
///   HLS 平均误差 0.02MB/s、原文件直出 0.03MB/s，真实空闲的每一秒都读 0。
/// - 起播第一坨：访问日志等第一片下完才建条目，第一片的字节是一次性出现的。这一次用日志里的传输时长当分母
///   （正好是这坨字节在路上花的时间），否则会报出两倍速度；之后不能再用它——HLS 的传输时长按整片结算，
///   字节却是实时涨的，两者对不上。
/// - 日志还没建（第一片没下完）时给 nil、不显示：这时其实在下，报 0 是错的。
struct LoadingSpeedMeter {
    static let window: TimeInterval = 2
    private var samples: [(at: TimeInterval, bytes: Int64)] = []
    private(set) var bps: Double?

    mutating func reset() {
        samples = []
        bps = nil
    }

    /// 记一个采样点（调用方每秒至少一次，诊断面板开着时会更密），返回最新读数（bps）。
    /// - bytes: 累计收到的字节；访问日志还没建时传 nil
    /// - transferSeconds: 累计传输时长（只用于起播第一坨）
    /// - now: 单调时钟（systemUptime），不用墙钟以免对时跳变
    mutating func sample(bytes: Int64?, transferSeconds: Double, at now: TimeInterval) -> Double? {
        guard let bytes else {
            reset()
            return nil
        }
        // 计数倒退只会是换了播放项：从头量
        if let last = samples.last, bytes < last.bytes { samples = [] }
        if samples.isEmpty {
            samples = [(now, bytes)]
            bps = bytes > 0 && transferSeconds > 0 ? Double(bytes) * 8 / transferSeconds : nil
            return bps
        }
        samples.append((now, bytes))
        // 窗口起点：至少早 2 秒的最后一个采样点（留 0.25 秒给计时抖动）；起播不满 2 秒时用最早的点，但至少隔 0.9 秒
        let cutoff = now - Self.window + 0.25
        let refIndex = samples.lastIndex { $0.at <= cutoff } ?? (now - samples[0].at >= 0.9 ? 0 : nil)
        guard let refIndex else { return bps }
        let ref = samples[refIndex]
        samples.removeFirst(refIndex)
        bps = Double(bytes - ref.bytes) * 8 / (now - ref.at)
        return bps
    }
}

/// 带宽估计：线路能跑多快——最近 12 秒（至少最近 3 次传输）里**最快的一次传输**的速度（字节 ÷ 这次传输真正花的时间）；
/// 缓冲满了停下来不取时照样保持最近的实测值。窗口与门槛同 Web `lib/player/bandwidth.ts`。
///
/// 「至少 3 次」是给转码会话留的：服务端要等 ffmpeg 追上来，分片隔 6～14 秒才到一片，12 秒窗口里常常只剩一片；
/// 偏偏那一片又被播放器读慢了（实测 14 秒才读完 1.6MB），带宽就会掉到 0.11MB/s。连续下载时每秒一个样本，照旧是 12 秒。
///
/// 它和顶栏的实时加载速度（`LoadingSpeedMeter`）是两回事：加载速度回答「此刻在下多快」（没在下就是 0），
/// 带宽回答「线路能跑多快」。带宽不能比加载速度小——那就是两个数打架。
///
/// 为什么取最快一次而不是平均（Web 取平均）：AVPlayer 会时不时自己放慢读取（边解码边渲染时尤其明显），
/// TCP 就把服务端也压慢，那一片的传输速度被拖到线路的三成到五成。本机限速实验（1MB/s）里同一次播放的分片
/// 速度在 0.29～0.99MB/s 之间跳，按平均算带宽只有 0.47～0.86，还会比加载速度小。慢的那几片慢在播放器自己，
/// 不在线路；每一片的计时取自网络层，快的那几片不会超过真实线路。浏览器收分片不会这样放慢，Web 的平均就接近线路。
///
/// 样本来源（见各引擎）：
/// - AVPlayer 放 HLS：AVMetrics 的分片请求事件，逐片「首字节到达 → 末字节到达」，服务端等转码的那几秒落在
///   首字节之前、天然不算进去（同 Web 的 Resource Timing）；读自缓存的分片丢掉。
/// - AVPlayer 放原文件、自研引擎：没有逐请求计时，样本就是每秒一个的加载速度读数，带宽即最近 12 秒的最高加载速度——
///   这样带宽天然不会比顶栏的加载速度小。下载开头结尾那个读数窗口只下了一部分，读数偏低，取最高值时不受影响。
///   不直接拿相邻两次读取的字节差：AVPlayer 的计数一格 128～256KB，0.5 秒的区间一取最高就虚高四成；
///   加载速度本身是 2 秒窗口，平滑得多。
///   访问日志的 observedBitrate 是整段播放的平均，同样会被慢读拖低（实测掉到 0.56，此后加载速度一回升就比它大），
///   只在起播头几秒还没有样本时顶一下。
///
/// 本机限速实验（1MB/s，真引擎端到端）：HLS 0.98～1.01MB/s；原文件 AVPlayer 0.95～1.14；
/// 服务端每片先挂 3 秒（模拟等转码）时，加载速度照实掉下来，带宽仍贴着线路。
struct BandwidthMeter {
    static let window: TimeInterval = 12
    /// 窗口外的样本也至少留这么多个（见上）
    static let minSamples = 3
    /// 一次传输至少这么多字节才算数：init 分片才几 KB，单靠它算出来的速度是噪声
    static let minBytes: Double = 64 * 1024
    /// 一次传输至少这么久才算数（给计时精度留的余量）
    static let minTransfer: TimeInterval = 0.02
    private var samples: [(at: TimeInterval, bps: Double)] = []

    mutating func reset() {
        samples = []
    }

    /// 记一次传输（HLS 分片）：bytes 字节在路上花了 transfer 秒。太小太短的不收
    mutating func push(bytes: Double, transfer: TimeInterval, at now: TimeInterval) {
        guard bytes >= Self.minBytes, transfer >= Self.minTransfer else { return }
        push(bps: bytes * 8 / transfer, at: now)
    }

    /// 记一个加载速度读数（原文件、自研引擎）。只在新样本到来时淘汰旧样本——停下来不取时读数保持不变
    mutating func push(bps: Double, at now: TimeInterval) {
        guard bps > 0, bps.isFinite else { return }
        samples.append((now, bps))
        while samples.count > Self.minSamples, let oldest = samples.first, oldest.at <= now - Self.window {
            samples.removeFirst()
        }
    }

    /// 窗口内最快一次传输的速度（bps）；还没有像样的样本时为 nil——宁可不显示也不显示错的
    var bps: Double? {
        samples.map(\.bps).max()
    }
}

/// 播放引擎抽象（Swiftfin 式多引擎，docs/design/ios-app.md §4）。
///
/// 控制器只和这层打交道：会话协议、降档、进度上报与引擎无关；
/// 引擎只管「把这个地址放出来」并如实报告状态。时间一律是**流时间**（秒），
/// 与文件时间的换算（会话时间轴起点）由控制器负责。
@MainActor
protocol PlayerEngine: AnyObject {
    var kind: EngineKind { get }
    /// 渲染表面（铺满播放区域）
    var view: NativeView { get }
    var onEvent: ((EngineEvent) -> Void)? { get set }

    /// 装载并（按需）起播；start 为流时间秒数
    func load(url: URL, start: Double, autoplay: Bool)
    func play()
    func pause()
    /// exact：精确定位（拖进度条松手）；否则允许按关键帧（±10 秒这类高频操作更快）
    func seek(to seconds: Double, exact: Bool)
    func setRate(_ rate: Float)

    var currentTime: Double { get }
    var duration: Double? { get }
    /// 已缓冲到的流时间
    var bufferedEnd: Double? { get }
    var isPaused: Bool { get }
    var videoSize: CGSize { get }
    func stats() -> EngineStats

    /// 能否原地换音轨（自研引擎直出原文件时可以；服务端流下要重开会话）
    var canSwitchAudioInPlace: Bool { get }
    func selectAudio(embeddedIndex: Int)
    /// 起播时的音轨：explicit = 用户这次选过、或服务端记着用户上次选的轨；否则只是服务端的默认挑选
    func selectInitialAudio(embeddedIndex: Int, explicit: Bool)

    /// 这类字幕（kind：vtt / ass / pgs）由引擎自己画；否则由 SwiftUI 叠加层用系统字体画
    func rendersSubtitle(kind: String) -> Bool
    /// 这条轨由引擎自己画吗（默认按类型判断；自研引擎的内封轨一律自己画，见 NativeEngine）
    func rendersSubtitle(_ option: SubtitleOption) -> Bool
    /// 选字幕：embeddedIndex 非空且直出原文件时直接选内封轨，否则挂服务端地址
    func selectSubtitle(_ option: SubtitleOption?, url: URL?)
    func applySubtitleStyle(_ style: SubtitleStyle)

    var supportsPictureInPicture: Bool { get }
    var isPictureInPictureActive: Bool { get }
    func togglePictureInPicture()

    /// App 前后台切换（后台只留声音）
    func setBackgrounded(_ background: Bool)
    /// 暂停下载 / 恢复：计费网络（蜂窝、个人热点、低数据模式）上用户按了暂停时控制器调，恢复播放时各引擎自己解除
    func setPrefetchSuspended(_ suspended: Bool)
    func destroy()
}

extension PlayerEngine {
    func selectInitialAudio(embeddedIndex: Int, explicit: Bool) { selectAudio(embeddedIndex: embeddedIndex) }
    func rendersSubtitle(_ option: SubtitleOption) -> Bool { rendersSubtitle(kind: option.kind) }
}
