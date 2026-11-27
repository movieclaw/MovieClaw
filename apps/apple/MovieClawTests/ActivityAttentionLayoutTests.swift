import Foundation
import SwiftUI
import Testing
import UIKit
@testable import MovieClaw

/// Regression tests for #1283: large "Needs Attention" lists in ActivityView must render
/// one virtualized List row per card, preserve multi-line summary height without crushing
/// 3-line text to 1 line, keep exact 10pt inter-card spacing (0pt on the final card), and
/// avoid symmetric top/bottom blank gaps inside the attention section.
@Suite(.serialized)
struct ActivityAttentionLayoutTests {
    private static func makeStubAPI(
        host: String,
        jobsJSON: [[String: Any]] = [],
        downloadsJSON: [[String: Any]] = []
    ) throws -> (APIClient, URLSession) {
        ActivityLayoutStubRegistry.shared.install(
            ActivityLayoutStubData(jobs: jobsJSON, downloads: downloadsJSON),
            host: host
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ActivityLayoutStubProtocol.self]
        let session = URLSession(configuration: config)
        let origin = try #require(URL(string: "http://\(host)"))
        return (APIClient(server: ServerAddress(origin: origin), session: session), session)
    }

    private static func decode<T: Decodable>(_ json: [String: Any]) -> T {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(T.self, from: data)
    }

    private static func failedSubtitleJobDict(
        index: Int,
        summaryLines: Int,
        includeUsage: Bool,
        extraTag: Bool
    ) -> [String: Any] {
        let errorText: String = switch summaryLines {
        case 1:
            "Model unavailable."
        case 2:
            "Model service temporarily unavailable: [OpenAI Endpoint] connection timed out after 30s, please verify proxy settings."
        default:
            "Model service temporarily unavailable: [OpenAI Endpoint] connection timed out repeatedly with HTTP 503 Service Unavailable across all retry attempts. Check API key, endpoint URL, proxy configuration, and account quota before retrying (code: upstream_timeout_\(index))."
        }
        let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_795_500_000 - Double(index * 60)))
        var details: [String: Any] = [
            "target_language": "chs",
            "secondary_language": "eng",
            "done_events": 0,
            "total_events": 861 - (index % 35),
            "parallelism": 8,
        ]
        if extraTag {
            details["rate_limit_count"] = 12
        }
        let usage: [String: Any] = includeUsage ? [
            "request_count": 13,
            "failed_request_count": 13,
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0,
            "cache_read_tokens": 0,
            "total_duration_ms": 18200.0,
            "max_duration_ms": 4100.0,
        ] : [:]
        return [
            "id": String(format: "sub-fail-%02d", index),
            "job_type": "subtitle.generate",
            "job_type_label": NSNull(),
            "subject": String(format: "Air Crash Investigation (2011) - S08E%02d.mkv", (index % 20) + 1),
            "definition_version": 1,
            "handler_revision": "fixture",
            "status": "failed",
            "input_data": ["target_language": "chs", "secondary_language": "eng"],
            "result": NSNull(),
            "error": [
                "message": errorText,
                "actions": [
                    ["type": "retry_job", "label": "Retry"],
                    ["type": "open_settings", "label": "Settings", "target": "ai"],
                ],
            ],
            "usage": usage,
            "progress": [
                "mode": "determinate",
                "phase": "failed",
                "phase_index": 3,
                "phase_count": 5,
                "percent": 0.0,
                "current": 0,
                "total": 18 - (index % 3),
                "message": errorText,
                "details": details,
            ],
            "resources": [],
            "origin": index % 2 == 1 ? "agent" : "cli",
            "actor_name": index % 2 == 1 ? "agent:28cb024d64834cd799ca91beadf6aa3d" : "horga",
            "attempt": 1,
            "max_attempts": 2,
            "revision": 1,
            "cancel_requested_by": NSNull(),
            "dismissed_at": NSNull(),
            "created_at": stamp,
            "updated_at": stamp,
        ]
    }

    private static func activeIngestJobDict(index: Int) -> [String: Any] {
        let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_795_500_000 - Double(index * 30)))
        return [
            "id": String(format: "active-%02d", index),
            "job_type": "library.ingest",
            "job_type_label": NSNull(),
            "subject": "Eyes Wide Shut \(index)",
            "definition_version": 1,
            "handler_revision": "fixture",
            "status": "running",
            "input_data": [:],
            "result": NSNull(),
            "error": NSNull(),
            "usage": [:],
            "progress": [
                "mode": "determinate",
                "phase": "ingesting",
                "percent": Double(6 + index * 5),
                "current": 100,
                "total": 1000,
                "message": "Waiting for connection",
                "details": [:],
            ],
            "resources": [],
            "origin": "system",
            "attempt": 1,
            "max_attempts": 2,
            "revision": 1,
            "cancel_requested_by": NSNull(),
            "dismissed_at": NSNull(),
            "created_at": stamp,
            "updated_at": stamp,
        ]
    }

    private static func attentionDownloadDict(index: Int) -> [String: Any] {
        [
            "id": "dl-attn-\(index)",
            "info_hash": String(format: "deadbeef1283%04d", index),
            "name": "Mayday.S08E0\(index + 1).1080p.WEB-DL.mkv",
            "downloader_id": 1,
            "downloader_name": "qBittorrent",
            "progress": 0.12,
            "size_bytes": 4_200_000_000,
            "state": "error",
            "source": "subscription",
            "remux": false,
            "media_item_id": 100 + index,
            "media_title": "Air Crash Investigation \(index + 1)",
            "media_kind": "tv",
            "plan": NSNull(),
            "subscriptions": [],
            "can_replace": true,
        ]
    }

    private static func findCollectionView(in root: UIView) -> UICollectionView? {
        if let cv = root as? UICollectionView { return cv }
        for child in root.subviews {
            if let found = findCollectionView(in: child) { return found }
        }
        return nil
    }

    /// Normalize any UIImage into an explicit 8-bit sRGB RGBA buffer so pixel scanning never
    /// depends on display gamut (16-bit wide color) or alpha-first byte order.
    private static func rgba8Buffer(from image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int, scale: CGFloat) {
        let cg = try #require(image.cgImage)
        let width = cg.width
        let height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = try #require(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        #expect(ctx.bitsPerComponent == 8)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height, image.scale)
    }

    private static func firstLitOffsetFromTop(
        in rgba: (bytes: [UInt8], width: Int, height: Int, scale: CGFloat),
        startY: CGFloat,
        xRange: ClosedRange<CGFloat>
    ) -> CGFloat {
        let scale = rgba.scale
        let yStart = max(0, Int(ceil(startY * scale)))
        let yEnd = rgba.height
        let xStart = max(0, Int(xRange.lowerBound * scale))
        let xEnd = min(rgba.width, Int(xRange.upperBound * scale))
        let bpr = rgba.width * 4
        for y in yStart ..< yEnd {
            var lit = 0
            let rowStart = y * bpr
            for x in stride(from: xStart, to: xEnd, by: 2) {
                let offset = rowStart + x * 4
                if rgba.bytes[offset] > 12 || rgba.bytes[offset + 1] > 12 || rgba.bytes[offset + 2] > 12 {
                    lit += 1
                }
            }
            if lit >= 10 { return max(0, (CGFloat(y) / scale) - startY) }
        }
        return CGFloat(yEnd - yStart) / scale
    }

    private static func lastLitOffsetFromBottom(
        in rgba: (bytes: [UInt8], width: Int, height: Int, scale: CGFloat),
        endY: CGFloat,
        xRange: ClosedRange<CGFloat>
    ) -> CGFloat {
        let scale = rgba.scale
        // Stay strictly inside [minY, maxY) so we never sample row 0 of the adjacent cell below.
        let yEnd = min(rgba.height - 1, Int(floor(endY * scale)) - 1)
        guard yEnd >= 0 else { return 0 }
        let xStart = max(0, Int(xRange.lowerBound * scale))
        let xEnd = min(rgba.width, Int(xRange.upperBound * scale))
        let bpr = rgba.width * 4
        for y in stride(from: yEnd, through: 0, by: -1) {
            var lit = 0
            let rowStart = y * bpr
            for x in stride(from: xStart, to: xEnd, by: 2) {
                let offset = rowStart + x * 4
                if rgba.bytes[offset] > 12 || rgba.bytes[offset + 1] > 12 || rgba.bytes[offset + 2] > 12 {
                    lit += 1
                }
            }
            if lit >= 10 { return max(0, endY - (CGFloat(y + 1) / scale)) }
        }
        return endY
    }

    @MainActor
    private static func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @MainActor
    private static func snapshotRGBA(of window: UIWindow) throws -> (bytes: [UInt8], width: Int, height: Int, scale: CGFloat) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.preferredRange = .standard
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try rgba8Buffer(from: image)
    }

    @MainActor
    private static func verifyAttentionSectionGeometry(
        hostName: String,
        failedJobs: [[String: Any]],
        activeCount: Int = 11,
        downloads: [[String: Any]] = [],
        assertThreeLineVsOneLineAtIndices: (threeLine: Int, oneLine: Int)? = nil,
        assertMiddleRowInsetIndex: Int? = nil
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)

        let activeJobs = (0 ..< activeCount).map { activeIngestJobDict(index: $0) }
        let (api, session) = try makeStubAPI(host: hostName, jobsJSON: failedJobs + activeJobs, downloadsJSON: downloads)
        defer {
            session.invalidateAndCancel()
            ActivityLayoutStubRegistry.shared.remove(host: hostName)
        }

        let badges = ShellBadges()
        let router = Router()
        let feedback = Feedback()

        let storeTask = Task { await badges.tasks.run(api: api) }
        defer { storeTask.cancel() }

        let expectedAttentionCount = failedJobs.count + downloads.count
        let loaded = await waitUntil(timeout: .seconds(5)) {
            badges.tasks.activity.attentionTotal == expectedAttentionCount
                && badges.tasks.activity.activeTotal == activeCount
        }
        #expect(loaded, "TaskActivityStore did not load expected \(expectedAttentionCount) attention items")

        let root = TabView {
            Tab("Activity", systemImage: "waveform.path.ecg") {
                NavigationStack {
                    ActivityView()
                }
            }
        }
        .environment(badges)
        .environment(router)
        .environment(feedback)
        .environment(\.api, api)
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(.dark)

        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }

        window.layoutIfNeeded()
        let attentionSection = 1
        let ready = await waitUntil(timeout: .seconds(5)) {
            guard let cv = findCollectionView(in: window),
                  cv.numberOfSections > attentionSection,
                  cv.numberOfItems(inSection: attentionSection) == expectedAttentionCount,
                  cv.cellForItem(at: IndexPath(item: 0, section: attentionSection)) != nil
            else { return false }
            return true
        }
        #expect(ready, "ActivityView List did not materialize expected attention section rows")

        let cv = try #require(findCollectionView(in: window))
        cv.layoutIfNeeded()
        // Allow one render pass after layout stabilization
        try? await Task.sleep(for: .milliseconds(100))

        let itemCount = cv.numberOfItems(inSection: attentionSection)
        #expect(itemCount == expectedAttentionCount, "Expected \(expectedAttentionCount) rows in attention section, got \(itemCount)")

        let firstPath = IndexPath(item: 0, section: attentionSection)
        let firstCell = try #require(cv.cellForItem(at: firstPath))
        let firstScreen = firstCell.convert(firstCell.bounds, to: window)
        let topRGBA = try snapshotRGBA(of: window)

        let topGap = firstLitOffsetFromTop(
            in: topRGBA,
            startY: firstScreen.minY,
            xRange: (firstScreen.minX + 10) ... (firstScreen.maxX - 10)
        )
        #expect(topGap >= 0 && topGap < 6, "Top blank gap was \(topGap)pt (expected < 6pt)")
        #expect(firstCell.bounds.height < 600, "First attention row height was \(firstCell.bounds.height)pt")

        if itemCount >= 2 {
            let firstAttr = try #require(cv.layoutAttributesForItem(at: firstPath))
            let secondAttr = try #require(cv.layoutAttributesForItem(at: IndexPath(item: 1, section: attentionSection)))
            let interCellGap = secondAttr.frame.minY - firstAttr.frame.maxY
            #expect(abs(interCellGap) < 1, "Adjacent attention cells should abut, got \(interCellGap)pt")

            // Non-last cell must carry the 10pt inter-card bottom inset visually.
            let firstRowBottomGap = lastLitOffsetFromBottom(
                in: topRGBA,
                endY: firstScreen.maxY,
                xRange: (firstScreen.minX + 10) ... (firstScreen.maxX - 10)
            )
            #expect(firstRowBottomGap >= 7 && firstRowBottomGap <= 13, "Expected ~10pt bottom inset on first card, got \(firstRowBottomGap)pt")
        }

        // Verify a 3-line summary card renders meaningfully taller than an otherwise identical 1-line summary card.
        if let pair = assertThreeLineVsOneLineAtIndices {
            let threeAttr = try #require(cv.layoutAttributesForItem(at: IndexPath(item: pair.threeLine, section: attentionSection)))
            let oneAttr = try #require(cv.layoutAttributesForItem(at: IndexPath(item: pair.oneLine, section: attentionSection)))
            let delta = threeAttr.frame.height - oneAttr.frame.height
            #expect(delta >= 24, "3-line summary card should be >=24pt taller than 1-line card (got \(delta)pt)")
        }

        // Optional check for an intermediate row's 10pt bottom inset (e.g. last DownloadTaskGroupCard before JobCards).
        if let midIdx = assertMiddleRowInsetIndex {
            let midPath = IndexPath(item: midIdx, section: attentionSection)
            cv.scrollToItem(at: midPath, at: .centeredVertically, animated: false)
            cv.layoutIfNeeded()
            _ = await waitUntil { cv.cellForItem(at: midPath) != nil }
            try? await Task.sleep(for: .milliseconds(100))
            let midCell = try #require(cv.cellForItem(at: midPath))
            let midScreen = midCell.convert(midCell.bounds, to: window)
            let midRGBA = try snapshotRGBA(of: window)
            let midBotGap = lastLitOffsetFromBottom(
                in: midRGBA,
                endY: midScreen.maxY,
                xRange: (midScreen.minX + 10) ... (midScreen.maxX - 10)
            )
            #expect(midBotGap >= 7 && midBotGap <= 13, "Expected ~10pt bottom inset on row \(midIdx), got \(midBotGap)pt")
        }

        // Scroll to the final row of the attention section and verify 0pt trailing inset / no blank gap.
        let lastPath = IndexPath(item: itemCount - 1, section: attentionSection)
        cv.scrollToItem(at: lastPath, at: .top, animated: false)
        cv.layoutIfNeeded()
        _ = await waitUntil { cv.cellForItem(at: lastPath) != nil }
        if let lastAttr = cv.layoutAttributesForItem(at: lastPath) {
            let offsetY = max(-cv.adjustedContentInset.top, lastAttr.frame.maxY - cv.bounds.height * 0.45)
            cv.setContentOffset(CGPoint(x: 0, y: offsetY), animated: false)
            cv.layoutIfNeeded()
        }
        _ = await waitUntil { cv.cellForItem(at: lastPath) != nil }
        try? await Task.sleep(for: .milliseconds(100))

        let lastCell = try #require(cv.cellForItem(at: lastPath))
        let lastScreen = lastCell.convert(lastCell.bounds, to: window)
        let botRGBA = try snapshotRGBA(of: window)
        let botGap = lastLitOffsetFromBottom(
            in: botRGBA,
            endY: lastScreen.maxY,
            xRange: (lastScreen.minX + 10) ... (lastScreen.maxX - 10)
        )
        #expect(botGap >= 0 && botGap < 4, "Bottom trailing gap on last attention card was \(botGap)pt (expected < 4pt)")
    }

    @Test @MainActor func attentionSectionWith29DetailedCardsHasNoBlankGaps() async throws {
        // Card 0 (3-line) and Card 1 (1-line) share identical usage/tags so height delta directly tests summary wrapping.
        let jobs = (0 ..< 29).map { idx in
            Self.failedSubtitleJobDict(
                index: idx,
                summaryLines: idx == 1 ? 1 : 3,
                includeUsage: idx < 22,
                extraTag: idx < 18
            )
        }
        try await Self.verifyAttentionSectionGeometry(
            hostName: "layout-29.test",
            failedJobs: jobs,
            assertThreeLineVsOneLineAtIndices: (threeLine: 0, oneLine: 1)
        )
    }

    @Test @MainActor func attentionSectionWith38DetailedCardsHasNoBlankGaps() async throws {
        let jobs = (0 ..< 38).map { idx in
            Self.failedSubtitleJobDict(
                index: idx,
                summaryLines: idx == 1 ? 1 : 3,
                includeUsage: idx < 30,
                extraTag: idx < 25
            )
        }
        try await Self.verifyAttentionSectionGeometry(
            hostName: "layout-38.test",
            failedJobs: jobs,
            assertThreeLineVsOneLineAtIndices: (threeLine: 0, oneLine: 1)
        )
    }

    @Test @MainActor func attentionSectionMixedDownloadGroupsAndJobsRespectsRowInsets() async throws {
        let downloads = (0 ..< 2).map { Self.attentionDownloadDict(index: $0) }
        let jobs = (0 ..< 2).map { idx in
            Self.failedSubtitleJobDict(index: idx, summaryLines: 3, includeUsage: true, extraTag: false)
        }
        // Row 1 is the last DownloadTaskGroupCard before JobCards: it must keep the 10pt bottom inset,
        // while Row 3 (last JobCard) must have 0pt bottom inset.
        try await Self.verifyAttentionSectionGeometry(
            hostName: "layout-mixed.test",
            failedJobs: jobs,
            activeCount: 2,
            downloads: downloads,
            assertMiddleRowInsetIndex: 1
        )
    }

    @Test @MainActor func attentionSectionDownloadGroupsOnlyHasNoTrailingGap() async throws {
        let downloads = (0 ..< 2).map { Self.attentionDownloadDict(index: $0) }
        // Row 1 is the last DownloadTaskGroupCard with no following jobs: it must have 0pt bottom inset.
        try await Self.verifyAttentionSectionGeometry(
            hostName: "layout-dl-only.test",
            failedJobs: [],
            activeCount: 2,
            downloads: downloads
        )
    }

    @Test @MainActor func hoistedDismissActionClearsPendingDismissAndUpdatesStore() async throws {
        let jobDict = Self.failedSubtitleJobDict(index: 0, summaryLines: 3, includeUsage: false, extraTag: false)
        let job: API.JobView = Self.decode(jobDict)
        let (api, session) = try Self.makeStubAPI(host: "layout-dismiss.test", jobsJSON: [jobDict])
        defer {
            session.invalidateAndCancel()
            ActivityLayoutStubRegistry.shared.remove(host: "layout-dismiss.test")
        }

        let store = TaskActivityStore()
        store.upsert(job)
        #expect(store.activity.attentionTotal == 1)

        let actions = TaskCenterActions()
        let feedback = Feedback()
        actions.pendingDismiss = job
        await actions.dismiss(job, muteSource: false, api: api, feedback: feedback, store: store)

        #expect(actions.pendingDismiss == nil)
        #expect(store.activity.attentionTotal == 0)
        #expect(store.activity.historyTotal == 1)
    }
}

private nonisolated struct ActivityLayoutStubData: @unchecked Sendable {
    var jobs: [[String: Any]]
    var downloads: [[String: Any]]
}

private nonisolated final class ActivityLayoutStubRegistry: @unchecked Sendable {
    static let shared = ActivityLayoutStubRegistry()
    private let lock = NSLock()
    private var entries: [String: ActivityLayoutStubData] = [:]

    func install(_ data: ActivityLayoutStubData, host: String) { lock.withLock { entries[host] = data } }
    func remove(host: String) { lock.withLock { entries[host] = nil } }
    func data(for host: String) -> ActivityLayoutStubData? { lock.withLock { entries[host] } }
}

private nonisolated final class ActivityLayoutStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host.map { ActivityLayoutStubRegistry.shared.data(for: $0) != nil } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let data = ActivityLayoutStubRegistry.shared.data(for: host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let path = url.path
        if path.hasSuffix("/jobs/stream") {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("event: ready\ndata: {}\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if path.hasSuffix("/jobs") {
            let onlyActive = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "active_only" })?.value == "true"
            let items = onlyActive ? data.jobs.filter { ($0["status"] as? String) == "running" } : data.jobs
            return respondJSON(["success": true, "data": ["items": items]])
        }
        if path.contains("/jobs/"), path.hasSuffix("/dismiss") {
            let parts = path.split(separator: "/")
            let jobId = parts.count >= 2 ? String(parts[parts.count - 2]) : ""
            if var matched = data.jobs.first(where: { ($0["id"] as? String) == jobId }) {
                let now = ISO8601DateFormatter().string(from: Date())
                matched["dismissed_at"] = now
                matched["updated_at"] = now
                return respondJSON(["success": true, "data": ["dismissed": true, "muted": false, "job": matched]])
            }
            return respondJSON(["success": false], status: 404)
        }
        if path.hasSuffix("/downloaders/tasks") {
            let sources: [[String: Any]] = data.downloads.isEmpty ? [] : [[
                "id": 1,
                "name": "qBittorrent",
                "client_type": "qbittorrent",
                "status": "active",
                "message": NSNull(),
                "task_count": data.downloads.count,
            ]]
            return respondJSON(["success": true, "data": ["items": data.downloads, "sources": sources]])
        }
        if path.hasSuffix("/llm/providers") {
            return respondJSON(["success": true, "data": []])
        }
        if path.hasSuffix("/playback/activity") {
            return respondJSON(["success": true, "data": ["sessions": [], "downloads": [], "hidden_session_count": 0, "hidden_download_count": 0]])
        }
        if path.hasSuffix("/playback/history") {
            return respondJSON(["success": true, "data": ["entries": [], "has_more": false, "next_cursor": NSNull()]])
        }
        return respondJSON(["success": true, "data": [:]])
    }

    override func stopLoading() {}

    private func respondJSON(_ object: [String: Any], status: Int = 200) {
        let payload = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
