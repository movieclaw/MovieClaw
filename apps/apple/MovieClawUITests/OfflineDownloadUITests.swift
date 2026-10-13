import XCTest

/// 离线下载的端到端验收（docs/design/offline-download.md §12）：真 App、真服务器、真片源。
///
/// App 连的是故障注入代理（`MC_OFFLINE_PROXY`，默认 http://127.0.0.1:18770），代理后面是服务器；
/// 测试经代理的控制口（`MC_OFFLINE_CONTROL`，默认 http://127.0.0.1:18771）切换「正常 / 慢 / 黑洞 / 拒绝 / 门户页」，
/// 并直连服务器（`MC_OFFLINE_BACKEND`，默认 http://127.0.0.1:18765）核对观看记录有没有按真实时间回到服务器。
/// 台子见 /tmp/mc-offline-e2e（不入库）：电影库 1 部 6 分钟 1080p mp4（带外挂字幕），剧集库 1 部剧 3 集 mkv。
final class OfflineDownloadUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var proxy: String { env["MC_OFFLINE_PROXY"] ?? "http://127.0.0.1:18770" }
    private var control: String { env["MC_OFFLINE_CONTROL"] ?? "http://127.0.0.1:18771" }
    private var backendURL: String { env["MC_OFFLINE_BACKEND"] ?? "http://127.0.0.1:18765" }
    private var username: String { env["MC_TEST_USERNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 } ?? "Sup3rSecret!" }
    private let movieId = 1
    private let showId = 2

    override func setUp() {
        continueAfterFailure = false
        setMode(["mode": "pass"])
    }

    override func tearDown() {
        setMode(["mode": "pass"])
    }

    // MARK: 用例

    /// 下载原画 → 断网（拒绝连接）冷启动 → 自动进离线首页 → 只读详情 → 播本机 → 恢复连接 → 观看记录按真实时间回到服务器
    @MainActor
    func test1DownloadPlayOfflineAndSync() throws {
        let app = launch(reset: true, route: "/library/1/item/\(movieId)")
        XCTAssertTrue(app.staticTexts["item-title"].waitForExistence(timeout: 30), "应进入电影详情")
        download(app, profile: "original")
        snapshot("1-downloaded")

        setMode(["mode": "refuse"])
        app.terminate()
        let offline = launch(reset: false)
        let home = offline.descendants(matching: .any)["offline-home"]
        let started = Date()
        XCTAssertTrue(home.waitForExistence(timeout: 25), "连接被拒时冷启动应自动进入离线首页")
        print("[OfflineE2E] 拒绝连接 → 进入离线首页用时 \(Int(Date().timeIntervalSince(started))) 秒")
        snapshot("2-offline-home")

        offline.buttons["offline-item-\(movieId)"].firstMatch.tap()
        XCTAssertTrue(offline.staticTexts["item-title"].waitForExistence(timeout: 15), "离线时详情页从本机打开")
        XCTAssertFalse(offline.buttons["item-actions"].exists, "离线时详情页只读：没有管理菜单")
        XCTAssertFalse(offline.buttons["item-favorite"].exists, "离线时不能收藏")
        snapshot("3-offline-detail")

        let playedFrom = Date()
        offline.buttons["item-play"].tap()
        let close = offline.buttons["player-close"]
        // 播 25 秒（超过片长 5%，服务端与本机才记续播点）
        Thread.sleep(forTimeInterval: 25)
        XCTAssertFalse(offline.descendants(matching: .any)["player-error"].exists, "本机副本应能直接播")
        snapshot("4-offline-playing")
        offline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(offline.buttons["item-play"].waitForExistence(timeout: 10))
        let label = offline.buttons["item-play"].label
        XCTAssertTrue(label.contains("继续"), "看了一段回来，播放键应是「继续」：\(label)")

        // 恢复连接：回首页点「重新连接」，应回到在线、观看记录补传
        setMode(["mode": "pass"])
        offline.navigationBars.buttons.element(boundBy: 0).tap()
        // 可能已经自动连上了（探测或页面请求成功）；还停在离线首页就点「重新连接」
        let reconnect = offline.buttons["offline-reconnect"]
        if reconnect.waitForExistence(timeout: 3) { reconnect.tap() }
        XCTAssertTrue(waitUntil(timeout: 45) { !home.exists }, "连上之后应自动回到在线首页")
        snapshot("5-back-online")

        let backend = Backend(server: backendURL, username: username, password: password)
        var resume: [String: Any] = [:]
        XCTAssertTrue(waitUntil(timeout: 30) {
            resume = backend.request("GET", "/playback/resume?media_item_id=\(self.movieId)") as? [String: Any] ?? [:]
            return (resume["position_ms"] as? Int ?? 0) > 5000
        }, "离线看到的位置应回到服务器：\(resume)")
        let history = backend.request("GET", "/playback/history?limit=5") as? [String: Any] ?? [:]
        let entries = history["entries"] as? [[String: Any]] ?? []
        let entry = try XCTUnwrap(entries.first { (($0["media"] as? [String: Any])?["media_item_id"] as? Int) == movieId },
                                  "观看历史应有这一场：\(history)")
        let startedAt = try XCTUnwrap(ISO8601DateFormatter.flexible(entry["started_at"] as? String))
        XCTAssertLessThan(abs(startedAt.timeIntervalSince(playedFrom)), 30, "观看历史的开始时间是离线时真正开始看的时间，不是补传那一刻")
    }

    /// 机场门户页、黑洞（只超时）两种「有网但回不了家」：冷启动都应进离线首页；门户页明确、几秒内，黑洞要满 30 秒
    @MainActor
    func test2CaptivePortalAndBlackholeColdStart() throws {
        ensureMovieDownloaded()
        setMode(["mode": "html"])
        var app = launch(reset: false)
        var started = Date()
        XCTAssertTrue(app.descendants(matching: .any)["offline-home"].waitForExistence(timeout: 20), "门户页：冷启动应进离线")
        print("[OfflineE2E] 门户页 → 进入离线首页用时 \(Int(Date().timeIntervalSince(started))) 秒")
        app.terminate()

        setMode(["mode": "blackhole"])
        app = launch(reset: false)
        started = Date()
        XCTAssertTrue(app.descendants(matching: .any)["offline-home"].waitForExistence(timeout: 60), "黑洞：冷启动应进离线")
        let elapsed = Date().timeIntervalSince(started)
        print("[OfflineE2E] 黑洞 → 进入离线首页用时 \(Int(elapsed)) 秒")
        XCTAssertGreaterThanOrEqual(elapsed, 25, "只有超时的情况要满 30 秒才判断连不上（不因一次慢就切）")
        snapshot("6-blackhole-offline")
        app.terminate()
    }

    /// 网慢不切离线：1.5 秒延迟 + 50 KB/s + 一成连接被掐，持续浏览 10 分钟，离线首页一次都不能出现
    @MainActor
    func test3SlowNetworkStaysOnline() throws {
        ensureMovieDownloaded()
        let app = launch(reset: false)
        XCTAssertTrue(app.descendants(matching: .any)["library-stats"].waitForExistence(timeout: 30)
            || app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library-card-'")).firstMatch.waitForExistence(timeout: 10))
        setMode(["mode": "slow", "latency_ms": 1500, "bps": 50_000, "drop": 0.1])
        let offlineHome = app.descendants(matching: .any)["offline-home"]
        let deadline = Date().addingTimeInterval(600)
        var rounds = 0
        while Date() < deadline {
            rounds += 1
            // 媒体库首页 → 剧集详情 → 返回，再下拉刷新；中途反复检查没切到离线
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library-card-'")).firstMatch
            if card.waitForExistence(timeout: 20) { card.tap() }
            XCTAssertFalse(offlineHome.exists, "网慢时不该切到离线（第 \(rounds) 轮）")
            Thread.sleep(forTimeInterval: 8)
            XCTAssertFalse(offlineHome.exists, "网慢时不该切到离线（第 \(rounds) 轮）")
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
            Thread.sleep(forTimeInterval: 8)
            XCTAssertFalse(offlineHome.exists, "网慢时不该切到离线（第 \(rounds) 轮）")
            app.swipeDown()
            Thread.sleep(forTimeInterval: 6)
        }
        print("[OfflineE2E] 慢网浏览 \(rounds) 轮、10 分钟，始终在线")
        XCTAssertFalse(offlineHome.exists)
        snapshot("7-slow-still-online")
    }

    /// 改下 480p（服务端边转边下）：点了就退到后台，后台照样下完；回来是 480p 那份
    @MainActor
    func test4TranscodedDownloadContinuesInBackground() throws {
        ensureMovieDownloaded()
        let app = launch(reset: false, route: "/library/1/item/\(movieId)")
        let control = app.buttons["item-download"]
        XCTAssertTrue(control.waitForExistence(timeout: 30))
        if (control.value as? String) == "done|480p" {
            // 上一轮已经是 480p：先换回原画，这一轮才真的走一遍「换档 + 边转边下」
            switchProfile(app, to: "original")
            XCTAssertTrue(waitUntil(timeout: 120) { (control.value as? String) == "done|original" })
        }
        let resumeBefore = app.buttons["item-play"].label
        switchProfile(app, to: nil)
        let profile = app.buttons["offline-profile-480p"]
        XCTAssertTrue(profile.waitForExistence(timeout: 30), "1080p 源应提供 480p")
        profile.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { (control.value as? String)?.hasSuffix("|480p") == true })
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 40)
        app.activate()
        XCTAssertTrue(waitUntil(timeout: 120) { (control.value as? String) == "done|480p" }, "后台应下完：\(control.value ?? "")")
        snapshot("8-480p-done")
        XCTAssertEqual(app.buttons["item-play"].label, resumeBefore, "换档不丢本机进度：播放键前后一致")
        // 本机的转码档（分片 MP4）能直接播：拖到中间也能接着放
        app.buttons["item-play"].tap()
        Thread.sleep(forTimeInterval: 8)
        XCTAssertFalse(app.descendants(matching: .any)["player-error"].exists, "转码档本机副本应能播")
        let progress = app.descendants(matching: .any)["player-progress"]
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if progress.waitForExistence(timeout: 5) {
            progress.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 5)
            XCTAssertFalse(app.descendants(matching: .any)["player-error"].exists, "拖动后应能接着放")
        }
        snapshot("8b-480p-playing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let close = app.buttons["player-close"]
        if close.waitForExistence(timeout: 5) { close.tap() }
    }

    /// 整季下载（3 集原画）→ 我的 → 下载与存储 → 左滑删除整部剧 → 目录空了
    @MainActor
    func test5SeasonDownloadAndDeleteFromStorage() throws {
        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        XCTAssertTrue(app.staticTexts["item-title"].waitForExistence(timeout: 30))
        let menu = app.buttons["season-download-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '下载本季未下载的'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        let original = app.buttons["offline-profile-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        original.tap()
        let downloaded = app.descendants(matching: .any).matching(NSPredicate(format: "label == '已下载'"))
        XCTAssertTrue(waitUntil(timeout: 180) { downloaded.count >= 3 }, "三集都应下完")
        snapshot("9-season-downloaded")

        app.terminate()
        let more = launch(reset: false, route: "/my/downloads")
        let row = more.descendants(matching: .any).matching(identifier: "offline-storage-item-\(showId)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "存储页应列出这部剧")
        snapshot("10a-storage")
        let cell = more.cells.containing(.any, identifier: "offline-storage-item-\(showId)").firstMatch
        (cell.exists ? cell : row).swipeLeft()
        let delete = more.buttons.matching(NSPredicate(format: "label == '删除'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "左滑应出「删除」")
        delete.tap()
        let confirm = more.buttons.matching(NSPredicate(format: "label BEGINSWITH '删除（释放'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !row.exists }, "删除后这一行应消失")
        snapshot("10-storage-after-delete")
    }

    // MARK: 工具

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

    /// 详情页点「下载」→ 选档 → 等下完
    @MainActor
    private func download(_ app: XCUIApplication, profile: String) {
        let control = app.buttons["item-download"]
        XCTAssertTrue(control.waitForExistence(timeout: 20), "应有下载按钮")
        control.tap()
        let option = app.buttons["offline-profile-\(profile)"]
        XCTAssertTrue(option.waitForExistence(timeout: 30), "选档 sheet 应列出 \(profile)")
        option.tap()
        XCTAssertTrue(waitUntil(timeout: 120) { (control.value as? String) == "done|\(profile)" },
                      "应下完：\(control.value ?? "")")
    }

    /// 已下载的按钮 → 「改下其他画质」→ 选档（profile 为 nil 时只打开 sheet）
    @MainActor
    private func switchProfile(_ app: XCUIApplication, to profile: String?) {
        app.buttons["item-download"].tap()
        let change = app.buttons["改下其他画质"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        change.tap()
        guard let profile else { return }
        let option = app.buttons["offline-profile-\(profile)"]
        XCTAssertTrue(option.waitForExistence(timeout: 30))
        option.tap()
    }

    @MainActor
    private func ensureMovieDownloaded() {
        let app = launch(reset: false, route: "/library/1/item/\(movieId)")
        let control = app.buttons["item-download"]
        if control.waitForExistence(timeout: 30), (control.value as? String)?.hasPrefix("done") == true {
            app.terminate()
            return
        }
        app.terminate()
        let fresh = launch(reset: true, route: "/library/1/item/\(movieId)")
        download(fresh, profile: "original")
        fresh.terminate()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return condition()
    }

    private func setMode(_ body: [String: Any]) {
        var request = URLRequest(url: URL(string: control + "/mode")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 5)
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension ISO8601DateFormatter {
    /// 服务端时间带不带毫秒都认
    static func flexible(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

private final class Backend {
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
        var request = URLRequest(url: URL(string: base + "/api/v1" + path)!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Any?
        session.dataTask(with: request) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { result = json["data"] }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return result
    }
}
