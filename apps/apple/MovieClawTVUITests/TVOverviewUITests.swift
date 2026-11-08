import XCTest

/// 详情页完整简介（issue #1238）的遥控器验收：首屏截断的简介能聚焦、按确认打开完整简介、按返回关掉；
/// 分集卡长按菜单里的「完整简介」。对着隔离的测试服务器跑（如 apps/android-tv/tests/fixture/fixture.py），
/// 环境变量经 TEST_RUNNER_ 前缀转交：
/// - MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD；
/// - MC_TEST_OVERVIEW_ROUTE：简介超过三行的电影「库id-条目id」（夹具里 1-10《星际回声》）；
/// - MC_TEST_OVERVIEW_LONG_ROUTE（可选）：简介长到完整简介页一屏放不下的条目，验证上下键滚动；
/// - MC_TEST_OVERVIEW_SHOW_ROUTE（可选）：有分集简介的剧（夹具里 2-18《雾港疑云》），验证长按菜单；
/// - MC_SHOT_DIR：截图同时落盘到这个目录。
final class TVOverviewUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(["MC_TEST_SERVER", "MC_TEST_USERNAME", "MC_TEST_PASSWORD", "MC_TEST_OVERVIEW_ROUTE"].allSatisfy { !(env[$0] ?? "").isEmpty },
                          "需提供 MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD / MC_TEST_OVERVIEW_ROUTE")
        continueAfterFailure = false
    }

    /// 截断的简介：进页面落在主按钮（简介排在上面也不抢）→ 往上聚焦简介 → 确认打开完整简介（全文）→ 返回关掉、焦点回简介
    /// → 往下回主按钮。冷启动直接落在详情页走的是主界面「整页交焦点」，正是简介最容易抢焦点的那条路
    @MainActor
    func testStageOverviewOpensFullText() throws {
        let app = launch(route: try XCTUnwrap(env["MC_TEST_OVERVIEW_ROUTE"]))
        let play = app.element("tv-item-play")
        let overview = app.element("tv-item-overview")
        XCTAssertTrue(waitForFocus(play), "进页面焦点没有落在主按钮上")
        XCTAssertTrue(overview.waitForExistence(timeout: 5), "简介超过三行，却不能聚焦")

        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(overview), "主按钮往上没有落到简介上")
        snapshot("appletv-overview-focused")
        let fullText = overview.label

        XCUIRemote.shared.press(.select)
        let panel = app.element("tv-overview-panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "按确认没有打开完整简介")
        let text = app.element("tv-overview-text")
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.label, fullText, "完整简介里不是全文")
        snapshot("appletv-overview-panel")

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "按返回没有关掉完整简介")
        XCTAssertTrue(waitForFocus(overview), "关掉完整简介后焦点没回到简介上")

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(play), "简介往下没有回到主按钮")
    }

    /// 一屏放不下的简介：完整简介页上下键滚动
    @MainActor
    func testLongOverviewScrolls() throws {
        let route = try optionalEnv("MC_TEST_OVERVIEW_LONG_ROUTE", skip: "没有超长简介条目（MC_TEST_OVERVIEW_LONG_ROUTE）")
        let app = launch(route: route)
        XCTAssertTrue(waitForFocus(app.element("tv-item-play")))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(app.element("tv-item-overview")))
        XCUIRemote.shared.press(.select)
        let text = app.element("tv-overview-text")
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        sleep(1)
        let top = text.frame.minY
        XCUIRemote.shared.press(.down)
        sleep(1)
        XCTAssertLessThan(text.frame.minY, top - 100, "按下键正文没有往上滚")
        snapshot("appletv-overview-scrolled")
        XCUIRemote.shared.press(.up)
        sleep(1)
        XCTAssertEqual(text.frame.minY, top, accuracy: 2, "按上键没有滚回顶部")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.element("tv-overview-panel").waitForNonExistence(timeout: 5))
    }

    /// 分集卡下面的简介只有四行：长按分集卡，菜单里选「完整简介」打开这一集的全文，返回回到这张卡
    @MainActor
    func testEpisodeContextMenuOpensOverview() throws {
        let route = try optionalEnv("MC_TEST_OVERVIEW_SHOW_ROUTE", skip: "没有剧集条目（MC_TEST_OVERVIEW_SHOW_ROUTE）")
        let app = launch(route: route)
        XCTAssertTrue(waitForFocus(app.element("tv-item-play")))
        let focusedEpisode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tv-episode-' AND hasFocus == true")).firstMatch
        for _ in 0 ..< 4 where !focusedEpisode.exists {
            XCUIRemote.shared.press(.down)
            sleep(1)
        }
        XCTAssertTrue(focusedEpisode.exists, "往下走不到分集横排")
        let episodeId = focusedEpisode.identifier

        XCUIRemote.shared.press(.select, forDuration: 1.5)
        let item = app.buttons.matching(NSPredicate(format: "label IN %@", ["完整简介", "Full Overview"])).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "长按分集卡的菜单里没有「完整简介」")
        // 「完整简介」排在菜单最后一项；菜单项不报告焦点状态，按到底再确认
        TVRemote.press(.down, times: 3)
        sleep(1)
        snapshot("appletv-episode-menu")
        XCUIRemote.shared.press(.select)

        let panel = app.element("tv-overview-panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "选「完整简介」没有打开完整简介")
        XCTAssertFalse(app.element("tv-overview-text").label.isEmpty)
        snapshot("appletv-episode-overview")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(app.element(episodeId)), "关掉完整简介后焦点没回到那张分集卡")
    }

    // MARK: 工具

    private func optionalEnv(_ key: String, skip message: String) throws -> String {
        guard let value = env[key], !value.isEmpty else { throw XCTSkip(message) }
        return value
    }

    @MainActor
    private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", env["MC_TEST_SERVER"] ?? "",
                               "-mcUser", env["MC_TEST_USERNAME"] ?? "", "-mcPass", env["MC_TEST_PASSWORD"] ?? "",
                               "-mcTab", "item-\(route)"]
        app.launch()
        // 冷启动直接落在详情页时外壳的启动黑幕要等一会儿才揭开，等它揭开再开始按
        XCTAssertTrue(app.element("tv-item-play").waitForExistence(timeout: 30), "没有进入详情页")
        sleep(4)
        return app
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
}
