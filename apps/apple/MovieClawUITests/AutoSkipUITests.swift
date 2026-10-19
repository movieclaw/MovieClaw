import XCTest

/// 自动跳过的端到端验收（docs/design/skip-intro.md §5）：广告直接跳 + 撤回；片头第一次只给按钮，
/// 手动跳过后「本剧以后自动跳过片头」，重开 App 播下一集时按账号里记下的选择自动跳；撤回后本剧忘掉。
///
/// 依赖专门灌好的夹具后端（MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD，条目 MC_TEST_AUTOSKIP_SHOW）：
/// 一部剧第 1 季两集，每集 240 秒，区间 0–15 秒广告、30–75 秒片头、150–165 秒未分类、225 秒起片尾放到结尾。
/// 开测前把这个账号的自动跳过重置成默认（总开关开、这部剧片头没学过）。
///
/// `MC_TEST_AUTOSKIP_LEGACY=1` 时夹具后端模拟旧服务端（会话里没有 `auto_skip`、保存接口 404），
/// 只跑 `testOldServerKeepsIntroManual`：广告照跳，片头手动跳过后不说「以后自动跳过」，下一集也不自动跳。
final class AutoSkipUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:8795" }
    private var username: String { env["MC_TEST_USERNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"] ?? "" }
    private var show: Int { env["MC_TEST_AUTOSKIP_SHOW"].flatMap { Int($0) } ?? 1 }
    private var legacy: Bool { env["MC_TEST_AUTOSKIP_LEGACY"] == "1" }

    @MainActor
    private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password, "-mcRoute", route]
        app.launch()
        return app
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // 另存一份到 MC_SHOT_DIR（模拟器里的测试进程能直接写宿主机的 /tmp），不用从未封口的 xcresult 里捞
        if let dir = env["MC_SHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    func testAdsSkipAndIntroLearnsPerShow() throws {
        try XCTSkipIf(legacy, "旧服务端夹具只跑 testOldServerKeepsIntroManual")
        continueAfterFailure = false
        let backend = Backend(server: server, username: username, password: password)
        backend.request("PUT", "/playback/auto-skip", body: ["enabled": true])
        backend.request("PUT", "/playback/auto-skip/intro/\(show)", body: ["enabled": false])
        XCUIDevice.shared.orientation = .landscapeLeft

        // 第 1 集从头：开头的广告直接跳，给「撤回」
        var app = launch(route: "/play/\(show)/s01e01?t=0")
        XCTAssertTrue(app.staticTexts["已跳过广告"].waitForExistence(timeout: 40), "开头广告应自动跳过")
        XCTAssertEqual(app.buttons["player-skip-notice-action"].label, "撤回")
        snapshot("1-ad-skipped")

        // 30 秒进片头：这部剧没学过，只给按钮
        let skip = app.buttons["player-skip-segment"]
        XCTAssertTrue(skip.waitForExistence(timeout: 40), "片头应只给「跳过片头」按钮")
        XCTAssertEqual(skip.value as? String, "intro")
        snapshot("2-intro-button")

        // 手动跳过一次：记下这部剧，给「不用」
        skip.tap()
        XCTAssertTrue(app.staticTexts["本剧以后自动跳过片头"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["player-skip-notice-action"].label, "不用")
        snapshot("3-intro-learned")

        // 控制层：进度条上标着区间；⋯ 菜单里不放自动跳过开关（靠记忆 + 撤回）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).tap()
        let settings = app.buttons["player-设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        snapshot("4-progress-marks")
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '播放诊断'")).firstMatch
            .waitForExistence(timeout: 5), "⋯ 菜单应已打开")
        let toggle = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '自动跳过'")).firstMatch
        XCTAssertFalse(toggle.exists, "⋯ 菜单不应再有「自动跳过」")
        snapshot("5-settings-menu")
        app.terminate()

        // 重开 App 播第 2 集：选择来自账号，片头直接跳
        app = launch(route: "/play/\(show)/s01e02?t=25")
        XCTAssertTrue(app.staticTexts["已跳过片头"].waitForExistence(timeout: 40), "学过的片头应自动跳过")
        snapshot("6-intro-skipped")

        // 撤回：回到片头起点，本剧忘掉；提示收起后还能手动跳
        app.buttons["player-skip-notice-action"].tap()
        XCTAssertTrue(app.staticTexts["本剧不再自动跳过片头"].waitForExistence(timeout: 5))
        snapshot("7-intro-undone")
        XCTAssertTrue(app.buttons["player-skip-segment"].waitForExistence(timeout: 10), "撤回后片头应给回按钮")
    }

    /// 旧服务端记不住片头选择：不能说「本剧以后自动跳过片头」，退出再播下一集片头照样只给按钮
    @MainActor
    func testOldServerKeepsIntroManual() throws {
        try XCTSkipUnless(legacy, "需要 MC_TEST_AUTOSKIP_LEGACY=1 的旧服务端夹具")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft

        // 广告不靠服务端记忆，照跳
        var app = launch(route: "/play/\(show)/s01e01?t=0")
        XCTAssertTrue(app.staticTexts["已跳过广告"].waitForExistence(timeout: 40), "旧服务端上广告也应自动跳过")
        snapshot("legacy-1-ad-skipped")

        let skip = app.buttons["player-skip-segment"]
        XCTAssertTrue(skip.waitForExistence(timeout: 40), "片头应只给「跳过片头」按钮")
        skip.tap()
        XCTAssertFalse(app.staticTexts["本剧以后自动跳过片头"].waitForExistence(timeout: 3), "旧服务端记不住，不该承诺以后自动跳")
        snapshot("legacy-2-intro-skipped-manually")
        app.terminate()

        // 退出后播下一集：片头仍只给按钮
        app = launch(route: "/play/\(show)/s01e02?t=25")
        XCTAssertTrue(app.buttons["player-skip-segment"].waitForExistence(timeout: 40), "下一集片头应仍只给按钮")
        XCTAssertFalse(app.staticTexts["已跳过片头"].exists)
        snapshot("legacy-3-next-episode-button")
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
        request("POST", "/auth/login", body: ["username": username, "password": password, "remember": true])
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
