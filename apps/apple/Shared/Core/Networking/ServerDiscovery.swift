import Darwin
import Foundation

/// 局域网自动发现 MovieClaw 服务器，给欢迎页的「服务器地址」自动填值。
///
/// 协议（docs/design/lan-discovery.md）：后端监听 UDP 7359，收到「who is MovieClawServer?」就向发送方单播回
/// `{"type": "movieclaw.discovery", "name": …, "addresses": [按可信度排好的候选地址]}`。
/// 每个地址同时再问一句 Jellyfin 的「who is JellyfinServer?」：v0.40.0 及更早的服务器只认这一句，
/// 回的是 `{"Address": "http://192.168.1.10:3000", "Name": "MovieClaw", …}`。同一台服务器的两条应答合并成一份候选。
/// 服务器自己不主动广播，要客户端先问。
///
/// 为什么逐个单播、不发广播：
/// 1. iOS 上发 UDP 广播 / 组播必须向苹果单独申请 multicast 权限（com.apple.developer.networking.multicast），
///    没有它发往广播地址会直接失败；逐个单播只需要 App 已有的「本地网络」权限；
/// 2. Docker 桥接部署时广播报文进不了容器，发给宿主 IP 的单播却能经 `-p 7359:7359/udp` 端口映射转进去。
/// 所以对手机所在网段（最多一个 /24，254 个地址）逐个发一遍询问，再收集应答。
///
/// 应答里的地址不一定能直接用：桥接部署时容器里探测不到宿主的局域网 IP，后端只能报浏览器访问时记下的地址、
/// 「设置 → 网络」的外部访问地址（可能是公网域名，家里的网络未必能回环访问），老版本甚至报容器内网 IP（如 172.17.0.2）。
/// 这些情况下应答报文的来源 IP 才是宿主的真实地址。于是按「应答地址 → 来源 IP + 应答里出现过的端口 → 来源 IP + 默认 3000」
/// 依次试 `/api/v1/health`，第一个确认是 MovieClaw 的才算数——这一步也顺带排除了局域网里真正的 Jellyfin。
nonisolated enum ServerDiscovery {
    /// 发现结果
    struct Found: Equatable, Sendable {
        let address: ServerAddress
        /// 服务器名（默认 MovieClaw）
        let name: String
    }

    /// 一条自动发现应答（或同一来源的几条合并后的结果）
    struct Reply: Equatable, Sendable {
        /// 自家应答的 addresses，或 Jellyfin 应答的 Address
        let addresses: [String]
        let name: String
        /// 应答报文的来源 IP
        let source: String
        /// 是不是自家协议的应答（合并时排在 Jellyfin 应答前面）
        var native = false
    }

    static let port: UInt16 = 7359
    /// 自家询问在前；Jellyfin 的询问与 Jellyfin 客户端发的一字不差（后端按大小写不敏感的包含关系匹配）
    static let queries = ["who is MovieClawServer?", "who is JellyfinServer?"]
    /// 后端对外端口的默认值（docker-compose 的 3000:3000）
    static let defaultPort = 3000

    /// 找第一台可用的 MovieClaw：每轮对整个网段问一遍、等 1.2 秒收应答，最多 `rounds` 轮，找到即返回。
    ///
    /// 要扫多轮，是因为第一次发包会弹出系统的「本地网络」授权框，用户点「允许」之前发的包都会被系统丢掉；
    /// 授权之后的下一轮才真正发得出去。手机没连 Wi-Fi（找不到私有网段）时直接返回空。
    static func findFirst(rounds: Int = 8, interval: Duration = .seconds(2)) async -> Found? {
        let hosts = localHosts()
        guard !hosts.isEmpty else { return nil }
        for round in 0 ..< rounds {
            guard !Task.isCancelled else { return nil }
            let replies = await Task.detached(priority: .utility) {
                sweep(hosts: hosts, listen: 1.2)
            }.value
            for reply in merged(replies) {
                if let address = await firstMovieClaw(in: candidates(for: reply)) {
                    return Found(address: address, name: reply.name)
                }
            }
            if round < rounds - 1 {
                do { try await Task.sleep(for: interval) } catch { return nil }
            }
        }
        return nil
    }

    // MARK: - 地址推导（纯函数，有单元测试）

    /// 一条应答可能对应的服务器地址，按可信度排序、去重
    static func candidates(for reply: Reply) -> [ServerAddress] {
        var list: [ServerAddress] = []
        func add(_ raw: String) {
            if let address = try? ServerAddress(parsing: raw), !list.contains(address) {
                list.append(address)
            }
        }
        reply.addresses.forEach(add)
        for port in reply.addresses.compactMap({ URLComponents(string: $0)?.port }) + [defaultPort] {
            add("http://\(reply.source):\(port)")
        }
        return list
    }

    /// 解析应答报文；不是合法的发现应答（不是 JSON、Jellyfin 应答没有 Address）返回 nil。
    /// 自家应答的地址列表可以为空：桥接部署又没学到宿主地址时，只能靠来源 IP 拼
    static func parse(_ data: Data, source: String) -> Reply? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func name(_ key: String) -> String {
            (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "MovieClaw"
        }
        if object["type"] as? String == "movieclaw.discovery" {
            let addresses = (object["addresses"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            return Reply(addresses: addresses, name: name("name"), source: source, native: true)
        }
        guard let address = object["Address"] as? String, !address.isEmpty else { return nil }
        return Reply(addresses: [address], name: name("Name"), source: source)
    }

    /// 同一来源 IP 的应答合并成一条（自家应答的地址与名字在前），按首次出现的顺序
    static func merged(_ replies: [Reply]) -> [Reply] {
        var sources: [String] = []
        var groups: [String: [Reply]] = [:]
        for reply in replies {
            if groups[reply.source] == nil { sources.append(reply.source) }
            groups[reply.source, default: []].append(reply)
        }
        return sources.map { source in
            let group = groups[source]!.filter(\.native) + groups[source]!.filter { !$0.native }
            var addresses: [String] = []
            for address in group.flatMap(\.addresses) where !addresses.contains(address) {
                addresses.append(address)
            }
            return Reply(addresses: addresses, name: group[0].name, source: source, native: group[0].native)
        }
    }

    /// 手动输入的地址只写了主机（没写协议也没写端口，如 `192.168.1.10`）时，依次试 `http://主机:3000`、`http://主机`、
    /// `https://主机` 的健康检查，用第一个确认是 MovieClaw 的；都不是就原样返回，让后面的登录步骤报出连不上的原因
    static func settle(_ address: ServerAddress, typed raw: String) async -> ServerAddress {
        let alternatives = manualAlternatives(address, typed: raw)
        guard alternatives.count > 1 else { return address }
        return await firstMovieClaw(in: alternatives) ?? address
    }

    /// `settle` 要试的地址；输入里写了协议或端口时只有它自己
    static func manualAlternatives(_ address: ServerAddress, typed raw: String) -> [ServerAddress] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.contains("://"),
            let components = URLComponents(string: "http://\(trimmed)"), components.port == nil,
            let host = address.origin.host
        else { return [address] }
        let hostText = host.contains(":") ? "[\(host)]" : host
        return ["http://\(hostText):\(defaultPort)", "http://\(hostText)", "https://\(hostText)"]
            .compactMap { try? ServerAddress(parsing: $0) }
    }

    /// 某个 IPv4 地址所在网段里要问的全部主机（主机字节序）。
    /// 掩码比 /24 宽（如公司网的 /16）时只扫本机所在的 /24：六万多个地址逐个问太慢，家庭网络也几乎都是 /24。
    /// 本机地址也在其中：模拟器里「本机」就是跑着服务端的那台 Mac。
    static func subnetHosts(address: UInt32, netmask: UInt32) -> [UInt32] {
        let mask = netmask | 0xFFFF_FF00
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network &+ 1 else { return [] }
        return Array((network + 1) ..< broadcast)
    }

    /// 私有网段（RFC 1918）：只在家庭 / 公司局域网里扫，蜂窝网络、公网地址一概不碰
    static func isPrivate(_ address: UInt32) -> Bool {
        address >> 24 == 10 || address >> 20 == 0xAC1 || address >> 16 == 0xC0A8
    }

    // MARK: - 网络

    /// 手机当前连着的局域网（Wi-Fi / 有线的 en* 接口）里要问的全部地址；最多 1024 个
    private static func localHosts() -> [UInt32] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var hosts: [UInt32] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard
                flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                String(cString: entry.pointee.ifa_name).hasPrefix("en"),
                let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                let netmask = entry.pointee.ifa_netmask
            else { continue }
            let ip = ipv4(address), mask = ipv4(netmask)
            guard isPrivate(ip) else { continue }
            for host in subnetHosts(address: ip, netmask: mask) where !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return Array(hosts.prefix(1024))
    }

    /// 对每个地址发一次询问，然后在 `listen` 秒内收集所有应答
    private static func sweep(hosts: [UInt32], listen: TimeInterval) -> [Reply] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        // 收包超时 150 毫秒：没有应答时 recvfrom 按时返回，好检查截止时间
        var timeout = timeval(tv_sec: 0, tv_usec: 150_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let messages = queries.map { Array($0.utf8) }
        for (index, host) in hosts.enumerated() {
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = port.bigEndian
            target.sin_addr = in_addr(s_addr: host.bigEndian)
            for message in messages {
                _ = withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            // 每 16 个地址（32 个包）歇 2 毫秒：一口气灌几百个包，网卡发送队列满了会丢包（ENOBUFS）
            if index % 16 == 15 { usleep(2000) }
        }

        var replies: [Reply] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(listen)
        while Date() < deadline, !Task.isCancelled {
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { continue }
            let from = UInt32(bigEndian: source.sin_addr.s_addr)
            if let reply = parse(Data(buffer[0 ..< count]), source: dotted(from)), !replies.contains(reply) {
                replies.append(reply)
            }
        }
        return replies
    }

    /// 在候选地址里找第一个确认是 MovieClaw 的：并发探测，按候选顺序取第一个通过的
    private static func firstMovieClaw(in candidates: [ServerAddress]) async -> ServerAddress? {
        let passed = await withTaskGroup(of: Int?.self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { await isMovieClaw(candidate) ? index : nil }
            }
            var indexes: [Int] = []
            for await index in group {
                if let index { indexes.append(index) }
            }
            return indexes
        }
        return passed.min().map { candidates[$0] }
    }

    /// 探测会话：不带 Cookie、不落缓存，免得污染登录用的共享会话
    private static let probeSession = URLSession(configuration: .ephemeral)

    /// `GET /api/v1/health` 返回 `status: ok` 才算 MovieClaw。超时压到 2.5 秒：
    /// 容器内网 IP 这类候选从手机上根本路由不到，不能让它拖住整个发现过程
    private static func isMovieClaw(_ server: ServerAddress) async -> Bool {
        var request = URLRequest(url: server.apiBase.appending(path: "health"), timeoutInterval: 2.5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await probeSession.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["status"] as? String == "ok"
    }

    private static func ipv4(_ address: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }

    static func dotted(_ address: UInt32) -> String {
        "\(address >> 24).\((address >> 16) & 0xFF).\((address >> 8) & 0xFF).\(address & 0xFF)"
    }
}
