import Foundation
import Testing
@testable import MovieClaw

/// 本地/NFO 库点演员 → 同库按演员筛的墙（网页 8540a15bc 的 iPhone / iPad 版）：
/// 条件模型、接口参数展开、演员卡的去向、`/library/{id}?actor=` 深链与 iPad 侧边栏
struct LibraryActorFilterTests {
    @Test func actorIsTrimmedCountedAndKeyedButNeverSavedAsRule() {
        var filter = LibraryFilter(genres: [18], actor: "  张三 ")
        #expect(filter.actorName == "张三")
        #expect(!filter.isEmpty)
        #expect(filter.count == 2)
        #expect(filter.key != LibraryFilter(genres: [18]).key)
        #expect(filter.key == LibraryFilter(genres: [18], actor: "张三").key)
        // 条件 chip：演员一维，取值就是姓名；✕ 摘掉
        #expect(LibraryFilter.dimensions.contains { $0.key == "actor" })
        #expect(filter.values(of: "actor") == ["张三"])
        // 合集规则没有演员这一维：不写进去（存为合集入口在有演员条件时隐藏）
        #expect(LibraryFilter(actor: "张三").rules.isEmpty)
        filter.remove("actor", "张三")
        #expect(filter.actor == nil)
        #expect(filter.count == 1)
    }

    @Test(arguments: [nil, "", "   ", "\n"] as [String?])
    func blankActorIsNoCondition(_ raw: String?) {
        let filter = LibraryFilter(actor: raw)
        #expect(filter.actorName == nil)
        #expect(filter.isEmpty)
        #expect(filter.count == 0)
        #expect(filter.key == "")
        #expect(!filter.queryItems.contains { $0.name == "actor" })
    }

    @Test func deepLinkQueryRoundTrips() throws {
        let filter = try #require(LibraryFilter(query: ["actor": " 张三 ", "g": "18"]))
        #expect(filter.actor == "张三")
        #expect(filter.genres == [18])
        #expect(filter.queryItems.first { $0.name == "actor" }?.value == "张三")
        #expect(LibraryFilter(query: ["actor": "  "]) == nil)
    }

    @Test func everyWallEndpointSendsTheSameActor() async throws {
        let host = "actor-filter-\(UUID().uuidString.lowercased()).test"
        let (api, session) = try recordingAPI(host: host)
        defer { session.invalidateAndCancel(); ActorRequestLog.shared.remove(host: host) }
        let filter = LibraryFilter(genres: [18], actor: "  张三 ")
        _ = try? await api.libraryItemsFiltered(libraryId: 7, filter: filter, sort: nil, order: nil, limit: 60, offset: 0)
        _ = try? await api.libraryFacetsFiltered(libraryId: 7, filter: filter, allTiers: false)
        _ = try? await api.libraryIndexFiltered(libraryId: 7, filter: filter, sort: "title", order: nil)
        _ = try? await api.libraryRelaxFiltered(libraryId: 7, filter: filter)
        _ = try? await api.libraryGalleryFiltered(libraryId: 7, filter: filter, sort: nil, order: nil, limit: 60, offset: 0)
        let urls = ActorRequestLog.shared.urls(host: host).filter { $0.path.hasPrefix("/api/v1/libraries/7/") }
        #expect(Set(urls.map(\.path)) == [
            "/api/v1/libraries/7/items", "/api/v1/libraries/7/facets", "/api/v1/libraries/7/item-index",
            "/api/v1/libraries/7/relax", "/api/v1/libraries/7/gallery",
        ])
        for url in urls {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.filter { $0.name == "actor" }.map(\.value) == ["张三"], "\(url.path) 要带去过空白的演员名")
            #expect(items.first { $0.name == "g" }?.value == "18")
        }
    }

    @Test func blankActorIsNotSent() async throws {
        let host = "actor-filter-\(UUID().uuidString.lowercased()).test"
        let (api, session) = try recordingAPI(host: host)
        defer { session.invalidateAndCancel(); ActorRequestLog.shared.remove(host: host) }
        _ = try? await api.libraryItemsFiltered(libraryId: 7, filter: LibraryFilter(actor: " "), sort: nil, order: nil, limit: 60, offset: 0)
        let url = try #require(ActorRequestLog.shared.urls(host: host).first { $0.path == "/api/v1/libraries/7/items" })
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!items.contains { $0.name == "actor" })
    }

    @Test func castCardTarget() {
        // TMDB 影人 id 优先：演员、导演都进影人页
        #expect(CastLink.resolve(personId: 31, name: "张三", isActor: true, libraryId: 7) == .person(tmdbId: 31))
        #expect(CastLink.resolve(personId: 31, name: "导演甲", isActor: false, libraryId: 7) == .person(tmdbId: 31))
        // 没有影人 id 的演员：同库按（去过空白的）演员名筛
        #expect(CastLink.resolve(personId: nil, name: " 张三 ", isActor: true, libraryId: 7) == .libraryActor(libraryId: 7, actor: "张三"))
        #expect(CastLink.resolve(personId: nil, name: "张三", isActor: true, libraryId: 7)?.opensLibrary == true)
        // 没有影人 id 的导演、空白名：静态卡
        #expect(CastLink.resolve(personId: nil, name: "导演甲", isActor: false, libraryId: 7) == nil)
        #expect(CastLink.resolve(personId: nil, name: "  ", isActor: true, libraryId: 7) == nil)
    }

    @Test(arguments: [
        ("/library/19?actor=%20%E5%BC%A0%E4%B8%89%20", AppRoute.library(id: 19, actor: "张三")),
        ("/library/19?actor=Tom%20Hanks&view=items", AppRoute.library(id: 19, view: "items", actor: "Tom Hanks")),
        ("/library/19?actor=%20", AppRoute.library(id: 19)),
    ])
    func parsesActorDeepLink(path: String, expected: AppRoute) {
        #expect(AppRoute(webPath: path) == expected)
    }

    /// iPad：侧边栏列着这个库时，不带条件的库链接直接选中侧边栏那一项；带演员的要压栈，否则条件就丢了
    @MainActor
    @Test func actorLinkPushesEvenForSidebarLibrary() {
        let router = Router()
        router.adoptSidebarLibraries([19])
        router.select(.mediaLibrary(19))
        router.open(.library(id: 19, actor: "张三"))
        #expect(router.selection == .mediaLibrary(19))
        #expect(router.currentPath == [.library(id: 19, actor: "张三")])
        // 冷启动清单晚到：带演员的库页也不被改成侧边栏选中
        let cold = Router()
        #expect(cold.open(webPath: "/library/19?actor=%E5%BC%A0%E4%B8%89"))
        cold.adoptSidebarLibraries([19])
        #expect(cold.selection == .tab(.library))
        #expect(cold.currentPath == [.library(id: 19, actor: "张三")])
    }

    private func recordingAPI(host: String) throws -> (APIClient, URLSession) {
        ActorRequestLog.shared.install(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActorRecordingProtocol.self]
        let session = URLSession(configuration: configuration)
        let origin = try #require(URL(string: "http://\(host)"))
        return (APIClient(server: ServerAddress(origin: origin), session: session), session)
    }
}

/// 按主机记下发出的请求（测试并行跑，各用各的主机名）
private nonisolated final class ActorRequestLog: @unchecked Sendable {
    static let shared = ActorRequestLog()
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

/// 只记请求、回一个解不出来的空信封：这里只关心查询参数，不关心解码
private nonisolated final class ActorRecordingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host.map { ActorRequestLog.shared.knows(host: $0) } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        ActorRequestLog.shared.record(url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"success":true,"data":null}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
