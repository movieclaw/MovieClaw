import XCTest

/// Smart subscription memory against the isolated fixture `tests/e2e/_smart_memory_api_launcher.py`
/// (real API, database and matcher; fixed metadata; dry-run downloads). Walks the household journey
/// from docs/design/smart-subscription-memory.md on iPhone and iPad. Start each run on a fresh server.
final class SmartMemoryUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"] ?? "" }
    private let session = URLSession(configuration: .ephemeral)
    private let admin = ("ios-memory", "isolated-ios-test")

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["MC_SMART_E2E"] == "1", let url = URL(string: server), ["localhost", "127.0.0.1"].contains(url.host) else { throw XCTSkip("Requires isolated server") }
    }

    @discardableResult
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, expect: Int? = 200) async throws -> Any {
        var req = URLRequest(url: URL(string: server + path)!); req.httpMethod = method
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: req)
        if let expect { XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expect, String(decoding: data, as: UTF8.self)) }
        let json = try JSONSerialization.jsonObject(with: data)
        return (json as? [String: Any])?["data"] ?? json
    }
    private func signIn(_ user: (String, String)) async throws {
        _ = try await request("/api/v1/auth/bootstrap", method: "POST", body: ["username": admin.0, "password": admin.1], expect: nil)
        try await request("/api/v1/auth/login", method: "POST", body: ["username": user.0, "password": user.1])
    }
    private func subscription(_ tmdb: Int) async throws -> [String: Any] {
        let all = try await request("/api/v1/subscriptions") as! [[String: Any]]
        let row = try XCTUnwrap(all.first { ($0["media"] as? [String: Any])?["tmdb_id"] as? Int == tmdb })
        return try await request("/api/v1/subscriptions/\(row["id"] as! Int)") as! [String: Any]
    }
    private func policy(_ tmdb: Int) async throws -> [String: Any] {
        let detail = try await subscription(tmdb)
        return try XCTUnwrap(detail["smart_policy"] as? [String: Any])
    }

    @MainActor private func launch(route: String = "/subscriptions", subscribe: String? = nil, as user: (String, String)? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        let who = user ?? admin
        app.launchArguments = ["--ui-testing", "-mcServer", server, "-mcUser", who.0, "-mcPass", who.1, "-mcRoute", route]
        if let subscribe { app.launchArguments += ["-mcSubscribe", subscribe] }
        app.launch(); return app
    }
    @MainActor private func snapshot(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let shot = XCUIScreen.main.screenshot()
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        if let dir = env["MC_SHOT_DIR"] { try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(device)-\(name).png")) }
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    @MainActor private func text(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }
    @MainActor private func wait(_ item: XCUIElement, _ app: XCUIApplication, _ what: String, timeout: TimeInterval = 20) {
        XCTAssertTrue(item.waitForExistence(timeout: timeout), what + "\n" + app.debugDescription)
    }
    @MainActor private func tap(_ app: XCUIApplication, _ item: XCUIElement, _ what: String) {
        wait(item, app, what)
        for _ in 0..<5 where !item.isHittable { app.swipeUp() }
        item.tap()
    }
    @MainActor private func submit(_ app: XCUIApplication) {
        tap(app, app.buttons["subscribe-submit"], "submit")
        XCTAssertTrue(app.buttons["subscribe-submit"].waitForNonExistence(timeout: 20), app.debugDescription)
    }
    @MainActor private func back(_ app: XCUIApplication, _ title: String) {
        app.navigationBars[title].buttons.element(boundBy: 0).tap()
    }
    /// 改画质：分辨率或片源，再选记在哪
    @MainActor private func changeQuality(_ app: XCUIApplication, _ value: String, scope: String) {
        tap(app, element(app, "smart-quality"), "改画质")
        tap(app, app.buttons[value].firstMatch, value)
        tap(app, app.buttons[scope].firstMatch, scope)
        snapshot("quality-\(scope)")
        back(app, "画质")
    }

    /// 服务器早于 0.42.0（启动器带 MC_LAB_LEGACY_SERVER=1）：预检没有智能摘要，弹层改按规则模式订阅
    @MainActor func testOlderServerSubscribesWithRules() async throws {
        guard env["MC_SMART_LEGACY"] == "1" else { throw XCTSkip("Requires MC_LAB_LEGACY_SERVER=1 server") }
        try await signIn(admin)
        let app = launch(subscribe: "tmdb:movie:701")
        wait(app.buttons["subscribe-submit"], app, "submit")
        XCTAssertFalse(text(app, "正在读取智能设置").exists, app.debugDescription)
        XCTAssertTrue(app.buttons["subscribe-submit"].isEnabled, app.debugDescription)
        snapshot("legacy-rules")
        submit(app)
        let detail = try await subscription(701)
        XCTAssertEqual(detail["selection_mode"] as? String, "rules")
    }

    @MainActor func testHouseholdJourney() async throws {
        guard env["MC_SMART_LEGACY"] != "1" else { throw XCTSkip("Needs a current server") }
        try await signIn(admin)

        // 1 首次设置：管理员直接进设置页；保存后回到订阅，第一次碰到英语就问一次
        var app = launch(subscribe: "tmdb:movie:701")
        tap(app, app.buttons["smart-save"], "first setup")
        wait(text(app, "这是英语片，要中文字幕吗？"), app, "english question")
        XCTAssertTrue(app.buttons["要，只下带中文字幕的"].isSelected || app.buttons["要，只下带中文字幕的"].exists)
        snapshot("01-first-english-question")
        submit(app)
        let oppenheimerLanguages = try await policy(701)["watchable_languages"] as? [String]
        XCTAssertEqual(oppenheimerLanguages, ["zh"])
        app.terminate()

        // 2 只有英语原版：详情写明在等字幕；这次先下原版，然后追问看不看得懂
        let released = try await request("/__lab/release/movie/701?name=RAW&hours_ago=1", method: "POST") as! [String: Any]
        XCTAssertEqual(released["dispatched"] as? Int, 0)
        let oppenheimer = try await subscription(701)["id"] as! Int
        app = launch(route: "/subscriptions/\(oppenheimer)")
        wait(element(app, "smart-awaiting-subtitles"), app, "awaiting subtitles", timeout: 30)
        wait(text(app, "英语 · 只下带中文字幕的"), app, "requirement")
        snapshot("02-awaiting-subtitles")
        tap(app, element(app, "smart-download-original"), "download original")
        let alert = app.alerts.firstMatch
        wait(alert, app, "understood alert")
        XCTAssertTrue(alert.label.contains("你看得懂英语吗"), alert.label)
        snapshot("03-understood-alert")
        alert.buttons["只这次"].tap()
        let wanted = (try await subscription(701)["wanted"] as! [[String: Any]])[0]
        XCTAssertNotEqual(wanted["status"] as? String, "wanted")
        app.terminate()

        // 3 同一种语言不再问；点「改」改成看得懂
        app = launch(subscribe: "tmdb:tv:804")
        wait(element(app, "smart-subtitle-line"), app, "subtitle line")
        XCTAssertEqual(element(app, "smart-subtitle-line").label, "英语 · 只下带中文字幕的")
        XCTAssertFalse(text(app, "要中文字幕吗").exists)
        tap(app, element(app, "smart-language-edit"), "edit language")
        tap(app, app.buttons["不用，我看得懂英语"].firstMatch, "understood")
        snapshot("04-change-language")
        submit(app)
        let breakingBadLanguages = try await policy(804)["watchable_languages"] as? [String]
        XCTAssertEqual(breakingBadLanguages, [])
        app.terminate()

        // 4 改了画质才问要不要记住，原因由用户自己点
        app = launch(subscribe: "tmdb:tv:801")
        wait(text(app, "这是韩语片，要中文或英语字幕吗？"), app, "korean question")
        changeQuality(app, "1080p", scope: "韩国的剧")
        wait(text(app, "优先 1080p WEB-DL"), app, "changed label")
        submit(app)
        app.terminate()
        app = launch(subscribe: "tmdb:tv:802")
        wait(element(app, "smart-quality-label"), app, "habit label")
        XCTAssertTrue(text(app, "优先 1080p WEB-DL").exists)
        XCTAssertTrue(text(app, "按「韩国的剧」的习惯").exists, app.debugDescription)
        snapshot("05-habit-applied")
        app.terminate()

        // 5 平台习惯比地区具体，写明被盖住的那条
        app = launch(subscribe: "tmdb:tv:803")
        changeQuality(app, "4K", scope: "Netflix 的剧")
        submit(app)
        app.terminate()
        app = launch(subscribe: "tmdb:tv:806")
        wait(text(app, "按「Netflix 的剧」的习惯"), app, "network habit")
        XCTAssertTrue(text(app, "「韩国的剧」是 1080p").exists, app.debugDescription)
        XCTAssertTrue(text(app, "优先 4K WEB-DL").exists)
        snapshot("06-conflict-order")
        app.terminate()

        // 6 「只这部」不会白设：续集沿用
        app = launch(subscribe: "tmdb:movie:703")
        changeQuality(app, "Remux", scope: "只这部")
        submit(app)
        app.terminate()
        app = launch(subscribe: "tmdb:movie:704")
        wait(text(app, "按《沙丘》的设置"), app, "series carry over")
        XCTAssertTrue(text(app, "优先 4K Remux").exists)
        snapshot("07-series")
        submit(app)
        let sequelSource = try await policy(704)["source"] as? String
        XCTAssertEqual(sequelSource, "remux")
        app.terminate()

        // 7 设置页：记住的东西都在这里，写明来源，可以删
        app = launch(subscribe: "tmdb:movie:705")
        tap(app, element(app, "smart-edit"), "settings")
        wait(element(app, "smart-language-en"), app, "english remembered")
        wait(text(app, "韩国的剧 · 1080p"), app, "region habit")
        XCTAssertTrue(text(app, "来自《请回答1988》").exists)
        snapshot("08-settings-memory")
        tap(app, app.buttons["移除韩国的剧"], "remove habit")
        XCTAssertTrue(text(app, "韩国的剧 · 1080p").waitForNonExistence(timeout: 10))
        let replyResolution = try await policy(801)["resolution"] as? String
        XCTAssertEqual(replyResolution, "2160p")
        tap(app, app.buttons["smart-cancel-edit"], "close settings")
        app.terminate()

        // 8 成员只看结论，不能改，也不会被问
        try await request("/api/v1/members", method: "POST", body: ["username": "ios-kid", "password": "member-pass-1"])
        app = launch(subscribe: "tmdb:tv:805", as: ("ios-kid", "member-pass-1"))
        wait(element(app, "smart-subtitle-line"), app, "member line")
        XCTAssertEqual(element(app, "smart-subtitle-line").label, "日语 · 只下带中文或英语字幕的")
        XCTAssertFalse(element(app, "smart-quality").exists)
        XCTAssertFalse(element(app, "smart-language-edit").exists)
        XCTAssertFalse(text(app, "字幕吗").exists)
        snapshot("09-member")
        app.terminate()
    }
}
