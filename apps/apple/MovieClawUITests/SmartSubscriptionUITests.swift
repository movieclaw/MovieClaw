import XCTest

/// Runs only against an explicitly enabled loopback fixture. Real API, database and matcher;
/// external metadata is fixed and downloading is dry-run. Never mutates the user's NAS.
final class SmartSubscriptionUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"] ?? "" }
    private let session = URLSession(configuration: .ephemeral)
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["MC_SMART_E2E"] == "1", let url = URL(string: server), ["localhost", "127.0.0.1"].contains(url.host) else { throw XCTSkip("Requires isolated server") }
    }
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        var req = URLRequest(url: URL(string: server + path)!); req.httpMethod = method
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        let json = try JSONSerialization.jsonObject(with: data)
        return (json as? [String: Any])?["data"] ?? json
    }
    private func login() async throws { _ = try await request("/api/v1/auth/login", method: "POST", body: ["username": "ios-smart", "password": "isolated-ios-test"]) }
    @MainActor private func launch(route: String = "/subscriptions", subscribe: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mcServer", server, "-mcUser", "ios-smart", "-mcPass", "isolated-ios-test", "-mcRoute", route]
        if let subscribe { app.launchArguments += ["-mcSubscribe", subscribe] }
        app.launch(); return app
    }
    @MainActor private func snapshot(_ name: String) {
        Thread.sleep(forTimeInterval: 1) // Let disclosure and sheet animations finish before visual review.
        let shot = XCUIScreen.main.screenshot()
        if let dir = env["MC_SHOT_DIR"] { try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let item = element(app, id)
        XCTAssertTrue(item.waitForExistence(timeout: 15), id + "\n" + app.debugDescription)
        for _ in 0..<5 where !item.isHittable { app.swipeUp() }
        item.tap()
    }
    @MainActor private func choose(_ app: XCUIApplication, _ id: String, _ label: String) {
        tap(app, id); let item = app.buttons[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), label); item.tap()
    }
    private func subscription(_ tmdb: Int) async throws -> [String: Any] {
        let all = try await request("/api/v1/subscriptions") as! [[String: Any]]
        return try XCTUnwrap(all.first { ($0["media"] as? [String: Any])?["tmdb_id"] as? Int == tmdb })
    }

    @MainActor func testSubscriptionWallsPutMissingContentBeforeUpgrades() async throws {
        try await login()
        let existing = try await request("/api/v1/subscriptions") as! [[String: Any]]
        if !existing.contains(where: { ($0["media"] as? [String: Any])?["title"] as? String == "排序电影search" }) {
            _ = try await request("/__lab/subscription-order", method: "POST")
        }
        for (kind, noun) in [("movie", "电影"), ("tv", "剧集")] {
            let app = launch()
            let home = element(app, "section-\(kind)")
            XCTAssertTrue(home.waitForExistence(timeout: 30), app.debugDescription)
            let homeCards = home.buttons.matching(identifier: "subscription-cell")
            for (index, state) in ["pipeline", "mixed", "search", "upgrade"].enumerated() {
                XCTAssertTrue(homeCards.element(boundBy: index).label.contains("排序\(noun)\(state)"), app.debugDescription)
            }
            tap(app, "shelf-more-\(kind)")
            let active = element(app, "wall-active")
            XCTAssertTrue(active.waitForExistence(timeout: 30), app.debugDescription)
            let cards = active.buttons.matching(identifier: "subscription-cell")
            XCTAssertEqual(cards.count, 4)
            for (index, state) in ["pipeline", "mixed", "search", "upgrade"].enumerated() {
                XCTAssertTrue(cards.element(boundBy: index).label.contains("排序\(noun)\(state)"), app.debugDescription)
            }
            XCTAssertTrue(cards.element(boundBy: 3).label.contains("洗版中"))
            snapshot("order-\(kind)")
            app.terminate()
        }
    }

    @MainActor func testIdentitySkipOnlyShowsInformation() async throws {
        try await login()
        let result = try await request("/__lab/identity/false", method: "POST") as! [String: Any]
        let id = try XCTUnwrap(result["id"] as? Int)
        let app = launch(route: "/subscriptions/\(id)")
        XCTAssertTrue(element(app, "identity-info").waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.buttons["smart-download-now"].exists)
        XCTAssertFalse(app.buttons["smart-extend-wait"].exists)
        XCTAssertFalse(element(app, "smart-deadline").exists)
        snapshot("identity-compact")
        tap(app, "identity-details")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Kitsune")).firstMatch.waitForExistence(timeout: 5))
        snapshot("identity-details")
        let notices = try await request("/api/v1/system/notices") as! [Any]
        XCTAssertTrue(notices.isEmpty)
        let recovered = try await request("/__lab/identity/true", method: "POST") as! [String: Any]
        XCTAssertEqual(recovered["dispatched"] as? Int, 1)
        app.terminate()
        let updated = launch(route: "/subscriptions/\(id)")
        XCTAssertTrue(updated.staticTexts["已提交下载器"].waitForExistence(timeout: 30))
        XCTAssertFalse(element(updated, "identity-info").exists)
        updated.terminate()
    }

    @MainActor func testMovieOnboardingReuseCustomDaysAndRules() async throws {
        try await login()
        let app = launch(subscribe: "tmdb:movie:100")
        XCTAssertTrue(app.buttons["smart-save"].waitForExistence(timeout: 35))
        XCTAssertFalse(app.buttons["subscribe-submit"].exists)
        XCTAssertFalse(element(app, "subscribe-library").exists)
        XCTAssertTrue(app.navigationBars["电影偏好"].buttons["smart-save"].exists)
        XCTAssertFalse(app.staticTexts["选择说明与最低要求"].exists)
        let upgrade = app.switches["smart-upgrade"].firstMatch
        XCTAssertEqual(upgrade.value as? String, "1")
        snapshot("movie-settings-green")
        upgrade.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(upgrade.value as? String, "0")
        snapshot("movie-settings-off")
        upgrade.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        choose(app, "smart-wait", "自定义")
        let days = app.textFields["smart-days"]
        XCTAssertTrue(days.waitForExistence(timeout: 5))
        days.doubleTap()
        days.typeText(XCUIKeyboardKey.delete.rawValue + "0")
        snapshot("movie-invalid-days")
        XCTAssertEqual(days.value as? String, "0", app.debugDescription)
        XCTAssertFalse(app.buttons["smart-save"].isEnabled, app.debugDescription)
        days.typeText(XCUIKeyboardKey.delete.rawValue + "7")
        XCTAssertTrue(app.steppers["smart-days-stepper"].buttons.allElementsBoundByIndex.contains { !$0.isEnabled })
        tap(app, "smart-save")
        XCTAssertTrue(app.buttons["smart-edit"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["smart-edit"].label.contains("最多等 7 天"))
        snapshot("movie-ready")
        tap(app, "smart-edit")
        XCTAssertTrue(app.buttons["smart-save"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["subscribe-submit"].exists)
        choose(app, "smart-resolution", "1080p")
        tap(app, "smart-cancel-edit")
        XCTAssertTrue(app.buttons["smart-edit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["smart-edit"].label.contains("优先 4K WEB-DL"))
        tap(app, "subscribe-submit")
        XCTAssertTrue(app.buttons["subscribe-submit"].waitForNonExistence(timeout: 20))
        let movie = try await subscription(100)
        XCTAssertEqual(movie["selection_mode"] as? String, "smart")
        let policy = try XCTUnwrap(movie["smart_policy"] as? [String: Any])
        XCTAssertEqual(policy["wait_seconds"] as? Int, 604800)
        XCTAssertEqual(policy["resolution"] as? String, "2160p")
        app.terminate()
        let second = launch(subscribe: "tmdb:movie:101")
        XCTAssertTrue(second.buttons["smart-edit"].waitForExistence(timeout: 30))
        XCTAssertTrue(second.buttons["subscribe-submit"].isEnabled)
        XCTAssertFalse(second.buttons["smart-save"].exists)
        tap(second, "subscribe-options"); choose(second, "subscribe-mode", "规则模式")
        XCTAssertTrue(element(second, "subscribe-ruleset").exists)
        XCTAssertFalse(element(second, "smart-summary").exists)
        snapshot("rules-options")
        second.navigationBars["更多选项"].buttons.element(boundBy: 0).tap()
        tap(second, "subscribe-submit")
        XCTAssertTrue(second.buttons["subscribe-submit"].waitForNonExistence(timeout: 20))
        let rule = try await subscription(101)
        XCTAssertEqual(rule["selection_mode"] as? String, "rules")
        XCTAssertGreaterThan(rule["rule_set_id"] as? Int ?? 0, 0)
        second.terminate()
    }

    @MainActor func testProfileConflictPreservesLegacyHoursAndExistingSubscription() async throws {
        try await login()
        let old = try await request("/api/v1/subscriptions/smart-profiles/movie") as! [String: Any]
        var preferences: [String: Any] = ["resolution": "2160p", "source": "web-dl", "wait_seconds": 21600, "allow_upgrade": true, "strict_resolution": false]
        let saved = try await request("/api/v1/subscriptions/smart-profiles/movie", method: "PUT", body: ["revision": old["revision"]!, "preferences": preferences]) as! [String: Any]
        _ = try await request("/api/v1/subscriptions", method: "POST", body: ["title_ref": "tmdb:movie:102", "selection_mode": "smart", "smart_profile_revision": saved["revision"]!])
        let app = launch(subscribe: "tmdb:movie:103")
        XCTAssertTrue(app.buttons["smart-edit"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["smart-edit"].label.contains("最多等 6 小时"))
        tap(app, "smart-edit")
        XCTAssertTrue(app.buttons["smart-save"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(element(app, "smart-wait").label.contains("原有设置"))
        snapshot("legacy-hour-settings")
        preferences["wait_seconds"] = 86400
        _ = try await request("/api/v1/subscriptions/smart-profiles/movie", method: "PUT", body: ["revision": saved["revision"]!, "preferences": preferences])
        tap(app, "smart-save")
        XCTAssertTrue(app.buttons["smart-reload"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["subscribe-submit"].exists)
        tap(app, "smart-reload")
        XCTAssertTrue(app.buttons["smart-save"].waitForExistence(timeout: 15))
        tap(app, "smart-cancel-edit")
        XCTAssertTrue(app.buttons["smart-edit"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["smart-edit"].label.contains("最多等 1 天"))
        let movie = try await subscription(102)
        XCTAssertEqual((movie["smart_policy"] as? [String: Any])?["wait_seconds"] as? Int, 21600)
        app.terminate()
    }

    @MainActor func testTVWaitActionsAndUnifiedEpisodeStatus() async throws {
        try await login()
        let app = launch(subscribe: "tmdb:tv:200")
        XCTAssertTrue(app.buttons["smart-save"].waitForExistence(timeout: 35))
        snapshot("tv-first-settings"); tap(app, "smart-save")
        XCTAssertTrue(app.buttons["smart-edit"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["smart-edit"].label.contains("最多等 3 小时"))
        XCTAssertFalse(app.buttons["season-1"].exists)
        tap(app, "subscribe-range")
        XCTAssertTrue(app.buttons["season-1"].waitForExistence(timeout: 10), app.debugDescription)
        let follow = app.switches["subscribe-follow-future"].firstMatch
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        follow.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(follow.value as? String, "0")
        tap(app, "season-2")
        snapshot("tv-range")
        app.navigationBars["追踪范围"].buttons.element(boundBy: 0).tap()
        snapshot("tv-ready"); tap(app, "subscribe-submit")
        XCTAssertTrue(app.buttons["subscribe-submit"].waitForNonExistence(timeout: 20))
        let tv = try await subscription(200); let id = try XCTUnwrap(tv["id"] as? Int)
        XCTAssertEqual(tv["selected_seasons"] as? [Int], [1])
        XCTAssertEqual(tv["follow_future"] as? Bool, false)
        _ = try await request("/__lab/discover", method: "POST")
        app.terminate()
        let detail = launch(route: "/subscriptions/\(id)")
        XCTAssertTrue(detail.buttons["subscription-more"].waitForExistence(timeout: 35))
        XCTAssertTrue(element(detail, "fact-智能目标").exists)
        XCTAssertFalse(detail.staticTexts["规则组"].exists)
        let row = detail.buttons["wanted-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        tap(detail, "smart-evidence"); snapshot("tv-wait-evidence")
        let before = try await request("/api/v1/subscriptions/\(id)") as! [String: Any]
        let beforeRow = try XCTUnwrap((before["wanted"] as? [[String: Any]])?.first)
        // Another client changes the wait first. The stale UI must fail visibly and refresh.
        _ = try await request("/api/v1/subscriptions/\(id)/wanted/\(beforeRow["id"]!)/smart-wait", method: "POST", body: ["version": beforeRow["selection_version"]!, "extend_seconds": 7200])
        tap(detail, "smart-extend-wait")
        XCTAssertTrue(element(detail, "smart-action-error").waitForExistence(timeout: 10))
        tap(detail, "smart-extend-wait")
        let extended = NSPredicate(format: "label CONTAINS %@", "按你延长的时间")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: extended, object: row)], timeout: 15), .completed)
        let after = try await request("/api/v1/subscriptions/\(id)") as! [String: Any]
        let afterRow = try XCTUnwrap((after["wanted"] as? [[String: Any]])?.first)
        XCTAssertGreaterThan(afterRow["selection_version"] as? Int ?? 0, beforeRow["selection_version"] as? Int ?? 0)
        tap(detail, "smart-download-now")
        var grabbed = false
        for _ in 0..<20 {
            let fresh = try await request("/api/v1/subscriptions/\(id)") as! [String: Any]
            grabbed = (fresh["wanted"] as? [[String: Any]])?.contains { $0["status"] as? String == "grabbed" } == true
            if grabbed { break }; try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(grabbed); detail.terminate()
        let manage = launch(route: "/subscriptions/\(id)")
        XCTAssertTrue(manage.buttons["subscription-more"].waitForExistence(timeout: 30))
        tap(manage, "subscription-more")
        XCTAssertTrue(manage.buttons["manage-洗一轮版"].waitForExistence(timeout: 5))
        XCTAssertFalse(manage.buttons["manage-更换规则组"].exists)
        tap(manage, "manage-洗一轮版")
        XCTAssertTrue(manage.staticTexts["智能目标：4K WEB-DL"].waitForExistence(timeout: 10))
        XCTAssertFalse(manage.buttons["upgrade-rule-option"].exists)
        snapshot("smart-upgrade")
        tap(manage, "upgrade-run-start")
        XCTAssertTrue(manage.buttons["upgrade-report-done"].waitForExistence(timeout: 20), manage.debugDescription)
        let checked = try await request("/api/v1/subscriptions/\(id)") as! [String: Any]
        XCTAssertEqual(checked["selection_mode"] as? String, "smart")
        XCTAssertEqual((checked["smart_policy"] as? [String: Any])?["resolution"] as? String, "2160p")
        manage.terminate()
    }
}
