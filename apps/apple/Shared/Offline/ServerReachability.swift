#if os(iOS)
import Foundation
import Observation

/// 一次请求的结果在「能不能和我家服务器说上话」这件事上算什么证据（docs/design/offline-download.md §2.2）
nonisolated enum ReachabilityOutcome: Sendable {
    /// 收到了带服务器标记头的响应（任何状态码，含 401、500）
    case success
    /// 明确连不上：拒绝连接、主机不可达、TLS / 证书错误（门户劫持）、不是我家服务器回的、蜂窝被禁
    case hard
    /// 可能只是慢：超时、连接中断、DNS 失败
    case soft
    /// 不算：主动取消
    case ignored

    static func of(_ error: URLError) -> ReachabilityOutcome {
        switch error.code {
        case .cancelled:
            .ignored
        case .cannotConnectToHost, .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .appTransportSecurityRequiresSecureConnection:
            .hard
        default:
            // 超时、中断、DNS 失败（信号差的蜂窝网上 DNS 也会超时）都只算「可能只是慢」
            .soft
        }
    }

    /// 所有 /api/v1 响应都带 spec 指纹头（middleware.py）：没有它的是门户页、反向代理的错误页、外地同 IP 的别的设备
    static func of(_ response: HTTPURLResponse) -> ReachabilityOutcome {
        response.value(forHTTPHeaderField: "x-movieclaw-spec-hash") != nil ? .success : .hard
    }
}

/// 连通性判断与离线模式（docs/design/offline-download.md §2）。
///
/// 两层分开：**可达性**只回答「现在能不能和我家服务器说上话」；**模式**（在线 / 离线）决定媒体库显示什么。
/// 播放不看模式——本机副本在线时也优先播。
///
/// 证据：所有页面请求的结果在 `APIClient` 出口旁听（不发额外请求）；只有出了问题才探测 `/health`
/// （探测本身也走同一个出口，结果照样经旁听进来）；网络通路看系统的 `NWPathMonitor`。
///
/// 网慢不会误切：任何一次成功立即清零；只有超时这类软失败时，要连续三次失败、跨度满 30 秒、
/// 期间没有任何成功才算不可达；就算判了不可达，使用途中也不自动切，只在首页提示条上给按钮。
/// 自动进离线只有两种情况：没有网络通路（飞行模式）；冷启动或久别回前台后的 60 秒内判定不可达。
@MainActor
@Observable
final class ServerReachability {
    static let shared = ServerReachability()

    enum Status: Equatable {
        case reachable
        /// 出过失败、正在探测：界面不变
        case suspect
        case unreachable
    }

    enum Mode: Equatable {
        case online
        case offline
    }

    private(set) var status: Status = .reachable
    private(set) var mode: Mode = .online {
        didSet { OfflineModeFlag.set(mode == .offline) }
    }
    /// 自动回到在线的次数（外壳据此弹「已连上服务器」）
    private(set) var reconnects = 0

    var isOffline: Bool { mode == .offline }

    @ObservationIgnored private var origin: URL?
    @ObservationIgnored private var judge = ReachabilityJudge()
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var lastForegroundAt = Date.distantPast
    /// 这个时刻之前判定不可达会自动进离线（冷启动、久别回前台后的 60 秒）
    @ObservationIgnored private var autoWindowUntil = Date().addingTimeInterval(60)
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var pathSatisfied = true
    @ObservationIgnored private var unreachableBackoff = 0
    /// 最近一次成功（冷启动检查：3 秒内没有任何请求成功才探一下）
    @ObservationIgnored private var lastSuccessAt = Date.distantPast

    private init() {
        NotificationCenter.default.addObserver(forName: .networkPathChanged, object: nil, queue: .main) { [weak self] note in
            let satisfied = note.userInfo?["satisfied"] as? Bool ?? true
            MainActor.assumeIsolated { self?.pathChanged(satisfied: satisfied) }
        }
        pathSatisfied = NetworkCost.shared.isSatisfied
    }

    // MARK: 输入

    /// 当前服务器（换账号、换服务器时）：之前的证据作废
    func track(server: ServerAddress) {
        guard origin != server.origin else { return }
        origin = server.origin
        resetStreak()
        status = pathSatisfied ? .reachable : .unreachable
        if status == .unreachable { evaluateMode(pathDown: true) }
        launchCheck()
    }

    /// 冷启动 / 久别回前台：3 秒内页面请求都没成功就主动探一下。黑洞（只超时）时页面请求要 60 秒才报失败，
    /// 不探的话要等一分多钟才有第一份证据；网络健康时页面请求早已成功，不发这个请求
    private func launchCheck() {
        let checkFrom = Date()
        guard let origin else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.lastSuccessAt < checkFrom, self.origin == origin else { return }
            _ = try? await Self.probeRequest(origin)
        }
    }

    /// 探测请求：`/health`，5 秒超时（几百字节，网慢也够），结果经 `APIClient` 出口旁听回来
    private static func probeRequest(_ origin: URL) async throws -> API.HealthResponse {
        try await APIClient(server: ServerAddress(origin: origin)).raw("GET", "/health", timeout: 5)
    }

    /// 旁听：`APIClient` 出口每个请求的结果（任意线程）
    nonisolated static func report(origin: URL, outcome: ReachabilityOutcome, startedAt: Date) {
        guard outcome != .ignored else { return }
        Task { @MainActor in shared.observe(origin: origin, outcome: outcome, startedAt: startedAt) }
    }

    private func observe(origin: URL, outcome: ReachabilityOutcome, startedAt: Date) {
        guard origin == self.origin else { return }
        switch outcome {
        case .success:
            markReachable()
        case .hard, .soft:
            // 回前台之前发出的请求：App 挂起时系统掐断了连接，回来报的错不说明网络坏了
            guard startedAt >= lastForegroundAt else { return }
            noteFailure(hard: outcome == .hard, startedAt: startedAt)
        case .ignored:
            break
        }
    }

    private func pathChanged(satisfied: Bool) {
        let was = pathSatisfied
        pathSatisfied = satisfied
        if !satisfied {
            // 没有任何网络通路（飞行模式、没 Wi-Fi 也没蜂窝）：不用探，确定连不上
            setUnreachable(pathDown: true)
        } else if !was {
            // 通路回来了：不急着当成在线，探一下
            resetStreak()
            if status == .unreachable { status = .suspect }
            probe(after: 0)
        }
    }

    /// 回到前台（外壳在场景激活时调）：后台超过 10 分钟算「久别回来」，重新给 60 秒自动进离线的窗口
    func noteForeground() {
        lastForegroundAt = Date()
        if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) >= 600 {
            autoWindowUntil = Date().addingTimeInterval(60)
            launchCheck()
        }
        backgroundedAt = nil
        if status != .reachable { probe(after: 0) }
    }

    func noteBackground() {
        backgroundedAt = Date()
        probeTask?.cancel()
        probeTask = nil
    }

    // MARK: 判定

    private func resetStreak() {
        judge = ReachabilityJudge()
    }

    private func markReachable() {
        lastSuccessAt = Date()
        resetStreak()
        unreachableBackoff = 0
        probeTask?.cancel()
        probeTask = nil
        if status != .reachable { status = .reachable }
        if mode == .offline {
            mode = .online
            reconnects += 1
        }
    }

    private func noteFailure(hard: Bool, startedAt: Date) {
        let conclusive = judge.failure(hard: hard, at: Date(), startedAt: startedAt)
        if status == .reachable {
            status = .suspect
            probe(after: 0)
        }
        if conclusive, status != .unreachable { setUnreachable(pathDown: false) }
    }

    private func setUnreachable(pathDown: Bool) {
        if status != .unreachable {
            status = .unreachable
            unreachableBackoff = 0
        }
        evaluateMode(pathDown: pathDown)
        if !pathDown { probe(after: nextBackoff()) }
    }

    /// 判定为不可达后要不要自动进离线：没有通路（意图明确）或还在自动窗口里；本机一部都没下过就不进
    private func evaluateMode(pathDown: Bool) {
        guard mode == .online, status == .unreachable, !OfflineStore.shared.downloadedItemIds.isEmpty else { return }
        if pathDown || !pathSatisfied || Date() < autoWindowUntil {
            mode = .offline
        }
    }

    /// 本机目录读完了 / 有了第一部下载：冷启动时可能先判了不可达、目录后到
    func catalogChanged() {
        evaluateMode(pathDown: !pathSatisfied)
    }

    // MARK: 手动

    /// 首页提示条「看 iPhone 上的 N 部」：用户点了才切
    func enterOffline() {
        guard !OfflineStore.shared.downloadedItemIds.isEmpty else { return }
        mode = .offline
        if status == .reachable { status = .suspect }
        probe(after: nextBackoff())
    }

    /// 离线提示条「重新连接」：立即探一次
    func reconnect() {
        unreachableBackoff = 0
        probe(after: 0)
    }

    // MARK: 探测

    private func nextBackoff() -> Double {
        let steps: [Double] = [30, 60, 120, 300]
        let delay = steps[min(unreachableBackoff, steps.count - 1)]
        unreachableBackoff += 1
        return delay
    }

    /// 存疑时每次探完隔 2 秒再探（每次最多 5 秒）；不可达时按 30 秒 → 1 → 2 → 5 分钟退避。
    /// 探测结果经 `APIClient` 出口旁听回来
    private func probe(after delay: Double) {
        guard let origin, pathSatisfied else { return }
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                guard let self, self.status != .reachable else { return }
                _ = try? await Self.probeRequest(origin)
                guard !Task.isCancelled, self.status != .reachable else { return }
                let wait: Double = self.status == .suspect ? 2 : self.nextBackoff()
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }
}

/// 判不可达的两条规则（满足其一）：连续硬失败至少两次、从第一次起 ≥3 秒；连续三次失败（软的也算）、
/// 从第一个失败请求**发出**起 ≥30 秒（= 服务器已经 30 秒没回过任何话）。中间任何一次成功都要重新建一个（清零）。
/// 纯逻辑，单元测试按时刻喂事件
nonisolated struct ReachabilityJudge: Sendable {
    static let hardGap: TimeInterval = 3
    static let softSpan: TimeInterval = 30
    static let softCount = 3

    private var streakStart: Date?
    private var streakCount = 0
    /// 这一串连续硬失败从何时开始、有几次（中间夹一次软失败就断）
    private var hardStart: Date?
    private var hardCount = 0

    /// 记一次失败，返回这串失败是否已足以判定「连不上」。`startedAt` 是这个请求发出的时刻（不给按失败时刻）
    mutating func failure(hard: Bool, at now: Date, startedAt: Date? = nil) -> Bool {
        let sent = min(startedAt ?? now, now)
        streakStart = min(streakStart ?? sent, sent)
        streakCount += 1
        if hard {
            if hardStart == nil { hardStart = now }
            hardCount += 1
        } else {
            hardStart = nil
            hardCount = 0
        }
        let twoHard = hardCount >= 2 && now.timeIntervalSince(hardStart ?? now) >= Self.hardGap
        let long = streakCount >= Self.softCount && now.timeIntervalSince(streakStart ?? now) >= Self.softSpan
        return twoHard || long
    }
}

/// 图片加载器在后台线程上要知道「现在是不是离线模式」：主线程改模式时同步一份
nonisolated enum OfflineModeFlag {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var offline = false

    static var isOffline: Bool { lock.withLock { offline } }

    static func set(_ value: Bool) { lock.withLock { offline = value } }
}
#endif
