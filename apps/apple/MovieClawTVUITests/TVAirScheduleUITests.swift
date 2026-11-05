import XCTest

/// 播出日历的遥控器验收（issue #547）。只对着专门的夹具跑（apps/android-tv/tests/fixture/air_schedule_fixture.py），
/// 没设 MC_AIR_FIXTURE=1 时跳过：
/// - MC_AIR_SERVER（默认 http://127.0.0.1:8840）、MC_AIR_USERNAME / MC_AIR_PASSWORD（默认 admin / mclaw-atv-2026）；
///   库 1 的条目 1 / 2 / 3 / 4 依次是：在播已订阅缺第 7 集、海外周更未订阅、已播完、两季长剧；
/// - MC_SHOT_DIR：每一步的截图同时落盘到这个目录。
/// 「订阅追更」用例真的会建订阅，结束时经接口删掉
final class TVAirScheduleUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_AIR_SERVER"] ?? "http://127.0.0.1:8840" }
    private var username: String { env["MC_AIR_USERNAME"] ?? "admin" }
    private var password: String { env["MC_AIR_PASSWORD"] ?? "mclaw-atv-2026" }

    override func setUpWithError() throws {
        try XCTSkipUnless(env["MC_AIR_FIXTURE"] == "1", "需要播出日历夹具（MC_AIR_FIXTURE=1）")
        continueAfterFailure = true
    }

    /// 站点日历的今天（夹具的播出日期按它算）
    private func day(_ offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date.now.addingTimeInterval(TimeInterval(offset) * 86400))
    }

    // MARK: 工具

    @MainActor
    private func launch(item: Int, english: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password,
                               "-mcTab", "item-1-\(item)"]
        if english { app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] }
        app.launch()
        // 冷启动直接落在详情页时外壳的启动黑幕要等一会儿才揭开（截图全黑），等它揭开再开始按
        _ = app.buttons["tv-item-play"].waitForExistence(timeout: 20)
        sleep(4)
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

    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.exists, element.hasFocus { return true }
            usleep(150_000)
        }
        return element.exists && element.hasFocus
    }

    @MainActor
    private func focusedDescription() -> String {
        let focused = XCUIApplication().descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return focused.exists ? "\(focused.identifier) | \(focused.label)" : "无"
    }

    /// 按一下键、断言焦点落到目标上
    @MainActor
    private func press(_ button: XCUIRemote.Button, times: Int = 1, expect target: XCUIElement, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0 ..< times {
            XCUIRemote.shared.press(button)
            usleep(300_000)
        }
        XCTAssertTrue(waitForFocus(target), "\(message)（实际焦点：\(focusedDescription()))", file: file, line: line)
    }

    /// 从首屏下到分集横排、再往上落到入口条
    @MainActor
    private func focusStrip(_ app: XCUIApplication) -> XCUIElement {
        XCUIRemote.shared.press(.down)
        sleep(1)
        let strip = app.buttons["air-schedule-summary"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "在播剧应有入口条")
        press(.up, expect: strip, "从分集横排往上落到入口条")
        return strip
    }

    // MARK: 用例

    /// 已订阅：入口条一行写清下一集；日程打开落在今天；已播折叠能展开；缺集那一行按确认就补；往左是补集按钮；返回回到入口条
    @MainActor
    func testAiringSubscribedShow() {
        let app = launch(item: 1)
        snapshot("tv-01 首屏")
        let strip = focusStrip(app)
        XCTAssertTrue(strip.label.contains("第 13–14 集更新"), strip.label)
        XCTAssertTrue(strip.label.contains("还剩 10 集"), strip.label)
        XCTAssertTrue(strip.label.contains("预计入库"), strip.label)
        XCTAssertFalse(strip.label.contains("缺"), "缺集只在日程里标，入口不提：\(strip.label)")
        snapshot("tv-02 入口条")

        // 入口条和分集横排之间上下走，页面不跳（下半截吸在顶上）
        let stripTop = strip.frame.minY
        XCUIRemote.shared.press(.down)
        sleep(1)
        XCTAssertEqual(strip.frame.minY, stripTop, accuracy: 3, "进分集横排页面不该再滚")
        // 再往下到演职员要露全，回来还是原来的位置
        XCUIRemote.shared.press(.down)
        sleep(1)
        let cast = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(cast.identifier.hasPrefix("tv-cast"), "分集往下是演职员（实际：\(focusedDescription())）")
        XCTAssertLessThanOrEqual(cast.frame.maxY, app.frame.maxY, "演职员要露全")
        snapshot("tv-02b 演职员")
        XCUIRemote.shared.press(.up)
        sleep(1)
        XCTAssertEqual(strip.frame.minY, stripTop, accuracy: 3, "回分集横排页面回到下半截的顶")
        press(.up, expect: strip, "往上回到入口条")
        sleep(1)
        XCTAssertEqual(strip.frame.minY, stripTop, accuracy: 3, "回入口条页面不该再滚")

        XCUIRemote.shared.press(.select)
        let sheet = app.element("air-schedule-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "按确认打开日程")
        let todayRow = app.buttons["air-day-\(day(0))"]
        XCTAssertTrue(waitForFocus(todayRow), "打开时焦点落在今天（实际：\(focusedDescription())）")
        XCTAssertTrue(todayRow.label.contains("第 13–14 集"), todayRow.label)
        XCTAssertTrue(app.staticTexts["还剩 10 集"].exists)
        XCTAssertTrue(app.staticTexts["本周"].exists)
        snapshot("tv-03 日程")

        // 往下一天一天走，回来
        press(.down, expect: app.buttons["air-day-\(day(1))"], "往下是明天")
        XCTAssertTrue(app.buttons["air-day-\(day(1))"].label.contains("明天"))
        press(.up, expect: todayRow, "往上回到今天")

        // 往上一格是折叠的已播出
        let past = app.buttons["air-schedule-past"]
        press(.up, expect: past, "今天往上是已播出")
        XCTAssertTrue(past.label.contains("第 1–12 集"), past.label)
        XCTAssertTrue(past.label.contains("缺第 7 集"), past.label)
        XCTAssertFalse(app.buttons["air-day-\(day(-3))"].exists, "已播出默认折叠")
        XCUIRemote.shared.press(.select)
        let missingRow = app.buttons["air-day-\(day(-3))"]
        XCTAssertTrue(missingRow.waitForExistence(timeout: 3), "展开后列出已播出的日子")
        XCTAssertTrue(past.hasFocus, "展开时焦点不动（实际：\(focusedDescription())）")
        snapshot("tv-04 展开已播出")

        // 缺第 7 集的那天（第 7–8 集）：整行就是「补这一集」
        press(.down, times: 4, expect: missingRow, "往下走到缺集那天")
        XCTAssertTrue(missingRow.label.contains("第 7–8 集"), missingRow.label)
        XCTAssertTrue(missingRow.label.contains("补这一集"), missingRow.label)
        XCUIRemote.shared.press(.select)
        let message = app.element("air-schedule-message")
        XCTAssertTrue(message.waitForExistence(timeout: 5), "补集后写明结果")
        XCTAssertTrue(message.label.contains("重新排队"), message.label)
        XCTAssertTrue(missingRow.hasFocus, "补完焦点不动（实际：\(focusedDescription())）")
        snapshot("tv-05 补集")

        // 往左到左栏的「补第 7 集」，往右回到时间线
        let find = app.buttons["air-schedule-find"]
        press(.left, expect: find, "往左是补集按钮")
        XCTAssertTrue(find.label.contains("补第 7 集"), find.label)
        XCUIRemote.shared.press(.right)
        sleep(1)
        XCTAssertTrue(focusedDescription().contains("air-day-"), "往右回到时间线（实际：\(focusedDescription())）")

        // 返回键关面板，焦点回到入口条
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "返回关面板")
        XCTAssertTrue(waitForFocus(strip), "焦点回到入口条（实际：\(focusedDescription())）")

        // 往下进横排，往右走到今天播出的集：剧照位换成入库状态
        XCUIRemote.shared.press(.down)
        sleep(1)
        for _ in 0 ..< 13 {
            XCUIRemote.shared.press(.right)
            usleep(350_000)
        }
        let todayCard = app.buttons["tv-episode-13"]
        XCTAssertTrue(todayCard.waitForExistence(timeout: 3))
        XCTAssertTrue(todayCard.label.contains("今天播出"), todayCard.label)
        XCTAssertTrue(todayCard.label.contains("预计"), todayCard.label)
        XCTAssertFalse(todayCard.label.contains("缺集"), todayCard.label)
        let tomorrowCard = app.buttons["tv-episode-15"]
        XCTAssertTrue(tomorrowCard.label.contains("明天"), tomorrowCard.label)
        snapshot("tv-06 未播出的分集卡")
    }

    /// 海外未订阅：标地区；走一遍「订阅追更」：列出默认值 → 返回先退回 → 确认建好 → 入口收起
    @MainActor
    func testSubscribeOverseasShow() async throws {
        let token = try await AirBackend.login(server: server, username: username, password: password)
        addTeardownBlock { [server] in
            try? await AirBackend.deleteSubscriptions(server: server, token: token, mediaItemId: 2)
            try? await AirBackend.logout(server: server, token: token)
        }
        let app = launch(item: 2)
        let strip = focusStrip(app)
        XCTAssertTrue(strip.label.contains("（美国）"), strip.label)
        XCTAssertTrue(strip.label.contains("天后"), strip.label)
        XCTAssertTrue(strip.label.contains("每周"), strip.label)
        snapshot("tv-07 海外未订阅入口")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.element("air-schedule-sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["播出日期为美国当地日期"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["air-schedule-find"].exists, "未订阅没有缺集")
        snapshot("tv-08 未订阅日程")

        let subscribe = app.buttons["air-schedule-subscribe"]
        press(.left, expect: subscribe, "往左是订阅追更")
        XCTAssertTrue(subscribe.label.contains("订阅追更"), subscribe.label)
        XCUIRemote.shared.press(.select)
        let draft = app.element("air-schedule-subscribe-draft")
        XCTAssertTrue(draft.waitForExistence(timeout: 8), "按下先列出默认值")
        XCTAssertTrue(draft.label.contains("第 1 季"), draft.label)
        XCTAssertTrue(subscribe.hasFocus, "焦点还在同一颗按钮上（实际：\(focusedDescription())）")
        XCTAssertTrue(subscribe.label.contains("确认订阅"), subscribe.label)
        snapshot("tv-09 确认订阅")

        // 返回键先退回，不关面板
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(draft.waitForNonExistence(timeout: 3), "返回先退回「订阅追更」")
        XCTAssertTrue(app.element("air-schedule-sheet").exists, "面板还在")
        XCTAssertTrue(waitForFocus(subscribe), "焦点回到订阅按钮（实际：\(focusedDescription())）")

        // 这次确认
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(draft.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(subscribe.waitForNonExistence(timeout: 10), "订阅建好，入口收起")
        XCTAssertTrue(app.staticTexts["播出日期来自 TMDB · 入库时间是订阅按站点发布规律推算的"].waitForExistence(timeout: 3), "日历刷新成已订阅的样子")
        XCTAssertTrue(app.element("air-schedule-message").label.contains("已在订阅中"), "写明订阅好了")
        sleep(1)
        XCTAssertTrue(focusedDescription().contains("air-day-"), "焦点回到时间线（实际：\(focusedDescription())）")
        snapshot("tv-10 订阅之后")
    }

    /// 英文界面：句子比中文长，入口条和左栏都要放得下（截图 tv-15、tv-16）
    @MainActor
    func testEnglishSchedule() {
        let app = launch(item: 1, english: true)
        let strip = focusStrip(app)
        XCTAssertTrue(strip.label.contains("Episodes 13–14"), strip.label)
        XCTAssertTrue(strip.label.contains("10 episodes left"), strip.label)
        snapshot("tv-15 英文入口条")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.element("air-schedule-sheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["10 episodes left"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["This week"].exists)
        snapshot("tv-16 英文日程")
    }

    /// 已播完：没有入口，往上直接回首屏
    @MainActor
    func testFinishedShowHasNoSchedule() {
        let app = launch(item: 3)
        XCUIRemote.shared.press(.down)
        sleep(1)
        XCTAssertFalse(app.buttons["air-schedule-summary"].exists, "已播完的季不出日历")
        snapshot("tv-11 已播完")
        // 没有入口条的页面照旧：往下到演职员要露全，往上回分集、回首屏
        XCUIRemote.shared.press(.down)
        sleep(1)
        let cast = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(cast.identifier.hasPrefix("tv-cast"), "分集往下是演职员（实际：\(focusedDescription())）")
        XCTAssertLessThanOrEqual(cast.frame.maxY, XCUIApplication().frame.maxY, "演职员要露全")
        XCUIRemote.shared.press(.up)
        sleep(1)
        XCTAssertTrue(focusedDescription().contains("tv-episode-"), "往上回分集（实际：\(focusedDescription())）")
        press(.up, expect: app.buttons["tv-item-play"], "往上回首屏")
    }

    /// 两季长剧：第 1 季播完没有入口；焦点移到第 2 季，入口条出来，顶上让位；选季 → 入口条 → 段页签 → 横排上下走得通；
    /// 第 2 季往上走回选季、回首屏不跳行
    @MainActor
    func testLongSeasonWithSeasonTabs() {
        let app = launch(item: 4)
        XCUIRemote.shared.press(.down)
        sleep(1)
        XCTAssertFalse(app.buttons["air-schedule-summary"].exists, "第 1 季播完了，没有入口")
        let season1 = app.buttons["tv-season-1"]
        press(.up, expect: season1, "横排往上是选季")
        let season2 = app.buttons["tv-season-2"]
        press(.right, expect: season2, "往右到第 2 季")
        let strip = app.buttons["air-schedule-summary"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "第 2 季在播，入口条出来")
        XCTAssertTrue(strip.label.contains("第 61 集更新"), strip.label)
        sleep(1)
        snapshot("tv-12 第2季入口条")
        press(.down, expect: strip, "选季往下是入口条")
        snapshot("tv-13 第2季入口条焦点")
        XCUIRemote.shared.press(.down)
        usleep(500_000)
        XCTAssertTrue(focusedDescription().contains("tv-range-"), "入口条往下是段页签（实际：\(focusedDescription())）")
        XCUIRemote.shared.press(.down)
        usleep(500_000)
        XCTAssertTrue(focusedDescription().contains("tv-episode-"), "段页签往下是分集（实际：\(focusedDescription())）")
        snapshot("tv-14 第2季分集")
        XCUIRemote.shared.press(.up)
        usleep(500_000)
        XCTAssertTrue(focusedDescription().contains("tv-range-"), "分集往上是段页签（实际：\(focusedDescription())）")
        press(.up, expect: strip, "段页签往上是入口条")
        press(.up, expect: season2, "入口条往上是选季，落在当前这一季")
        press(.up, expect: app.buttons["tv-item-play"], "选季往上回首屏")
    }
}

/// 夹具后端：登录、清掉用例建的订阅（`TVEpisodeRangeUITests` 的 `RangeBackend` 同款做法）
private enum AirBackend {
    static func login(server: String, username: String, password: String) async throws -> String {
        let body: [String: Any] = [
            "username": username, "password": password,
            "client": ["kind": "ios", "installation_id": "tv-ui-test-air", "name": "UI Test (air schedule)"],
        ]
        let data = try await call(server, "POST", "/api/v1/auth/device/login", body: body, token: nil)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = (json?["data"] as? [String: Any])?["token"] as? String else {
            throw URLError(.userAuthenticationRequired)
        }
        return token
    }

    static func logout(server: String, token: String) async throws {
        _ = try await call(server, "DELETE", "/api/v1/auth/devices/current", body: nil, token: token)
    }

    static func deleteSubscriptions(server: String, token: String, mediaItemId: Int) async throws {
        let data = try await call(server, "GET", "/api/v1/subscriptions?media_item_id=\(mediaItemId)", body: nil, token: token)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        for row in (json?["data"] as? [[String: Any]]) ?? [] {
            if let id = row["id"] as? Int {
                _ = try await call(server, "DELETE", "/api/v1/subscriptions/\(id)", body: nil, token: token)
            }
        }
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
