import XCTest

/// Issue #1336 合成素材端到端验证（分两条独立用例分别验收）：
/// 1) `testDetailRefreshShowsPostDownloadSubtitlesWithoutFileCountChange`：
///    验收详情旧列表刷新契约（本地 detail.json 秒开 → 服务端延迟返回且 fileCount 不变 → 字幕行与下拉刷新必须展示最新字幕）；
/// 2) `testOnlineSubtitleBackfillThenOfflinePlaybackPreservesDefaultAndNoVideoRedownload`：
///    验收 #1336 批准的在线字幕补齐能力：
///    先下载原画 → 服务端生成 AI 字幕（服务端默认选中 AI 双语）→ 断网确认补齐前仅有 0 条外挂 →
///    联网补齐（核实无视频重传/无导出/无服务端播放会话）→ 断网冷启动实播（核实 2 条补齐字幕可选可切，默认选轨仍为原 embedded:3）→
///    联网但字幕拉取失败 500（服务端再加第 3 条字幕）→ 断网再实播核实上次成功同步的 2 条字幕完整保留、默认选轨不变。
///
/// 外部隔离实验台契约（默认 proxy `http://127.0.0.1:18870`、control `http://127.0.0.1:18871`、backend `http://127.0.0.1:18865`，
/// 均可通过 `MC_1336_PROXY` / `MC_1336_CONTROL` / `MC_1336_BACKEND` 覆盖）：
/// - 夹具：剧集库 1 / 条目 1 / 文件 1（S06E01 合成 MKV，5 条内封字幕：3 中文 + 2 英语，容器默认 `embedded:3`，初始无外挂字幕）；
/// - 控制口：`GET /info`（存活探针）、`GET /log`、`POST /clear_log`、`POST /mode`（`pass` / `refuse` + `delay_paths` + `fail_paths`）、
///   `POST /reset_subtitles`、`POST /add_ai_subtitles`、`POST /add_extra_subtitle`。
/// 未启动实验台时在 `setUpWithError()` 中通过 `XCTSkip` 立即跳过，不影响常规测试套件。
final class OfflinePostDownloadSubtitleUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var proxy: String { env["MC_1336_PROXY"] ?? "http://127.0.0.1:18870" }
    private var control: String { env["MC_1336_CONTROL"] ?? "http://127.0.0.1:18871" }
    private var backendURL: String { env["MC_1336_BACKEND"] ?? "http://127.0.0.1:18865" }
    private let username = "admin"
    private let password = "Sup3rSecret!"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(controlAvailable(), "未检测到 #1336 合成素材实验台（\(control)），跳过端到端用例")
        try controlPOST("/mode", body: ["mode": "pass", "delay_paths": [:], "fail_paths": [:], "degrade_manifest": false])
        try controlPOST("/reset_subtitles", body: [:])
        try controlPOST("/clear_log", body: [:])
    }

    override func tearDown() {
        try? controlPOST("/mode", body: ["mode": "pass", "delay_paths": [:], "fail_paths": [:], "degrade_manifest": false])
    }

    /// 独立验收 A（详情旧列表刷新修复）：本地 detail.json 秒开 → 服务端延迟返回且 fileCount 不变 → 详情与下拉刷新展示最新字幕。
    @MainActor
    func testDetailRefreshShowsPostDownloadSubtitlesWithoutFileCountChange() throws {
        let app = downloadInitialOriginalEpisode()

        try controlPOST("/add_ai_subtitles", body: [:])
        try assertServerHasTwoAISubtitles()

        // 断网确认离线详情仍停在下载快照（无 AI 字幕芯片）
        try controlPOST("/mode", body: ["mode": "refuse"])
        app.terminate()
        let offline = launch(reset: false)
        openOfflineItemDetail(offline)
        let offlineChiChip = offline.buttons.matching(NSPredicate(format: "label CONTAINS '中文' AND label CONTAINS '×3'")).firstMatch
        let offlineAiChip = offline.buttons.matching(NSPredicate(format: "label CONTAINS '简体中文 + 英语'")).firstMatch
        XCTAssertTrue(offlineChiChip.waitForExistence(timeout: 10), "离线详情页应显示下载快照里的中文 ×3")
        XCTAssertFalse(offlineAiChip.exists, "离线无网络时详情页无法发现服务端后生成的 AI 字幕")

        // 恢复联网并延迟 GET /items/1 900ms，稳定复现「本地 detail.json 秒开 → 在线 detail 返回但 fileCount 不变」
        try controlPOST("/mode", body: ["mode": "pass", "delay_paths": ["/api/v1/libraries/1/items/1": 0.9], "fail_paths": [:]])
        try controlPOST("/clear_log", body: [:])
        offline.terminate()

        let online = launch(reset: false, route: "/library/1/item/1")
        XCTAssertTrue(online.staticTexts["item-title"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.proxyLog().contains { $0.contains("GET /api/v1/libraries/1/items/1 -> 200") }
        }, "联网打开详情页应请求服务端最新详情：\(proxyLog())")

        let onlineAiChip = online.buttons.matching(NSPredicate(format: "label CONTAINS '简体中文 + 英语'")).firstMatch
        XCTAssertTrue(onlineAiChip.waitForExistence(timeout: 8),
                      "联网刷新详情后，剧集字幕行必须展示新生成的 AI 双语字幕（不能停在 detail.json 旧快照）\n\(online.debugDescription)")

        // 同页停留期间服务端再新增一条外挂字幕 → 下拉刷新后应立即反映，不必退出重进
        try controlPOST("/mode", body: ["mode": "pass", "delay_paths": [:], "fail_paths": [:]])
        try controlPOST("/add_extra_subtitle", body: [:])
        try controlPOST("/clear_log", body: [:])
        let startCoord = online.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let endCoord = online.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        startCoord.press(forDuration: 0.05, thenDragTo: endCoord)
        XCTAssertTrue(waitUntil(timeout: 12) {
            self.proxyLog().contains { $0.contains("GET /api/v1/libraries/1/items/1 -> 200") }
        }, "下拉刷新应重新拉取详情：\(proxyLog())")
        onlineAiChip.tap()
        let jpnHeader = online.staticTexts.matching(NSPredicate(format: "label == '日语'")).firstMatch
        XCTAssertTrue(jpnHeader.waitForExistence(timeout: 8),
                      "下拉刷新后点开字幕列表，应立即看到新增的日语外挂字幕\n\(online.debugDescription)")
    }

    /// 独立验收 B（#1336 在线字幕补齐）：
    /// 先下载 → 服务端生成 AI 字幕 → 联网补齐（无视频重传）→ 断网实播（新字幕可用、默认选轨不变）→ 同步失败保留上次同步字幕。
    @MainActor
    func testOnlineSubtitleBackfillThenOfflinePlaybackPreservesDefaultAndNoVideoRedownload() throws {
        // Phase 1: 下载 S06E01 原画（5 条内封字幕，embedded:3 默认，0 条外挂）
        let app = downloadInitialOriginalEpisode()

        // Phase 2: 服务端在下载完成后生成 2 条 AI 外挂字幕（服务端 manifest 标 AI 双语 is_default=true）
        try controlPOST("/add_ai_subtitles", body: [:])
        try assertServerHasTwoAISubtitles()

        // Phase 3: 联网补齐之前先断网实播一次，确认下载快照此时确实只有 0 条外挂字幕、默认 embedded:3
        try controlPOST("/mode", body: ["mode": "refuse"])
        app.terminate()
        let offlineBefore = launch(reset: false)
        openOfflineItemDetail(offlineBefore)
        openOfflinePlayerSubtitleMenu(offlineBefore, phaseLabel: "补齐前断网实播")
        assertEmbeddedTracksAndDefault(offlineBefore, phaseLabel: "补齐前断网实播")
        XCTAssertEqual(externalSubtitleRows(offlineBefore).count, 0, "联网补齐前本机快照应有 0 条外挂字幕")
        offlineBefore.terminate()

        // Phase 4: 恢复联网 → 打开详情页触发在线补齐字幕 → 核实只拉 manifest + 字幕，绝不重传视频/建播放会话
        try controlPOST("/mode", body: ["mode": "pass", "delay_paths": [:], "fail_paths": [:]])
        try controlPOST("/clear_log", body: [:])
        let onlineSync = launch(reset: false, route: "/library/1/item/1")
        XCTAssertTrue(onlineSync.staticTexts["item-title"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) {
            let log = self.proxyLog()
            let hasManifest = log.contains { $0.contains("GET /api/v1/offline/manifest?file_id=1 -> 200") }
            let subFetches = log.filter { $0.contains("GET /api/v1/playback/files/1/subtitles") && $0.hasSuffix("-> 200") }
            return hasManifest && subFetches.count >= 2
        }, "联网后应通过 offline/manifest 补齐 2 条外挂字幕：\(proxyLog())")

        let syncLog = proxyLog()
        assertNoVideoRedownloadOrPlaybackSession(in: syncLog, phaseLabel: "联网补齐字幕")
        // 等待原子写盘收尾
        Thread.sleep(forTimeInterval: 0.8)
        onlineSync.terminate()

        // Phase 5: 彻底断网（关闭代理端口）→ 冷启动进入离线模式 → 实播本机副本
        try controlPOST("/mode", body: ["mode": "refuse"])
        let offlineAfter = launch(reset: false)
        openOfflineItemDetail(offlineAfter)
        openOfflinePlayerSubtitleMenu(offlineAfter, phaseLabel: "补齐后断网实播")
        assertEmbeddedTracksAndDefault(offlineAfter, phaseLabel: "补齐后断网实播")

        let syncedExternal = externalSubtitleRows(offlineAfter)
        XCTAssertEqual(syncedExternal.count, 2, "断网实播字幕菜单应包含联网补齐的 2 条外挂字幕\n\(offlineAfter.debugDescription)")
        let aiRow = offlineAfter.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'subtitle-external:sync-' AND label CONTAINS 'ai-bilingual-chs-eng'")
        ).firstMatch
        XCTAssertTrue(aiRow.waitForExistence(timeout: 5), "应找到补齐的 AI 双语外挂字幕行\n\(offlineAfter.debugDescription)")
        XCTAssertFalse(aiRow.isSelected, "新增补齐的 AI 字幕不得改变默认选轨")

        // 断网状态下手动切换到补齐后的 AI 外挂字幕，确认可选可播、无报错
        aiRow.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(offlineAfter.descendants(matching: .any)["player-error"].exists, "断网切换补齐后的外挂字幕不应报错")
        if !aiRow.exists {
            let subBtn = offlineAfter.buttons["player-字幕"]
            if !subBtn.exists {
                let gesture = offlineAfter.otherElements["player-gesture-layer"]
                if gesture.exists { gesture.tap() } else { offlineAfter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                XCTAssertTrue(subBtn.waitForExistence(timeout: 5))
            }
            subBtn.tap()
        }
        XCTAssertTrue(waitUntil(timeout: 5) { aiRow.isSelected }, "断网切换到补齐的 AI 字幕后菜单应保持选中态")
        offlineAfter.terminate()

        // Phase 6: 失败保留原字幕 — 服务端再新增第 3 条日语外挂字幕，但代理对字幕下载注入 HTTP 500
        try controlPOST("/add_extra_subtitle", body: [:])
        try controlPOST("/mode", body: [
            "mode": "pass",
            "delay_paths": [:],
            "fail_paths": ["/api/v1/playback/files/1/subtitles": 500],
        ])
        try controlPOST("/clear_log", body: [:])

        let onlineFail = launch(reset: false, route: "/library/1/item/1")
        XCTAssertTrue(onlineFail.staticTexts["item-title"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) {
            let log = self.proxyLog()
            return log.contains { $0.contains("GET /api/v1/offline/manifest?file_id=1 -> 200") }
                && log.contains { $0.contains("GET /api/v1/playback/files/1/subtitles") && $0.hasSuffix("-> 500") }
        }, "应实际发起补齐并遭遇字幕下载 500 失败：\(proxyLog())")
        assertNoVideoRedownloadOrPlaybackSession(in: proxyLog(), phaseLabel: "字幕补齐失败")
        Thread.sleep(forTimeInterval: 0.8)
        onlineFail.terminate()

        // 再次彻底断网冷启动实播 → 上次成功同步的 2 条 AI 外挂字幕必须完整保留，默认选轨仍是 embedded:3
        try controlPOST("/mode", body: ["mode": "refuse"])
        let offlinePreserved = launch(reset: false)
        openOfflineItemDetail(offlinePreserved)
        openOfflinePlayerSubtitleMenu(offlinePreserved, phaseLabel: "失败后断网实播")
        assertEmbeddedTracksAndDefault(offlinePreserved, phaseLabel: "失败后断网实播")
        XCTAssertEqual(externalSubtitleRows(offlinePreserved).count, 2,
                       "同步失败后必须保留上次成功同步的 2 条外挂字幕，不能清空也不能写入半截第 3 条\n\(offlinePreserved.debugDescription)")
        offlinePreserved.terminate()

        // Phase 7 (回归): 降级 HTTP 200 空清单（audio_tracks/default_audio/subtitles 全空）不得清掉本机已有字幕
        try controlPOST("/mode", body: [
            "mode": "pass",
            "delay_paths": [:],
            "fail_paths": [:],
            "degrade_manifest": true,
        ])
        try controlPOST("/clear_log", body: [:])
        let onlineDegraded = launch(reset: false, route: "/library/1/item/1")
        XCTAssertTrue(onlineDegraded.staticTexts["item-title"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) {
            self.proxyLog().contains { $0.contains("GET /api/v1/offline/manifest?file_id=1 -> 200 [DEGRADED_EMPTY]") }
        }, "应实际命中降级 HTTP 200 空清单：\(proxyLog())")
        assertNoVideoRedownloadOrPlaybackSession(in: proxyLog(), phaseLabel: "降级 HTTP 200 空清单")
        Thread.sleep(forTimeInterval: 0.8)
        onlineDegraded.terminate()

        try controlPOST("/mode", body: ["mode": "refuse"])
        let offlineAfterDegraded = launch(reset: false)
        openOfflineItemDetail(offlineAfterDegraded)
        openOfflinePlayerSubtitleMenu(offlineAfterDegraded, phaseLabel: "降级空清单后断网实播")
        assertEmbeddedTracksAndDefault(offlineAfterDegraded, phaseLabel: "降级空清单后断网实播")
        XCTAssertEqual(externalSubtitleRows(offlineAfterDegraded).count, 2,
                       "降级 HTTP 200 空清单绝对不能清掉上次成功同步的 2 条外挂字幕\n\(offlineAfterDegraded.debugDescription)")
    }

    /// 独立验收 C（慢网回归）：manifest 延迟 6 秒时，在线点播本机副本必须在 2 秒超时窗口内起播（不得阻塞满 6 秒），
    /// 且后台同步在 6 秒后继续收尾，之后断网实播能看到补齐的字幕且默认选轨不变。
    @MainActor
    func testSlowManifestPlaybackDoesNotBlockOnTwoSecondTimeoutAndFinishesInBackground() throws {
        let app = downloadInitialOriginalEpisode()

        // 服务端在下载完成后生成 2 条 AI 外挂字幕，不对当前详情页做刷新，直接注入 6 秒 manifest 延迟并点播本机副本
        try controlPOST("/add_ai_subtitles", body: [:])
        try assertServerHasTwoAISubtitles()
        try controlPOST("/mode", body: [
            "mode": "pass",
            "delay_paths": ["/api/v1/offline/manifest": 6.0],
            "fail_paths": [:],
            "degrade_manifest": false,
        ])
        try controlPOST("/clear_log", body: [:])

        let play = app.buttons["item-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "慢网起播回归：应有播放键")
        let tapAt = Date()
        play.tap()
        // player-video 只有在 startLocal() 结束 2 秒等待并装载引擎后才出现，能真实反映是否被 6 秒 manifest 阻塞
        let video = app.descendants(matching: .any)["player-video"]
        XCTAssertTrue(video.waitForExistence(timeout: 5), "慢网 manifest 延迟 6 秒时，本机起播应在 2 秒超时窗口内完成引擎装载")
        let elapsed = Date().timeIntervalSince(tapAt)
        XCTAssertLessThan(elapsed, 4.5, "慢网 manifest 延迟 6 秒时，2 秒起播等待不得阻塞满 6 秒（实测 \(String(format: "%.2f", elapsed)) 秒）")
        // 确认此时 6 秒延迟的 manifest 确实还没返回（证明不是靠提前返回才快）
        XCTAssertFalse(proxyLog().contains { $0.contains("GET /api/v1/offline/manifest?file_id=1 -> 200") },
                       "本机视频已开播时 6 秒延迟的 manifest 应尚未返回，说明确实按 2 秒超时放行了本机起播")
        XCTAssertFalse(app.descendants(matching: .any)["player-error"].exists, "超时放行本机起播不应报错")

        // 后台同步未被取消：6 秒后 manifest 与 2 条外挂字幕均应拉完落盘，且无视频重传
        XCTAssertTrue(waitUntil(timeout: 15) {
            let log = self.proxyLog()
            let hasManifest = log.contains { $0.contains("GET /api/v1/offline/manifest?file_id=1 -> 200") }
            let subFetches = log.filter { $0.contains("GET /api/v1/playback/files/1/subtitles") && $0.hasSuffix("-> 200") }
            return hasManifest && subFetches.count >= 2
        }, "超时后后台同步不应被取消，应在 6 秒后补齐 2 条外挂字幕：\(proxyLog())")
        assertNoVideoRedownloadOrPlaybackSession(in: proxyLog(), phaseLabel: "慢网后台补齐字幕")
        Thread.sleep(forTimeInterval: 0.8)
        app.terminate()

        // 彻底断网冷启动实播 → 核实后台收尾补齐的 2 条外挂字幕已生效，默认选轨仍为 embedded:3
        try controlPOST("/mode", body: ["mode": "refuse"])
        let offline = launch(reset: false)
        openOfflineItemDetail(offline)
        openOfflinePlayerSubtitleMenu(offline, phaseLabel: "慢网后台补齐后断网实播")
        assertEmbeddedTracksAndDefault(offline, phaseLabel: "慢网后台补齐后断网实播")
        XCTAssertEqual(externalSubtitleRows(offline).count, 2,
                       "慢网超时后后台补齐完成的 2 条外挂字幕应在断网实播时可用\n\(offline.debugDescription)")
    }

    // MARK: - Helpers

    @MainActor
    private func downloadInitialOriginalEpisode() -> XCUIApplication {
        let app = launch(reset: true, route: "/library/1/item/1")
        XCTAssertTrue(app.staticTexts["item-title"].waitForExistence(timeout: 30), "应打开合成剧集详情页")
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 20), "应加载第 6 季第 1 集")

        let aiChip = app.buttons.matching(NSPredicate(format: "label CONTAINS '简体中文 + 英语'")).firstMatch
        let chiChip = app.buttons.matching(NSPredicate(format: "label CONTAINS '中文' AND label CONTAINS '×3'")).firstMatch
        XCTAssertTrue(chiChip.waitForExistence(timeout: 15), "下载前详情页应显示 3 条内封中文轨\n\(app.debugDescription)")
        XCTAssertFalse(aiChip.exists, "下载前尚未生成 AI 双语字幕")

        let card = app.buttons["episode-1"]
        card.press(forDuration: 1.2)
        let dlItem = app.buttons["下载这一集"]
        XCTAssertTrue(dlItem.waitForExistence(timeout: 5), "长按分集卡应出现「下载这一集」")
        dlItem.tap()
        let original = app.buttons["offline-profile-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 20), "选档面板应列出原画")
        original.tap()
        app.buttons["offline-profile-confirm"].tap()

        let downloadedBadge = app.images.matching(NSPredicate(format: "label == '已下载'"))
        XCTAssertTrue(waitUntil(timeout: 90) { downloadedBadge.count >= 1 }, "S06E01 原画应下载完成")
        return app
    }

    private func assertServerHasTwoAISubtitles() throws {
        let backend = LabBackend(server: backendURL, username: username, password: password)
        let itemData = try XCTUnwrap(backend.request("GET", "/libraries/1/items/1") as? [String: Any])
        let serverFiles = try XCTUnwrap(itemData["files"] as? [[String: Any]])
        let serverFile = try XCTUnwrap(serverFiles.first)
        let serverSubs = try XCTUnwrap(serverFile["subtitle_streams"] as? [[String: Any]])
        let externalSubs = serverSubs.filter { ($0["external"] as? Bool) == true }
        XCTAssertEqual(externalSubs.count, 2, "服务端详情应返回 2 条外挂 AI 字幕：\(serverSubs)")

        let manifest = try XCTUnwrap(backend.request("GET", "/offline/manifest?file_id=1") as? [String: Any])
        let manifestSubs = try XCTUnwrap(manifest["subtitles"] as? [[String: Any]])
        XCTAssertTrue(manifestSubs.contains {
            ($0["track_ref"] as? String)?.contains("ai-bilingual-chs-eng.chi.srt") == true && ($0["is_default"] as? Bool) == true
        }, "服务端 offline/manifest 应包含新增且标为默认的 AI 字幕：\(manifestSubs)")
    }

    @MainActor
    private func openOfflineItemDetail(_ app: XCUIApplication) {
        let offlineHome = app.descendants(matching: .any)["offline-home"]
        XCTAssertTrue(offlineHome.waitForExistence(timeout: 25), "断网冷启动应自动进入离线首页")
        app.buttons["offline-item-1"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["item-title"].waitForExistence(timeout: 15), "离线应从本地 detail.json 打开详情页")
    }

    @MainActor
    private func openOfflinePlayerSubtitleMenu(_ app: XCUIApplication, phaseLabel: String) {
        let play = app.buttons["item-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "\(phaseLabel)：应有播放键")
        play.tap()
        let screen = app.descendants(matching: .any)["player-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "\(phaseLabel)：应进入播放器")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(app.descendants(matching: .any)["player-error"].exists, "\(phaseLabel)：本机副本应正常起播")

        let subBtn = app.buttons["player-字幕"]
        if !subBtn.exists {
            let gesture = app.otherElements["player-gesture-layer"]
            if gesture.exists { gesture.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            XCTAssertTrue(subBtn.waitForExistence(timeout: 5), "\(phaseLabel)：控制层应有字幕按钮\n\(app.debugDescription)")
        }
        subBtn.tap()
    }

    @MainActor
    private func assertEmbeddedTracksAndDefault(_ app: XCUIApplication, phaseLabel: String) {
        for idx in 0 ... 4 {
            XCTAssertTrue(app.buttons["subtitle-embedded:\(idx)"].waitForExistence(timeout: 5),
                          "\(phaseLabel)：字幕菜单应有内封轨 embedded:\(idx)\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["subtitle-embedded:3"].isSelected },
                      "\(phaseLabel)：默认选轨必须保持原容器默认轨 embedded:3 不变")
    }

    @MainActor
    private func externalSubtitleRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subtitle-external:'"))
    }

    private func assertNoVideoRedownloadOrPlaybackSession(in log: [String], phaseLabel: String) {
        XCTAssertFalse(log.contains { $0.contains("/api/v1/offline/files/1/content") },
                       "\(phaseLabel)：不得重下原画视频：\(log)")
        XCTAssertFalse(log.contains { $0.contains("/api/v1/offline/exports") },
                       "\(phaseLabel)：不得触发转码导出：\(log)")
        XCTAssertFalse(log.contains { $0.contains("/api/v1/playback/sessions") },
                       "\(phaseLabel)：不得建立服务端播放会话：\(log)")
        XCTAssertFalse(log.contains { $0.contains("/api/v1/playback/files/1/stream") },
                       "\(phaseLabel)：不得拉取视频流：\(log)")
    }

    @MainActor
    private func launch(reset: Bool, route: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--ui-testing"]
        if reset {
            args += ["--reset-state", "-mcServer", proxy, "-mcUser", username, "-mcPass", password]
        }
        if let route { args += ["-mcRoute", route] }
        app.launchArguments = args
        app.launch()
        return app
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    private func controlAvailable() -> Bool {
        guard let url = URL(string: control + "/info") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, err in
            ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return ok
    }

    private func controlPOST(_ path: String, body: [String: Any]) throws {
        var req = URLRequest(url: URL(string: control + path)!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        var status = 0
        URLSession.shared.dataTask(with: req) { _, resp, err in
            failure = err
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        if let failure { throw failure }
        guard (200 ..< 300).contains(status) else {
            throw NSError(domain: "OfflinePostDownloadSubtitleUITests", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "control POST \(path) failed with HTTP \(status)"])
        }
    }

    private func proxyLog() -> [String] {
        let sem = DispatchSemaphore(value: 0)
        var lines: [String] = []
        URLSession.shared.dataTask(with: URL(string: control + "/log")!) { data, _, _ in
            lines = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String]) ?? []
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return lines
    }
}

private final class LabBackend {
    let base: String
    let session: URLSession

    init(server: String, username: String, password: String) {
        base = server.hasSuffix("/") ? String(server.dropLast()) : server
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config)
        _ = request("POST", "/auth/login", body: ["username": username, "password": password, "remember": true])
    }

    @discardableResult
    func request(_ method: String, _ path: String, body: Any? = nil) -> Any? {
        var req = URLRequest(url: URL(string: base + "/api/v1" + path)!)
        req.httpMethod = method
        req.setValue("zh-Hans", forHTTPHeaderField: "Accept-Language")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let sem = DispatchSemaphore(value: 0)
        var result: Any?
        session.dataTask(with: req) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = json["data"]
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        return result
    }
}
