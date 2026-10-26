import XCTest

/// Apple TV 的自动跳过验收（docs/design/skip-intro.md §5）：只用遥控器。
/// 广告直接跳、「撤回」自动拿焦点、返回键 = 不撤回（不退出播放）；片头手动跳过一次后
/// 「本剧以后自动跳过片头」只告知、不抢焦点；重开播下一集片头自动跳，按确认撤回就忘掉。
///
/// 夹具同 iPhone 版 `AutoSkipUITests`（MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD，剧 MC_TEST_AUTOSKIP_SHOW）：
/// 每集 240 秒，0–15 秒广告、30–75 秒片头、150–165 秒未分类、225 秒起片尾。
/// `MC_TEST_AUTOSKIP_LEGACY=1` 时后端模拟旧服务端（会话不带 `auto_skip`、保存接口 404），只跑 `testOldServerKeepsIntroManual`。
final class TVAutoSkipUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:8795" }
    private var username: String { env["MC_TEST_USERNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"] ?? "" }
    private var show: Int { env["MC_TEST_AUTOSKIP_SHOW"].flatMap { Int($0) } ?? 1 }
    private var legacy: Bool { env["MC_TEST_AUTOSKIP_LEGACY"] == "1" }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password, "-mcRoute", route]
        app.launch()
        return app
    }

    @MainActor
    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if let dir = env["MC_SHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.hasFocus { return true }
            usleep(200_000)
        }
        return element.hasFocus
    }

    /// 开测前把账号的自动跳过重置成默认（总开关开、这部剧片头没学过）
    private func resetPreferences() async throws {
        let token = try await TestBackend.login(server: server, username: username, password: password)
        try await TestBackend.setAutoSkip(server: server, token: token, enabled: true)
        try await TestBackend.setIntroAutoSkip(server: server, token: token, item: show, enabled: false)
    }

    @MainActor
    func testAdsSkipAndIntroLearnsPerShow() async throws {
        try XCTSkipIf(legacy, "旧服务端夹具只跑 testOldServerKeepsIntroManual")
        try await resetPreferences()

        // 第 1 集从头：开头广告直接跳，「撤回」自动拿焦点；返回键 = 不撤回，播放器不退出
        var app = launch(route: "/play/\(show)/s01e01?t=0")
        let undo = app.element("tv-player-skip-undo")
        XCTAssertTrue(undo.waitForExistence(timeout: 40), "开头广告应自动跳过")
        XCTAssertTrue(undo.label.contains("已跳过广告"), undo.label)
        XCTAssertTrue(waitForFocus(undo), "「撤回」应自动拿到焦点")
        snapshot("tv-1-ad-skipped")
        TVRemote.press(.menu)
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5), "返回键应收起「撤回」")
        XCTAssertTrue(app.element("tv-player").exists, "返回键收起提示，不该退出播放")

        // 30 秒进片头：没学过，只给按钮；按一下跳过并学会，提示只告知、不抢焦点
        let skip = app.element("tv-player-skip")
        XCTAssertTrue(skip.waitForExistence(timeout: 40), "片头应只给「跳过片头」按钮")
        XCTAssertTrue(waitForFocus(skip))
        TVRemote.press(.select)
        let notice = app.element("tv-player-skip-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "手动跳过后应提示以后自动跳过")
        XCTAssertEqual(notice.label, "本剧以后自动跳过片头")
        XCTAssertFalse(app.element("tv-player-skip-undo").exists)
        snapshot("tv-2-intro-learned")
        app.terminate()

        // 重开播第 2 集：选择来自账号，片头自动跳；按确认撤回，本剧忘掉，按钮回来
        app = launch(route: "/play/\(show)/s01e02?t=25")
        let undo2 = app.element("tv-player-skip-undo")
        XCTAssertTrue(undo2.waitForExistence(timeout: 40), "学过的片头应自动跳过")
        XCTAssertTrue(undo2.label.contains("已跳过片头"), undo2.label)
        XCTAssertTrue(waitForFocus(undo2))
        snapshot("tv-3-intro-skipped")
        TVRemote.press(.select)
        let forgot = app.element("tv-player-skip-notice")
        XCTAssertTrue(forgot.waitForExistence(timeout: 5))
        XCTAssertEqual(forgot.label, "本剧不再自动跳过片头")
        snapshot("tv-4-intro-undone")
        XCTAssertTrue(app.element("tv-player-skip").waitForExistence(timeout: 10), "撤回后片头应给回按钮")
    }

    /// 旧服务端记不住片头选择：不说「本剧以后自动跳过片头」，重开播下一集片头照样只给按钮
    @MainActor
    func testOldServerKeepsIntroManual() throws {
        try XCTSkipUnless(legacy, "需要 MC_TEST_AUTOSKIP_LEGACY=1 的旧服务端夹具")
        var app = launch(route: "/play/\(show)/s01e01?t=0")
        XCTAssertTrue(app.element("tv-player-skip-undo").waitForExistence(timeout: 40), "旧服务端上广告也应自动跳过")
        let skip = app.element("tv-player-skip")
        XCTAssertTrue(skip.waitForExistence(timeout: 40))
        XCTAssertTrue(waitForFocus(skip))
        TVRemote.press(.select)
        XCTAssertFalse(app.element("tv-player-skip-notice").waitForExistence(timeout: 3), "旧服务端记不住，不该承诺以后自动跳")
        snapshot("tv-legacy-1-no-promise")
        app.terminate()

        app = launch(route: "/play/\(show)/s01e02?t=25")
        XCTAssertTrue(app.element("tv-player-skip").waitForExistence(timeout: 40), "下一集片头应仍只给按钮")
        XCTAssertFalse(app.element("tv-player-skip-undo").exists)
        snapshot("tv-legacy-2-ep2-button")
    }
}
