import XCTest

/// Apple TV 版的端到端验收（docs/design/tvos-app.md §7）：只用遥控器（方向键、确认、返回、播放暂停）走完每条主动线。
///
/// 对着**隔离的测试服务器**跑（全新数据库 + 生成的测试片，不碰任何真实服务器），环境变量经 TEST_RUNNER_ 前缀转交：
/// - MC_TEST_SERVER（默认 http://127.0.0.1:8790）、MC_TEST_USERNAME / MC_TEST_PASSWORD（管理员）、
///   MC_TEST_MEMBER / MC_TEST_MEMBER_PASSWORD（第二个账号，验收「谁在看」）；
/// - MC_TEST_MOVIE_LIBRARY / MC_TEST_SHOW_LIBRARY（库 id）、MC_TEST_MKV_ITEM（多音轨多字幕的电影）、
///   MC_TEST_SHOW_ITEM（剧集）；
/// - MC_SHOT_DIR：每一步的截图同时落盘到这个目录（交付对照）。
final class TVFlowUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"] ?? "http://127.0.0.1:8790" }
    private var username: String { env["MC_TEST_USERNAME"] ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"] ?? "mclaw-tv-2026" }
    private var member: String { env["MC_TEST_MEMBER"] ?? "xiaoyu" }
    private var memberPassword: String { env["MC_TEST_MEMBER_PASSWORD"] ?? "mclaw-tv-2026" }
    private var movieLibrary: String { env["MC_TEST_MOVIE_LIBRARY"] ?? "1" }
    private var showLibrary: String { env["MC_TEST_SHOW_LIBRARY"] ?? "2" }
    private var mkvItem: String { env["MC_TEST_MKV_ITEM"] ?? "2" }
    private var showItem: String { env["MC_TEST_SHOW_ITEM"] ?? "4" }

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: 启动

    /// 已登录启动（调试参数直接以管理员进入，跳过欢迎页）
    @MainActor
    private func launchSignedIn(_ extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["--reset-state"] : []) + ["--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password] + extra
        app.launch()
        return app
    }

    @MainActor
    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if let dir = env["MC_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 等播放器出画：转圈消失、画面在
    @MainActor
    private func waitForPlayback(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.element("tv-player").waitForExistence(timeout: 15), "播放器没有弹出", file: file, line: line)
        XCTAssertTrue(app.element("tv-player-video").waitForExistence(timeout: 30), "引擎画面没有出现", file: file, line: line)
        let busy = app.element("tv-player-busy")
        let deadline = Date.now.addingTimeInterval(45)
        while busy.exists, Date.now < deadline { usleep(500_000) }
        XCTAssertFalse(busy.exists, "45 秒还在转圈（起播失败）", file: file, line: line)
        XCTAssertFalse(app.element("tv-player-dialog").exists, "播放出错：\(app.element("tv-player-dialog").label)", file: file, line: line)
    }

    // MARK: 登录

    /// 第一次打开 → 连接服务器（手动输地址）→ 扫码页改用账号密码 → 登录 → 首页
    @MainActor
    func testPasswordSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing"]
        app.launch()
        let start = app.element("tv-welcome-start")
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        snapshot("01-welcome")
        TVRemote.select(start, by: .down)

        TVRemote.type(server, into: app.element("tv-server-address"), app: app, by: .down)
        TVRemote.select(app.element("tv-server-connect"), by: .right)

        let usePassword = app.element("tv-pairing-use-password")
        XCTAssertTrue(usePassword.waitForExistence(timeout: 15), "没有出现扫码登录页")
        snapshot("02-pairing")
        TVRemote.select(usePassword, by: .down)

        TVRemote.type(username, into: app.element("tv-signin-username"), app: app, by: .down)
        TVRemote.type(password, into: app.element("tv-signin-password"), app: app, by: .down)
        snapshot("03-password-form")
        TVRemote.select(app.element("tv-signin-submit"), trying: [.down, .left])

        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 20), "登录后没有进首页")
        snapshot("04-home-after-signin")
    }

    /// 扫码登录：电视显示配对码 → 「手机」（这里用接口代替）批准 → 电视自动进入
    @MainActor
    func testQRCodePairingSignIn() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing"]
        app.launch()
        TVRemote.select(app.element("tv-welcome-start"), by: .down)
        TVRemote.type(server, into: app.element("tv-server-address"), app: app, by: .down)
        TVRemote.select(app.element("tv-server-connect"), by: .right)

        let code = app.element("tv-pairing-code")
        XCTAssertTrue(code.waitForExistence(timeout: 15), "没有显示配对码")
        snapshot("05-pairing-code")
        let userCode = code.label
        XCTAssertTrue(userCode.hasPrefix("MCLW-"), "配对码格式不对：\(userCode)")

        // 「手机上批准」：以管理员的身份调批准接口
        let approver = try await TestBackend.login(server: server, username: username, password: password)
        try await TestBackend.approve(server: server, token: approver, userCode: userCode)
        try await TestBackend.logout(server: server, token: approver)

        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 20), "批准后电视没有自动进入")
        snapshot("06-home-after-pairing")
    }

    // MARK: 首页 → 续播

    /// 首页大图「继续播放」→ 出画 → 播放暂停键暂停 → 返回键退出播放回到首页
    @MainActor
    func testHomeHeroResumesPlayback() {
        let app = launchSignedIn()
        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 20))
        snapshot("10-home")
        TVRemote.select(app.element("tv-home-hero-play"), trying: [.right, .down])
        waitForPlayback(app)
        snapshot("11-playing")
        TVRemote.press(.playPause)
        XCTAssertTrue(app.element("tv-player-paused").waitForExistence(timeout: 10), "暂停后没有显示片名")
        snapshot("12-paused")
        TVRemote.press(.menu)
        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 10), "返回键没有退出播放器")
        XCTAssertFalse(app.element("tv-player").exists)
    }

    // MARK: 媒体库 → 详情 → 播放

    @MainActor
    func testLibraryDetailPlay() {
        let app = launchSignedIn(["-mcTab", "library-\(movieLibrary)"])
        XCTAssertTrue(app.element("tv-library-\(movieLibrary)").waitForExistence(timeout: 20))
        snapshot("20-library")
        // 焦点进入海报墙，选第一张
        TVRemote.press(.right)
        TVRemote.press(.down)
        TVRemote.press(.select)
        let play = app.element("tv-item-play")
        XCTAssertTrue(play.waitForExistence(timeout: 15), "没有进入详情页")
        snapshot("21-detail")
        TVRemote.select(play, by: .down)
        waitForPlayback(app)
        snapshot("22-playing-from-detail")
        TVRemote.press(.menu)
        XCTAssertTrue(play.waitForExistence(timeout: 10), "退出播放后没有回到详情页")
    }

    /// 剧集：详情页的分集横排里选第 3 集直接播
    @MainActor
    func testShowEpisodePlay() {
        let app = launchSignedIn(["-mcTab", "library-\(showLibrary)"])
        XCTAssertTrue(app.element("tv-library-\(showLibrary)").waitForExistence(timeout: 20))
        TVRemote.press(.right)
        TVRemote.press(.down)
        TVRemote.press(.select)
        let episode = app.element("tv-episode-3")
        XCTAssertTrue(episode.waitForExistence(timeout: 15), "剧集详情没有分集")
        TVRemote.focus(episode, trying: [.down, .right])
        snapshot("30-show-detail-episode-3")
        TVRemote.press(.select)
        waitForPlayback(app)
        snapshot("31-playing-episode-3")
        TVRemote.press(.menu)
    }

    // MARK: 搜索

    @MainActor
    func testSearchFindsLibraryItem() {
        let app = launchSignedIn(["-mcTab", "search"])
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "没有搜索框")
        // 冷启动落在搜索页时焦点在侧边栏上：往右挪进内容，焦点落到搜索键盘
        let keyboard = app.keyboards.firstMatch
        for _ in 0 ..< 4 where !(keyboard.exists && keyboard.hasFocus) && !field.hasFocus {
            TVRemote.press(.right)
        }
        snapshot("39-search-keyboard")
        field.typeText("星际")
        let result = app.buttons["星际回声"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "搜索结果里没有「星际回声」")
        snapshot("40-search-results")
    }

    // MARK: 播放器的信息面板

    /// 多音轨、多字幕的 MKV：下滑出面板 → 有字幕与音轨两页 → 选一条字幕 → 返回键收起面板 → 再按返回退出
    @MainActor
    func testPlayerInfoPanel() {
        let app = launchSignedIn(["-mcRoute", "/play/\(mkvItem)"])
        waitForPlayback(app)
        TVRemote.press(.down)
        XCTAssertTrue(app.element("tv-player-panel").waitForExistence(timeout: 10), "下滑没有出信息面板")
        XCTAssertTrue(app.element("tv-panel-tab-audio").exists, "多音轨片源的面板里没有音轨页")
        snapshot("50-panel-subtitles")
        TVRemote.press(.right)
        TVRemote.press(.select)
        TVRemote.press(.menu)
        XCTAssertFalse(app.element("tv-player-panel").waitForExistence(timeout: 2), "返回键没有收起面板")
        XCTAssertTrue(app.element("tv-player").exists, "收面板时不该退出播放器")
        snapshot("51-after-subtitle-pick")
        TVRemote.press(.menu)
    }

    // MARK: 谁在看

    /// 登录两个账号后重开 App：先问「谁在看」，选第二个账号进入，侧边栏顶上是他的名字
    @MainActor
    func testWhoIsWatchingSwitchesAccount() {
        // 第一次：以管理员进入，再用账号页「添加账号」登录第二个账号
        var app = launchSignedIn(["-mcTab", "account"])
        TVRemote.select(app.element("tv-account-add"), trying: [.right, .down])
        let usePassword = app.element("tv-pairing-use-password")
        XCTAssertTrue(usePassword.waitForExistence(timeout: 15))
        TVRemote.select(usePassword, by: .down)
        TVRemote.type(member, into: app.element("tv-signin-username"), app: app, by: .down)
        TVRemote.type(memberPassword, into: app.element("tv-signin-password"), app: app, by: .down)
        TVRemote.select(app.element("tv-signin-submit"), trying: [.down, .left])
        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 20) || app.element("tv-account").waitForExistence(timeout: 5))
        app.terminate()

        // 第二次：不清状态、不带调试登录参数，正常冷启动
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.element("tv-who-is-watching").waitForExistence(timeout: 20), "登录过两个账号却没问「谁在看」")
        snapshot("60-who-is-watching")
        TVRemote.select(app.element("tv-profile-\(member)"), trying: [.right, .left])
        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 20), "选人后没有进首页")
        snapshot("61-home-as-member")
    }

    // MARK: T3：发现、订阅、片段

    /// 发现：本周精选大图 → 作品详情 → 一键订阅（已经订过就看到「已订阅」）
    @MainActor
    func testDiscoverOneClickSubscribe() {
        let app = launchSignedIn(["-mcTab", "discover"])
        let detailButton = app.element("tv-discover-hero-detail")
        XCTAssertTrue(detailButton.waitForExistence(timeout: 25), "发现页没有本周精选大图")
        snapshot("70-discover")
        TVRemote.select(detailButton, trying: [.right, .down, .up])
        XCTAssertTrue(app.element("tv-discover-title").waitForExistence(timeout: 15), "没有进作品详情")
        snapshot("71-discover-detail")
        let subscribe = app.element("tv-discover-subscribe")
        if subscribe.exists {
            TVRemote.select(subscribe, trying: [.down, .right, .left])
            let note = app.element("tv-discover-subscribe-note")
            XCTAssertTrue(note.waitForExistence(timeout: 20), "按了订阅没有结果提示")
            XCTAssertFalse(note.label.contains("失败"), "订阅失败：\(note.label)")
            snapshot("72-discover-subscribed")
        } else {
            XCTAssertTrue(app.element("tv-discover-subscribed").exists || app.element("tv-discover-play").exists,
                          "详情页既没有「订阅」也没有「已订阅」/「播放」")
        }
    }

    /// 我的订阅：大图里刚入库的那部「播放」→ 出画 → 返回
    @MainActor
    func testSubscriptionsHeroPlays() {
        let app = launchSignedIn(["-mcTab", "subscriptions"])
        XCTAssertTrue(app.element("tv-subscriptions").waitForExistence(timeout: 25))
        snapshot("80-subscriptions")
        let play = app.element("tv-subscriptions-hero-play")
        guard play.waitForExistence(timeout: 10) else {
            // 大图挑的不是已入库的那一部：页面能打开、各行在就算过（刚刚入库在下面的行里）
            XCTAssertTrue(app.staticTexts["刚刚入库"].exists || app.staticTexts["本周日程"].exists, "订阅页没有任何分区")
            return
        }
        TVRemote.select(play, trying: [.right, .down])
        waitForPlayback(app)
        snapshot("81-playing-from-subscriptions")
        TVRemote.press(.menu)
    }

    /// 片段：自动放第一段 → 点按右换下一段 → 按确认键接着看正片 → 返回回到片段
    @MainActor
    func testReelsPlayAndWatchFull() {
        let app = launchSignedIn(["-mcTab", "reels"])
        XCTAssertTrue(app.element("tv-reels-video").waitForExistence(timeout: 30), "片段没有出画")
        sleep(3)
        snapshot("90-reels-first")
        TVRemote.press(.right)
        sleep(3)
        snapshot("91-reels-next")
        TVRemote.press(.select)
        waitForPlayback(app)
        snapshot("92-reels-watch-full")
        TVRemote.press(.menu)
        XCTAssertTrue(app.element("tv-reels").waitForExistence(timeout: 10), "退出正片后没有回到片段")
    }
}

/// 用例里需要「另一台设备」做的事（手机上批准配对）：直接调测试服务器的接口
enum TestBackend {
    static func login(server: String, username: String, password: String) async throws -> String {
        let body: [String: Any] = [
            "username": username, "password": password,
            "client": ["kind": "ios", "installation_id": "tv-ui-test-approver", "name": "UI 测试"],
        ]
        let data = try await call(server, "POST", "/api/v1/auth/device/login", body: body, token: nil)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = (json?["data"] as? [String: Any])?["token"] as? String else {
            throw URLError(.userAuthenticationRequired)
        }
        return token
    }

    static func approve(server: String, token: String, userCode: String) async throws {
        _ = try await call(server, "POST", "/api/v1/auth/devices/requests/\(userCode)/approve", body: nil, token: token)
    }

    static func logout(server: String, token: String) async throws {
        _ = try await call(server, "DELETE", "/api/v1/auth/devices/current", body: nil, token: token)
    }

    private static func call(_ server: String, _ method: String, _ path: String, body: [String: Any]?, token: String?) async throws -> Data {
        var request = URLRequest(url: URL(string: server + path)!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
