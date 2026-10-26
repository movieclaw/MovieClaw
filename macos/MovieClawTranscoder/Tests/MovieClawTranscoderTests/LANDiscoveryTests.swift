import Darwin
import XCTest

@testable import MovieClawTranscoder

/// 局域网发现的解析与目标计算（docs/design/device-auth.md §6.5）。
///
/// 真广播在 CI 里既不可控也不该发，所以这里只测能确定的两件事：
/// 应答报文怎么解析、往哪些地址发。
final class LANDiscoveryTests: XCTestCase {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func parse(_ json: String) -> LANDiscovery.Reply? {
        LANDiscovery.parse(data(json), source: "10.1.1.5")
    }

    func testParsesJellyfinReply() throws {
        let reply = try XCTUnwrap(parse(#"{"Address":"http://10.1.1.5:3000","Id":"abc","Name":"客厅 NAS"}"#))
        XCTAssertFalse(reply.native)
        XCTAssertEqual(reply.server.address, "http://10.1.1.5:3000")
        XCTAssertEqual(reply.server.name, "客厅 NAS")
        XCTAssertEqual(reply.server.displayName, "客厅 NAS")
    }

    /// 自家应答取服务端排好的第一个地址；列表为空时退回来源 IP + 3000。
    func testParsesNativeReply() throws {
        let reply = try XCTUnwrap(parse(#"{"type":"movieclaw.discovery","version":1,"name":"客厅 NAS","addresses":["","http://192.168.1.10:3300","https://m.example.com"]}"#))
        XCTAssertTrue(reply.native)
        XCTAssertEqual(reply.server, LANDiscovery.Server(address: "http://192.168.1.10:3300", name: "客厅 NAS"))
        let empty = try XCTUnwrap(parse(#"{"type":"movieclaw.discovery","addresses":[]}"#))
        XCTAssertEqual(empty.server, LANDiscovery.Server(address: "http://10.1.1.5:3000", name: ""))
    }

    /// 服务端没配名字时不能在界面上显示空白。
    func testFallsBackToGenericName() throws {
        let server = try XCTUnwrap(parse(#"{"Address":"http://10.1.1.5:3000"}"#)).server
        XCTAssertEqual(server.name, "")
        XCTAssertEqual(server.displayName, "movieclaw")
    }

    /// 局域网里什么都可能往这个端口发，解析不了的一律跳过而不是崩。
    func testIgnoresGarbage() {
        XCTAssertNil(parse("不是 JSON"))
        XCTAssertNil(parse("[1,2,3]"))
        XCTAssertNil(parse(#"{"Name":"缺地址"}"#))
        XCTAssertNil(parse(#"{"Address":""}"#))
    }

    /// 受限广播必须永远在列表里：逐网卡枚举可能一无所获（虚拟机、无网卡环境），
    /// 那时它是唯一的出路。
    func testAlwaysBroadcastsToLimitedAddress() throws {
        let targets = LANDiscovery.broadcastTargets()
        let first = try XCTUnwrap(targets.first)
        XCTAssertEqual(first.sin_addr.s_addr, INADDR_BROADCAST.bigEndian)
        XCTAssertEqual(first.sin_port, LANDiscovery.port.bigEndian)
        XCTAssertEqual(first.sin_family, sa_family_t(AF_INET))
    }

    /// 广播目标不重复：多网卡机器上同一网段可能被枚举到两次。
    func testBroadcastTargetsAreUnique() {
        let addresses = LANDiscovery.broadcastTargets().map(\.sin_addr.s_addr)
        XCTAssertEqual(addresses.count, Set(addresses).count)
    }
}
