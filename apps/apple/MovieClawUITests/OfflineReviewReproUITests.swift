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

    /// 离线时把一部剧的下载逐集删光：页面上不能还显示那几集已下载、还能点播放
    @MainActor
    func testOfflineSeasonDeleteRefreshesPage() throws {
        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        // 只数分集卡上的「已下载」角标（图片）；下载前必须是 0（播放键旁的下载按钮也叫「已下载」，不能混进来）
        let downloaded = app.images.matching(NSPredicate(format: "label == '已下载'"))
        openItemMenu(app, then: "下载")
        let original = app.buttons["offline-profile-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        app.segmentedControls["offline-scope"].buttons["全部 3 集"].tap()
        XCTAssertEqual(downloaded.count, 0, app.debugDescription)
        original.tap()
        app.buttons["offline-profile-confirm"].tap()
        XCTAssertTrue(waitUntil(timeout: 180) { downloaded.count >= 3 })
        setMode(["mode": "refuse"])
        app.terminate()
        let offline = launch(reset: false, route: "/library/2/item/\(showId)")
        XCTAssertTrue(offline.buttons["episode-1"].waitForExistence(timeout: 30))
        // 冷启动后 6～11 秒才判定离线，期间页面会重排一次：等它定下来再长按
        Thread.sleep(forTimeInterval: 12)
        for episode in 1 ... 3 {
            let card = offline.buttons["episode-\(episode)"]
            XCTAssertTrue(card.waitForExistence(timeout: 10), "第 \(episode) 集应还在")
            card.press(forDuration: 1.2)
            tapMenuItem(offline, "删除下载")
        }
        let stillDownloaded = offline.images.matching(NSPredicate(format: "label == '已下载'"))
        XCTAssertTrue(waitUntil(timeout: 10) { stillDownloaded.count == 0 && !offline.buttons["item-play"].exists },
                      "删完后页面不能还显示已下载的集、还能点播放")
    }

    /// 右上角菜单：顶部一排「下载 · 加入合集 · 分享」，管理类收进「管理」子菜单，删除垫底；
    /// 「下载」打开选档面板，顶部分段选范围（第 N 集 / 未看 / 全部），切范围大小跟着变；
    /// 未看的只下没看过的、选中的集只下这一集、全下完后提示都已下载；季选择旁不再有「⋯」
    @MainActor
    func testItemMenuDownloadSection() throws {
        let backend = Backend(server: backendURL, username: username, password: password)
        backend.request("POST", "/playback/marks", body: ["media_item_id": showId, "season_number": 1, "played": false])
        backend.request("POST", "/playback/marks", body: ["media_item_id": showId, "season_number": 1, "episode_number": 1, "played": true])
        defer { backend.request("POST", "/playback/marks", body: ["media_item_id": showId, "season_number": 1, "played": false]) }

        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        let actions = app.buttons["item-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["season-download-menu"].exists, "季选择旁的「⋯」应已去掉")
        actions.tap()
        let manage = app.buttons["item-manage"]
        for label in ["下载", "加入合集", "分享", "item-manage", "从媒体库删除"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "菜单顶层应有「\(label)」\n\(app.debugDescription)")
        }
        for gone in ["下载选中的集", "下载未看的集", "下载全部剧集", "修正识别", "洗版", "转移到其他库", "搜索资源", "清除观看记录"] {
            XCTAssertFalse(app.buttons[gone].exists, "菜单顶层不该有「\(gone)」")
        }
        // 下载、加入合集、分享排成一行；管理在它们下面、删除垫底
        let download = app.buttons["下载"].frame, collection = app.buttons["加入合集"].frame, share = app.buttons["分享"].frame
        XCTAssertEqual(download.midY, share.midY, accuracy: 2, "下载和分享应在同一行")
        XCTAssertTrue(download.minX < collection.minX && collection.minX < share.minX, "顺序应是 下载 · 加入合集 · 分享")
        XCTAssertTrue(share.maxY <= manage.frame.minY && manage.frame.maxY <= app.buttons["从媒体库删除"].frame.minY)
        snapshot("item-menu")
        manage.tap()
        // 刷新元数据在后台刷新时写作「正在刷新元数据」
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label ENDSWITH '刷新元数据'")).firstMatch.waitForExistence(timeout: 5))
        for label in ["修正识别", "洗版", "转移到其他库"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "管理子菜单里应有「\(label)」\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.buttons["修正识别"].frame.minY < app.buttons["洗版"].frame.minY
                      && app.buttons["洗版"].frame.minY < app.buttons["转移到其他库"].frame.minY)
        snapshot("item-menu-manage")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["转移到其他库"].exists })

        openItemMenu(app, then: "下载")
        let downloaded = app.images.matching(NSPredicate(format: "label == '已下载'"))
        let original = app.buttons["offline-profile-original"]
        let scope = app.segmentedControls["offline-scope"]
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        XCTAssertEqual(downloaded.count, 0)
        // 有没看的默认选「未看」；写明共几集、每档是整批的总大小
        XCTAssertTrue(scope.buttons["未看 2 集"].isSelected, app.debugDescription)
        XCTAssertTrue(scope.buttons["全部 3 集"].exists)
        XCTAssertTrue(app.staticTexts["共 2 集"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(original.label.contains("共约"), "原画一行应是整批总大小：\(original.label)")
        let unwatchedTotal = Self.megabytes(original.label)
        XCTAssertGreaterThan(unwatchedTotal, 40, "两集约 47 MB，不该只是一集的大小：\(original.label)")
        snapshot("profile-sheet-batch")
        // 切到「全部」：集数和大小跟着变；再切回来
        scope.buttons["全部 3 集"].tap()
        XCTAssertTrue(app.staticTexts["共 3 集"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 30) { Self.megabytes(original.label) > unwatchedTotal }, "全部应比未看大：\(original.label)")
        scope.buttons["未看 2 集"].tap()
        XCTAssertTrue(app.staticTexts["共 2 集"].waitForExistence(timeout: 5))
        original.tap()
        XCTAssertTrue(app.buttons["offline-profile-confirm"].exists, "点一行不该直接开始、关掉表单")
        app.buttons["offline-profile-confirm"].tap()
        XCTAssertTrue(waitUntil(timeout: 180) { downloaded.count == 2 }, "未看的只有第 2、3 集")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(downloaded.count, 2, "看过的第 1 集不该被下载")
        XCTAssertFalse(app.buttons["episode-1"].label.contains("已下载"))

        // 选中第 1 集：只剩这一集能下，面板不给范围选择
        app.buttons["episode-1"].tap()
        openItemMenu(app, then: "下载")
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        XCTAssertFalse(scope.exists, "只有一个范围时不该有分段")
        original.tap()
        app.buttons["offline-profile-confirm"].tap()
        XCTAssertTrue(waitUntil(timeout: 120) { downloaded.count == 3 }, "第 1 集也应下完")

        // 都在本机了：面板说都已下载，不给选档
        openItemMenu(app, then: "下载")
        XCTAssertTrue(app.staticTexts["都已下载"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(original.exists)
    }

    /// 选档行上的「共约 47.1 MB」取出 MB 数
    private static func megabytes(_ label: String) -> Double {
        Double(label.components(separatedBy: "约 ").last?.components(separatedBy: " ").first ?? "") ?? 0
    }

    /// 剧集下载状态画在分集卡的剧照上，样式同首页「正在下载」：底部一条写「下载中 N%」+ 实时速度 + 进度；
    /// 暂停 / 继续在长按菜单；首页「正在下载」用这一集的剧照；下完提示「下载完成」，右上角绿箭头「已下载」
    @MainActor
    func testEpisodeCardShowsDownloadProgress() throws {
        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        let card = app.buttons["episode-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["item-download"].exists, "剧集页不该再有播放键下方的下载按钮")
        card.press(forDuration: 1.2)
        tapMenuItem(app, "下载这一集")
        let original = app.buttons["offline-profile-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        // 限速到约 400 KB/s：25 MB 的一集要下一分钟，够看清进度和速度
        setMode(["mode": "slow", "bps": 400_000])
        original.tap()
        app.buttons["offline-profile-confirm"].tap()

        XCTAssertTrue(waitUntil(timeout: 30) { card.label.contains("下载中") }, "卡片应写下载中：\(card.label)")
        XCTAssertTrue(waitUntil(timeout: 15) { card.label.contains("/s") }, "应显示实时速度：\(card.label)")
        XCTAssertFalse(card.label.contains("已下载"))
        Thread.sleep(forTimeInterval: 3)
        snapshot("episode-downloading")

        card.press(forDuration: 1.2)
        tapMenuItem(app, "暂停")
        XCTAssertTrue(waitUntil(timeout: 10) { card.label.contains("已暂停") }, "应暂停：\(card.label)")
        XCTAssertFalse(card.label.contains("/s"), "暂停后不该还有速度：\(card.label)")
        snapshot("episode-paused")

        // 首页「正在下载」：同样的条，卡片是这一集的剧照
        app.terminate()
        let home = launch(reset: false, route: "/library")
        let row = home.descendants(matching: .any)["home-downloading"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "首页应有「正在下载」")
        let homeCard = row.buttons.matching(NSPredicate(format: "label CONTAINS '第 1 季第 1 集'")).firstMatch
        XCTAssertTrue(homeCard.waitForExistence(timeout: 10), row.debugDescription)
        XCTAssertTrue(homeCard.label.contains("已暂停"), "首页卡片：\(homeCard.label)")
        snapshot("home-downloading")
        homeCard.tap()

        let detailCard = home.buttons["episode-1"]
        XCTAssertTrue(detailCard.waitForExistence(timeout: 30))
        detailCard.press(forDuration: 1.2)
        tapMenuItem(home, "继续下载")
        XCTAssertTrue(waitUntil(timeout: 20) { detailCard.label.contains("下载中") }, "应继续：\(detailCard.label)")

        setMode(["mode": "pass"])
        XCTAssertTrue(home.staticTexts["下载完成"].waitForExistence(timeout: 120), "下完应提示「下载完成」")
        snapshot("episode-finished")
        XCTAssertTrue(detailCard.label.contains("已下载"))
        XCTAssertFalse(detailCard.label.contains("下载中"))
        XCTAssertTrue(waitUntil(timeout: 6) { !home.staticTexts["下载完成"].exists }, "「下载完成」只短暂提示")
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
        app.buttons["offline-profile-confirm"].tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openItemMenu(_ app: XCUIApplication, then label: String) {
        let actions = app.buttons["item-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 30))
        actions.tap()
        tapMenuItem(app, label)
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
