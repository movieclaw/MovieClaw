import Foundation
import Network

/// 播放失败之后下一步做什么（docs/design/player-engine.md §3「兜底阶梯」）。纯函数，每条规则一行表驱动单测
/// （MovieClawTests/PlaybackRoutingTests）。
///
/// 四条铁律（2026-09-28 用户拍板：自研引擎要解决所有问题，力保不降级）：
///
/// 1. **自研引擎解决本机能解决的一切，没有别的本机播放器兜底。**硬解不了的编码由引擎自己在本机软解（软件通路，
///    引擎补丁 P24 补上了「找不到解码器」也转软解），不再有 MPV（已整个移除，见设计文档 §3）。
/// 2. **网络问题不换引擎、不降码率。**线路慢只是缓冲：看门狗根本不报失败（见 `StallWatch`），转圈下显示实时
///    加载速度，用户可以暂停攒缓冲，要不要换低画质由用户决定（`QualitySuggestion` 只在反复卡顿时提示一次）。
///    连接断了（取流报错、缓冲见底且持续没有字节）就等片源取得到了同引擎、同片源原地重开（新会话、新取流令牌）；
///    一直取不到落错误页让用户重试——换转码要一样的线路，还要用户同意画质变差。
///    引擎在起播那一刻遇到断线只知道「打不开」，控制器先探一下片源（`SourceProbe`）再归因，不当成解不了。
/// 3. **不是「解不了」的失败都不换播放器**：片源不在了（404）直接说明；手机存储写满就收小缓冲原位重开
///    （引擎补丁 P25）；一时的问题（引擎楞住、中途出错、持续掉帧）先原位重开一次（`NativeRetryBudget`）。
/// 4. **只有确定「本机解不了」才改走服务端流**：自研引擎（硬解 → 引擎自己软解 → 原位重开一次）→ 服务端 HLS
///    交给系统播放器 → 逐级降档 → 报错。用户自己限了画质时服务端压码率，转出的 HLS 仍由自研引擎直连放（不经过这里）。
enum FailurePolicy {
    struct Input: Equatable {
        var engine: EngineKind
        var cause: EngineFailureCause
        /// 在直出原文件（没有服务端会话流）
        var playsOriginalFile: Bool
        /// 连接类失败还能同档重开（`NetworkRestartBudget` 没用完）
        var restartAllowed: Bool
        /// 自研引擎还能先原位重开一次（`NativeRetryBudget`）
        var nativeRetryAllowed = false
    }

    enum Response: Equatable {
        /// 同引擎、同片源原地重开（新会话 = 新取流令牌）；原文件直出时先等片源取得到
        case reconnect
        /// 自研引擎一时出了问题：同引擎原位重开（新会话、新引擎实例），不换播放器
        case retryNative
        /// 手机存储写满：收小缓冲窗口、关掉片源字节缓存，原位重开
        case retryNativeLowStorage
        /// 原文件直出一直取不到片源：落错误页，让用户检查网络后重试
        case failNetwork
        /// 片源不在了（404）：落错误页说明
        case failSourceMissing
        /// 自研引擎确定解不了原文件（连引擎自己的软解、原位重开都不行）：改拉服务端 HLS 交给系统播放器
        case fallbackToServerStream
        /// 服务端这一档放不了（或反复连不上）：逐级降档（failed_tiers）
        case stepDownTier
    }

    static func decide(_ input: Input) -> Response {
        let nativeOriginal = input.engine == .native && input.playsOriginalFile
        switch input.cause {
        case .network:
            if input.restartAllowed { return .reconnect }
            // 服务端流连续重开都没出画：多半是这一档的换封装 / 转码出了问题，按「这一档放不了」往下走；
            // 原文件直出连不上就是连不上，换什么都一样
            return input.playsOriginalFile ? .failNetwork : .stepDownTier
        case .sourceMissing:
            return .failSourceMissing
        case .storageFull:
            guard nativeOriginal else { return .stepDownTier }
            return input.nativeRetryAllowed ? .retryNativeLowStorage : .fallbackToServerStream
        case .decode:
            guard nativeOriginal else { return .stepDownTier }
            return input.nativeRetryAllowed ? .retryNative : .fallbackToServerStream
        case .decodeFinal:
            // 原文件交给服务端转成系统播放器能放的流；已经在放服务端流的，降一档再试
            return nativeOriginal ? .fallbackToServerStream : .stepDownTier
        }
    }
}

/// 自研引擎「解不了」时先原位重开的额度。引擎楞住、中途出错、存储刚写满这类一时的问题，原位重开就好；
/// 真解不了的，重开也一样——同一集 3 分钟内只重开一次，再失败才改走服务端流（反复出问题说明不是一时的）
struct NativeRetryBudget {
    static let window: TimeInterval = 180

    private var lastRetryAt: Date?

    /// 还能重开返回 true（并记下这一次）
    mutating func allowRetry(now: Date = Date()) -> Bool {
        if let lastRetryAt, now.timeIntervalSince(lastRetryAt) < Self.window { return false }
        lastRetryAt = now
        return true
    }

    /// 换单元 / 用户手动重试：从头计
    mutating func reset() { lastRetryAt = nil }
}

/// 自研引擎的落盘计划（引擎补丁 P25）。换封装通路把切好的分片写进临时目录：前方 10 段、后方 20 段
/// （AVPlayer 换音频交接时会回头重取 7～10 段），片源字节缓存另占最多 1 GB。UHD 原盘一段 30～45 MB
/// （长 GOP 的首段能到 77 MB），光两个窗口就要 1 GB 上下。原来可用空间低于 512 MB 就改走服务端流；
/// 现在按剩余空间与片子码率把窗口收小，自研引擎照样能放——代价只是回头重取、往回跳要重新生产分片
struct NativeStoragePlan: Equatable {
    /// 分片缓存的前方 / 后方窗口（段数），nil = 引擎默认（10 / 20）
    var forwardSegments: Int?
    var backwardSegments: Int?
    /// 片源字节缓存（引擎补丁 P22）
    var sourceCache: Bool
    /// 线路慢时允许把前方缓冲放大到 3 分钟（引擎补丁 P20）
    var canGrowForward: Bool

    static let normal = NativeStoragePlan(forwardSegments: nil, backwardSegments: nil, sourceCache: true, canGrowForward: true)
    /// 存储写满后重开用：只留引擎允许的最小窗口
    static let minimal = NativeStoragePlan(forwardSegments: 2, backwardSegments: 2, sourceCache: false, canGrowForward: false)

    /// 一段按 8 秒估（长 GOP 的片子一段就是一个关键帧间隔）；不知道码率按 UHD 原盘的 80 Mbit/s。
    /// 台账码率超过 200 Mbit/s 不可信（UHD 蓝光上限约 128）：光盘镜像的片长常被记成几秒，码率算出几 Gbit/s，
    /// 实测会把窗口误收到最小
    static func segmentBytes(bitrateBps: Double?) -> Double {
        let bitrate = bitrateBps.flatMap { $0 > 0 && $0 <= 200_000_000 ? $0 : nil } ?? 80_000_000
        return max(Double(1 << 20), bitrate / 8 * 8)
    }

    static func make(freeBytes: Int64?, bitrateBps: Double?, forceMinimal: Bool = false) -> NativeStoragePlan {
        if forceMinimal { return .minimal }
        guard let freeBytes else { return .normal }
        let segment = segmentBytes(bitrateBps: bitrateBps)
        let free = Double(freeBytes)
        // 默认两个窗口（外加生产中的一段）只占剩余空间一半以内：照常
        if segment * 31 <= free / 2 { return .normal }
        // 否则留 256 MB 给系统，剩下的一半给窗口，按 4:6 分给前方与后方
        let segments = max(0, (free - 256 * 1024 * 1024) / 2 / segment)
        return NativeStoragePlan(
            forwardSegments: min(10, max(2, Int(segments * 0.4))),
            backwardSegments: min(20, max(2, Int(segments * 0.6) - 1)),
            sourceCache: free >= 4 * Double(1 << 30),
            canGrowForward: false
        )
    }

    /// 临时目录所在卷的可用字节（按「重要用途可用」，与引擎算分片预算同一口径）。
    /// 开发期 -mcFakeFreeBytes <字节> 假装存储快满（同时交给引擎，见 `PlaybackController`）
    ///
    /// 这个查询在真机上每次约 17 毫秒，而起播路径正卡在主线程上（2026-09-30 真机：会话回来到装载引擎的 38 毫秒里
    /// 有 33 毫秒是它，调试包多查一次）。所以走引擎带 10 秒缓存的那个入口（引擎补丁 P44），点播放时先在后台查好
    /// （`refreshFreeBytesInBackground`）：这里、引擎的分片留存预算、片源字节缓存预算都命中同一份
    static var temporaryFreeBytes: Int64? {
        #if DEBUG
        let fake = UserDefaults.standard.integer(forKey: "mcFakeFreeBytes")
        if fake > 0 { return Int64(fake) }
        #endif
        return NativeEngine.temporaryFreeBytes()
    }

    /// 在后台查一次可用空间备用（点播放时调：会话回来之前就查好了）
    nonisolated static func refreshFreeBytesInBackground() {
        Task.detached(priority: .userInitiated) { _ = NativeEngine.temporaryFreeBytes() }
    }
}

/// 自研引擎报「解不了」、或连接断了之后，先确认片源取不取得到。引擎在起播那一刻遇到断线、超时只知道「打不开」，
/// 会被当成解不了（故障注入实测：取流被拒 6 秒就改走了服务端流）；404 是文件不在了——这两种换播放器都没用。
/// 取一个字节（Range: bytes=0-0），5 秒超时
enum SourceProbe {
    enum Verdict: Equatable {
        /// 取得到（或令牌过期——开新会话换张令牌就取得到）
        case reachable
        /// 服务端说文件不在（404）
        case missing
        /// 取不到：断线、超时、服务端 5xx / 限流
        case unreachable(String)
    }

    static func check(_ url: URL) async -> Verdict {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return verdict(status: status)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func verdict(status: Int) -> Verdict {
        switch status {
        case 200 ..< 300, 401, 403: .reachable
        case 404: .missing
        default: .unreachable("HTTP \(status)")
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}

/// 网速跟不上时的「换低画质」提示（只提示、从不自动切，2026-09-28 用户拍板）。
///
/// 时机要严谨：换不换码率由用户决定，只在真有必要时打扰。条件全部满足才给，每个播放单元最多一次：
/// 1. 只算用户想看的时候：暂停期间不计；
/// 2. 触发（满足其一）：
///    - **一次等太久**：等首帧、等跳转落点、播放中卡住，连续等满 8 秒（2026-09-30 用户拍板）。外网放 4K 原片时
///      用户常常一上来就等十几秒，人早退出了，只数「开播后卡了几次」永远等不到提示；
///    - **反复卡**：开播后最近 5 分钟里卡了 2 次（起播、跳转、从暂停恢复后 10 秒内的缓冲不计，跳转的等待也不计）；
/// 3. 等待期间实测加载速度低于这条流码率的 90%（一次长等看这段里最快的一秒，反复卡看中位数）——
///    速度够还卡，不是线路问题，提示了也没用。
/// 缓冲攒满后引擎会暂停下载，平时的速度读数不可信（App 因此早先去掉了「速度低于码率」的预警）；
/// 等待时缓冲是空的、引擎在全力下载，这时的读数才代表线路。
struct QualitySuggestion {
    static let graceSeconds = 10
    static let windowSeconds = 300
    static let minStalls = 2
    static let longWaitSeconds = 8
    static let linkMargin = 0.9

    /// 给用户的提议：实测速度、这条流要的码率、推荐的画质上限
    struct Offer: Equatable {
        let measuredBps: Double
        let requiredBps: Double
        let maxHeight: Int
    }

    private struct Stall {
        var start: Int
        var seconds: Int
        var speeds: [Double]
    }

    /// 观看秒数：只在用户想看（没暂停）的时候走
    private var clock = 0
    private var graceUntil = graceSeconds
    private var stalls: [Stall] = []
    private var stalling = false
    /// 当前这一段连续等待（不管宽限、不管是不是跳转）的秒数与期间的速度读数
    private(set) var waitSeconds = 0
    private var waitSpeeds: [Double] = []
    private(set) var offered = false

    /// 起播、跳转、从暂停恢复：接下来 10 秒的缓冲不算「卡」；新的一段等待从这一刻算起
    mutating func restartGrace() {
        graceUntil = clock + Self.graceSeconds
        stalling = false
        waitSeconds = 0
        waitSpeeds = []
    }

    /// 每秒一次，只在用户想看时调用。stalled：正在等（缓冲中，含起播）；seeking：这段等待是跳转造成的
    mutating func tick(stalled: Bool, seeking: Bool = false, loadingBps: Double?) {
        clock += 1
        stalls.removeAll { $0.start + $0.seconds < clock - Self.windowSeconds }
        let speed = loadingBps.flatMap { $0 > 0 ? $0 : nil }
        if stalled {
            waitSeconds += 1
            if let speed { waitSpeeds.append(speed) }
        } else {
            waitSeconds = 0
            waitSpeeds = []
        }
        guard stalled, !seeking, clock > graceUntil else {
            stalling = false
            return
        }
        if !stalling {
            stalls.append(Stall(start: clock, seconds: 0, speeds: []))
            stalling = true
        }
        stalls[stalls.count - 1].seconds += 1
        if let speed { stalls[stalls.count - 1].speeds.append(speed) }
    }

    /// 现在该不该提议；给出一次后本单元不再给
    mutating func offer(streamBitrate: Double?, currentHeight: Int?) -> Offer? {
        guard !offered, let streamBitrate, streamBitrate > 0 else { return nil }
        let measured: Double
        if waitSeconds >= Self.longWaitSeconds {
            // 一次长等取这段里最快的一秒：冷起播时引擎一段一段地取（索引、文件头分头取），逐秒读数时有时无，
            // 模拟器 6 Mbit/s 限速实测读数只有 0～2 Mbit/s；最快那秒最接近线路能力，它都跟不上码率才算线路问题
            guard let fastest = waitSpeeds.max() else { return nil }
            measured = fastest
        } else if stalls.count >= Self.minStalls {
            let speeds = stalls.flatMap(\.speeds).sorted()
            guard !speeds.isEmpty else { return nil }
            measured = speeds[speeds.count / 2]
        } else {
            return nil
        }
        guard measured < streamBitrate * Self.linkMargin,
              let height = Self.recommendedHeight(for: measured, below: currentHeight) else { return nil }
        offered = true
        return Offer(measuredBps: measured, requiredBps: streamBitrate, maxHeight: height)
    }

    /// 推荐档位：比当前低、码率留两成余量装得下实测速度的最高一档；都装不下就给最低档；
    /// 已经在最低档（没有更低的可换）返回 nil（各档码率同 `QualityOption` 的说明：1080p 约 6、720p 约 3、480p 约 1.5 Mbps）
    static func recommendedHeight(for bps: Double, below currentHeight: Int?) -> Int? {
        let ladder: [(height: Int, bps: Double)] = [(1080, 6_000_000), (720, 3_000_000), (480, 1_500_000)]
        let lower = ladder.filter { rung in currentHeight.map { rung.height < $0 } ?? true }
        return lower.first { $0.bps <= bps * 0.8 }?.height ?? lower.last?.height
    }
}

/// 当前网络是否按流量计费：蜂窝 / 个人热点（系统标为 expensive），或用户开了「低数据模式」（constrained）。
/// 暂停时要不要连下载也停按它定（2026-09-28 用户拍板：暂停处理按网络类型决定，见 `PlaybackController.togglePlay`）。
/// 系统直接给，不需要任何权限。账号就绪时就开始监听（`SessionPrewarm`），第一次播放时已经有结果
nonisolated final class NetworkCost: @unchecked Sendable {
    static let shared = NetworkCost()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var metered = false
    private var currentInterface = "other"

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let now = path.isExpensive || path.isConstrained
            let interface = if path.usesInterfaceType(.wifi) {
                "wifi"
            } else if path.usesInterfaceType(.cellular) {
                "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                "wired"
            } else {
                "other"
            }
            self.lock.lock()
            let changed = now != self.metered
            self.metered = now
            self.currentInterface = interface
            self.lock.unlock()
            if changed { NotificationCenter.default.post(name: .networkCostChanged, object: nil) }
        }
        monitor.start(queue: DispatchQueue(label: "movieclaw.network-cost", qos: .utility))
    }

    var isMetered: Bool {
        #if DEBUG
        // 开发期：-mcNetworkCost metered 把当前网络当成计费网络（模拟器连不了蜂窝网，验证暂停停下载用）
        if UserDefaults.standard.string(forKey: "mcNetworkCost") == "metered" { return true }
        #endif
        lock.lock(); defer { lock.unlock() }
        return metered
    }

    /// 当前网络接口：wifi / cellular / wired / other（播放记录的分组维度，docs/design/playback-qoe.md §3.4）
    var interface: String {
        lock.lock(); defer { lock.unlock() }
        return currentInterface
    }
}

extension Notification.Name {
    /// `NetworkCost` 的计费状态变了（Wi-Fi ↔ 蜂窝、开关低数据模式）
    nonisolated static let networkCostChanged = Notification.Name("movieclaw.networkCostChanged")
}

/// 播放时的网络环境：画质按它分开记（`QualityMemory`）。
///
/// 「在家」= 服务器地址是私有 IPv4，且手机当前某个网卡的地址和它在同一网段（家里 Wi-Fi 直连 NAS）；
/// 服务器地址是私有 IPv4 但网段对不上 =「在外面」：走 VPN 回家（地址在隧道网卡上）、别的网络。
/// 服务器地址是公网（公网 IP，或域名解析出公网 IP）=「分不清」：在家经路由器回流和在外面连的是同一个地址，
/// 硬猜会把在家说成外网——这种情况画质只按片记、提示里也不写环境。
/// 不需要任何额外权限（Wi-Fi 名字要定位权限，拿不到）。域名在账号就绪时就在后台查好（`prewarm`），
/// 查到之前算「分不清」。
enum PlaybackNetwork: String {
    case home
    case away
    case unknown

    /// 提示里的环境名；分不清时不写
    var label: String? {
        switch self {
        case .home: "家里网络"
        case .away: "外网"
        case .unknown: nil
        }
    }

    /// 网卡地址（IPv4，主机序）与掩码
    struct Interface: Equatable {
        let address: UInt32
        let netmask: UInt32
    }

    static func classify(serverIPv4: UInt32?, interfaces: [Interface]) -> PlaybackNetwork {
        guard let server = serverIPv4, isPrivate(server) else { return .unknown }
        let sameSubnet = interfaces.contains { item in
            item.netmask != 0 && item.netmask != .max && item.address & item.netmask == server & item.netmask
        }
        return sameSubnet ? .home : .away
    }

    /// RFC 1918 私有网段（10/8、172.16/12、192.168/16）
    static func isPrivate(_ ip: UInt32) -> Bool {
        ip >> 24 == 10 || ip >> 20 == 0xAC1 || ip >> 16 == 0xC0A8
    }

    static func parseIPv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    /// 当前环境。IPv4 地址直接判；域名用查到的地址（还没查到就在后台发起，这次先算「分不清」）
    static func current(server: ServerAddress) -> PlaybackNetwork {
        guard let host = server.origin.host else { return .unknown }
        let ip = parseIPv4(host) ?? resolvedHosts.value(for: host)
        return classify(serverIPv4: ip, interfaces: localInterfaces())
    }

    /// 账号就绪时调用：服务器配的是域名就先在后台把地址查好，第一次播放就能判出环境
    static func prewarm(server: ServerAddress) {
        guard let host = server.origin.host, parseIPv4(host) == nil else { return }
        _ = resolvedHosts.value(for: host)
    }

    /// 本机开着的非回环 IPv4 网卡
    static func localInterfaces() -> [Interface] {
        var result: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor?.pointee {
            defer { cursor = item.ifa_next }
            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = item.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(Interface(address: ip, netmask: mask))
        }
        return result
    }

    /// 域名 → IPv4 的缓存：查询放后台线程，不卡播放器弹出。
    /// 家里路由器把域名解析成内网地址（分区 DNS）时，出门后结果会变：超过 5 分钟的结果先照用、同时后台重查
    private static let resolvedHosts = HostCache()

    /// 必须 nonisolated：工程默认隔离在主线程，lookup 却在后台队列里调，隔离检查会直接 trap 闪退
    /// （2026-09-29 服务器地址填域名的账号登录后每次启动必崩；填 IP 的走不到这里）
    private nonisolated final class HostCache: @unchecked Sendable {
        private static let freshSeconds: TimeInterval = 300
        private let lock = NSLock()
        private var resolved: [String: (ip: UInt32, at: Date)] = [:]
        private var pending: Set<String> = []

        func value(for host: String) -> UInt32? {
            lock.lock()
            defer { lock.unlock() }
            let hit = resolved[host]
            let stale = hit.map { Date().timeIntervalSince($0.at) > Self.freshSeconds } ?? true
            if stale, !pending.contains(host) {
                pending.insert(host)
                DispatchQueue.global(qos: .utility).async { [self] in
                    let ip = Self.lookup(host)
                    lock.lock()
                    pending.remove(host)
                    if let ip { resolved[host] = (ip, Date()) }
                    lock.unlock()
                }
            }
            return hit?.ip
        }

        private static func lookup(_ host: String) -> UInt32? {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
            defer { freeaddrinfo(result) }
            guard let address = info.pointee.ai_addr else { return nil }
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        }
    }
}
