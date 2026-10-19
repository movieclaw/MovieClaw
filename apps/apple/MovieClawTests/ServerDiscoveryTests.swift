import Foundation
import Testing
@testable import MovieClaw

/// 局域网自动发现里不碰网络的部分：应答解析、合并、候选地址推导、网段枚举
struct ServerDiscoveryTests {
    /// 与后端 `services/lan_discovery.py` 的 Jellyfin 应答同一形状
    @Test func parsesJellyfinReply() throws {
        let data = Data(#"{"Address": "http://192.168.1.10:3000", "Id": "abc", "Name": "MovieClaw", "EndpointAddress": null}"#.utf8)
        let reply = try #require(ServerDiscovery.parse(data, source: "192.168.1.10"))
        #expect(reply == .init(addresses: ["http://192.168.1.10:3000"], name: "MovieClaw", source: "192.168.1.10"))
    }

    /// 自家应答：一组地址，可以为空
    @Test func parsesNativeReply() throws {
        let data = Data(#"{"type": "movieclaw.discovery", "version": 1, "instance_id": "abc", "name": "客厅", "server_version": "0.41.0", "addresses": ["http://192.168.1.10:3300", "", 5, "https://m.example.com"]}"#.utf8)
        let reply = try #require(ServerDiscovery.parse(data, source: "192.168.1.10"))
        #expect(reply == .init(addresses: ["http://192.168.1.10:3300", "https://m.example.com"], name: "客厅", source: "192.168.1.10", native: true))
        let empty = try #require(ServerDiscovery.parse(Data(#"{"type": "movieclaw.discovery", "addresses": []}"#.utf8), source: "10.0.0.2"))
        #expect(empty.addresses.isEmpty && empty.name == "MovieClaw")
    }

    /// 新服务器对两句询问都应答：同一来源合并成一条，自家的地址在前
    @Test func mergesRepliesFromTheSameSource() {
        let jellyfin = ServerDiscovery.Reply(addresses: ["http://172.17.0.2:3000"], name: "NAS", source: "192.168.1.10")
        let native = ServerDiscovery.Reply(addresses: ["http://192.168.1.10:3300"], name: "NAS", source: "192.168.1.10", native: true)
        let other = ServerDiscovery.Reply(addresses: ["http://192.168.1.20:8096"], name: "Jellyfin", source: "192.168.1.20")
        #expect(ServerDiscovery.merged([jellyfin, other, native]) == [
            .init(addresses: ["http://192.168.1.10:3300", "http://172.17.0.2:3000"], name: "NAS", source: "192.168.1.10", native: true),
            other,
        ])
    }

    @Test func emptyNameFallsBackToMovieClaw() throws {
        let reply = try #require(ServerDiscovery.parse(Data(#"{"Address": "http://a:3000", "Name": ""}"#.utf8), source: "1.2.3.4"))
        #expect(reply.name == "MovieClaw")
    }

    @Test(arguments: ["", "who is JellyfinServer?", #"{"Name": "x"}"#, #"{"Address": ""}"#, "[1, 2]"])
    func rejectsNonReplies(raw: String) {
        #expect(ServerDiscovery.parse(Data(raw.utf8), source: "1.2.3.4") == nil)
    }

    /// 应答地址就是宿主地址：只有一个候选
    @Test func directAddressIsTheOnlyCandidate() {
        let reply = ServerDiscovery.Reply(addresses: ["http://192.168.1.10:3000"], name: "MovieClaw", source: "192.168.1.10")
        #expect(ServerDiscovery.candidates(for: reply).map(\.displayString) == ["http://192.168.1.10:3000"])
    }

    /// Docker 桥接且没配对外地址：后端报的是容器内网 IP，改用报文来源 IP，端口沿用应答里的
    @Test func dockerBridgeAddressFallsBackToSourceIP() {
        let reply = ServerDiscovery.Reply(addresses: ["http://172.17.0.2:8096"], name: "MovieClaw", source: "192.168.1.10")
        #expect(ServerDiscovery.candidates(for: reply).map(\.displayString) == [
            "http://172.17.0.2:8096",
            "http://192.168.1.10:8096",
            "http://192.168.1.10:3000",
        ])
    }

    /// 配了公网发布地址（无端口的 https）：公网地址优先，局域网退回默认端口
    @Test func publishedURLComesFirst() {
        let reply = ServerDiscovery.Reply(addresses: ["https://movie.example.com/"], name: "家里", source: "192.168.1.10")
        #expect(ServerDiscovery.candidates(for: reply).map(\.displayString) == [
            "https://movie.example.com",
            "http://192.168.1.10:3000",
        ])
    }

    /// 自家应答的地址列表为空（桥接部署、还没学到宿主地址）：只剩来源 IP + 默认端口；
    /// 学到的宿主端口 3300 也会和来源 IP 拼一份
    @Test func nativeAddressesAndTheirPortsComeFirst() {
        #expect(ServerDiscovery.candidates(for: .init(addresses: [], name: "m", source: "192.168.1.10", native: true))
            .map(\.displayString) == ["http://192.168.1.10:3000"])
        let reply = ServerDiscovery.Reply(addresses: ["http://10.0.0.5:3300", "https://m.example.com"], name: "m", source: "192.168.1.10", native: true)
        #expect(ServerDiscovery.candidates(for: reply).map(\.displayString) == [
            "http://10.0.0.5:3300",
            "https://m.example.com",
            "http://192.168.1.10:3300",
            "http://192.168.1.10:3000",
        ])
    }

    /// 手动输入只写了主机：依次试 3000、80、https；写了协议或端口就只用它自己
    @Test(arguments: [
        ("192.168.1.10", ["http://192.168.1.10:3000", "http://192.168.1.10", "https://192.168.1.10"]),
        ("nas.local/", ["http://nas.local:3000", "http://nas.local", "https://nas.local"]),
        ("192.168.1.10:3300", ["http://192.168.1.10:3300"]),
        ("192.168.1.10:80", ["http://192.168.1.10"]),
        ("http://192.168.1.10", ["http://192.168.1.10"]),
        ("https://movie.example.com", ["https://movie.example.com"]),
    ])
    func manualAlternatives(typed: String, expected: [String]) throws {
        let address = try ServerAddress(parsing: typed)
        #expect(ServerDiscovery.manualAlternatives(address, typed: typed).map(\.displayString) == expected)
    }

    @Test func slash24ListsAll254Hosts() {
        let hosts = ServerDiscovery.subnetHosts(address: ip("192.168.1.23"), netmask: ip("255.255.255.0"))
        #expect(hosts.count == 254)
        #expect(hosts.first.map(ServerDiscovery.dotted) == "192.168.1.1")
        #expect(hosts.last.map(ServerDiscovery.dotted) == "192.168.1.254")
        #expect(hosts.contains(ip("192.168.1.23")), "本机也要问：模拟器里本机就是跑服务端的 Mac")
    }

    /// 比 /24 宽的网段只扫本机所在的 /24
    @Test func widerMasksAreClampedTo24() {
        let hosts = ServerDiscovery.subnetHosts(address: ip("10.1.7.40"), netmask: ip("255.255.0.0"))
        #expect(hosts.count == 254)
        #expect(hosts.first.map(ServerDiscovery.dotted) == "10.1.7.1")
    }

    @Test func narrowMasksStayNarrow() {
        #expect(ServerDiscovery.subnetHosts(address: ip("192.168.1.5"), netmask: ip("255.255.255.252")).map(ServerDiscovery.dotted) == ["192.168.1.5", "192.168.1.6"])
        #expect(ServerDiscovery.subnetHosts(address: ip("192.168.1.5"), netmask: ip("255.255.255.255")).isEmpty)
    }

    @Test(arguments: [
        ("10.0.0.8", true), ("172.16.0.1", true), ("172.31.255.1", true), ("192.168.1.10", true),
        ("172.32.0.1", false), ("100.64.0.1", false), ("8.8.8.8", false), ("192.169.0.1", false),
    ])
    func privateRanges(address: String, expected: Bool) {
        #expect(ServerDiscovery.isPrivate(ip(address)) == expected)
    }

    private func ip(_ dotted: String) -> UInt32 {
        dotted.split(separator: ".").reduce(0) { $0 << 8 | UInt32($1)! }
    }
}
