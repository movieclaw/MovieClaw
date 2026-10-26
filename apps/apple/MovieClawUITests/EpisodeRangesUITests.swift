import XCTest

/// 长剧集分段选集的端到端验收（docs/design/long-season-episode-ranges.md）：进页锁锚点的段、换段、上一段 / 下一段、
/// 「全部分集」面板、播放回来（这里用详情页的「标为已看」走同一条刷新链路）锚点变了重新锁段、两季长剧、≤50 集不出段胶囊但同样落在锚点上。
///
/// 依赖专门灌好的夹具后端（MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD）：库 1 里
/// 条目 1「名侦探柯南」一季 1186 集、锚点 1050；条目 2「两季长剧」S1 120 集锚点 77、S2 30 集；条目 3「十二集短剧」锚点 5。
/// 测完把第 1050 集恢复成没看完。
final class EpisodeRangesUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:8798" }
    private var username: String { env["MC_TEST_USERNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "ios" }
    private var password: String { env["MC_TEST_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 } ?? "range-pass-1" }

    @MainActor
    private func launch(item: Int) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password,
                               "-mcRoute", "/library/1/item/\(item)"]
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
    private func waitSelected(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND isSelected == true")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// 分集区在详情页下方：滚到能看见段胶囊
    @MainActor
    private func revealEpisodes(_ app: XCUIApplication) {
        let section = app.descendants(matching: .any)["season-episodes"]
        XCTAssertTrue(section.waitForExistence(timeout: 20), "应出现分集区")
        for _ in 0..<4 where !app.buttons["episode-ranges-all"].isHittable && !app.buttons["season-picker"].isHittable {
            app.swipeUp(velocity: .slow)
        }
    }

    private lazy var backend = Backend(server: server, username: username, password: password)

    override func tearDown() {
        // 恢复夹具：第 1050 集回到没看完（取消已看会把进度一起清掉），再把进度补回 42%（锚点 1050）
        backend.request("POST", "/playback/marks", body: ["media_item_id": 1, "season_number": 1, "episode_number": 1050, "played": false])
        backend.request("POST", "/playback/progress", body: ["media_item_id": 1, "season_number": 1, "episode_number": 1050,
                                                             "event": "stop", "position_ms": 604_800])
        super.tearDown()
    }

    /// 柯南：进页锁 1001–1050 选中 1050（服务端锚点，不被第 3 集拽回去）→ 换段落段首 → 上一段 / 下一段 →
    /// 全部分集面板落在锚点段并露出 1050 → 面板里换段点一集 → 关面板、选中与段锁过去 → 标为已看后锚点变 1051，重新锁段
    @MainActor
    func testLongSeasonRangesFollowAnchor() {
        let app = launch(item: 1)
        revealEpisodes(app)
        let anchorCard = app.buttons["episode-1050"]
        let entered = waitSelected(anchorCard, timeout: 20)
        snapshot("01 进页锁定 1001–1050 选中 1050")
        XCTAssertTrue(entered, "进页应选中锚点 1050")
        XCTAssertEqual(anchorCard.value as? String, "接着看")
        XCTAssertTrue(anchorCard.isHittable, "锚点卡应滚到可见")
        XCTAssertTrue(app.buttons["episode-range-20"].isSelected, "段应锁在 1001–1050")
        XCTAssertEqual(app.buttons["episode-range-20"].value as? String, "接着看")
        XCTAssertEqual(app.buttons["episode-range-20"].label, "1001–1050")
        XCTAssertTrue(app.buttons["episode-range-23"].exists && app.buttons["episode-range-23"].label == "1151–1186")
        XCTAssertFalse(app.buttons["episode-1000"].exists, "横排只放当前段")
        XCTAssertFalse(app.buttons["episode-1051"].exists, "横排只放当前段")
        // 1050 是段尾：下一段小卡紧挨着它露出来（上一段在横排最前，懒加载没建，下面换段后再验）
        XCTAssertTrue(app.buttons["episode-range-next"].isHittable)
        XCTAssertTrue(app.buttons["episode-ranges-all"].label.contains("全部 1186 集"))

        // 手动换段：段里没有锚点 → 段首
        app.buttons["episode-range-21"].tap()
        XCTAssertTrue(waitSelected(app.buttons["episode-1051"]), "换到 1051–1100 应选中段首 1051")
        XCTAssertTrue(app.buttons["episode-range-21"].isSelected)
        XCTAssertFalse(app.buttons["episode-1050"].exists)
        XCTAssertTrue(app.buttons["episode-range-prev"].isHittable, "段首在最前，上一段小卡应可见")
        snapshot("02 换段 1051–1100 选中段首")

        // 上一段：段里有锚点 → 锚点
        app.buttons["episode-range-prev"].tap()
        XCTAssertTrue(waitSelected(app.buttons["episode-1050"]), "上一段回到 1001–1050 应选中锚点")
        XCTAssertTrue(app.buttons["episode-range-20"].isSelected)
        XCTAssertTrue(app.buttons["episode-range-next"].waitForExistence(timeout: 3))
        snapshot("03 上一段回到锚点段")
        app.buttons["episode-range-next"].tap()
        XCTAssertTrue(waitSelected(app.buttons["episode-1051"]), "下一段应选中 1051")

        // 全部分集：落在锚点段，锚点格子可见
        app.buttons["episode-ranges-all"].tap()
        let anchorCell = app.buttons["episode-grid-1050"]
        XCTAssertTrue(anchorCell.waitForExistence(timeout: 5), "面板应落在锚点段")
        XCTAssertTrue(app.buttons["episode-grid-range-20"].isSelected)
        XCTAssertTrue((anchorCell.value as? String)?.contains("接着看") == true)
        XCTAssertTrue(anchorCell.isHittable, "锚点格子应滚到可见")
        XCTAssertFalse(app.buttons["episode-grid-1051"].exists)
        XCTAssertFalse(anchorCell.isSelected, "选中的是 1051，不在这一段")
        XCTAssertEqual(app.buttons["episode-grid-1049"].value as? String, "已看")
        XCTAssertFalse(app.buttons["episode-grid-1049"].isSelected, "已看的格子不是选中")
        snapshot("04 全部分集面板落在锚点段")

        // 面板里换段点一集：关面板、选中它、段跟过去
        app.buttons["episode-grid-range-2"].tap()
        let cell = app.buttons["episode-grid-120"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["episode-grid-range-2"].isSelected)
        snapshot("05 面板换到 101–150")
        cell.tap()
        XCTAssertTrue(waitGone(app.buttons["episode-grid-120"]), "点格子后面板应关闭")
        XCTAssertTrue(waitSelected(app.buttons["episode-120"]), "应选中第 120 集")
        XCTAssertTrue(app.buttons["episode-120"].isHittable, "横排应滚到第 120 集")
        XCTAssertTrue(app.buttons["episode-range-2"].isSelected, "段应锁到 101–150")
        XCTAssertFalse(app.buttons["episode-1050"].exists)
        snapshot("06 面板选 120 后锁到 101–150")

        // 回到锚点段（段胶囊横滑过去，同手指操作），把 1050 标为已看（与播放回来同一条刷新链路）：锚点变 1051 → 锁到 1051–1100 选中 1051
        let anchorChip = app.buttons["episode-range-20"]
        let rowY = app.buttons["episode-range-2"].frame.midY
        let width = app.frame.width
        for _ in 0..<12 where !(anchorChip.frame.minX > 0 && anchorChip.frame.maxX < width) {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: 340, dy: rowY)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 40, dy: rowY)))
        }
        anchorChip.tap()
        XCTAssertTrue(waitSelected(app.buttons["episode-1050"]))
        let played = app.buttons["item-played"]
        for _ in 0..<4 where !played.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(played.isHittable)
        played.tap()
        revealEpisodes(app)
        XCTAssertTrue(waitSelected(app.buttons["episode-1051"], timeout: 15), "锚点变成 1051 应重新锁段并选中它")
        XCTAssertTrue(app.buttons["episode-range-21"].isSelected)
        XCTAssertEqual(app.buttons["episode-1051"].value as? String, "接着看")
        XCTAssertEqual(app.buttons["episode-range-21"].value as? String, "接着看")
        snapshot("07 标为已看后锁到 1051–1100")
    }

    /// 服务端把 1050 标为看完后重新进页：直接锁到 1051–1100、选中 1051
    @MainActor
    func testReopenAfterFinishingAnchorLocksNextRange() {
        backend.request("POST", "/playback/marks", body: ["media_item_id": 1, "season_number": 1, "episode_number": 1050, "played": true])
        let app = launch(item: 1)
        revealEpisodes(app)
        XCTAssertTrue(waitSelected(app.buttons["episode-1051"], timeout: 20), "看完 1050 后进页应选中 1051")
        XCTAssertTrue(app.buttons["episode-1051"].isHittable)
        XCTAssertTrue(app.buttons["episode-range-21"].isSelected)
        XCTAssertEqual(app.buttons["episode-1051"].value as? String, "接着看")
        snapshot("08 看完 1050 后重新进页锁到 1051")
    }

    /// 两季长剧：S1 120 集锁 51–100 选中 77；S2 30 集不分段
    @MainActor
    func testTwoSeasonShow() {
        let app = launch(item: 2)
        revealEpisodes(app)
        XCTAssertTrue(waitSelected(app.buttons["episode-77"], timeout: 20), "S1 应选中锚点 77")
        XCTAssertTrue(app.buttons["episode-range-1"].isSelected)
        XCTAssertEqual(app.buttons["episode-range-1"].label, "51–100")
        XCTAssertEqual(app.buttons["episode-range-2"].label, "101–120")
        XCTAssertTrue(app.buttons["episode-ranges-all"].label.contains("全部 120 集"))
        snapshot("09 两季长剧 S1 锁 51–100")

        app.buttons["season-picker"].tap()
        let s2 = app.buttons["第 2 季"]
        XCTAssertTrue(s2.waitForExistence(timeout: 5))
        s2.tap()
        XCTAssertTrue(waitSelected(app.buttons["episode-1"]), "S2 没播放过（锚点 null）应按原规则落第 1 集")
        snapshot("10 两季长剧 S2 不分段")
        XCTAssertTrue(waitGone(app.buttons["episode-range-0"]), "30 集不分段")
        XCTAssertFalse(app.buttons["episode-ranges-all"].exists)
        XCTAssertTrue(app.staticTexts["在库 30 / 30 集"].exists)
        XCTAssertTrue(app.buttons["episode-1"].isHittable)
        XCTAssertNotEqual(app.buttons["episode-1"].value as? String, "接着看", "一集没碰过的季不标「接着看」")
    }

    /// ≤50 集：没有段胶囊与面板入口；默认选中并滚到锚点（第 5 集），有观看记录所以标「接着看」
    @MainActor
    func testShortSeasonLandsOnAnchor() {
        let app = launch(item: 3)
        revealEpisodes(app)
        XCTAssertTrue(waitSelected(app.buttons["episode-5"], timeout: 20), "应选中接着看的第 5 集")
        XCTAssertTrue(app.buttons["episode-5"].isHittable, "第 5 集应在可视区")
        XCTAssertFalse(app.buttons["episode-range-0"].exists)
        XCTAssertFalse(app.buttons["episode-ranges-all"].exists)
        XCTAssertFalse(app.buttons["episode-range-next"].exists)
        XCTAssertTrue(app.staticTexts["在库 12 / 12 集"].exists)
        XCTAssertEqual(app.buttons["episode-5"].value as? String, "接着看", "短季有观看记录同样标「接着看」")
        snapshot("11 十二集短剧落在第 5 集无段胶囊")
    }
}

/// 测试侧直连后端（独立登录，与 App 同一个成员）
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
