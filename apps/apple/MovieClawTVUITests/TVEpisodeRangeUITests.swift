import XCTest

/// 长剧集分段选集的遥控器验收（docs/design/long-season-episode-ranges.md §5）。只对着专门的夹具跑（一季 1186 集的
/// 「名侦探柯南」、两季长剧、十二集短剧，第 1050 集看到 42% 是锚点），没设 MC_RANGE_FIXTURE=1 时跳过：
/// - MC_RANGE_SERVER（默认 http://127.0.0.1:8798）、MC_RANGE_USERNAME / MC_RANGE_PASSWORD（默认 tvos / range-pass-1）、
///   MC_RANGE_LIBRARY（默认 1）；条目 1 / 2 / 3 依次是上面三部；
/// - MC_SHOT_DIR：每一步的截图同时落盘到这个目录。
/// 用例中途会把第 1050 集标成已看（验收「锚点变了跟过去」），结束时经接口复原成看到 42%
final class TVEpisodeRangeUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_RANGE_SERVER"] ?? "http://127.0.0.1:8798" }
    private var username: String { env["MC_RANGE_USERNAME"] ?? "tvos" }
    private var password: String { env["MC_RANGE_PASSWORD"] ?? "range-pass-1" }
    private var library: String { env["MC_RANGE_LIBRARY"] ?? "1" }

    override func setUpWithError() throws {
        try XCTSkipUnless(env["MC_RANGE_FIXTURE"] == "1", "需要长剧集夹具（MC_RANGE_FIXTURE=1）")
        continueAfterFailure = true
    }

    // MARK: 工具

    @MainActor
    private func launch(item: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password,
                               "-mcTab", "item-\(library)-\(item)"]
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

    /// 按一下键、断言焦点落到目标上
    @MainActor
    private func press(_ button: XCUIRemote.Button, times: Int = 1, expect target: XCUIElement, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0 ..< times {
            XCUIRemote.shared.press(button)
            usleep(250_000)
        }
        XCTAssertTrue(waitForFocus(target), "\(message)（实际焦点：\(focusedDescription(target)))", file: file, line: line)
    }

    @MainActor
    private func focusedDescription(_ any: XCUIElement) -> String {
        let app = XCUIApplication()
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return focused.exists ? "\(focused.identifier) | \(focused.label)" : "无"
    }

    private func value(_ element: XCUIElement) -> String { (element.value as? String) ?? "" }

    // MARK: 用例

    /// 一季 1186 集：进来落在锚点 1050（接着看），段页签换段、面板挑集、横排跨段、标记已看后跟到新锚点、重开页面落在 1051
    @MainActor
    func testLongSeasonRanges() async throws {
        let token = try await RangeBackend.login(server: server, username: username, password: password)
        addTeardownBlock { [server] in
            // 复原：第 1050 集取消已看（后端会连进度一起清掉），再把 42% 的进度补回去
            try? await RangeBackend.restore1050(server: server, token: token)
            try? await RangeBackend.logout(server: server, token: token)
        }
        try await RangeBackend.restore1050(server: server, token: token)

        var app = launch(item: 1)
        let play = app.buttons["tv-item-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForFocus(play, timeout: 6), "首屏主按钮没拿到焦点")
        XCTAssertTrue(play.label.contains("第 1050 集"), "首屏不是锚点 1050：\(play.label)")
        snapshot("r01-stage")

        // 从首屏往下：落在锚点 1050，卡上标「接着看」，段页签 1001–1050 是当前段、带橙点
        let ep1050 = app.buttons["tv-episode-1050"]
        press(.down, expect: ep1050, "往下没有落在锚点 1050")
        XCTAssertTrue(ep1050.label.contains("接着看"), "锚点卡没标「接着看」：\(ep1050.label)")
        let range1001 = app.buttons["tv-range-1001"]
        XCTAssertTrue(value(range1001).contains("当前"), "1001–1050 不是当前段：\(value(range1001))")
        XCTAssertTrue(value(range1001).contains("接着看"), "1001–1050 没有锚点橙点：\(value(range1001))")
        snapshot("r02-row-anchor")

        // 往上到段页签（落在当前段，不跳横排）→ 往左换到 951–1000，横排跳到段首 951
        press(.up, expect: range1001, "往上没有落在当前段 1001–1050")
        let range951 = app.buttons["tv-range-951"]
        press(.left, expect: range951, "往左没有到 951–1000")
        snapshot("r03-range-951")
        press(.down, expect: app.buttons["tv-episode-951"], "换到 951–1000 后往下没有落在段首 951")
        XCTAssertTrue(value(range951).contains("当前"), "951–1000 没成当前段")
        // 回到锚点那一段：入口是锚点
        press(.up, expect: range951, "往上没回到 951–1000")
        press(.right, expect: range1001, "往右没到 1001–1050")
        press(.down, expect: ep1050, "回到 1001–1050 往下没有落在锚点 1050")

        // 在段页签上按确认：面板打开在这一段，焦点在锚点格；返回键关面板回到段页签
        press(.up, expect: range1001, "往上没回到段页签")
        XCUIRemote.shared.press(.select)
        let panel = app.descendants(matching: .any)["tv-range-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "按确认没有打开「全部分集」面板")
        XCTAssertTrue(waitForFocus(app.buttons["tv-panel-cell-1050"]), "面板没有落在锚点格 1050")
        snapshot("r04-panel-1001")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "返回键没有关掉面板")
        XCTAssertTrue(waitForFocus(range1001), "关面板后焦点没回到段页签")

        // 再打开：往左进左栏，往下换到 1101–1150（宫格跟着换），往右进宫格落在段首，挑 1103 → 关面板、焦点落在横排 1103
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(app.buttons["tv-panel-cell-1050"]))
        press(.left, times: 10, expect: app.buttons["tv-panel-range-1001"], "往左没进左栏的 1001–1050")
        press(.down, times: 2, expect: app.buttons["tv-panel-range-1101"], "左栏往下没到 1101–1150")
        XCTAssertTrue(app.buttons["tv-panel-cell-1101"].waitForExistence(timeout: 3), "宫格没换成 1101–1150")
        press(.right, expect: app.buttons["tv-panel-cell-1101"], "往右进宫格没落在段首 1101")
        press(.right, times: 2, expect: app.buttons["tv-panel-cell-1103"], "宫格里往右没到 1103")
        snapshot("r05-panel-1103")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "挑集后面板没关")
        let ep1103 = app.buttons["tv-episode-1103"]
        XCTAssertTrue(waitForFocus(ep1103, timeout: 5), "挑集后焦点没落在横排 1103（实际：\(focusedDescription(ep1103))）")
        let range1101 = app.buttons["tv-range-1101"]
        XCTAssertTrue(value(range1101).contains("当前"), "挑 1103 后 1101–1150 不是当前段")
        usleep(1_200_000)
        snapshot("r06-picked-1103")

        // 横排往右一直走：到 1150 还是 1101–1150，跨到 1151 当前段跟着换
        press(.right, times: 47, expect: app.buttons["tv-episode-1150"], "往右没走到 1150")
        XCTAssertTrue(value(range1101).contains("当前"))
        press(.right, expect: app.buttons["tv-episode-1151"], "往右没跨到 1151")
        let range1151 = app.buttons["tv-range-1151"]
        XCTAssertTrue(value(range1151).contains("当前"), "跨到 1151 后当前段没换成 1151–1186：\(value(range1151))")
        snapshot("r07-crossed-1151")

        // 回到锚点：段页签往左三段到 1001–1050，往下落在 1050
        press(.up, expect: range1151, "往上没落在当前段 1151–1186")
        press(.left, times: 3, expect: range1001, "往左没回到 1001–1050")
        press(.down, expect: ep1050, "没回到锚点 1050")

        // 长按 → 标为已看：锚点变成 1051，焦点、当前段、橙点都跟过去
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        // 菜单只有「标为已看」一项、打开就落在它上面（菜单项不一定是按钮，按标签找）
        let markPlayed = app.descendants(matching: .any).matching(NSPredicate(format: "label == '标为已看'")).firstMatch
        XCTAssertTrue(markPlayed.waitForExistence(timeout: 5), "长按没出「标为已看」")
        usleep(500_000)
        XCUIRemote.shared.press(.select)
        let ep1051 = app.buttons["tv-episode-1051"]
        XCTAssertTrue(waitForFocus(ep1051, timeout: 6), "标记后焦点没跟到新锚点 1051（实际：\(focusedDescription(ep1051))）")
        XCTAssertTrue(ep1051.label.contains("接着看"), "1051 没标「接着看」：\(ep1051.label)")
        let range1051 = app.buttons["tv-range-1051"]
        XCTAssertTrue(value(range1051).contains("当前") && value(range1051).contains("接着看"),
                      "1051–1100 不是当前段或没有橙点：\(value(range1051))")
        XCTAssertFalse(value(range1001).contains("接着看"), "1001–1050 的橙点没撤掉")
        usleep(1_500_000)
        snapshot("r08-marked-1051")

        // 重新打开页面：首屏讲 1051，往下落在 1051
        app.terminate()
        app = launch(item: 1)
        let play2 = app.buttons["tv-item-play"]
        XCTAssertTrue(play2.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForFocus(play2, timeout: 6))
        XCTAssertTrue(play2.label.contains("第 1051 集"), "重开后首屏不是 1051：\(play2.label)")
        press(.down, expect: app.buttons["tv-episode-1051"], "重开后往下没落在 1051")
        XCTAssertTrue(value(app.buttons["tv-range-1051"]).contains("当前"))
        snapshot("r09-reopen-1051")
    }

    /// 两季长剧：第 1 季 120 集（锚点 77）季页签与段页签都在；换到第 2 季（30 集，没看过）段页签消失、落在第 1 集且不标「接着看」
    @MainActor
    func testSeasonTabsWithRanges() {
        let app = launch(item: 2)
        let play = app.buttons["tv-item-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForFocus(play, timeout: 6))
        XCTAssertTrue(play.label.contains("第 77 集"), "首屏不是锚点 77：\(play.label)")
        let ep77 = app.buttons["tv-episode-77"]
        press(.down, expect: ep77, "往下没有落在锚点 77")
        XCTAssertTrue(ep77.label.contains("接着看"))
        let range51 = app.buttons["tv-range-51"]
        XCTAssertTrue(value(range51).contains("当前"), "51–100 不是当前段")
        XCTAssertTrue(app.buttons["tv-season-1"].exists && app.buttons["tv-season-2"].exists, "季页签不在")
        snapshot("r10-two-seasons-row")
        press(.up, expect: range51, "往上没到段页签 51–100")
        snapshot("r11-two-seasons-range")
        press(.up, expect: app.buttons["tv-season-1"], "再往上没到第 1 季页签")
        press(.right, expect: app.buttons["tv-season-2"], "往右没到第 2 季")
        let deadline = Date.now.addingTimeInterval(5)
        while app.buttons["tv-range-1"].exists, Date.now < deadline { usleep(200_000) }
        XCTAssertFalse(app.buttons["tv-range-1"].exists, "换到 30 集的第 2 季后段页签还在")
        snapshot("r12-season2")
        let ep1 = app.buttons["tv-episode-1"]
        press(.down, expect: ep1, "第 2 季往下没落在第 1 集")
        XCTAssertFalse(ep1.label.contains("接着看"), "没看过的第 2 季不该标「接着看」：\(ep1.label)")
        usleep(1_000_000)
        snapshot("r13-season2-row")
    }

    /// 十二集短剧：没有段页签，往下落在锚点第 5 集、标「接着看」
    @MainActor
    func testShortSeasonUnchanged() {
        let app = launch(item: 3)
        let play = app.buttons["tv-item-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForFocus(play, timeout: 6))
        let ep5 = app.buttons["tv-episode-5"]
        press(.down, expect: ep5, "往下没有落在第 5 集")
        XCTAssertTrue(ep5.label.contains("接着看"), "短季锚点卡没标「接着看」：\(ep5.label)")
        let ranges = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tv-range-'"))
        XCTAssertEqual(ranges.count, 0, "12 集的季不该有段页签")
        usleep(800_000)
        snapshot("r14-short-season")
        // 往上直接回首屏（没有段页签、季页签挡在中间）
        press(.up, expect: play, "往上没回到首屏")
    }
}

/// 夹具接口：设备登录拿令牌，复原第 1050 集
private enum RangeBackend {
    static func login(server: String, username: String, password: String) async throws -> String {
        let body: [String: Any] = [
            "username": username, "password": password,
            "client": ["kind": "ios", "installation_id": "tv-ui-test-ranges", "name": "UI 测试（分段选集）"],
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

    /// 第 1050 集取消已看（后端连进度一起清），再补一条停止进度，回到「看到 42%、是锚点」
    static func restore1050(server: String, token: String) async throws {
        let unit: [String: Any] = ["media_item_id": 1, "season_number": 1, "episode_number": 1050]
        _ = try await call(server, "POST", "/api/v1/playback/marks", body: unit.merging(["played": false]) { $1 }, token: token)
        _ = try await call(server, "POST", "/api/v1/playback/progress",
                           body: unit.merging(["event": "stop", "position_ms": 604_800]) { $1 }, token: token)
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
