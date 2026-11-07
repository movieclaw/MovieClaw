import Foundation
import Testing
@testable import MovieClaw

/// 「订阅追更」撞上智能设置 409 后要重读 title-preview，换掉摘要和版本号再等用户确认。
/// 季和续订保持打开时的那份（同 iPhone `SubscribeSheet.refreshSmartPlan`）。不要拿旧版本自动重试。
struct AirScheduleActionsTests {
    @Test func smartVersionConflictRefreshesTheDraftBeforeTheNextConfirm() async throws {
        let box = SubscribeConflictBox()
        let (api, session) = try scriptedAPI(box, host: "conflict.test")
        defer {
            session.invalidateAndCancel()
            SubscribeConflictScripts.shared.remove(host: "conflict.test")
        }
        let actions = AirScheduleActions()

        await actions.beginSubscribe(api: api, tmdbId: 42)
        guard case let .confirming(opened) = actions.stage else {
            Issue.record("预检完成后应停在确认态")
            return
        }
        #expect(opened.seasons == [1])
        #expect(opened.smart?.profileRevision == 3)
        #expect(opened.smart?.memoryRevision == 9)

        let failed = await actions.confirmSubscribe(api: api, libraryId: 3)
        #expect(!failed)
        guard case let .confirming(refreshed) = actions.stage else {
            Issue.record("冲突后仍应停在确认态，不能自动提交")
            return
        }
        #expect(refreshed.seasons == [1], "季是打开时确认的范围，不随新预检改")
        #expect(refreshed.followFuture)
        #expect(refreshed.smart?.profileRevision == 4)
        #expect(refreshed.smart?.memoryRevision == 10)
        #expect(refreshed.quality == ["优先 1080p WEB-DL"])
        #expect(actions.message?.isError == true)
        #expect(actions.message?.text == "智能设置已在别处更新，请重新确认")
        let afterConflict = box.snapshot()
        #expect(afterConflict.previews == ["tmdb:tv:42", "tmdb:tv:42"])
        #expect(afterConflict.creates.map(\.profile) == [3])
        #expect(afterConflict.creates.map(\.memory) == [9])
        #expect(afterConflict.creates.map(\.library) == [3])

        let ok = await actions.confirmSubscribe(api: api, libraryId: 3)
        #expect(ok)
        #expect(actions.stage == .idle)
        #expect(actions.message?.isError == false)
        let done = box.snapshot()
        #expect(done.creates.map(\.profile) == [3, 4], "第二次确认带新版本，不再提交打开时的 3")
        #expect(done.creates.map(\.memory) == [9, 10])
        #expect(done.previews.count == 2, "成功的那次不再读预检")
    }

    @Test func otherCreateFailuresKeepTheOldDraft() async throws {
        let box = SubscribeConflictBox()
        box.firstCreateStatus = 500
        let (api, session) = try scriptedAPI(box, host: "other-error.test")
        defer {
            session.invalidateAndCancel()
            SubscribeConflictScripts.shared.remove(host: "other-error.test")
        }
        let actions = AirScheduleActions()

        await actions.beginSubscribe(api: api, tmdbId: 42)
        let failed = await actions.confirmSubscribe(api: api, libraryId: 3)
        #expect(!failed)
        guard case let .confirming(draft) = actions.stage else {
            Issue.record("失败后回到确认态")
            return
        }
        #expect(draft.smart?.profileRevision == 3)
        #expect(draft.seasons == [1])
        #expect(box.snapshot().previews.count == 1, "不是版本冲突就不要重读预检")
        #expect(actions.message?.text == "服务器出错了")
    }

    @Test func failedRefreshKeepsTheDraftThatWasConfirmed() async throws {
        let box = SubscribeConflictBox()
        box.failPreviewFrom = 2
        let (api, session) = try scriptedAPI(box, host: "refresh-fails.test")
        defer {
            session.invalidateAndCancel()
            SubscribeConflictScripts.shared.remove(host: "refresh-fails.test")
        }
        let actions = AirScheduleActions()

        await actions.beginSubscribe(api: api, tmdbId: 42)
        let failed = await actions.confirmSubscribe(api: api, libraryId: 3)
        #expect(!failed)
        guard case let .confirming(draft) = actions.stage else {
            Issue.record("刷新失败仍回到确认态")
            return
        }
        #expect(draft.smart?.profileRevision == 3, "预检没读到就不换成新版本")
        #expect(draft.quality == ["优先 4K WEB-DL"])
        #expect(actions.message?.text == "智能设置已在别处更新，请重新确认")
        #expect(box.snapshot().creates.map(\.profile) == [3])
    }

    private func scriptedAPI(_ box: SubscribeConflictBox, host: String) throws -> (APIClient, URLSession) {
        SubscribeConflictScripts.shared.install(box, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscribeConflictProtocol.self]
        let session = URLSession(configuration: configuration)
        let origin = try #require(URL(string: "http://\(host)"))
        return (APIClient(server: ServerAddress(origin: origin), session: session), session)
    }
}

private nonisolated final class SubscribeConflictBox: @unchecked Sendable {
    let lock = NSLock()
    var profile = 3
    var memory = 9
    var label = "优先 4K WEB-DL"
    /// 新预检改建议季，用来确认客户端不会把已展示的范围一起换掉
    var suggested = 1
    var firstCreateStatus = 409
    /// 第几次预检起改回 500（1 起算）。默认不失败
    var failPreviewFrom = Int.max
    private(set) var previews: [String] = []
    private(set) var creates: [(profile: Int?, memory: Int?, library: Int?)] = []

    func onPreview(titleRef: String?) -> (status: Int, profile: Int, memory: Int, label: String, suggested: Int) {
        lock.withLock {
            previews.append(titleRef ?? "")
            if previews.count >= failPreviewFrom { return (500, profile, memory, label, suggested) }
            return (200, profile, memory, label, suggested)
        }
    }

    func onCreate(profile: Int?, memory: Int?, library: Int?) -> Int {
        lock.withLock {
            creates.append((profile, memory, library))
            guard creates.count == 1, firstCreateStatus != 200 else { return 200 }
            if firstCreateStatus == 409 {
                self.profile = 4
                self.memory = 10
                self.label = "优先 1080p WEB-DL"
                self.suggested = 2
            }
            return firstCreateStatus
        }
    }

    func snapshot() -> (previews: [String], creates: [(profile: Int?, memory: Int?, library: Int?)]) {
        lock.withLock { (previews: previews, creates: creates) }
    }
}

private nonisolated final class SubscribeConflictScripts: @unchecked Sendable {
    static let shared = SubscribeConflictScripts()
    private let lock = NSLock()
    private var boxes: [String: SubscribeConflictBox] = [:]

    func install(_ box: SubscribeConflictBox, host: String) { lock.withLock { boxes[host] = box } }
    func remove(host: String) { lock.withLock { boxes[host] = nil } }
    func box(for host: String) -> SubscribeConflictBox? { lock.withLock { boxes[host] } }
}

private nonisolated final class SubscribeConflictProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host.map { SubscribeConflictScripts.shared.box(for: $0) != nil } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let box = SubscribeConflictScripts.shared.box(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let path = url.path
        let body = Self.body(of: request)
        if path.hasSuffix("/subscriptions/title-preview") {
            let titleRef = body.flatMap { Self.jsonObject($0)?["title_ref"] as? String }
            let preview = box.onPreview(titleRef: titleRef)
            if preview.status != 200 {
                respond(preview.status, #"{"success":false,"code":"INTERNAL","message":"预检失败"}"#)
                return
            }
            respond(200, """
            {"success":true,"data":{"status":"ready","media":{"media_item_id":1,"kind":"tv","tmdb_id":42,"title":"长街夜行","original_title":"Long Street","status":"Returning Series"},"seasons":[{"season_number":\(preview.suggested),"name":"季","aired_count":10,"owned_count":1}],"movie_owned":false,"suggested_seasons":[\(preview.suggested)],"candidates":[],"smart":{"configured":true,"profile_revision":\(preview.profile),"memory_revision":\(preview.memory),"quality_label":"\(preview.label)","scope_options":[],"can_edit":true}}}
            """)
            return
        }
        if path.hasSuffix("/subscriptions") {
            let json = body.flatMap(Self.jsonObject)
            let status = box.onCreate(
                profile: (json?["smart_profile_revision"] as? NSNumber)?.intValue,
                memory: (json?["smart_memory_revision"] as? NSNumber)?.intValue,
                library: (json?["library_id"] as? NSNumber)?.intValue
            )
            if status == 409 {
                respond(409, #"{"success":false,"code":"SMART_VERSION_CONFLICT","message":"智能设置已在别处更新，请重新确认","message_key":"errors.subscription.settingsChanged"}"#)
                return
            }
            if status != 200 {
                respond(status, #"{"success":false,"code":"INTERNAL","message":"服务器出错了"}"#)
                return
            }
            respond(200, """
            {"success":true,"data":{"subscription":{"id":9,"media":{"media_item_id":1,"kind":"tv","tmdb_id":42,"title":"长街夜行","original_title":"Long Street"},"status":"active","selected_seasons":[1],"follow_future":true,"rule_set_id":0,"progress":{"total":0,"wanted":0,"grabbed":0,"downloaded":0,"imported":0,"upgrading":0},"season_collection":[],"created_at":"2026-11-05T00:00:00Z","updated_at":"2026-11-05T00:00:00Z","wanted":[],"can_manage":true,"forecast_pending":false}}}
            """)
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return request.httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return stream.read(base.assumingMemoryBound(to: UInt8.self), maxLength: raw.count)
            }
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
