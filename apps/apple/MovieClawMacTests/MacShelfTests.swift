import Foundation
import Testing
@testable import MovieClaw

struct MacShelfTests {
    @Test func restoringCachedSearchClearsFeedbackAndKeepsPagination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(server: ServerAddress(origin: URL(string: "http://search.test")!), session: session)
        let model = MacSearchModel()
        let cached = MacSearchInput(query: "1917", personId: nil)
        await model.search(api: api, input: cached, immediately: true)
        #expect(model.loadedInput == cached)
        #expect(model.nextCursor == "next-page")

        let pending = Task { await model.search(api: api, input: .init(query: "1917x", personId: nil)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.searching)
        pending.cancel()
        await pending.value
        await model.search(api: api, input: cached)
        #expect(!model.searching)
        #expect(!model.requesting)
        #expect(model.failed == nil)
        #expect(model.nextCursor == "next-page")
    }

    @Test func cancelledDebounceKeepsFeedbackUntilTheNextInput() async throws {
        let model = MacSearchModel()
        let api = APIClient(server: ServerAddress(origin: URL(string: "http://localhost:1")!))
        await model.search(api: api, input: .init(query: "", personId: nil))
        let pending = Task { await model.search(api: api, input: .init(query: "a", personId: nil)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.searching)
        #expect(!model.requesting)
        pending.cancel()
        await pending.value
        #expect(model.searching)
        await model.search(api: api, input: .init(query: "", personId: nil))
        #expect(!model.searching)
        #expect(!model.requesting)
    }

    @Test func typingDoesNotRewriteAnEmptyNavigationStack() {
        let router = MacRouter(selection: .home)
        router.paths[.search] = []
        router.searchText = "a"
        #expect(router.isSearching)
        #expect(router.paths[.search] == [])
        router.paths[.search] = [.item(libraryId: 19, itemId: 7181)]
        router.searchText = "ab"
        #expect(router.paths[.search] == nil)
        router.searchText = " \n "
        #expect(!router.isSearching)
    }

    @Test func pagesPreserveOverlapAndStopAtBothEnds() {
        let metrics = MacShelfScrollMetrics()
        metrics.viewport = 900
        metrics.contentWidth = 2400
        #expect(metrics.target(direction: -1) == 0)
        #expect(metrics.target(direction: 1) == 756)
        metrics.offset = 756
        #expect(metrics.target(direction: 1) == 1500)
        metrics.offset = 1500
        #expect(metrics.target(direction: 1) == 1500)
        #expect(metrics.target(direction: -1) == 744)
    }

    @Test func resizeAndShortRowsNeverScrollPastTheContent() {
        let metrics = MacShelfScrollMetrics()
        metrics.viewport = 900
        metrics.contentWidth = 600
        #expect(metrics.target(direction: 1) == 0)
        metrics.contentWidth = 2400
        metrics.offset = 1500
        metrics.viewport = 1400
        #expect(metrics.target(direction: 1) == 1000)
    }
}

private nonisolated final class SearchResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "search.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"success":true,"data":{"query":"1917","items":[],"people":[],"suggestions":[],"next_cursor":"next-page","index_pending":false}}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
