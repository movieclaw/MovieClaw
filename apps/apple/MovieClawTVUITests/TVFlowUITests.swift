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
    /// 演职员带 TMDB 影人 id 的电影（影人页验收）：夹具里的「一路向南」
    private var personItem: String { env["MC_TEST_PERSON_ITEM"] ?? "7" }

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

    /// 等一个元素拿到焦点（焦点动画与程序挪焦点都要一点时间）
    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.hasFocus { return true }
            usleep(200_000)
        }
        return element.hasFocus
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
        TVRemote.select(app.element("tv-home-hero-play"), trying: [.down, .left])
        waitForPlayback(app)
        snapshot("11-playing")
        TVRemote.press(.playPause)
        XCTAssertTrue(app.element("tv-player-paused").waitForExistence(timeout: 10), "暂停后没有显示片名")
        snapshot("12-paused")
        TVRemote.press(.menu)
        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 10), "返回键没有退出播放器")
        XCTAssertFalse(app.element("tv-player").exists)
    }

    // MARK: 首页行的「查看全部」

    /// 首页「接下来继续」下面那一行：往右滑到底是「查看全部」，按确认进完整海报墙，返回键回到原来的位置
    @MainActor
    func testHomeRowSeeAll() {
        let app = launchSignedIn()
        XCTAssertTrue(app.element("tv-home-hero-play").waitForExistence(timeout: 20))
        XCTAssertTrue(waitForFocus(app.element("tv-home-hero-play"), timeout: 10))
        // 大图按钮 → 「接下来继续」→ 下一行
        TVRemote.press(.down, times: 2)
        let seeAll = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv-see-all-' AND hasFocus == true")).firstMatch
        for _ in 0 ..< 30 where !seeAll.exists {
            TVRemote.press(.right)
        }
        XCTAssertTrue(seeAll.exists, "行尾没有「查看全部」")
        let identifier = seeAll.identifier
        snapshot("15-home-see-all")
        TVRemote.press(.select)
        XCTAssertTrue(app.element("tv-row-wall").waitForExistence(timeout: 10), "没有进入「查看全部」海报墙")
        let poster = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv-poster-'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15), "「查看全部」海报墙是空的")
        snapshot("16-row-wall")
        TVRemote.press(.menu)
        XCTAssertTrue(waitForFocus(app.element(identifier), timeout: 10), "返回后焦点没有回到「查看全部」")
    }

    // MARK: 媒体库 → 详情 → 播放

    @MainActor
    func testLibraryDetailPlay() {
        let app = launchSignedIn(["-mcTab", "library-\(movieLibrary)"])
        XCTAssertTrue(app.element("tv-library-\(movieLibrary)").waitForExistence(timeout: 20))
        snapshot("20-library")
        // 冷启动直接落在海报墙：等第一张海报拿到焦点再按确认（页面刚出来就按，海报还没进焦点系统）
        let poster = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv-poster-'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15), "海报墙是空的")
        XCTAssertTrue(waitForFocus(poster, timeout: 10), "海报墙的第一张没有拿到焦点")
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

    /// 详情页的演职员 → 影人页（库内作品，与海报墙同一套版式）→ 返回时焦点回到那位演职员
    @MainActor
    func testCastOpensPersonPage() {
        let app = launchSignedIn(["-mcTab", "item-\(movieLibrary)-\(personItem)"])
        let play = app.element("tv-item-play")
        XCTAssertTrue(play.waitForExistence(timeout: 20), "没有进入详情页")
        XCTAssertTrue(waitForFocus(play, timeout: 10), "详情页主按钮没有拿到焦点")
        // 电影往下第一行就是演职员，落在第一位
        TVRemote.press(.down)
        let cast = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv-cast-' AND identifier != 'tv-cast-none'")).firstMatch
        XCTAssertTrue(cast.waitForExistence(timeout: 10), "详情页没有能进影人页的演职员")
        XCTAssertTrue(waitForFocus(cast, timeout: 5), "往下没有落到演职员第一位")
        let personId = cast.identifier.dropFirst("tv-cast-".count)
        TVRemote.press(.select)
        XCTAssertTrue(app.element("tv-person-\(personId)").waitForExistence(timeout: 15), "没有进入影人页")
        let credit = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv-person-credit-'")).firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: 15), "影人页没有作品")
        XCTAssertTrue(waitForFocus(credit, timeout: 5), "影人页的第一部作品没有拿到焦点")
        snapshot("25-person")
        TVRemote.press(.menu)
        XCTAssertTrue(waitForFocus(cast, timeout: 10), "返回后焦点没有回到那位演职员")
    }

    /// 剧集：详情页往下滑到分集横排，选第 3 集直接播
    @MainActor
    func testShowEpisodePlay() {
        let app = launchSignedIn(["-mcTab", "library-\(showLibrary)"])
        XCTAssertTrue(app.element("tv-library-\(showLibrary)").waitForExistence(timeout: 20))
        // 焦点在标签栏的「首页」上：库里只有一部剧、摆在最左边，「首页」正下方是右上角的排序按钮——按条目找海报
        TVRemote.select(app.element("tv-poster-\(showItem)"), trying: [.down, .left])
        let episode = app.element("tv-episode-3")
        XCTAssertTrue(episode.waitForExistence(timeout: 15), "剧集详情没有分集")
        // 往下滑到分集横排（落在接着看的那一集），再左右找到第 3 集
        TVRemote.press(.down)
        TVRemote.focus(episode, trying: [.right, .left])
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
        // 冷启动直接落在搜索页签：焦点在屏幕键盘上，文字发给键盘（同登录页的输入）
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "没有出屏幕键盘")
        // 键盘出来后过一会儿焦点才落进去（侧边栏收起的动画），落进去之前发文字系统会说没有输入焦点
        XCTAssertTrue(waitForFocus(keyboard, timeout: 10), "屏幕键盘没有拿到焦点")
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

    /// 登录两个账号后重开 App：先问「谁在看」，选第二个账号进入
    @MainActor
    func testWhoIsWatchingSwitchesAccount() {
        // 第一次：以管理员进入，落在侧边栏的「账号」页签（谁在看），用「添加账号」登录第二个账号
        var app = launchSignedIn(["-mcTab", "account"])
        XCTAssertTrue(app.element("tv-who-is-watching").waitForExistence(timeout: 20), "没有打开「谁在看」")
        TVRemote.select(app.element("tv-profile-add"), trying: [.right, .left])
        let usePassword = app.element("tv-pairing-use-password")
        XCTAssertTrue(usePassword.waitForExistence(timeout: 15))
        TVRemote.select(usePassword, by: .down)
        TVRemote.type(member, into: app.element("tv-signin-username"), app: app, by: .down)
        TVRemote.type(memberPassword, into: app.element("tv-signin-password"), app: app, by: .down)
        TVRemote.select(app.element("tv-signin-submit"), trying: [.down, .left])
        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 20), "登录第二个账号后没有回到首页")
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

    // MARK: 播放器：跳过片头、下一集

    /// 剧集从头放：片头时段出现「跳过片头」并自动拿到焦点，按一下就跳过
    @MainActor
    func testSkipIntroButton() {
        let app = launchSignedIn(["-mcRoute", "/play/\(showItem)/s01e03?t=0"])
        waitForPlayback(app)
        let skip = app.element("tv-player-skip")
        XCTAssertTrue(skip.waitForExistence(timeout: 15), "片头时段没有出现「跳过片头」")
        XCTAssertTrue(waitForFocus(skip), "「跳过片头」出现时没有自动拿到焦点")
        snapshot("55-skip-intro")
        TVRemote.press(.select)
        XCTAssertTrue(skip.waitForNonExistence(timeout: 10), "按了「跳过片头」按钮没有消失（没跳过去）")
        TVRemote.press(.menu)
    }

    /// 片尾：出现「下一集」卡片并拿到焦点，按一下直接放下一集
    @MainActor
    func testUpNextCardPlaysNextEpisode() {
        let app = launchSignedIn(["-mcRoute", "/play/\(showItem)/s01e01?t=290"])
        waitForPlayback(app)
        let card = app.element("tv-player-upnext")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "片尾没有出现「下一集」卡片")
        snapshot("56-up-next")
        XCTAssertTrue(waitForFocus(card), "「下一集」卡片没有自动拿到焦点")
        TVRemote.press(.select)
        XCTAssertTrue(card.waitForNonExistence(timeout: 15), "按了「下一集」卡片还在")
        waitForPlayback(app)
        snapshot("57-next-episode")
        TVRemote.press(.menu)
    }

    // MARK: Top Shelf 的内部链接

    /// Top Shelf「播放」用的 movieclaw://play/… 链接：直接起播（模拟器打开外部链接会先问一句，按「打开」）
    @MainActor
    func testTopShelfDeepLinkPlays() {
        let app = launchSignedIn()
        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 20))
        app.open(URL(string: "movieclaw://play/1")!)
        // 系统确认框在系统界面（PineBoard）里：焦点默认在「打开」上，按确认即可
        let confirm = XCUIApplication(bundleIdentifier: "com.apple.PineBoard").buttons["打开"]
        if confirm.waitForExistence(timeout: 5) { TVRemote.press(.select) }
        waitForPlayback(app)
        snapshot("58-deeplink-playing")
        TVRemote.press(.menu)
    }

    // MARK: 侧边栏的账号页签（谁在看）与关于

    /// 侧边栏的「账号」页签就是「谁在看」：选自己回到首页；底部「关于」在本页签里压栈打开，返回回到「谁在看」
    @MainActor
    func testProfilesAndAbout() {
        var app = launchSignedIn(["-mcTab", "account"])
        XCTAssertTrue(app.element("tv-who-is-watching").waitForExistence(timeout: 20), "没有打开「谁在看」")
        snapshot("65-profiles")
        XCTAssertTrue(waitForFocus(app.element("tv-profile-\(username)"), timeout: 10), "当前账号没有拿到焦点")
        TVRemote.press(.select)
        XCTAssertTrue(app.element("tv-home").waitForExistence(timeout: 10), "选自己没有回到首页")
        app.terminate()

        app = launchSignedIn(["-mcTab", "account"])
        XCTAssertTrue(app.element("tv-who-is-watching").waitForExistence(timeout: 20))
        // 焦点先落在当前账号上（页面刚出来就按，焦点还没进来），往下就是「关于」
        XCTAssertTrue(waitForFocus(app.element("tv-profile-\(username)"), timeout: 10), "当前账号没有拿到焦点")
        TVRemote.select(app.element("tv-profiles-about"), by: .down)
        XCTAssertTrue(app.element("tv-about").waitForExistence(timeout: 10), "关于页没有打开")
        XCTAssertTrue(app.staticTexts["AetherEngine（MovieClaw 修改版）"].exists, "关于页没有列出播放引擎的开源许可")
        snapshot("66-about")
        TVRemote.press(.menu)
        XCTAssertTrue(app.element("tv-about").waitForNonExistence(timeout: 10), "返回键没有退出关于页")
        XCTAssertTrue(app.element("tv-who-is-watching").waitForExistence(timeout: 5), "关于页退回来应当回到「谁在看」")
    }

    // MARK: T3：发现、订阅、片段
    // 2026-10-03 起这三项在 Apple TV 上暂时收起（TVMainView.showsDiscoverAndSubscriptions），测试先跳过，开关打开时一并恢复

    private static let discoverHidden = "发现、订阅、片段在 Apple TV 上暂时收起（TVMainView.showsDiscoverAndSubscriptions）"

    /// 发现：本周精选大图 → 作品详情 → 一键订阅。大图那部已经订过时，往下到「相似推荐」里挨个找一部还没订的
    @MainActor
    func testDiscoverOneClickSubscribe() throws {
        throw XCTSkip(Self.discoverHidden)
        let app = launchSignedIn(["-mcTab", "discover"])
        let detailButton = app.element("tv-discover-hero-detail")
        XCTAssertTrue(detailButton.waitForExistence(timeout: 25), "发现页没有本周精选大图")
        snapshot("70-discover")
        // 先往下：焦点可能在「电影 / 剧集」切换上，往右会直接切到剧集、整页重载
        TVRemote.select(detailButton, trying: [.down, .up, .right])
        XCTAssertTrue(app.element("tv-discover-title").waitForExistence(timeout: 15), "没有进作品详情")
        snapshot("71-discover-detail")

        var subscribe = app.element("tv-discover-subscribe")
        var attempt = 0
        while !subscribe.waitForExistence(timeout: 3), attempt < 6 {
            // 这一部已订阅 / 在库：从「相似推荐」进下一部（第 attempt 张海报）
            attempt += 1
            TVRemote.press(.down, times: 2)
            TVRemote.press(.right, times: attempt - 1)
            TVRemote.press(.select)
            _ = app.element("tv-discover-title").waitForExistence(timeout: 10)
            subscribe = app.element("tv-discover-subscribe")
        }
        XCTAssertTrue(subscribe.exists, "找了 \(attempt) 部推荐都没有可订阅的")
        snapshot("72-discover-before-subscribe")
        TVRemote.select(subscribe, trying: [.down, .right, .left])
        let note = app.element("tv-discover-subscribe-note")
        XCTAssertTrue(note.waitForExistence(timeout: 20), "按了订阅没有结果提示")
        XCTAssertTrue(note.label.hasPrefix("已订阅"), "订阅没成功：\(note.label)")
        XCTAssertTrue(app.element("tv-discover-subscribed").waitForExistence(timeout: 10), "订阅后按钮没有变成「已订阅」")
        snapshot("73-discover-subscribed")
    }

    /// 我的订阅：大图里刚入库的那部「播放」→ 出画 → 返回
    @MainActor
    func testSubscriptionsHeroPlays() throws {
        throw XCTSkip(Self.discoverHidden)
        let app = launchSignedIn(["-mcTab", "subscriptions"])
        XCTAssertTrue(app.element("tv-subscriptions").waitForExistence(timeout: 25))
        snapshot("80-subscriptions")
        let play = app.element("tv-subscriptions-hero-play")
        guard play.waitForExistence(timeout: 10) else {
            // 大图挑的不是已入库的那一部：页面能打开、各行在就算过（刚刚入库在下面的行里）
            XCTAssertTrue(app.staticTexts["刚刚入库"].exists || app.staticTexts["本周日程"].exists, "订阅页没有任何分区")
            return
        }
        // 冷启动直接落在订阅页时，页面还没加载完焦点可能先落在标签栏上：先往下进大图、再往左到「播放」
        TVRemote.select(play, trying: [.down, .left])
        waitForPlayback(app)
        snapshot("81-playing-from-subscriptions")
        TVRemote.press(.menu)
    }

    /// 片段：自动放第一段 → 点按右换下一段 → 按确认键接着看正片 → 返回回到片段
    @MainActor
    func testReelsPlayAndWatchFull() throws {
        throw XCTSkip(Self.discoverHidden)
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
