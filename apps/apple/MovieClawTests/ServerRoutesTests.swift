import CryptoKit
import Foundation
import Testing
@testable import MovieClaw

/// 内外双地址的选址规则（docs/design/server-addresses.md §4）
struct ServerRoutesTests {
    private static let lan = ServerRoutes.Endpoint(origin: URL(string: "http://192.168.1.10:3300")!, kind: "lan")
    private static let wan = ServerRoutes.Endpoint(origin: URL(string: "https://movie.example.com")!, kind: "wan")

    private static func book(_ endpoints: [ServerRoutes.Endpoint] = [lan, wan], memory: [ServerRoutes.Book.Memory] = []) -> ServerRoutes.Book {
        ServerRoutes.Book(instanceId: "abc", hostKey: "", endpoints: endpoints, lanSubnets: ["192.168.1.0/24"], memory: memory)
    }

    private static func iface(_ name: String, _ ip: String, _ bits: Int = 24) -> NetworkSnapshot.Interface {
        NetworkSnapshot.Interface(name: name, address: PlaybackNetwork.parseIPv4(ip)!, netmask: .max << (32 - UInt32(bits)))
    }

    private static let home = NetworkSnapshot(physical: [iface("en0", "192.168.1.23")], vpn: [], cellular: false)
    private static let cafe = NetworkSnapshot(physical: [iface("en0", "10.0.0.8")], vpn: [], cellular: false)
    private static let cellular = NetworkSnapshot(physical: [], vpn: [], cellular: true)
    private static let cellularVPN = NetworkSnapshot(physical: [], vpn: [iface("utun4", "100.80.1.2", 32)], cellular: true)
    private static let server = ServerAddress(origin: URL(string: "http://192.168.1.10:3300")!)

    @Test func cellularOnlyNeverTriesThePrivateAddress() {
        #expect(ServerRoutes.candidates(book: Self.book(), server: Self.server, net: Self.cellular) == [Self.wan])
        #expect(ServerRoutes.candidates(book: Self.book(), server: Self.server, net: Self.cafe) == [Self.lan, Self.wan],
                "别人家的 Wi-Fi 也试：内网不通不耽误，外网 250 毫秒后照常接上")
        #expect(ServerRoutes.candidates(book: Self.book(), server: Self.server, net: Self.cellularVPN) == [Self.lan, Self.wan],
                "蜂窝上开着 VPN 回家：内网地址可能通")
    }

    @Test func optimisticGuessNeverSendsTheTokenToAnUnverifiedAddress() {
        let wanLogin = ServerAddress(origin: Self.wan.origin)
        // 登录地址就是内网的：在家直接用（和改造前一样）
        #expect(ServerRoutes.optimisticGuess(book: Self.book(), server: Self.server, net: Self.home)
            == ServerRoutes.Current(origin: Self.lan.origin, route: .lan))
        // 只有蜂窝：内网登录地址不用，先用 https 外网地址（证书验过主机名）
        #expect(ServerRoutes.optimisticGuess(book: Self.book(), server: Self.server, net: Self.cellular)
            == ServerRoutes.Current(origin: Self.wan.origin, route: .wan))
        // 用外网域名登录、这个网络记过内网 http 地址：不先用它——网段一样的别人家 Wi-Fi 指纹也一样，
        // 那个 192.168.1.10 可能是另一台机器。先用登录地址，等探测验过身份再换
        let rememberedLAN = Self.book(memory: [.init(fingerprint: Self.home.fingerprint, origin: Self.lan.origin)])
        #expect(ServerRoutes.optimisticGuess(book: rememberedLAN, server: wanLogin, net: Self.home)
            == ServerRoutes.Current(origin: Self.wan.origin, route: .wan))
        // 记过的是 https 地址：证书验过主机名，可以先用
        let httpsLAN = ServerRoutes.Endpoint(origin: URL(string: "https://nas.home.example.com")!, kind: "lan")
        let rememberedHTTPS = Self.book([httpsLAN, Self.wan], memory: [.init(fingerprint: Self.home.fingerprint, origin: httpsLAN.origin)])
        #expect(ServerRoutes.optimisticGuess(book: rememberedHTTPS, server: wanLogin, net: Self.home)?.origin == httpsLAN.origin)
        // 内网登录地址、在咖啡馆（不同网段、没有 VPN）：先用 https 外网地址，不让头一批请求等超时
        #expect(ServerRoutes.optimisticGuess(book: Self.book(), server: Self.server, net: Self.cafe)
            == ServerRoutes.Current(origin: Self.wan.origin, route: .wan))
        // 家里分了多个网段、这个网络记过内网登录地址：照旧直接用
        let multiSubnet = Self.book(memory: [.init(fingerprint: Self.cafe.fingerprint, origin: Self.lan.origin)])
        #expect(ServerRoutes.optimisticGuess(book: multiSubnet, server: Self.server, net: Self.cafe)?.origin == Self.lan.origin)
        // 内网登录地址 + 只有蜂窝 + 只有 http 外网地址：不先用任何地址（照旧登录地址，等探测）
        let httpWAN = ServerRoutes.Endpoint(origin: URL(string: "http://movie.example.com:8888")!, kind: "wan")
        #expect(ServerRoutes.optimisticGuess(book: Self.book([Self.lan, httpWAN]), server: Self.server, net: Self.cellular) == nil)
    }

    @Test func routeTellsVPNApartFromHome() {
        #expect(ServerRoutes.route(of: Self.lan, book: Self.book(), net: Self.home) == .lan)
        #expect(ServerRoutes.route(of: Self.lan, book: Self.book(), net: Self.cellularVPN) == .vpn)
        #expect(ServerRoutes.route(of: Self.wan, book: Self.book(), net: Self.home) == .wan)
        // 家里 DNS 指向内网的域名（手动标成内网）：本机在内网网段里就算家里，哪怕也开着 VPN
        let split = ServerRoutes.Endpoint(origin: URL(string: "https://nas.home.example.com")!, kind: "lan")
        let homeWithVPN = NetworkSnapshot(physical: Self.home.physical, vpn: Self.cellularVPN.vpn, cellular: false)
        #expect(ServerRoutes.route(of: split, book: Self.book([split, Self.wan]), net: homeWithVPN) == .lan)
        #expect(ServerRoutes.route(of: split, book: Self.book([split, Self.wan]), net: Self.cellularVPN) == .vpn)
        // 同一个域名，在咖啡馆经公网 DNS 连上：人在外面
        #expect(ServerRoutes.route(of: split, book: Self.book([split, Self.wan]), net: Self.cafe) == .wan)
        // 内网 IP 不同网段、没有 VPN：家里分了多个网段（路由器转过去的），仍算家里
        #expect(ServerRoutes.route(of: Self.lan, book: Self.book(), net: Self.cafe) == .lan)
    }

    @Test func otherAddressesOfTheServerCountAsItsOwn() {
        let server = ServerAddress(origin: URL(string: "http://10.9.8.6:3000")!)
        let other = ServerRoutes.Endpoint(origin: URL(string: "https://belongs-test.example.com")!, kind: "wan")
        ServerRoutes.shared.install(Self.book([ServerRoutes.Endpoint(origin: server.origin, kind: "lan"), other]), for: server)
        #expect(ServerRoutes.shared.belongs(URL(string: "https://belongs-test.example.com/library/3")!, to: server))
        #expect(ServerRoutes.shared.belongs(URL(string: "http://10.9.8.6:3000/library/3")!, to: server))
        #expect(!ServerRoutes.shared.belongs(URL(string: "https://example.org/x")!, to: server))
        #expect(ServerRoutes.shared.hostLabels(of: server).contains("belongs-test.example.com"))
    }

    @Test func healthProofMustVerifyWithThePinnedHostKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        var book = Self.book()
        book.hostKey = key.publicKey.rawRepresentation.base64URLEncoded()
        let nonce = "n0nce-AbCdEf_1234567"
        let signature = try key.signature(for: Data("movieclaw-health\nabc\n\(nonce)".utf8))
        func health(_ instance: String, _ proof: String?) throws -> API.HealthResponse {
            var json: [String: Any] = ["status": "ok", "service": "MovieClaw", "environment": "production", "spec_hash": "x",
                                       "version": "0.42.0", "instance_id": instance]
            if let proof { json["proof"] = proof }
            return try JSONDecoder().decode(API.HealthResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(ServerRoutes.verify(health: try health("abc", signature.base64URLEncoded()), nonce: nonce, book: book))
        #expect(!ServerRoutes.verify(health: try health("abc", signature.base64URLEncoded()), nonce: "other-nonce-123456", book: book),
                "换了随机串（录下来重放的应答）验不过")
        #expect(!ServerRoutes.verify(health: try health("zzz", signature.base64URLEncoded()), nonce: nonce, book: book), "别的实例")
        #expect(!ServerRoutes.verify(health: try health("abc", nil), nonce: nonce, book: book), "没有签名（冒充的旧版本）")
        let stranger = try Curve25519.Signing.PrivateKey().signature(for: Data("movieclaw-health\nabc\n\(nonce)".utf8))
        #expect(!ServerRoutes.verify(health: try health("abc", stranger.base64URLEncoded()), nonce: nonce, book: book),
                "同网段冒充实例号的另一台机器")
    }

    @Test func rewriteMovesAnyAddressOfTheServerToTheCurrentOne() {
        let server = ServerAddress(origin: URL(string: "http://10.9.8.7:3000")!)
        let other = ServerRoutes.Endpoint(origin: URL(string: "https://rewrite-test.example.com")!, kind: "wan")
        ServerRoutes.shared.install(Self.book([ServerRoutes.Endpoint(origin: server.origin, kind: "lan"), other]), for: server)
        ServerRoutes.shared.setCurrent(.init(origin: other.origin, route: .wan), for: server)
        defer { ServerRoutes.shared.setCurrent(nil, for: server) }
        // 图片按登录地址拼：换到当前地址，路径与查询不变
        let image = URL(string: "http://10.9.8.7:3000/api/v1/images/proxy?url=x&w=300")!
        #expect(ServerRoutes.shared.rewrite(image).absoluteString == "https://rewrite-test.example.com/api/v1/images/proxy?url=x&w=300")
        // 不认识的主机原样
        let tmdb = URL(string: "https://image.tmdb.org/t/p/w300/a.jpg")!
        #expect(ServerRoutes.shared.rewrite(tmdb) == tmdb)
        // 请求与取流地址都发到当前地址；身份（令牌、缓存键）仍是登录地址
        #expect(APIClient(server: server).url("/auth/me").absoluteString == "https://rewrite-test.example.com/api/v1/auth/me")
        #expect(server.resolve("/api/v1/playback/files/1/stream?token=t")?.absoluteString
            == "https://rewrite-test.example.com/api/v1/playback/files/1/stream?token=t")
        #expect(server.apiBase.absoluteString == "http://10.9.8.7:3000/api/v1")
        // 当前改回内网：断线前拼好的外网地址也换回来
        ServerRoutes.shared.setCurrent(.init(origin: server.origin, route: .lan), for: server)
        let probe = URL(string: "https://rewrite-test.example.com/api/v1/playback/files/1/stream?token=t")!
        #expect(ServerRoutes.shared.rewrite(probe).absoluteString == "http://10.9.8.7:3000/api/v1/playback/files/1/stream?token=t")
    }

    @Test func onlyReadRequestsAreRetriedOnAnotherAddress() throws {
        #expect(APIClient.shouldFailover(URLError(.cannotConnectToHost), method: "GET"))
        #expect(APIClient.shouldFailover(URLError(.timedOut), method: nil))
        #expect(!APIClient.shouldFailover(URLError(.cannotConnectToHost), method: "POST"), "写请求不自动重发")
        #expect(!APIClient.shouldFailover(URLError(.cancelled), method: "GET"))
        var request = URLRequest(url: URL(string: "http://192.168.1.10:3300/api/v1/libraries?x=1")!)
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        let moved = try #require(APIClient.retarget(request, to: URL(string: "https://movie.example.com")!))
        #expect(moved.url?.absoluteString == "https://movie.example.com/api/v1/libraries?x=1")
        #expect(moved.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }

    @Test func networkSnapshotRules() {
        #expect(NetworkSnapshot.kind(of: "en0") == .physical)
        #expect(NetworkSnapshot.kind(of: "pdp_ip0") == .cellular)
        #expect(NetworkSnapshot.kind(of: "utun3", address: PlaybackNetwork.parseIPv4("100.80.1.2")!) == .vpn)
        #expect(NetworkSnapshot.kind(of: "utun4", address: PlaybackNetwork.parseIPv4("198.18.0.1")!) == .other,
                "代理 App 的 TUN（fake-ip）不是回家的 VPN")
        #expect(NetworkSnapshot.kind(of: "utun4", address: PlaybackNetwork.parseIPv4("198.19.255.1")!) == .other)
        #expect(NetworkSnapshot.kind(of: "utun4", address: PlaybackNetwork.parseIPv4("198.20.0.1")!) == .vpn)
        #expect(NetworkSnapshot.kind(of: "awdl0") == .other)
        #expect(Self.home.fingerprint == "192.168.1.0/24")
        #expect(Self.cellular.fingerprint == "cellular")
        #expect(Self.cellularVPN.fingerprint == "cellular", "VPN 不进指纹：开关 VPN 不算换了网络")
        #expect(Self.home.physicalIn(subnets: ["192.168.1.0/24"]))
        #expect(!Self.cafe.physicalIn(subnets: ["192.168.1.0/24"]))
        #expect(ServerRoutes.guessKind(URL(string: "http://100.80.1.2:3000")!) == "wan")
        #expect(ServerRoutes.guessKind(URL(string: "http://nas.local")!) == "lan")
    }

    @Test func statusLine() {
        #expect(ServerRouteLabel.text(.init(origin: Self.lan.origin, route: .lan)) == "家里网络 · 192.168.1.10:3300")
        #expect(ServerRouteLabel.text(.init(origin: Self.wan.origin, route: .wan)) == "外网 · movie.example.com")
        #expect(ServerRouteLabel.text(.init(origin: Self.lan.origin, route: .vpn)) == "外网（经 VPN）· 192.168.1.10:3300")
        #expect(ServerRouteLabel.text(.init(origin: Self.lan.origin, route: nil)) == nil)
    }

    @Test func resumeDataBoundToAnOldAddressIsDropped() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "NSURLSessionDownloadURL": "http://192.168.1.10:3300/api/v1/offline/files/7/content",
            "NSURLSessionResumeBytesReceived": 1024,
        ] as [String: Any], format: .binary, options: 0)
        #expect(OfflineDownloader.resumeData(plist, matches: URL(string: "http://192.168.1.10:3300/api/v1/offline/files/7/content")!))
        #expect(!OfflineDownloader.resumeData(plist, matches: URL(string: "https://movie.example.com/api/v1/offline/files/7/content")!),
                "出门后地址换了：不拿旧地址续传")
        #expect(OfflineDownloader.resumeData(Data("garbage".utf8), matches: URL(string: "https://movie.example.com/x")!),
                "读不出地址照旧续传")
    }
}
