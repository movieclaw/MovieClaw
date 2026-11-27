import XCTest

/// Issue #1336 合成素材端到端验证：
/// 先下载原画本机副本 → 服务端后续生成 AI 外挂字幕 → 分别验证：
/// 1) 离线无网络：详情页与本机播放都只能看到下载快照（无法发现新字幕）；
/// 2) 联网打开详情页（本地 detail.json 秒开 → 服务端刷新，fileCount 不变）与下拉刷新：
///    已定义的详情刷新契约必须能立即展示服务端新字幕（回归修复验证）；
/// 3) 联网播放本机副本：按当前 offline-download.md §6 契约仍优先直放本机副本与 playback.json 快照
///    （不建服务端会话、不拉 manifest，新增增量同步 / 默认字幕属于待确认产品方案）。
///
/// 外部隔离实验台契约（默认 proxy `http://127.0.0.1:18870`、control `http://127.0.0.1:18871`、backend `http://127.0.0.1:18865`，
/// 均可通过 `MC_1336_PROXY` / `MC_1336_CONTROL` / `MC_1336_BACKEND` 覆盖）：
/// - 夹具：剧集库 1 / 条目 1 / 文件 1（S06E01 合成 MKV，5 条内封字幕：3 中文 + 2 英语，容器默认 `embedded:3`，初始无外挂字幕）；
/// - 控制口：`GET /info`（存活探针）、`GET /log`、`POST /clear_log`、`POST /mode`（`pass` / `refuse` + `delay_paths`）、
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
        try controlPOST("/mode", body: ["mode": "pass", "delay_paths": [:]])
        try controlPOST("/reset_subtitles", body: [:])
        try controlPOST("/clear_log", body: [:])
    }

    override func tearDown() {
        try? controlPOST("/mode", body: ["mode": "pass", "delay_paths": [:]])
    }

    @MainActor
    func testPostDownloadSubtitlesOfflineVsOnlineDetailAndLocalPlayback() throws {
        // Phase 1: 服务端仅有 5 条内封字幕（3 中文 + 2 英语，embedded:3 为容器默认），先下载 S06E01 原画
        let app = launch(reset: true, route: "/library/1/item/1")
        XCTAssertTrue(app.staticTexts["item-title"].waitForExistence(timeout: 30), "应打开合成剧集详情页")
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 20), "应加载第 6 季第 1 集")

        let aiChip = app.buttons.matching(NSPredicate(format: "label CONTAINS '简体中文 + 英语'")).firstMatch
        let chiChip = app.buttons.matching(NSPredicate(format: "label CONTAINS '中文' AND label CONTAINS '×3'")).firstMatch
        XCTAssertTrue(chiChip.waitForExistence(timeout: 15), "下载前详情页应显示 3 条内封中文轨\n\(app.debugDescription)")
        XCTAssertFalse(aiChip.exists, "下载前尚未生成 AI 双语字幕")

        // 长按分集卡下载原画
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

        // Phase 2: 服务端在下载完成后生成两条 AI 外挂字幕，并核对服务端台账与 manifest
        try controlPOST("/add_ai_subtitles", body: [:])
        let backend = LabBackend(server: backendURL, username: username, password: password)
        let itemData = try XCTUnwrap(backend.request("GET", "/libraries/1/items/1") as? [String: Any])
        let serverFiles = try XCTUnwrap(itemData["files"] as? [[String: Any]])
        let serverFile = try XCTUnwrap(serverFiles.first)
        let serverSubs = try XCTUnwrap(serverFile["subtitle_streams"] as? [[String: Any]])
        let externalSubs = serverSubs.filter { ($0["external"] as? Bool) == true }
        XCTAssertEqual(externalSubs.count, 2, "服务端详情应返回 2 条外挂 AI 字幕：\(serverSubs)")
        let defaults = serverFile["playback_defaults"] as? [String: Any]
        XCTAssertTrue((defaults?["subtitle_track"] as? String)?.contains("ai-bilingual-chs-eng.chi.srt") == true,
                      "服务端 playback_defaults 应默认选中 AI 双语字幕：\(String(describing: defaults))")

        let manifest = try XCTUnwrap(backend.request("GET", "/offline/manifest?file_id=1") as? [String: Any])
        let manifestSubs = try XCTUnwrap(manifest["subtitles"] as? [[String: Any]])
        XCTAssertTrue(manifestSubs.contains { ($0["track_ref"] as? String)?.contains("ai-bilingual-chs-eng.chi.srt") == true && ($0["is_default"] as? Bool) == true },
                      "服务端 offline/manifest 应包含新增的默认 AI 字幕：\(manifestSubs)")

        // Phase 3: 离线无网络（代理拒绝连接）→ 详情页和本机播放都只能看到下载快照，无法发现新字幕
        try controlPOST("/mode", body: ["mode": "refuse"])
        app.terminate()
        let offline = launch(reset: false)
        let offlineHome = offline.descendants(matching: .any)["offline-home"]
        XCTAssertTrue(offlineHome.waitForExistence(timeout: 25), "断网冷启动应自动进入离线首页")
        offline.buttons["offline-item-1"].firstMatch.tap()
        XCTAssertTrue(offline.staticTexts["item-title"].waitForExistence(timeout: 15), "离线应从本地 detail.json 打开详情页")
        let offlineChiChip = offline.buttons.matching(NSPredicate(format: "label CONTAINS '中文' AND label CONTAINS '×3'")).firstMatch
        let offlineAiChip = offline.buttons.matching(NSPredicate(format: "label CONTAINS '简体中文 + 英语'")).firstMatch
        XCTAssertTrue(offlineChiChip.waitForExistence(timeout: 10), "离线详情页应显示下载快照里的中文 ×3")
        XCTAssertFalse(offlineAiChip.exists, "离线无网络时详情页无法发现服务端后生成的 AI 字幕")

        verifyLocalPlayerSubtitleSnapshot(offline, phaseLabel: "离线播放")

        // Phase 4: 恢复联网 → 延迟 GET /libraries/1/items/1 900ms 以稳定复现「本地 detail.json 秒开 → 分集先 report() → 在线 detail 返回但 fileCount 不变」
        try controlPOST("/mode", body: ["mode": "pass", "delay_paths": ["/api/v1/libraries/1/items/1": 0.9]])
        try controlPOST("/clear_log", body: [:])
        offline.terminate()

        let online = launch(reset: false, route: "/library/1/item/1")
        XCTAssertTrue(online.staticTexts["item-title"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.proxyLog().contains { $0.contains("GET /api/v1/libraries/1/items/1 -> 200") }
        }, "联网打开详情页应请求服务端最新详情：\(proxyLog())")

        // 已定义行为契约：联网打开已下载条目详情时，服务端新详情回来后必须刷新字幕行（不得停在旧快照）
        let onlineAiChip = online.buttons.matching(NSPredicate(format: "label CONTAINS '简体中文 + 英语'")).firstMatch
        XCTAssertTrue(onlineAiChip.waitForExistence(timeout: 8),
                      "联网刷新详情后，剧集字幕行必须展示新生成的 AI 双语字幕（不能停在 detail.json 旧快照）\n\(online.debugDescription)")

        // 同页停留期间服务端再新增一条外挂字幕 → 下拉刷新后应立即反映，不必退出重进
        try controlPOST("/mode", body: ["mode": "pass", "delay_paths": [:]])
        try controlPOST("/add_extra_subtitle", body: [:])
        try controlPOST("/clear_log", body: [:])
        let scroll = online.scrollViews.firstMatch
        if scroll.exists { scroll.swipeDown() } else { online.swipeDown() }
        XCTAssertTrue(waitUntil(timeout: 10) {
            self.proxyLog().contains { $0.contains("GET /api/v1/libraries/1/items/1 -> 200") }
        }, "下拉刷新应重新拉取详情")
        onlineAiChip.tap()
        let jpnHeader = online.staticTexts.matching(NSPredicate(format: "label == '日语'")).firstMatch
        XCTAssertTrue(jpnHeader.waitForExistence(timeout: 8),
                      "下拉刷新后点开字幕列表，应立即看到新增的日语外挂字幕\n\(online.debugDescription)")
        if online.buttons["sheet-close"].exists { online.buttons["sheet-close"].tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { !online.buttons["sheet-close"].exists })

        // Phase 5: 联网播放本机副本 → 核对当前 §6 契约（优先播本机，不建服务端会话、不拉 manifest，字幕菜单仍停在下载快照）
        try controlPOST("/clear_log", body: [:])
        verifyLocalPlayerSubtitleSnapshot(online, phaseLabel: "联网播放本机副本")
        let playLog = proxyLog()
        XCTAssertFalse(playLog.contains { $0.contains("/api/v1/playback/sessions") },
                       "当前 §6 契约：联网播放本机副本不建服务端会话：\(playLog)")
        XCTAssertFalse(playLog.contains { $0.contains("/api/v1/offline/manifest") },
                       "当前 §6 契约：联网播放本机副本不拉 offline/manifest：\(playLog)")
    }

    @MainActor
    private func verifyLocalPlayerSubtitleSnapshot(_ app: XCUIApplication, phaseLabel: String) {
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

        for idx in 0 ... 4 {
            XCTAssertTrue(app.buttons["subtitle-embedded:\(idx)"].waitForExistence(timeout: 5),
                          "\(phaseLabel)：字幕菜单应有内封轨 embedded:\(idx)\n\(app.debugDescription)")
        }
        let externalRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subtitle-external:'"))
        XCTAssertEqual(externalRows.count, 0, "\(phaseLabel)：下载快照里无外挂字幕，菜单不应出现后生成的外挂轨")
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["subtitle-embedded:3"].isSelected },
                      "\(phaseLabel)：无外部默认轨时应回落到容器默认轨 embedded:3")
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
