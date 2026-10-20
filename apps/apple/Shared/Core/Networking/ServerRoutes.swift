import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 内外双地址：这台服务器现在该连哪个地址（docs/design/server-addresses.md §4）。
///
/// 服务器的身份仍是登录时的地址（`ServerAddress.origin`，下称「登录地址」）：令牌、推送、离线副本、页面快照、
/// 图片缓存都按它存，一条都不用迁移。这里只决定「真正发请求时用哪个地址」：
/// - `APIClient` 拼请求地址、`ServerAddress.resolve` 拼取流地址时换成当前地址；
/// - 图片地址照旧用登录地址（Nuke 缓存键、离线图片都不变），图片加载器发请求前再换（`rewrite`）。
///
/// 怎么选（全程不让用户选）：
/// - 地址簿来自服务端 `GET /server/addresses`，按登录地址缓存在本机；旧服务器没有这个接口时只用登录地址；
/// - 只有蜂窝网络（没有 Wi-Fi / 有线 / VPN）时不试内网地址：私网地址发往运营商多半石沉大海；
/// - 内网先发 `/health?nonce=`（1.5 秒），有内网候选时外网晚 250 毫秒再发（5 秒）：先通过身份校验的先用，
///   外网先到、内网后到就升级到内网。在别人家同网段的 Wi-Fi 里，内网不通也最多多等 250 毫秒；
/// - 按网络记住结论（网卡 + 网段，不读 Wi-Fi 名）：回到来过的网络直接用上次的地址，后台再核实；
/// - 只在账号就绪、网络变化、后台超过 10 分钟回前台、当前地址出硬错误时重新选，平时不发探测；
/// - 带令牌之前三关：响应带服务器标记头、实例号对得上、签名能用登录后拿到的主机公钥验过——酒店 Wi-Fi 里
///   恰好也有一台 `192.168.1.10` 时，令牌不会发过去。
///
/// 路线（`X-MovieClaw-Route`）：用内网地址为 `lan`，经 VPN 连上内网地址为 `vpn`，其余 `wan`。服务端据此判断
/// 在家还是在外面（上传让路、网盘直连），见设计文档 §5。
nonisolated final class ServerRoutes: @unchecked Sendable {
    static let shared = ServerRoutes()

    enum Route: String, Codable, Sendable {
        case lan, vpn, wan
    }

    /// 地址簿里的一个地址
    struct Endpoint: Codable, Hashable, Sendable {
        let origin: URL
        /// lan / wan
        let kind: String
    }

    /// 一台服务器的地址簿与按网络记下的结论（按登录地址存在本机）
    struct Book: Codable, Sendable {
        var instanceId: String
        var hostKey: String
        var endpoints: [Endpoint]
        var lanSubnets: [String]
        /// 网络指纹 → 在这个网络里最后用上的地址，新的在后（最多 8 个）
        var memory: [Memory] = []

        struct Memory: Codable, Sendable {
            let fingerprint: String
            let origin: URL
        }
    }

    /// 当前用的地址与路线
    struct Current: Equatable, Sendable {
        let origin: URL
        let route: Route?
    }

    static let didChange = Notification.Name("movieclaw.serverRouteChanged")

    private static let storageKey = "movieclaw.serverRoutes"
    private static let lanTimeout: TimeInterval = 1.5
    private static let wanTimeout: TimeInterval = 5
    private static let wanDelay: Duration = .milliseconds(250)
    private static let memoryLimit = 8
    /// 后台待多久回前台算「久别」，要重新选（与 `ServerReachability` 同一口径）
    private static let longAbsence: TimeInterval = 600

    private let lock = NSLock()
    private var books: [String: Book]
    private var current: [String: Current] = [:]
    /// 正在用的服务器（登录地址的键 → 登录地址），网络变化时为它们重新选
    private var active: [String: ServerAddress] = [:]
    private var selecting: [String: Task<Void, Never>] = [:]
    /// 每起一轮加一：只有最后起的那轮跑完才清掉 `selecting`
    private var generation = 0
    private var lastFingerprint: String?
    private var backgroundedAt: Date?
    private var observers: [NSObjectProtocol] = []

    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": APIClient.userAgent]
        return URLSession(configuration: config)
    }()

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: Book].self, from: data) {
            books = stored
        } else {
            books = [:]
        }
    }

    // MARK: - 读（任意线程，只读内存）

    /// 发请求时用的地址；没选过就是登录地址
    func origin(for server: ServerAddress) -> URL {
        lock.withLock { current[Self.key(server.origin)]?.origin } ?? server.origin
    }

    /// 这次请求带的路线头；没选过（旧服务器、还没就绪）不带
    func route(for server: ServerAddress) -> Route? {
        lock.withLock { current[Self.key(server.origin)]?.route }
    }

    /// 把一个用这台服务器任一地址拼的地址（图片用登录地址拼；断线前拼好的取流探测地址可能是旧的那个）换成当前地址；
    /// 不认识的地址原样返回
    func rewrite(_ url: URL) -> URL {
        let key = Self.key(url)
        let target = lock.withLock { () -> URL? in
            if let hit = current[key] { return hit.origin }
            // 同一台服务器的别的地址
            guard let owner = books.first(where: { $0.value.endpoints.contains { Self.key($0.origin) == key } })?.key else { return nil }
            return current[owner]?.origin
        }
        guard let target, Self.key(target) != key,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = target.scheme
        components.host = target.host
        components.port = target.port
        return components.url ?? url
    }

    // MARK: - 时机

    /// 账号就绪（冷启动、登录、切换账号）：先按本机记忆当场定一个地址（不等网络），再在后台核实、刷新地址簿
    func activate(_ server: ServerAddress, token: String?) {
        startObserving()
        let key = Self.key(server.origin)
        let net = NetworkSnapshot.current()
        lock.withLock {
            active = [key: server]
            if let book = books[key], current[key] == nil, let guess = Self.optimisticGuess(book: book, server: server, net: net) {
                current[key] = guess
            }
        }
        select(server, reason: "账号就绪")
        if let token {
            Task.detached(priority: .utility) { [self] in await refreshBook(server, token: token) }
        }
    }

    /// 当前地址出了硬错误（连不上、找不到主机、超时）：重新选，选出不同的地址就返回它（调用方据此重试一次）。
    /// 先看正在跑的那轮（它可能是别的原因起的、没排除这个坏地址）；还停在坏地址上就排除它补跑一轮。
    /// 一有别的地址就返回，不等这一轮里慢的探测超时
    func failover(_ server: ServerAddress, failed: URL) async -> URL? {
        let key = Self.key(server.origin)
        guard lock.withLock({ books[key] }) != nil else { return nil }
        let failedKey = Self.key(failed)
        for rerun in [false, true] {
            let round = select(server, reason: "当前地址连不上", excluding: failedKey, rerun: rerun)
            if let moved = await movedAway(server, from: failedKey, during: round) { return moved }
        }
        return nil
    }

    /// 等到当前地址不再是坏的那个（返回新地址），或这一轮跑完还没换（返回 nil）
    private func movedAway(_ server: ServerAddress, from failedKey: String, during round: Task<Void, Never>) async -> URL? {
        let done = DoneFlag()
        Task.detached { await round.value; done.set() }
        while true {
            let now = origin(for: server)
            if Self.key(now) != failedKey { return now }
            if done.isSet { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func startObserving() {
        lock.lock()
        guard observers.isEmpty else { lock.unlock(); return }
        lock.unlock()
        let center = NotificationCenter.default
        var list = [center.addObserver(forName: .networkPathUpdated, object: nil, queue: nil) { [weak self] _ in
            self?.networkMaybeChanged()
        }]
        #if canImport(UIKit)
        list.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.backgroundedAt = Date() }
        })
        list.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.foregrounded()
        })
        #elseif canImport(AppKit)
        list.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.reselectAll(reason: "电脑唤醒")
        })
        #endif
        lock.withLock { observers = list }
        lastFingerprintUpdate(NetworkSnapshot.current().fingerprint)
    }

    private func foregrounded() {
        let since = lock.withLock { () -> Date? in
            defer { backgroundedAt = nil }
            return backgroundedAt
        }
        if let since, Date().timeIntervalSince(since) >= Self.longAbsence {
            reselectAll(reason: "久别回到前台")
        }
    }

    private func networkMaybeChanged() {
        let fingerprint = NetworkSnapshot.current().fingerprint
        if lastFingerprintUpdate(fingerprint) {
            reselectAll(reason: "网络变了")
        }
    }

    /// 记下当前网络指纹，变了返回 true
    @discardableResult
    private func lastFingerprintUpdate(_ fingerprint: String) -> Bool {
        lock.withLock {
            defer { lastFingerprint = fingerprint }
            return lastFingerprint != nil && lastFingerprint != fingerprint
        }
    }

    private func reselectAll(reason: String) {
        for server in lock.withLock({ Array(active.values) }) {
            select(server, reason: reason)
        }
    }

    // MARK: - 选

    /// 同一台服务器同时只跑一轮；在跑的那轮结束前再来的请求共用它。`rerun`（地址簿刚换了）时不共用：
    /// 在跑的那轮用的是旧地址簿，等它跑完再按新的补跑一轮
    @discardableResult
    private func select(_ server: ServerAddress, reason: String, excluding: String? = nil, rerun: Bool = false) -> Task<Void, Never> {
        let key = Self.key(server.origin)
        return lock.withLock {
            let running = selecting[key]
            if let running, !rerun { return running }
            generation += 1
            let mine = generation
            let task = Task.detached(priority: .userInitiated) { [self] in
                await running?.value
                await race(server, excluding: excluding)
                lock.withLock { if generation == mine { selecting[key] = nil } }
            }
            selecting[key] = task
            return task
        }
    }

    private func race(_ server: ServerAddress, excluding: String?) async {
        let key = Self.key(server.origin)
        guard let book = lock.withLock({ books[key] }) else { return }
        let net = NetworkSnapshot.current()
        let candidates = Self.candidates(book: book, server: server, net: net).filter { Self.key($0.origin) != excluding }
        let lan = candidates.filter { $0.kind == "lan" }
        let wan = candidates.filter { $0.kind != "lan" }
        guard !candidates.isEmpty else { return }

        await withTaskGroup(of: Endpoint?.self) { group in
            for endpoint in lan {
                group.addTask { await self.probe(endpoint, book: book, timeout: Self.lanTimeout) ? endpoint : nil }
            }
            for endpoint in wan {
                group.addTask {
                    if !lan.isEmpty { try? await Task.sleep(for: Self.wanDelay) }
                    return await self.probe(endpoint, book: book, timeout: Self.wanTimeout) ? endpoint : nil
                }
            }
            var settled: Endpoint?
            for await result in group {
                guard let result else { continue }
                if settled == nil || (settled?.kind != "lan" && result.kind == "lan") {
                    settled = result
                    adopt(result, server: server, book: book, net: net)
                }
                if result.kind == "lan" {
                    // 内网通了就是最好的结果，其余不用等
                    group.cancelAll()
                }
            }
        }
    }

    private func adopt(_ endpoint: Endpoint, server: ServerAddress, book: Book, net: NetworkSnapshot) {
        let key = Self.key(server.origin)
        let route = Self.route(of: endpoint, book: book, net: net)
        let next = Current(origin: endpoint.origin, route: route)
        let changed = lock.withLock { () -> Bool in
            let changed = current[key] != next
            current[key] = next
            if var stored = books[key] {
                stored.memory.removeAll { $0.fingerprint == net.fingerprint }
                stored.memory.append(.init(fingerprint: net.fingerprint, origin: endpoint.origin))
                stored.memory = Array(stored.memory.suffix(Self.memoryLimit))
                books[key] = stored
            }
            return changed
        }
        persist()
        if changed {
            NotificationCenter.default.post(name: Self.didChange, object: server)
        }
    }

    // MARK: - 探测

    /// 匿名的 `/health?nonce=`：带服务器标记头、实例号对得上、主机签名验过才算是「我家那台」
    private func probe(_ endpoint: Endpoint, book: Book, timeout: TimeInterval) async -> Bool {
        let nonce = Self.nonce()
        guard var components = URLComponents(url: endpoint.origin.appending(path: "api/v1/health"), resolvingAgainstBaseURL: false)
        else { return false }
        components.queryItems = [URLQueryItem(name: "nonce", value: nonce)]
        guard let url = components.url else { return false }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        guard let (data, response) = try? await probeSession.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "x-movieclaw-spec-hash") != nil,
              let health = try? APIClient.decoder.decode(API.HealthResponse.self, from: data)
        else { return false }
        return Self.verify(health: health, nonce: nonce, book: book)
    }

    static func verify(health: API.HealthResponse, nonce: String, book: Book) -> Bool {
        guard health.instanceId == book.instanceId, let proof = health.proof,
              let signature = Data(base64URL: proof), let keyData = Data(base64URL: book.hostKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        let message = Data("movieclaw-health\n\(book.instanceId)\n\(nonce)".utf8)
        return key.isValidSignature(signature, for: message)
    }

    private static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    // MARK: - 地址簿

    /// 登录后（及每次账号就绪）向服务端要一份地址簿。旧服务器没有这个接口（404）时什么都不记
    func refreshBook(_ server: ServerAddress, token: String) async {
        let api = APIClient(server: server, token: token)
        guard let view = try? await api.appAddressesList() else { return }
        let key = Self.key(server.origin)
        var endpoints: [Endpoint] = view.addresses.compactMap { item in
            guard let url = URL(string: item.url) else { return nil }
            return Endpoint(origin: Self.normalized(url), kind: item.kind == "lan" ? "lan" : "wan")
        }
        // 登录地址总是候选（用户填的那个一定能用过）
        if !endpoints.contains(where: { Self.key($0.origin) == key }) {
            endpoints.append(Endpoint(origin: server.origin, kind: Self.guessKind(server.origin)))
        }
        let isNew = lock.withLock { () -> Bool in
            let previous = books[key]
            books[key] = Book(instanceId: view.instanceId, hostKey: view.hostKey, endpoints: endpoints,
                              lanSubnets: view.lanSubnets, memory: previous?.memory ?? [])
            return previous == nil || previous?.instanceId != view.instanceId
                || Set(previous?.endpoints ?? []) != Set(endpoints)
        }
        persist()
        if isNew { select(server, reason: "地址簿更新", rerun: true) }
    }

    /// 测试用：直接放一份地址簿
    func install(_ book: Book, for server: ServerAddress) {
        lock.withLock { books[Self.key(server.origin)] = book }
    }

    /// 测试用：直接定当前地址
    func setCurrent(_ value: Current?, for server: ServerAddress) {
        lock.withLock { current[Self.key(server.origin)] = value }
    }

    func book(for server: ServerAddress) -> Book? {
        lock.withLock { books[Self.key(server.origin)] }
    }

    func current(for server: ServerAddress) -> Current? {
        lock.withLock { current[Self.key(server.origin)] }
    }

    private func persist() {
        let snapshot = lock.withLock { books }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - 规则（纯函数，有单元测试）

    /// 这一轮参加的候选：只有蜂窝网络时不试内网地址
    static func candidates(book: Book, server: ServerAddress, net: NetworkSnapshot) -> [Endpoint] {
        book.endpoints.filter { $0.kind != "lan" || net.canReachPrivate }
    }

    /// 不发请求先定一个，冷启动不用等探测。这时还没验身份，带令牌只能发给本来就信得过的地址：
    /// - 登录地址（用户自己填的，和改造前一样）；
    /// - https 地址（证书验过主机名）。
    /// 未验证的 http 地址一律不先用：网络指纹只看网段，换到同网段的别人家 Wi-Fi 时，记过的
    /// `192.168.1.10` 可能是另一台机器。在此之上：这个网络记过的 > 登录地址（只剩蜂窝时的内网登录地址除外）>
    /// 第一个 https 外网地址；都不行返回 nil（照旧用登录地址，等探测）
    static func optimisticGuess(book: Book, server: ServerAddress, net: NetworkSnapshot) -> Current? {
        let usable = candidates(book: book, server: server, net: net)
        func trusted(_ endpoint: Endpoint) -> Bool {
            key(endpoint.origin) == key(server.origin) || endpoint.origin.scheme?.lowercased() == "https"
        }
        if let remembered = book.memory.last(where: { $0.fingerprint == net.fingerprint }),
           let endpoint = usable.first(where: { key($0.origin) == key(remembered.origin) }), trusted(endpoint) {
            return Current(origin: endpoint.origin, route: route(of: endpoint, book: book, net: net))
        }
        let login = usable.first(where: { key($0.origin) == key(server.origin) })
        // 登录地址是内网 IP，本机却不在它的网段、也没开 VPN：多半在外面，先用 https 外网地址，
        // 免得头一批请求等满超时（家里分了多个网段时，这个网络记过登录地址，上面已经直接用了）
        let loginLooksAway = login.map { endpoint in
            let host = endpoint.origin.host() ?? ""
            return endpoint.kind == "lan" && parseIPv4(host) != nil && !net.sameSubnet(host) && !net.hasVPN
        } ?? true
        if let login, !loginLooksAway {
            return Current(origin: login.origin, route: route(of: login, book: book, net: net))
        }
        if let https = usable.first(where: { $0.kind != "lan" && trusted($0) }) {
            return Current(origin: https.origin, route: .wan)
        }
        return login.map { Current(origin: $0.origin, route: route(of: $0, book: book, net: net)) }
    }

    /// 用这个地址时的路线：
    /// - 内网 IP：和某块实体网卡同网段为 lan；不同网段但有 VPN 为 vpn（经 VPN 连回家）；不同网段也没有 VPN
    ///   为 lan（家里分了多个网段，路由器转过去的）；
    /// - 内网域名（手动标的，家里 DNS 指向内网）：本机实体网卡在内网网段里为 lan；否则有 VPN 为 vpn，
    ///   没有 VPN 为 wan——在咖啡馆经公网 DNS 连上了同一个域名，人在外面
    static func route(of endpoint: Endpoint, book: Book, net: NetworkSnapshot) -> Route {
        guard endpoint.kind == "lan" else { return .wan }
        let host = endpoint.origin.host() ?? ""
        if parseIPv4(host) != nil {
            if net.sameSubnet(host) { return .lan }
            return net.hasVPN ? .vpn : .lan
        }
        if net.physicalIn(subnets: book.lanSubnets) { return .lan }
        return net.hasVPN ? .vpn : .wan
    }

    /// 这台服务器所有已知地址的「主机:端口」（登录地址、地址簿）：扫码批准时判断二维码是不是这台服务器的
    func hostLabels(of server: ServerAddress) -> [String] {
        let endpoints = lock.withLock { books[Self.key(server.origin)]?.endpoints ?? [] }
        return [server.hostLabel] + endpoints.map { ServerAddress(origin: $0.origin).hostLabel }
    }

    /// 这个地址是不是这台服务器的（登录地址、当前地址、地址簿里任一个）：站内链接判断用
    func belongs(_ url: URL, to server: ServerAddress) -> Bool {
        let target = Self.key(url)
        if target == Self.key(server.origin) { return true }
        return lock.withLock {
            let key = Self.key(server.origin)
            if let now = current[key], Self.key(now.origin) == target { return true }
            return books[key]?.endpoints.contains { Self.key($0.origin) == target } ?? false
        }
    }

    static func guessKind(_ url: URL) -> String {
        let host = (url.host() ?? "").lowercased()
        if let ip = parseIPv4(host) {
            let shared = ip >> 22 == (100 << 2 | 1) // 100.64.0.0/10
            return !shared && (PlaybackNetwork.isPrivate(ip) || ip >> 24 == 127 || ip >> 16 == 0xA9FE) ? "lan" : "wan"
        }
        let suffixes = [".local", ".lan", ".home.arpa", ".internal", ".localdomain"]
        return !host.contains(".") || suffixes.contains(where: host.hasSuffix) ? "lan" : "wan"
    }

    static func parseIPv4(_ text: String) -> UInt32? {
        PlaybackNetwork.parseIPv4(text)
    }

    /// `scheme://host:port`，默认端口补齐，用来比较两个地址是不是同一个
    static func key(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "http"
        let host = url.host()?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// 只留协议、主机、端口（去掉默认端口），与 `ServerAddress(parsing:)` 同口径
    static func normalized(_ url: URL) -> URL {
        (try? ServerAddress(parsing: url.absoluteString))?.origin ?? url
    }
}

/// 本机此刻的网络：哪些网卡有 IPv4 地址、是实体网卡还是 VPN、有没有蜂窝（只读本机网卡，不发请求）
nonisolated struct NetworkSnapshot: Equatable, Sendable {
    struct Interface: Equatable, Sendable {
        let name: String
        let address: UInt32
        let netmask: UInt32
    }

    /// Wi-Fi / 有线
    var physical: [Interface]
    var vpn: [Interface]
    var cellular: Bool

    var hasVPN: Bool { !vpn.isEmpty }
    /// 能不能试内网地址：有 Wi-Fi / 有线 / VPN 才试；只剩蜂窝时不试
    var canReachPrivate: Bool { !physical.isEmpty || !vpn.isEmpty }

    /// 网络指纹：实体网卡的网段（不读 Wi-Fi 名）；只有蜂窝时为 cellular
    var fingerprint: String {
        let nets = physical.map { iface -> String in
            let net = iface.address & iface.netmask
            return "\(NetworkSnapshot.dotted(net))/\(iface.netmask.nonzeroBitCount)"
        }.sorted()
        if !nets.isEmpty { return nets.joined(separator: ",") }
        return cellular ? "cellular" : "none"
    }

    /// 主机（IPv4 字面量）和某块实体网卡在同一网段
    func sameSubnet(_ host: String) -> Bool {
        guard let ip = PlaybackNetwork.parseIPv4(host) else { return false }
        return physical.contains { $0.netmask != 0 && $0.netmask != .max && $0.address & $0.netmask == ip & $0.netmask }
    }

    /// 某块实体网卡落在这些网段（`192.168.1.0/24`）里
    func physicalIn(subnets: [String]) -> Bool {
        subnets.contains { subnet in
            let parts = subnet.split(separator: "/")
            guard parts.count == 2, let base = PlaybackNetwork.parseIPv4(String(parts[0])), let bits = Int(parts[1]), (0 ... 32).contains(bits)
            else { return false }
            let mask: UInt32 = bits == 0 ? 0 : .max << (32 - UInt32(bits))
            return physical.contains { $0.address & mask == base & mask }
        }
    }

    static func current() -> NetworkSnapshot {
        var snapshot = NetworkSnapshot(physical: [], vpn: [], cellular: false)
        for iface in interfaces() {
            switch kind(of: iface.name, address: iface.address) {
            case .physical: snapshot.physical.append(iface)
            case .vpn: snapshot.vpn.append(iface)
            case .cellular: snapshot.cellular = true
            case .other: break
            }
        }
        return snapshot
    }

    /// 本机开着的非回环 IPv4 网卡（只读本机，不发请求）
    static func interfaces() -> [Interface] {
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
            result.append(Interface(name: String(cString: item.ifa_name), address: ip, netmask: mask))
        }
        return result
    }

    enum Kind { case physical, vpn, cellular, other }

    /// 按网卡名分：en* 是 Wi-Fi / 有线，pdp_ip* 是蜂窝，utun / ipsec / ppp / tun / tap 是 VPN，其余（网桥、AWDL…）不算。
    /// 地址在 198.18.0.0/15 的隧道网卡不算 VPN：那是代理 App 的 TUN 模式（fake-ip），流量出公网而不是回家
    static func kind(of name: String, address: UInt32 = 0) -> Kind {
        if name.hasPrefix("en") { return .physical }
        if name.hasPrefix("pdp_ip") { return .cellular }
        if ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains(where: name.hasPrefix) {
            return address >> 17 == 0xC612 >> 1 ? .other : .vpn
        }
        return .other
    }

    static func dotted(_ ip: UInt32) -> String {
        "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }
}

/// 一轮选址跑完没有（故障转移等它时轮询）
private nonisolated final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

nonisolated extension Data {
    /// base64url（可无填充）
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
