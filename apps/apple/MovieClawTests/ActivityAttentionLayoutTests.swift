import SwiftUI
import Testing
import UIKit
@testable import MovieClaw

/// Regression tests for #1283: large "Needs Attention" lists in ActivityView must not
/// collapse multi-line summaries or create symmetric top/bottom blank gaps inside the
/// attention section when cards have varying natural heights.
@Suite(.serialized)
struct ActivityAttentionLayoutTests {
    private static func decode<T: Decodable>(_ json: [String: Any]) -> T {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(T.self, from: data)
    }

    private static func failedSubtitleJob(
        index: Int,
        summaryLines: Int,
        includeUsage: Bool,
        extraTag: Bool
    ) -> API.JobView {
        let errorText: String = switch summaryLines {
        case 1:
            "Model service unavailable: connection refused."
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
        return decode([
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
        ])
    }

    private static func activeIngestJob(index: Int) -> API.JobView {
        let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_795_500_000 - Double(index * 30)))
        return decode([
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
        ])
    }

    private static func findCollectionView(in root: UIView) -> UICollectionView? {
        if let cv = root as? UICollectionView { return cv }
        for child in root.subviews {
            if let found = findCollectionView(in: child) { return found }
        }
        return nil
    }

    private static func firstLitOffsetFromTop(in image: UIImage, startY: CGFloat, xRange: ClosedRange<CGFloat>) -> CGFloat {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return -1 }
        let scale = image.scale
        let yStart = max(0, Int(ceil(startY * scale)))
        let yEnd = cg.height
        let xStart = max(0, Int(xRange.lowerBound * scale))
        let xEnd = min(cg.width, Int(xRange.upperBound * scale))
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        for y in yStart ..< yEnd {
            var lit = 0
            let row = ptr + y * bpr
            for x in stride(from: xStart, to: xEnd, by: 2) {
                let p = row + x * bpp
                if Int(p[0]) > 12 || Int(p[1]) > 12 || Int(p[2]) > 12 { lit += 1 }
            }
            if lit >= 10 { return (CGFloat(y) / scale) - startY }
        }
        return CGFloat(yEnd - yStart) / scale
    }

    private static func lastLitOffsetFromBottom(in image: UIImage, endY: CGFloat, xRange: ClosedRange<CGFloat>) -> CGFloat {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return -1 }
        let scale = image.scale
        let yEnd = min(cg.height - 1, Int(floor(endY * scale)))
        let xStart = max(0, Int(xRange.lowerBound * scale))
        let xEnd = min(cg.width, Int(xRange.upperBound * scale))
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        for y in stride(from: yEnd, through: 0, by: -1) {
            var lit = 0
            let row = ptr + y * bpr
            for x in stride(from: xStart, to: xEnd, by: 2) {
                let p = row + x * bpp
                if Int(p[0]) > 12 || Int(p[1]) > 12 || Int(p[2]) > 12 { lit += 1 }
            }
            if lit >= 10 { return endY - (CGFloat(y) / scale) }
        }
        return endY
    }

    @MainActor
    private static func verifyAttentionSectionGeometry(
        label: String,
        failedCount: Int,
        usageCutoff: Int,
        tagCutoff: Int,
        snapshotPrefix: String? = nil
    ) async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("No active UIWindowScene available in test host")
            return
        }

        let badges = ShellBadges()
        let router = Router()
        let feedback = Feedback()
        let jobs = (0 ..< failedCount).map { idx in
            failedSubtitleJob(index: idx, summaryLines: 3, includeUsage: idx < usageCutoff, extraTag: idx < tagCutoff)
        } + (0 ..< 11).map { activeIngestJob(index: $0) }
        for job in jobs.reversed() { badges.tasks.upsert(job) }

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
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(.dark)

        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(500))

        guard let cv = findCollectionView(in: window) else {
            Issue.record("ActivityView List did not produce a UICollectionView")
            return
        }
        cv.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        // Section 1 is "Needs Attention" (Section 0 is the summary header section).
        let attentionSection = 1
        let itemCount = cv.numberOfItems(inSection: attentionSection)
        guard let firstCell = cv.cellForItem(at: IndexPath(item: 0, section: attentionSection)) else {
            Issue.record("First attention cell not visible")
            return
        }

        let firstScreen = firstCell.convert(firstCell.bounds, to: window)
        let topImg = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let snapshotPrefix {
            try? topImg.pngData()?.write(to: URL(fileURLWithPath: "\(snapshotPrefix)-top.png"))
        }
        let topGap = firstLitOffsetFromTop(
            in: topImg,
            startY: firstScreen.minY,
            xRange: (firstScreen.minX + 10) ... (firstScreen.maxX - 10)
        )

        // Scroll to the last item in the attention section to inspect the trailing gap before "Active".
        let lastPath = IndexPath(item: itemCount - 1, section: attentionSection)
        cv.scrollToItem(at: lastPath, at: .top, animated: false)
        cv.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(450))
        if let lastAttr = cv.layoutAttributesForItem(at: lastPath) {
            let offsetY = max(-cv.adjustedContentInset.top, lastAttr.frame.maxY - cv.bounds.height * 0.45)
            cv.setContentOffset(CGPoint(x: 0, y: offsetY), animated: false)
            cv.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(450))
        }

        let botImg = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let snapshotPrefix {
            try? botImg.pngData()?.write(to: URL(fileURLWithPath: "\(snapshotPrefix)-bot.png"))
        }
        let lastCell = cv.cellForItem(at: lastPath)
        let botGap: CGFloat
        if let lastCell {
            let lastScreen = lastCell.convert(lastCell.bounds, to: window)
            botGap = lastLitOffsetFromBottom(
                in: botImg,
                endY: lastScreen.maxY,
                xRange: (lastScreen.minX + 10) ... (lastScreen.maxX - 10)
            )
        } else {
            botGap = -1
        }

        print(String(
            format: "LAYOUT-VERIFY [%@] items=%d firstCellH=%.1f topGap=%.1f botGap=%.1f",
            label, itemCount, firstCell.bounds.height, topGap, botGap
        ))

        // 1. Each attention card must be its own List row (virtualized, not one monolithic 10,000pt cell).
        #expect(itemCount == failedCount, "Expected \(failedCount) rows in attention section, got \(itemCount)")
        // 2. No blank vertical gap inside the top or bottom of the attention section.
        #expect(topGap >= 0 && topGap < 6, "Top blank gap was \(topGap)pt (expected < 6pt)")
        #expect(botGap >= 0 && botGap < 6, "Bottom blank gap was \(botGap)pt (expected < 6pt)")
        // 3. First card's row height must be a single card (~280-420pt), not thousands of points.
        #expect(firstCell.bounds.height < 600, "First attention row height was \(firstCell.bounds.height)pt")
        // 4. First card and second card must sit adjacent with the preserved 10pt card gap (via row inset).
        if let firstAttr = cv.layoutAttributesForItem(at: IndexPath(item: 0, section: attentionSection)),
           let secondAttr = cv.layoutAttributesForItem(at: IndexPath(item: 1, section: attentionSection)) {
            let interCellGap = secondAttr.frame.minY - firstAttr.frame.maxY
            #expect(abs(interCellGap) < 1, "Adjacent attention cells should abut (gap handled by 10pt bottom inset), got \(interCellGap)pt")
        }
    }

    @Test @MainActor func attentionSectionWith29DetailedCardsHasNoBlankGaps() async throws {
        let prefix = ProcessInfo.processInfo.environment["MC_1283_SNAPSHOT_DIR"].map { "\($0)/29" }
        try await Self.verifyAttentionSectionGeometry(
            label: "29-cards",
            failedCount: 29,
            usageCutoff: 22,
            tagCutoff: 18,
            snapshotPrefix: prefix
        )
    }

    @Test @MainActor func attentionSectionWith38DetailedCardsHasNoBlankGaps() async throws {
        let prefix = ProcessInfo.processInfo.environment["MC_1283_SNAPSHOT_DIR"].map { "\($0)/38" }
        try await Self.verifyAttentionSectionGeometry(
            label: "38-cards",
            failedCount: 38,
            usageCutoff: 30,
            tagCutoff: 25,
            snapshotPrefix: prefix
        )
    }
}
