import Darwin
import Foundation

/// 局域网里找 movieclaw（docs/design/device-auth.md §6.5）。
///
/// 协议见 docs/design/lan-discovery.md：往 UDP 7359 广播两句询问——自家的
/// `who is MovieClawServer?`（应答一组按可信度排好的地址）与 Jellyfin 的
/// `who is JellyfinServer?`（v0.40.0 及更早的服务器只认这一句，应答一个 `Address`）。
/// 同一来源 IP 的应答只留一条，自家的优先。mclaw CLI 用的是同一套
/// （`cli/internal/discover`），两边行为保持一致。
///
/// **它只是省掉一次手打，不是必需路径**。这些情况下找不到，地址输入框
/// 因此永远保留：
///
///   1. 服务端停用了「局域网发现」，或 Docker 部署没映射 UDP 7359；
///   2. 桥接网络部署下服务端还不知道宿主地址（自报的连不上）；
///   3. 跨网段、VPN、公网——广播出不去；
///   4. UDP 7359 被别的程序占了。
///
/// 另外要留意：服务端优先返回用户配的「对外访问地址」，那可能是反向代理域名。
/// 对 Worker 来说走反代明显更慢（要来回传大量视频分片），所以发现到的地址只
/// **填进输入框供用户过目**，不直接保存——最终用哪个地址是用户的决定。
///
/// 与 CLI 的一处有意差异：mclaw 拿到地址后会自己打一次 `/health` 确认对面是
/// movieclaw（局域网里的真 Jellyfin 会应答同一句问询），Worker 这边不做——
/// 紧接着的「连接并配对」按下去就是同一个检查，而且结论直接显示在窗口里。
/// 在这里再探一次只是把同一件事做两遍。
enum LANDiscovery {
    /// 一台应答了发现请求的服务器。
    struct Server: Equatable {
        /// 服务端自报的完整地址（含协议与端口）。
        let address: String
        /// 服务器名，用于在多台之间区分。
        let name: String
    }

    /// 一帧应答：解析出的服务器，以及是不是自家协议的应答。
    struct Reply: Equatable {
        let server: Server
        let native: Bool
    }

    /// 与服务端 `services/lan_discovery.py` 的 DISCOVERY_PORT 一致。
    static let port: UInt16 = 7359
    /// 服务端认的两句暗号（大小写不敏感），自家的在前。
    private static let probes = ["who is MovieClawServer?", "who is JellyfinServer?"]

    /// 广播一次并收集 timeout 内的全部应答，按地址去重。
    ///
    /// 这是**阻塞调用**（BSD socket + 读超时），必须在后台线程执行。
    /// 找不到不是错误：局域网里没有、或者不在同一网段都是正常情况，
    /// 调用方据空数组提示用户手填即可。
    static func find(timeout: TimeInterval) -> [Server] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        // 内核默认拒绝往广播地址发包；不开这个选项 sendto 直接失败，
        // 那种失败会被误当成「局域网里没有 movieclaw」。
        var enable: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST,
                         &enable, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return []
        }
        var readTimeout = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                       &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        var sent = 0
        for target in broadcastTargets() {
            for probe in probes {
                var addr = target
                let bytes = Array(probe.utf8)
                let result = withUnsafePointer(to: &addr) { pointer -> Int in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if result > 0 { sent += 1 }
            }
        }
        guard sent > 0 else { return [] }

        let deadline = Date().addingTimeInterval(timeout)
        var replies: [Reply] = []
        var sources: [String] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            // 读超时（EAGAIN）或出错都表示本轮结束，这是正常出口
            guard count > 0 else { break }
            let source = String(cString: inet_ntoa(from.sin_addr))
            guard let reply = parse(Data(buffer[0..<count]), source: source) else { continue }
            // 同一来源只留一条：新服务器两句都答，自家的应答优先
            if let index = sources.firstIndex(of: source) {
                if reply.native && !replies[index].native { replies[index] = reply }
                continue
            }
            sources.append(source)
            replies.append(reply)
        }
        var seen = Set<String>()
        return replies.map(\.server).filter { seen.insert($0.address).inserted }
    }

    /// 解析一帧应答。非 JSON、Jellyfin 应答缺 Address 的都跳过——局域网里什么都可能往这个端口发。
    /// 自家应答取地址列表的第一个（服务端已按可信度排好，局域网地址在公网域名前面）；
    /// 列表为空（桥接部署、服务端还不知道宿主地址）时用来源 IP + 默认端口 3000。
    static func parse(_ data: Data, source: String) -> Reply? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let payload = object as? [String: Any]
        else { return nil }
        if payload["type"] as? String == "movieclaw.discovery" {
            let addresses = (payload["addresses"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            let address = addresses.first ?? "http://\(source):3000"
            return Reply(server: Server(address: address, name: (payload["name"] as? String) ?? ""), native: true)
        }
        guard let address = payload["Address"] as? String, !address.isEmpty else { return nil }
        return Reply(server: Server(address: address, name: (payload["Name"] as? String) ?? ""), native: false)
    }

    /// 要发往的广播地址。
    ///
    /// 除了受限广播 255.255.255.255，还要逐网卡取定向广播地址：多网卡机器
    /// （有线 + 无线、虚拟机网桥）上，受限广播只会从内核选的那一张网卡出去，
    /// 服务器恰好在另一张网卡那侧就找不到了。
    static func broadcastTargets() -> [sockaddr_in] {
        var targets = [makeAddress(INADDR_BROADCAST)]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return targets }
        defer { freeifaddrs(head) }

        var seen = Set<UInt32>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            guard
                let raw = entry.pointee.ifa_dstaddr,
                raw.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let broadcast = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            guard broadcast != 0, seen.insert(broadcast).inserted else { continue }
            targets.append(makeAddress(broadcast, alreadyNetworkOrder: true))
        }
        return targets
    }

    private static func makeAddress(_ address: in_addr_t, alreadyNetworkOrder: Bool = false) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = alreadyNetworkOrder ? address : address.bigEndian
        return addr
    }
}

extension LANDiscovery.Server {
    /// 界面上显示的名字；服务端没配名字时不显示空白。
    var displayName: String { name.isEmpty ? "movieclaw" : name }
}
