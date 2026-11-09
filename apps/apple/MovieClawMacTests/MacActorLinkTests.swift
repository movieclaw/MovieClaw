import Foundation
import Testing
@testable import MovieClaw

/// Mac 版：详情页没有影人 id 的演员卡 → 同库按演员筛的海报墙（`AppRoute.library(_, actor:)`）
struct MacActorLinkTests {
    @Test func castCardTargetsAndRoute() {
        #expect(CastLink.resolve(personId: 31, name: "张三", isActor: true, libraryId: 3) == .person(tmdbId: 31))
        #expect(CastLink.resolve(personId: nil, name: " 张三 ", isActor: true, libraryId: 3) == .libraryActor(libraryId: 3, actor: "张三"))
        #expect(CastLink.resolve(personId: nil, name: "导演甲", isActor: false, libraryId: 3) == nil)
        // 原有的压栈点（首页「我的媒体库」、调试驱动）不带演员，含义不变
        #expect(AppRoute.library(3) == AppRoute.library(3, actor: nil))
        #expect(AppRoute.library(3) != AppRoute.library(3, actor: "张三"))
    }

    @Test func wallRequestCarriesActor() async throws {
        let host = "mac-actor-\(UUID().uuidString.lowercased()).test"
        MacActorRequestLog.shared.install(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MacActorRecordingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MacActorRequestLog.shared.remove(host: host) }
        let api = APIClient(server: ServerAddress(origin: try #require(URL(string: "http://\(host)"))), session: session)
        // 与 MacLibraryView.reload 同一个调用
        _ = try? await api.libraryItemsList(libraryId: 3, sort: "added_at", order: nil, limit: 60, offset: 0, w: nil, actor: "张三")
        _ = try? await api.libraryItemsList(libraryId: 3, sort: "added_at", order: nil, limit: 60, offset: 0, w: nil, actor: nil)
        let queries = MacActorRequestLog.shared.urls(host: host).map {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? []
        }
        #expect(queries.count == 2)
        #expect(queries.first?.first { $0.name == "actor" }?.value == "张三")
        #expect(queries.last?.contains { $0.name == "actor" } == false)
    }
}

private nonisolated final class MacActorRequestLog: @unchecked Sendable {
    static let shared = MacActorRequestLog()
    private let lock = NSLock()
    private var log: [String: [URL]] = [:]

    func install(host: String) { lock.withLock { log[host] = [] } }
    func remove(host: String) { lock.withLock { log[host] = nil } }
    func knows(host: String) -> Bool { lock.withLock { log[host] != nil } }
    func record(_ url: URL) {
        guard let host = url.host else { return }
        lock.withLock {
            log[host]?.append(url)
            return
        }
    }
    func urls(host: String) -> [URL] { lock.withLock { log[host] ?? [] } }
}

private nonisolated final class MacActorRecordingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host.map { MacActorRequestLog.shared.knows(host: $0) } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        MacActorRequestLog.shared.record(url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"success":true,"data":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
