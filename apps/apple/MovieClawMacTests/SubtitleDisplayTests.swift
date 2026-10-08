import AppKit
import SwiftUI
import Testing
@testable import MovieClaw

struct SubtitleDisplayTests {
    @Test func subtitleNamesAndMetadataStaySeparate() throws {
        let json = #"[{"track_ref":"embedded:3","kind":"pgs","language":"chi","is_default":true,"is_ai":false,"title":"国配简体特效 · 修订版","is_forced":true},{"track_ref":"embedded:4","kind":"pgs","language":"chi","is_default":false,"is_ai":false,"title":"国配简体特效 · 修订版"},{"track_ref":"embedded:5","kind":"vtt","language":"und","is_default":false,"is_ai":false}]"#
        let plans = try JSONDecoder().decode([API.SubtitlePlanView].self, from: Data(json.utf8))
        let options = SubtitleTracks.plan(plans, urls: ["/a", "/b", "/c"]).options
        #expect(options[0].displayTitle == "国配简体特效 · 修订版")
        #expect(MacTrackText.subtitleDetail(options[0]) == "中文 · PGS 图形 · 内封轨 4 · 默认 · 强制")
        #expect(MacTrackText.subtitleDetail(options[1]) == "中文 · PGS 图形 · 内封轨 5")
        #expect(options[2].displayTitle == "内封轨 6")
        #expect(options[2].detail == "未知语言 · WebVTT · 内封")
        #expect(MacSubtitleGroups.build(options).flatMap(\.options).count == 3)
        #expect(options[0].id != options[1].id)
    }

    @Test func longSubtitleRowsGrowVerticallyWithinTheColumn() {
        let detail = "中文 · PGS 图形 · 内封轨 4 · 默认 · 强制"
        func size(_ title: String) -> CGSize {
            let row = MacPanelRow(id: "mac-panel-subtitle-embedded:3", title: title, detail: detail, active: true, action: {})
            let host = NSHostingView(rootView: row.frame(width: 274))
            return host.fittingSize
        }
        let short = size("国配简体特效")
        let long = size("国配简体特效 · " + String(repeating: "保留屏幕文字与歌曲翻译🎬", count: 60))
        #expect(abs(long.width - 274) < 1)
        #expect(long.height > short.height * 5)
    }

    /// 与浏览器/iPhone/Apple TV 共用隔离媒体夹具，令牌只放在测试 APIClient 中。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MC_TEST_SUBTITLE_ITEM"] != nil))
    func realMediaLoadsIntoNativeSubtitlePanel() async throws {
        let env = ProcessInfo.processInfo.environment
        let server = try ServerAddress(parsing: #require(env["MC_TEST_SERVER"]))
        let login = try await APIClient(server: server).authDeviceLogin(body: .init(
            username: #require(env["MC_TEST_USERNAME"]), password: #require(env["MC_TEST_PASSWORD"]),
            client: .init(kind: "macos", installationId: UUID().uuidString, name: "Subtitle E2E")))
        let api = APIClient(server: server, token: login.token)
        let rawItem = try #require(env["MC_TEST_SUBTITLE_ITEM"])
        let item = try #require(Int(rawItem))
        let controller = PlaybackController(request: .init(mediaItemId: item, startSeconds: 3), api: api)
        defer { controller.close() }
        controller.start()
        let deadline = Date.now.addingTimeInterval(45)
        while controller.positionMs < 4000 || controller.phase != .playing {
            try #require(Date.now < deadline, "真实字幕夹具没有起播：\(controller.phase)")
            try await Task.sleep(for: .milliseconds(100))
        }
        let options = controller.subtitles.options
        #expect(options.count == 9)
        let long = try #require(options.first { $0.ref == "embedded:2" })
        #expect(long.displayTitle.hasPrefix("国配简体特效 · 蓝光修订版 · "))
        #expect(long.displayTitle.hasSuffix("保留屏幕文字与歌曲翻译🎬"))
        #expect(long.detail.contains("内封轨 3"))
        #expect(options.first { $0.ref == "embedded:3" }?.displayTitle == "内封轨 4")
        let forced = try #require(options.first { $0.ref == "embedded:5" })
        #expect(forced.displayTitle == "简英特效")
        #expect(forced.isForced)
        let host = NSHostingView(rootView: MacTracksPanel(controller: controller, maxHeight: 420, close: {}).frame(width: 286))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 286, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.frame.width - 286) < 1)
        controller.selectSubtitle("embedded:5")
        #expect(controller.selectedSubtitle == "embedded:5")
        let position = controller.positionMs
        let switchDeadline = Date.now.addingTimeInterval(10)
        while controller.positionMs < position + 1000 {
            try #require(Date.now < switchDeadline, "选轨后播放进度停止")
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.phase == .playing)
    }

}
