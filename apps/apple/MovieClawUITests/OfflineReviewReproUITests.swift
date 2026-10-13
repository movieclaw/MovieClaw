import XCTest

/// 代码评审发现的离线下载问题的端到端复现（docs/design/offline-download.md）：先确认问题真的存在，再修，
/// 修完同一批用例转绿。台子同 `OfflineDownloadUITests`（/tmp/mc-offline-e2e）。
final class OfflineReviewReproUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var proxy: String { env["MC_OFFLINE_PROXY"] ?? "http://127.0.0.1:18770" }
    private var control: String { env["MC_OFFLINE_CONTROL"] ?? "http://127.0.0.1:18771" }
    private var backendURL: String { env["MC_OFFLINE_BACKEND"] ?? "http://127.0.0.1:18765" }
    private let username = "admin"
    private let password = "Sup3rSecret!"
    private let movieId = 1
    private let showId = 2

    override func setUp() {
        continueAfterFailure = false
        setMode(["mode": "pass"])
    }

    override func tearDown() {
        setMode(["mode": "pass"])
    }

    /// 下载被服务器回 503（转码还在排队，Retry-After 15 秒）：App 一直在前台，到点应自己重试下完
    @MainActor
    func testDownloadRetriesAfterServerBusyInForeground() throws {
        let app = launch(reset: true, route: "/library/1/item/\(movieId)")
        let control = app.buttons["item-download"]
        XCTAssertTrue(control.waitForExistence(timeout: 30))
        // 过了冷启动的自动离线窗口：不靠「重新连上」来触发重试
        Thread.sleep(forTimeInterval: 65)
        setMode(["mode": "pass", "fail_paths": ["/api/v1/offline/files/"], "fail_status": 503,
                 "retry_after": 15, "fail_times": 1])
        startDownload(app, profile: "original")
        XCTAssertTrue(waitUntil(timeout: 20) { (control.value as? String)?.hasPrefix("failed") == true },
                      "先收到 503：\(control.value ?? "")")
        XCTAssertTrue(waitUntil(timeout: 90) { (control.value as? String) == "done|original" },
                      "Retry-After 到点后应自己重试并下完：\(control.value ?? "")")
    }

    /// 暂停再继续：应接着下完（续传后的大小校验不能误判、不能卡住）
    @MainActor
    func testPauseThenResumeFinishes() throws {
        let app = launch(reset: true, route: "/library/1/item/\(movieId)")
        let control = app.buttons["item-download"]
        XCTAssertTrue(control.waitForExistence(timeout: 30))
        setMode(["mode": "slow", "bps": 1_000_000])
        startDownload(app, profile: "original")
        XCTAssertTrue(waitUntil(timeout: 30) { (control.value as? String)?.hasPrefix("downloading") == true })
        Thread.sleep(forTimeInterval: 15)
        control.tap()
        tapMenuItem(app, "暂停")
        XCTAssertTrue(waitUntil(timeout: 10) { (control.value as? String)?.hasPrefix("paused") == true })
        Thread.sleep(forTimeInterval: 3)
        setMode(["mode": "pass"])
        control.tap()
        tapMenuItem(app, "继续下载")
        XCTAssertTrue(waitUntil(timeout: 120) { (control.value as? String) == "done|original" },
                      "继续后应下完：\(control.value ?? "")")
        // 续传：继续之后的那个请求应带 Range（从已下的位置接着要），而不是从头重下
        let log = proxyLog().filter { $0.contains("/offline/files/") }
        XCTAssertTrue(log.last?.contains("Range: bytes=") == true && log.last?.contains("bytes=0-") == false,
                      "继续下载应从断点续传：\(log.suffix(3))")
    }

    /// 在线放本机副本：起播点应取服务器上更新的续播点（在电视上看到了 200 秒）
    @MainActor
    func testLocalPlaybackUsesNewerServerResumePoint() throws {
        ensureMovieDownloaded()
        let backend = Backend(server: backendURL, username: username, password: password)
        // 每次一个新值（别的用例打开过详情页，会把服务器上旧的续播点同步进本机）
        let target = Int.random(in: 150 ... 250)
        backend.request("POST", "/playback/progress", body: ["media_item_id": movieId, "event": "start"])
        backend.request("POST", "/playback/progress", body: ["media_item_id": movieId, "event": "stop", "position_ms": target * 1000])
        // 从首页进（不经详情页：详情页会顺手把服务器续播点写进本机），再起播
        let app = launch(reset: false, route: "/library", then: "/play/\(movieId)")
        Thread.sleep(forTimeInterval: 12)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let time = app.staticTexts["player-time"]
        XCTAssertTrue(time.waitForExistence(timeout: 10))
        let seconds = Int(time.value as? String ?? "") ?? 0
        XCTAssertTrue((target - 2 ... target + 30).contains(seconds), "应从服务器上的 \(target) 秒接着放，实际 \(seconds) 秒")
    }

    /// 播放中 App 被系统结束（不走正常收尾）：重开后这场观看在服务端应当收口（有结束时间）
    @MainActor
    func testKilledPlaybackViewingIsClosedOnNextLaunch() throws {
        ensureMovieDownloaded()
        let app = launch(reset: false, route: "/play/\(movieId)")
        Thread.sleep(forTimeInterval: 15)
        app.terminate()
        let again = launch(reset: false)
        Thread.sleep(forTimeInterval: 15)
        again.terminate()
        let backend = Backend(server: backendURL, username: username, password: password)
        let history = backend.request("GET", "/playback/history?limit=1") as? [String: Any] ?? [:]
        let entry = try XCTUnwrap((history["entries"] as? [[String: Any]])?.first)
        XCTAssertFalse(entry["ended_at"] is NSNull, "被结束的那场观看应在重开后收口：\(entry)")
    }

    /// 在详情页时短暂断网、刷新失败：网络恢复后页面应自己回到可操作（管理菜单回来）
    @MainActor
    func testDetailRecoversFromTransientFailure() throws {
        ensureMovieDownloaded()
        // 详情接口失败一次（像反向代理一时回了 502）：页面回落本机副本、只读
        setMode(["mode": "pass", "fail_paths": ["/api/v1/libraries/1/items/1"], "fail_status": 502, "fail_times": 1])
        // 先进首页等本机目录读完（冷启动目录还没读完时的问题另有用例），再进详情
        let app = launch(reset: false, route: "/library", then: "/library/1/item/\(movieId)")
        let actions = app.buttons["item-actions"]
        XCTAssertTrue(app.staticTexts["item-title"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 15) { !actions.exists }, "请求失败时回落本机副本（只读）")
        // 之后接口都正常：页面应自己回到在线详情（管理菜单回来）
        XCTAssertTrue(waitUntil(timeout: 60) { actions.exists }, "接口恢复后应自己回到在线详情")
    }

    /// 离线时删掉整季下载：页面上不能还显示那几集已下载
    @MainActor
    func testOfflineSeasonDeleteRefreshesPage() throws {
        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        let menu = app.buttons["season-download-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        tapMenuItem(app, prefix: "下载本季未下载的")
        let original = app.buttons["offline-profile-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        // 只数分集卡上的「已下载」角标（图片）；下载前必须是 0，免得别处同名标签让这一步提前过
        let downloaded = app.images.matching(NSPredicate(format: "label == '已下载'"))
        XCTAssertEqual(downloaded.count, 0, app.debugDescription)
        original.tap()
        XCTAssertTrue(waitUntil(timeout: 180) { downloaded.count >= 3 })
        setMode(["mode": "refuse"])
        app.terminate()
        let offline = launch(reset: false, route: "/library/2/item/\(showId)")
        XCTAssertTrue(offline.buttons["season-download-menu"].waitForExistence(timeout: 30))
        // 冷启动后 6～11 秒才判定离线，期间页面会重排一次，点开的菜单可能被收掉：没出来就再点
        let deleteSeason = offline.buttons["删除本季下载"]
        for _ in 0 ..< 3 where !deleteSeason.exists {
            offline.buttons["season-download-menu"].tap()
            _ = deleteSeason.waitForExistence(timeout: 3)
        }
        tapMenuItem(offline, "删除本季下载")
        let confirm = offline.buttons.matching(NSPredicate(format: "label BEGINSWITH '删除 3 集'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let stillDownloaded = offline.descendants(matching: .any).matching(NSPredicate(format: "label == '已下载'"))
        XCTAssertTrue(waitUntil(timeout: 10) { stillDownloaded.count == 0 && !offline.buttons["item-play"].exists },
                      "删完后页面不能还显示已下载的集、还能点播放")
    }

    /// 断网冷启动直接起播（通知、站内链接直达播放页）：本机目录还没读完也要放本机副本，不能去连服务器
    @MainActor
    func testOfflineColdStartDeepLinkPlaysLocalCopy() throws {
        ensureMovieDownloaded()
        setMode(["mode": "refuse"])
        let app = launch(reset: false, route: "/play/\(movieId)")
        Thread.sleep(forTimeInterval: 12)
        XCTAssertFalse(app.descendants(matching: .any)["player-error"].exists, "断网直达播放应放本机副本")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let time = app.staticTexts["player-time"]
        XCTAssertTrue(time.waitForExistence(timeout: 10), "应在播放")
        let first = Int(time.value as? String ?? "") ?? -1
        Thread.sleep(forTimeInterval: 4)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let second = Int(app.staticTexts["player-time"].value as? String ?? "") ?? -1
        XCTAssertGreaterThan(second, first, "时间应在走（\(first) → \(second)）")
    }

    /// 存储页「编辑」多选后应出现「删除所选」
    @MainActor
    func testStorageMultiSelectDelete() throws {
        ensureMovieDownloaded()
        let app = launch(reset: false, route: "/my/downloads")
        let edit = app.buttons["编辑"].firstMatch.exists ? app.buttons["编辑"].firstMatch : app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        edit.tap()
        let row = app.cells.containing(.any, identifier: "offline-storage-item-\(movieId)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let delete = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '删除所选'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "多选后应出现「删除所选」")
    }

    // MARK: 工具

    @MainActor
    private func launch(reset: Bool, route: String? = nil, then: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--ui-testing"]
        if reset { args += ["--reset-state", "-mcServer", proxy, "-mcUser", username, "-mcPass", password] }
        if let route { args += ["-mcRoute", route] }
        if let then { args += ["-mcRouteThen", then, "-mcRouteThenDelay", "5"] }
        app.launchArguments = args
        app.launch()
        return app
    }

    @MainActor
    private func startDownload(_ app: XCUIApplication, profile: String) {
        let control = app.buttons["item-download"]
        XCTAssertTrue(control.waitForExistence(timeout: 30))
        control.tap()
        let option = app.buttons["offline-profile-\(profile)"]
        XCTAssertTrue(option.waitForExistence(timeout: 30))
        option.tap()
    }

    @MainActor
    private func tapMenuItem(_ app: XCUIApplication, _ label: String? = nil, prefix: String? = nil) {
        let predicate = label.map { NSPredicate(format: "label == %@", $0) } ?? NSPredicate(format: "label BEGINSWITH %@", prefix ?? "")
        let item = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "菜单里应有 \(label ?? prefix ?? "")\n\(app.debugDescription)")
        item.tap()
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
        startDownload(fresh, profile: "original")
        let freshControl = fresh.buttons["item-download"]
        XCTAssertTrue(waitUntil(timeout: 120) { (freshControl.value as? String) == "done|original" })
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

    private func proxyLog() -> [String] {
        let done = DispatchSemaphore(value: 0)
        var lines: [String] = []
        URLSession.shared.dataTask(with: URL(string: control + "/log")!) { data, _, _ in
            lines = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String]) ?? []
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return lines
    }

    private func setMode(_ body: [String: Any]) {
        var request = URLRequest(url: URL(string: control + "/mode")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 5)
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
