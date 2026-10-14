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
    /// 台子里那部电影的文件号
    private let movieFileId = 1
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
        XCTAssertTrue(app.buttons["item-actions"].waitForExistence(timeout: 30))
        // 过了冷启动的自动离线窗口：不靠「重新连上」来触发重试
        Thread.sleep(forTimeInterval: 65)
        setMode(["mode": "pass", "fail_paths": ["/api/v1/offline/files/"], "fail_status": 503,
                 "retry_after": 15, "fail_times": 1])
        startDownload(app, profile: "original")
        XCTAssertTrue(waitUntil(timeout: 20) { movieState(app)?.hasPrefix("failed") == true },
                      "先收到 503：\(movieState(app) ?? "")")
        XCTAssertTrue(waitUntil(timeout: 90) { movieState(app) == "done|original" },
                      "Retry-After 到点后应自己重试并下完：\(movieState(app) ?? "")")
    }

    /// 暂停再继续：应接着下完（续传后的大小校验不能误判、不能卡住）
    @MainActor
    func testPauseThenResumeFinishes() throws {
        let app = launch(reset: true, route: "/library/1/item/\(movieId)")
        let control = app.buttons["item-download"]
        XCTAssertTrue(app.buttons["item-actions"].waitForExistence(timeout: 30))
        setMode(["mode": "slow", "bps": 1_000_000])
        startDownload(app, profile: "original")
        XCTAssertTrue(waitUntil(timeout: 30) { movieState(app)?.hasPrefix("downloading") == true })
        Thread.sleep(forTimeInterval: 15)
        control.tap()
        tapMenuItem(app, "暂停")
        XCTAssertTrue(waitUntil(timeout: 10) { movieState(app)?.hasPrefix("paused") == true })
        Thread.sleep(forTimeInterval: 3)
        setMode(["mode": "pass"])
        control.tap()
        tapMenuItem(app, "继续下载")
        XCTAssertTrue(waitUntil(timeout: 120) { movieState(app) == "done|original" },
                      "继续后应下完：\(movieState(app) ?? "")")
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
        let detail = app.staticTexts["offline-scope-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(detail.label, "第 2～3 集，共 2 集")
        XCTAssertFalse(app.staticTexts["offline-download-note"].exists, "一集都没下过时不用说明")
        XCTAssertTrue(original.label.contains("共 "), "原画一行应是整批总大小：\(original.label)")
        XCTAssertFalse(original.label.contains("≈"), "原画是文件实际大小，写准数：\(original.label)")
        let transcoded = app.buttons["offline-profile-480p"]
        if transcoded.exists {
            XCTAssertTrue(transcoded.label.contains("共 ≈ "), "转码档是预计大小，带 ≈：\(transcoded.label)")
        }
        let unwatchedTotal = Self.megabytes(original.label)
        XCTAssertGreaterThan(unwatchedTotal, 40, "两集约 47 MB，不该只是一集的大小：\(original.label)")
        snapshot("profile-sheet-batch")
        // 切到「全部」：集数和大小跟着变；再切回来
        scope.buttons["全部 3 集"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { detail.label == "第 1～3 集，共 3 集" }, detail.label)
        XCTAssertTrue(waitUntil(timeout: 30) { Self.megabytes(original.label) > unwatchedTotal }, "全部应比未看大：\(original.label)")
        scope.buttons["未看 2 集"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { detail.label == "第 2～3 集，共 2 集" }, detail.label)
        original.tap()
        XCTAssertTrue(app.buttons["offline-profile-confirm"].exists, "点一行不该直接开始、关掉表单")
        app.buttons["offline-profile-confirm"].tap()
        XCTAssertTrue(waitUntil(timeout: 180) { downloaded.count == 2 }, "未看的只有第 2、3 集")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(downloaded.count, 2, "看过的第 1 集不该被下载")
        XCTAssertFalse(app.buttons["episode-1"].label.contains("已下载"))

        // 选中已下载的第 2 集：说明为什么，范围只剩「剩余 1 集」（没有「接下来」：后面的都下了）
        app.buttons["episode-2"].tap()
        openItemMenu(app, then: "下载")
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["offline-download-note"].label, "第 2 集已下载 · 已下载 2 集，不会重复下载")
        XCTAssertFalse(scope.exists, "只有一个范围时不该有分段")
        XCTAssertEqual(app.staticTexts["offline-scope-only"].label, "剩余 1 集")
        XCTAssertEqual(app.staticTexts["offline-scope-detail"].label, "第 1 集")
        snapshot("profile-sheet-selected-downloaded")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !original.exists })

        // 选中第 1 集：只剩这一集能下，面板不给范围选择
        app.buttons["episode-1"].tap()
        openItemMenu(app, then: "下载")
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        XCTAssertFalse(scope.exists, "只有一个范围时不该有分段")
        XCTAssertEqual(app.staticTexts["offline-scope-only"].label, "第 1 集")
        original.tap()
        app.buttons["offline-profile-confirm"].tap()
        XCTAssertTrue(waitUntil(timeout: 120) { downloaded.count == 3 }, "第 1 集也应下完")

        // 都在本机了：面板说都已下载，不给选档
        openItemMenu(app, then: "下载")
        XCTAssertTrue(app.staticTexts["都已下载"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(original.exists)
    }

    /// 转码档排队：服务端一次只转一份导出（别的设备 / 别人正在转时，这一集收到 503 排队）。
    /// 分集卡与存储页「下载中」写「等待转码，前面还有 1 个」，不能写「下载中断」、不用警告色；排到了照常下完。
    /// 真机上用户看到过「下载中断，稍后自动重试」
    @MainActor
    func testQueuedTranscodeSaysItIsWaiting() throws {
        // 先占住转码队列：电影 720p 的导出（别的设备在转）
        let backend = Backend(server: backendURL, username: username, password: password)
        let detail = backend.request("GET", "/libraries/1/items/\(movieId)") as? [String: Any]
        let movieFile = ((detail?["files"] as? [[String: Any]])?.first?["id"] as? Int) ?? 0
        XCTAssertGreaterThan(movieFile, 0, "拿不到电影的文件号：\(String(describing: detail))")
        let blocker = backend.request("POST", "/offline/exports", body: ["file_id": movieFile, "profile": "720p"]) as? [String: Any]
        XCTAssertNotNil(blocker?["export_id"], "占队列的导出没建起来")
        XCTAssertNotEqual(blocker?["status"] as? String, "done", "占队列的导出已经转完了（上一轮留下的），占不住队列")

        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        let card = app.buttons["episode-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.press(forDuration: 1.2)
        tapMenuItem(app, "下载这一集")
        let transcoded = app.buttons["offline-profile-480p"]
        XCTAssertTrue(transcoded.waitForExistence(timeout: 30), app.debugDescription)
        transcoded.tap()
        app.buttons["offline-profile-confirm"].tap()

        XCTAssertTrue(waitUntil(timeout: 30) { card.label.contains("等待转码") }, "分集卡应写等待转码：\(card.label)")
        XCTAssertTrue(card.label.contains("前面还有 1 个"), card.label)
        XCTAssertFalse(card.label.contains("中断"), card.label)
        snapshot("episode-queued-transcode")

        let storage = launch(reset: false, route: "/my/downloads")
        let row = storage.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-downloading-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), storage.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) { row.label.contains("等待转码") || row.label.contains("即将开始转码") }, row.label)
        snapshot("storage-queued-transcode")
        // 排到了照常下完：「下载中」那一行消失，条目进「已下载」
        XCTAssertTrue(waitUntil(timeout: 240) { !row.exists }, "排到了应照常下完：\(row.exists ? row.label : "")")
        XCTAssertTrue(storage.descendants(matching: .any)["offline-storage-item-\(showId)"].waitForExistence(timeout: 10))
    }

    /// 「下载」页底部的容量条：下载中不跟着进度跳（也不每秒去查磁盘），下完一集才更新一次
    @MainActor
    func testCapacityBarOnlyUpdatesWhenADownloadFinishes() throws {
        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        let card = app.buttons["episode-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        // 限速到约 400 KB/s：25 MB 的一集要下一分钟
        setMode(["mode": "slow", "bps": 400_000])
        card.press(forDuration: 1.2)
        tapMenuItem(app, "下载这一集")
        let original = app.buttons["offline-profile-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        original.tap()
        app.buttons["offline-profile-confirm"].tap()
        XCTAssertTrue(waitUntil(timeout: 30) { card.label.contains("下载中") }, card.label)

        let storage = launch(reset: false, route: "/my/downloads")
        let row = storage.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-downloading-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let summary = storage.descendants(matching: .any)["offline-storage-summary"]
        storage.swipeUp()
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let during = summary.label
        // 这几秒里下载在走（行上的百分比在变），容量条一个字都不该变
        let progressBefore = row.label
        Thread.sleep(forTimeInterval: 8)
        XCTAssertNotEqual(row.label, progressBefore, "下载应在进行：\(row.label)")
        XCTAssertEqual(summary.label, during, "下载中容量条不该跟着变")
        snapshot("capacity-during-download")

        setMode(["mode": "pass"])
        XCTAssertTrue(waitUntil(timeout: 120) { !row.exists }, "应下完")
        XCTAssertTrue(waitUntil(timeout: 10) { summary.label != during }, "下完应更新一次：\(summary.label)")
        XCTAssertFalse(summary.label.contains("MovieClaw 下载 0 KB") || summary.label.contains("MovieClaw 下载 Zero KB"), summary.label)
        snapshot("capacity-after-download")
    }

    /// 选档行上的「共 47.1 MB」「共 ≈ 47.1 MB」取出 MB 数
    private static func megabytes(_ label: String) -> Double {
        let size = (label.components(separatedBy: "共 ").last ?? "").replacingOccurrences(of: "≈ ", with: "")
        return Double(size.components(separatedBy: " ").first ?? "") ?? 0
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

        // 首页「正在下载」：一条汇总提示条（几部、状态），点进「我的 → 下载」的「下载中」，那里每一集一行
        app.terminate()
        let home = launch(reset: false, route: "/library")
        let bar = home.buttons["home-downloading"]
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "首页应有「正在下载」提示条：\(home.debugDescription)")
        XCTAssertTrue(bar.label.contains("已暂停下载《示例剧》1 集"), "提示条写清在下什么：\(bar.label)")
        snapshot("home-downloading")
        bar.tap()
        let storageRow = home.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline-downloading-'")).firstMatch
        XCTAssertTrue(storageRow.waitForExistence(timeout: 15), "应进到「下载」页的「下载中」：\(home.debugDescription)")
        XCTAssertTrue(storageRow.label.contains("第 1 季第 1 集") && storageRow.label.contains("已暂停"), storageRow.label)
        snapshot("storage-downloading")
        storageRow.tap()

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
        // 剧集同一套：选中的这集下完后「文件」区多一行本机副本
        detailCard.tap()
        XCTAssertTrue(home.buttons["local-file-row-2"].waitForExistence(timeout: 10), "选中的第 1 集下完后，文件区应有本机那一行")
        XCTAssertTrue(waitUntil(timeout: 6) { !home.staticTexts["下载完成"].exists }, "「下载完成」只短暂提示")
        // 下完：「下载中」那一行消失，首页的提示条也没了
        home.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !storageRow.exists }, "下完应从「下载中」消失")
        XCTAssertTrue(home.descendants(matching: .any)["offline-storage-item-\(showId)"].exists, "应出现在「已下载」")
        snapshot("storage-after-done")
    }

    /// 选档表单一次问完所有范围的档位：打开就出、切范围不再请求；完整清单等点「下载」才取，每集只取一次。
    /// 真机复现：43 集逐集取完整清单要十几秒，切范围还会取消重发
    @MainActor
    func testProfileSheetAsksOnceForAllEpisodes() throws {
        func count(_ needle: String) -> Int { proxyLog().filter { $0.contains(needle) }.count }
        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        XCTAssertTrue(app.buttons["item-actions"].waitForExistence(timeout: 30))
        let profilesBefore = count("POST /api/v1/offline/profiles"), manifestsBefore = count("GET /api/v1/offline/manifest")

        openItemMenu(app, then: "下载")
        let original = app.buttons["offline-profile-original"]
        let opened = Date()
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        let took = Date().timeIntervalSince(opened)
        XCTAssertLessThan(took, 3, "画质应马上出来，用了 \(took)s")
        let scope = app.segmentedControls["offline-scope"]
        if scope.exists {
            for button in scope.buttons.allElementsBoundByIndex {
                button.tap()
                XCTAssertTrue(original.waitForExistence(timeout: 2), "切到「\(button.label)」应立即有大小")
            }
            scope.buttons.allElementsBoundByIndex.last?.tap()  // 停在「全部」
        }
        XCTAssertEqual(count("POST /api/v1/offline/profiles") - profilesBefore, 1, "所有范围只问一次：\(proxyLog().suffix(30))")
        XCTAssertEqual(count("GET /api/v1/offline/manifest") - manifestsBefore, 0, "点「下载」前不取完整清单")

        original.tap()
        app.buttons["offline-profile-confirm"].tap()
        let downloaded = app.images.matching(NSPredicate(format: "label == '已下载'"))
        XCTAssertTrue(waitUntil(timeout: 180) { downloaded.count == 3 }, "三集都应下完：\(downloaded.count)")
        let manifests = proxyLog().filter { $0.contains("GET /api/v1/offline/manifest") }
        XCTAssertEqual(manifests.count - manifestsBefore, 3, "每集只取一次完整清单：\(manifests)")
        XCTAssertEqual(Set(manifests.suffix(3)).count, 3)
    }

    /// 一部剧在下载时，右上角菜单临时出现「取消下载」：取消选中的集 / 取消全部（确认后，已下完的保留）；
    /// 分集卡长按菜单只有操作，不再重复写进度
    @MainActor
    func testCancelDownloadsFromItemMenu() throws {
        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        XCTAssertTrue(app.buttons["item-actions"].waitForExistence(timeout: 30))
        openItemMenu(app, then: "下载")
        let original = app.buttons["offline-profile-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        let scope = app.segmentedControls["offline-scope"]
        if scope.exists { scope.buttons.allElementsBoundByIndex.last?.tap() }
        setMode(["mode": "slow", "bps": 150_000])
        original.tap()
        app.buttons["offline-profile-confirm"].tap()
        let card1 = app.buttons["episode-1"]
        XCTAssertTrue(waitUntil(timeout: 30) { card1.label.contains("下载") && !card1.label.contains("已下载") }, card1.label)

        // 长按菜单：只有操作。页面上分集卡的下载条本来就有这些字，菜单打开后不该多出一份
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '下载中' OR label BEGINSWITH '准备下载' OR label BEGINSWITH '等待下载'"))
        let onCards = status.count
        card1.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["取消下载"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(status.count, onCards, "长按菜单不该再写进度\n\(app.debugDescription)")
        snapshot("episode-menu-actions-only")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["取消下载"].exists })

        // 右上角菜单：取消选中的集
        card1.tap()
        app.buttons["item-actions"].tap()
        XCTAssertTrue(app.buttons["取消下载选中的集"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["取消全部下载（3 集）"].exists, app.debugDescription)
        snapshot("item-menu-cancel")
        app.buttons["取消下载选中的集"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !card1.label.contains("下载") }, "第 1 集应不再下载：\(card1.label)")

        // 取消全部（确认后）
        let actions = app.buttons["item-actions"].frame
        app.buttons["item-actions"].tap()
        let all = app.buttons["取消全部下载（2 集）"]
        XCTAssertTrue(all.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["取消下载选中的集"].exists, "选中的第 1 集已取消，不该再有这一项")
        all.tap()
        let confirm = app.buttons["取消 2 集的下载"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        // 确认气泡从右上角「⋯」弹出：在屏幕上方、偏右（挂在整页上时浮在页面中间）
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(confirm.frame.minY, window.height * 0.4, "确认框应贴着顶部的「⋯」：\(confirm.frame)")
        XCTAssertGreaterThan(confirm.frame.maxX, actions.minX - 40, "确认框应靠右、在「⋯」下方：\(confirm.frame) vs \(actions)")
        snapshot("cancel-confirm-anchored")
        confirm.tap()
        for episode in 2 ... 3 {
            let card = app.buttons["episode-\(episode)"]
            XCTAssertTrue(waitUntil(timeout: 10) { !card.label.contains("下载") }, "第 \(episode) 集应不再下载：\(card.label)")
        }
        app.buttons["item-actions"].tap()
        XCTAssertTrue(app.buttons["加入合集"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '取消全部下载'")).firstMatch.exists, "都取消了，「取消下载」应消失")
        setMode(["mode": "pass"])
    }

    /// 旧服务器没有批量档位接口（404）：退回逐集取清单，照样能选档、能下
    @MainActor
    func testProfileSheetFallsBackWithoutBatchEndpoint() throws {
        setMode(["mode": "pass", "fail_paths": ["/api/v1/offline/profiles"], "fail_status": 404, "fail_times": -1])
        defer { setMode(["mode": "pass"]) }
        let app = launch(reset: true, route: "/library/2/item/\(showId)")
        XCTAssertTrue(app.buttons["item-actions"].waitForExistence(timeout: 30))
        openItemMenu(app, then: "下载")
        let original = app.buttons["offline-profile-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 30), "批量接口 404 时应退回逐集清单\n\(app.debugDescription)")
        XCTAssertTrue(proxyLog().contains { $0.contains("fail 404 POST /api/v1/offline/profiles") }, "应先试过批量接口")
        original.tap()
        app.buttons["offline-profile-confirm"].tap()
        let downloaded = app.images.matching(NSPredicate(format: "label == '已下载'"))
        XCTAssertTrue(waitUntil(timeout: 180) { downloaded.count >= 1 }, "退回逐集清单后也应能下完")
    }

    /// 电影与剧集同一套：开始下载在右上角「⋯」；播放键上方只在有本机副本时出现状态条（进度 + 速度，下完「已下载 · 档位 · 大小」）；
    /// 下载中「⋯」里「下载」换成「取消下载」
    @MainActor
    func testMovieDownloadFromItemMenu() throws {
        let app = launch(reset: true, route: "/library/1/item/\(movieId)")
        let actions = app.buttons["item-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 30))
        let bar = app.buttons["item-download"]
        XCTAssertFalse(bar.exists, "没下过时播放键下方不该有下载按钮 / 状态条")
        setMode(["mode": "slow", "bps": 1_500_000])
        defer { setMode(["mode": "pass"]) }
        startDownload(app, profile: "original")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "开始下载后应出现状态条")
        XCTAssertTrue(waitUntil(timeout: 30) { bar.label.contains("下载中") && bar.label.contains("/s") }, "状态条：\(bar.label)")
        XCTAssertTrue(bar.frame.maxY < app.buttons["item-play"].frame.minY, "状态条应在播放键上方")
        snapshot("movie-downloading")

        actions.tap()
        XCTAssertTrue(app.buttons["取消下载"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["下载"].exists, "已在下载，菜单里不该再有「下载」")
        snapshot("movie-menu-downloading")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["取消下载"].exists })

        setMode(["mode": "pass"])
        XCTAssertTrue(waitUntil(timeout: 120) { movieState(app) == "done|original" }, "应下完：\(movieState(app) ?? "")")
        // 下完：播放键上方的状态条收起；「文件」区多一行本机副本（标「本机」）
        XCTAssertTrue(waitUntil(timeout: 5) { !bar.exists }, "下完后状态条应收起")
        let local = app.buttons["local-file-row-\(movieFileId)"]
        XCTAssertTrue(local.exists)
        XCTAssertTrue(app.descendants(matching: .any)["local-file-tag"].exists, "本机那一行应标「本机」")
        actions.tap()
        XCTAssertTrue(app.buttons["加入合集"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["下载"].exists || app.buttons["取消下载"].exists, "下完后菜单里两项都不该有")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["加入合集"].exists })

        // 展开：信息与源文件一致，保存位置写本机
        local.tap()
        XCTAssertTrue(app.staticTexts["本机（iPhone · MovieClaw 下载）"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["从服务器下载 · 原画"].exists)
        XCTAssertTrue(app.staticTexts["视频编码"].exists, "原画应照抄源文件的规格")
        snapshot("movie-local-file-row")
        // 长按：改下其他画质
        local.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["改下其他画质"].waitForExistence(timeout: 5))
        app.otherElements["PopoverDismissRegion"].firstMatch.exists
            ? app.otherElements["PopoverDismissRegion"].firstMatch.tap()
            : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["改下其他画质"].exists })

        // 删除：确认气泡从垃圾桶弹出，写明不进回收站、没网就不能播；确认后本机那一行消失，「⋯」里又有「下载」
        let trash = app.buttons["local-file-delete-\(movieFileId)"]
        let trashFrame = trash.frame
        trash.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '删除（释放'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirm.label.hasSuffix("）"), confirm.label)
        XCTAssertLessThan(abs(confirm.frame.midY - trashFrame.midY), 300, "确认框应贴着垃圾桶：\(confirm.frame) vs \(trashFrame)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '不进回收站' AND label CONTAINS '没网'")).firstMatch.exists,
                      app.debugDescription)
        snapshot("movie-local-delete-confirm")
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !local.exists }, "删除后本机那一行应消失")
        actions.tap()
        XCTAssertTrue(app.buttons["下载"].waitForExistence(timeout: 5), "删了以后菜单里应又有「下载」")
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

    /// 存储页按系统「iPhone 储存空间」分组：容量条 / 建议 / 已下载 / 下载设置；没有「编辑」；
    /// 左滑出（红色的）删除，取消不删；点一行进到媒体库里的这部片
    @MainActor
    func testStoragePageLayout() throws {
        ensureMovieDownloaded()
        // 从「我的」点入口进：入口与页面都叫「下载」
        let app = launch(reset: false, route: "/my")
        let entry = app.buttons["more-downloads"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(entry.label.hasPrefix("下载") && !entry.label.contains("存储"), entry.label)
        entry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["offline-storage-summary"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["下载"].exists, "页面就叫「下载」：\(app.navigationBars.allElementsBoundByIndex.map(\.identifier))")
        XCTAssertFalse(app.buttons["编辑"].exists || app.buttons["Edit"].exists, "不该再有「编辑」")
        XCTAssertTrue(app.staticTexts["已下载"].exists, "应有「已下载」分组\n\(app.debugDescription)")
        // 容量条放在最后：在「已下载」那一行下面
        let summary = app.descendants(matching: .any)["offline-storage-summary"]
        let firstRow = app.cells.containing(.any, identifier: "offline-storage-item-\(movieId)").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(summary.frame.minY, firstRow.frame.maxY, "容量条应在已下载列表之后")
        XCTAssertFalse(app.switches["使用蜂窝网络下载"].exists, "下载设置不该再占页面里的分组")
        snapshot("storage-page")
        // 下载设置在右上角菜单：开关蜂窝下载，再打开菜单状态跟着变
        let settings = app.buttons["offline-settings"]
        XCTAssertTrue(settings.exists)
        settings.tap()
        let cellular = app.switches["使用蜂窝网络下载"].firstMatch.exists ? app.switches["使用蜂窝网络下载"].firstMatch : app.buttons["使用蜂窝网络下载"].firstMatch
        XCTAssertTrue(cellular.waitForExistence(timeout: 5), "菜单里应有蜂窝下载开关\n\(app.debugDescription)")
        snapshot("storage-settings-menu")
        XCTAssertTrue(cellular.isEnabled, "第一次打开时开关就应可点\n\(app.debugDescription)")
        // 菜单里的开关是带「已选中」特征的按钮（勾号），不是有 value 的开关
        let before = cellular.isSelected || (cellular.value as? String) == "1"
        cellular.tap()
        func toggleElement() -> XCUIElement {
            app.switches["使用蜂窝网络下载"].firstMatch.exists ? app.switches["使用蜂窝网络下载"].firstMatch : app.buttons["使用蜂窝网络下载"].firstMatch
        }
        // 点完菜单应收起；再打开看状态
        XCTAssertTrue(waitUntil(timeout: 5) { !toggleElement().exists }, "点了开关菜单应收起")
        settings.tap()
        let after = toggleElement()
        XCTAssertTrue(after.waitForExistence(timeout: 5), app.debugDescription)
        let now = after.isSelected || (after.value as? String) == "1"
        XCTAssertNotEqual(now, before, "开关状态应变了：\(before) → \(now)\n\(app.debugDescription)")
        XCTAssertTrue(after.isEnabled, "再打开时开关应可点")
        snapshot("storage-settings-menu-on")
        after.tap()  // 还原
        XCTAssertTrue(waitUntil(timeout: 5) { !toggleElement().exists })


        let row = app.cells.containing(.any, identifier: "offline-storage-item-\(movieId)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        let delete = app.buttons["删除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "左滑应出「删除」")
        snapshot("storage-swipe")
        delete.tap()
        let confirmDelete = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '删除（释放'")).firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        // 确认气泡从这一行弹出：离这一行不远（挂在整个列表上时浮在页面中间的容量条上）
        XCTAssertLessThan(abs(confirmDelete.frame.midY - row.frame.midY), 260, "确认框应贴着这一行：\(confirmDelete.frame) vs \(row.frame)")
        XCTAssertTrue(confirmDelete.label.hasSuffix("）"), "括号要成对：\(confirmDelete.label)")
        let cancel = app.buttons["取消"].firstMatch.exists ? app.buttons["取消"].firstMatch : app.buttons["Cancel"].firstMatch
        // iOS 26 的确认框以弹出式窗口出现：点窗口外（系统的 PopoverDismissRegion）取消
        let outside = app.otherElements["PopoverDismissRegion"]
        if cancel.exists { cancel.tap() } else if outside.exists { outside.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { !confirmDelete.exists }, "确认框应关掉\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 5) { row.exists }, "取消后这一行应还在")

        // 确认框收起动画期间点不中：等它走完；左滑露出的按钮若还开着，第一下点击只是收起
        let title = app.staticTexts["item-title"]
        for _ in 0 ..< 3 where !title.exists {
            Thread.sleep(forTimeInterval: 1)
            if row.isHittable { row.tap() }
            _ = title.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(title.exists, "点一行应进到媒体库里的这部片")

        // 「建议」：有看完的下载才出现。服务器上标已看 → 详情页在线时把续播状态写回本机 → 回到存储页
        let backend = Backend(server: backendURL, username: username, password: password)
        backend.request("POST", "/playback/marks", body: ["media_item_id": movieId, "played": true])
        defer { backend.request("POST", "/playback/marks", body: ["media_item_id": movieId, "played": false]) }
        app.terminate()
        let again = launch(reset: false, route: "/library/1/item/\(movieId)")
        XCTAssertTrue(again.staticTexts["item-title"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        again.buttons["BackButton"].firstMatch.tap()
        again.terminate()
        let storage = launch(reset: false, route: "/my/downloads")
        XCTAssertTrue(storage.buttons["offline-delete-watched"].waitForExistence(timeout: 20), "看完的下载应出现在「建议」里")
        XCTAssertTrue(storage.staticTexts["建议"].exists)
        let watchedButton = storage.buttons["offline-delete-watched"]
        let buttonFrame = watchedButton.frame
        watchedButton.tap()
        let confirmWatched = storage.buttons.matching(NSPredicate(format: "label BEGINSWITH '删除（释放'")).firstMatch
        XCTAssertTrue(confirmWatched.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(confirmWatched.frame.midY - buttonFrame.midY), 260, "确认框应贴着「删除」按钮：\(confirmWatched.frame) vs \(buttonFrame)")
        snapshot("storage-watched-confirm")
        storage.otherElements["PopoverDismissRegion"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !confirmWatched.exists })
        let stray = storage.staticTexts.matching(NSPredicate(format: "label MATCHES '.*[0-9] ?[KMG]?B\\).*'"))
        XCTAssertEqual(stray.count, 0, "文案里不该有半角右括号：\(stray.allElementsBoundByIndex.map(\.label))")
        snapshot("storage-suggestion")
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

    /// 电影：右上角「⋯」→「下载」→ 选档 → 确认
    @MainActor
    private func startDownload(_ app: XCUIApplication, profile: String) {
        openItemMenu(app, then: "下载")
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

    /// 电影在本机的状态：下着看播放键上方的状态条，下完看「文件」区本机那一行（值都是「状态|档位」）
    @MainActor
    private func movieState(_ app: XCUIApplication) -> String? {
        let bar = app.buttons["item-download"]
        if bar.exists { return bar.value as? String }
        let local = app.buttons["local-file-row-\(movieFileId)"]
        return local.exists ? local.value as? String : nil
    }

    @MainActor
    private func ensureMovieDownloaded() {
        let app = launch(reset: false, route: "/library/1/item/\(movieId)")
        _ = app.buttons["item-actions"].waitForExistence(timeout: 30)
        if waitUntil(timeout: 5, { movieState(app)?.hasPrefix("done") == true }) {
            app.terminate()
            return
        }
        app.terminate()
        let fresh = launch(reset: true, route: "/library/1/item/\(movieId)")
        startDownload(fresh, profile: "original")
        let freshControl = fresh.buttons["item-download"]
        XCTAssertTrue(waitUntil(timeout: 120) { movieState(fresh) == "done|original" })
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
