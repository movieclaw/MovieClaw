import XCTest

/// 播放器选集剧照排（`TVEpisodeShelf`）端到端：只用遥控器。
///
/// 夹具：MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD，剧 MC_TEST_EPISODE_SHOW（第一季前两集有片源；
/// 服务端给了季列表且第二季第一集有片源时连跨季一起测）。可选 MC_SHOT_DIR 存截图。
/// 用例会在这部剧的前几集留下观看进度，夹具请用专门的测试库。
final class TVEpisodeShelfUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:8795" }
    private var username: String { env["MC_TEST_USERNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"] ?? "" }
    private var show: Int { env["MC_TEST_EPISODE_SHOW"].flatMap { Int($0) } ?? 1 }

    override func setUp() {
        continueAfterFailure = false
    }

    /// 上键升起、停在正在播的那一集 → 右键 + 确认换到下一集 → 再升起、往上到季页签换到第二季 → 往下、确认跨季播放 → 返回收起
    @MainActor
    func testShelfSwitchesEpisodeAndSeason() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password,
                               "-mcRoute", "/play/\(show)/s01e01?t=20"]
        app.launch()
        let surface = app.buttons["tv-player-surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 30), "播放器没有打开")
        // 等起播完（会话建好之前上键只唤出进度条）
        XCTAssertTrue(app.staticTexts["tv-player-episodes-hint"].waitForExistence(timeout: 60) || waitForSession(app), "播放没有开始")

        // 升起：焦点落在正在播的那一集
        TVRemote.press(.up)
        let shelf = app.descendants(matching: .any)["tv-player-episodes"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 5), "上键没有升起选集剧照排")
        let current = app.buttons["tv-episode-current"]
        XCTAssertTrue(waitForFocus(current, timeout: 5), "焦点没有落在正在播的那一集")
        snapshot("tv-episodes-open")

        // 右键 + 确认：换到第二集，剧照排收起
        TVRemote.press(.right)
        XCTAssertTrue(waitForFocus(app.buttons["tv-episode-2"]), "右键没有挪到第 2 集")
        TVRemote.press(.select)
        XCTAssertTrue(shelf.waitForNonExistence(timeout: 5), "选了一集后剧照排应收起")
        XCTAssertTrue(waitForTitle(app, contains: "S01E02"), "没有换到第 2 集")

        // 再升起：焦点落在第二集（它现在是正在播的）
        TVRemote.press(.up)
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(current, timeout: 5), "换集后再打开，焦点应在新的那一集")

        let seasonTwo = app.buttons["tv-episodes-season-2"]
        if seasonTwo.waitForExistence(timeout: 2) {
            // 往上到季页签：焦点落在当前季，往右移到第二季，下面就换成第二季
            TVRemote.press(.up)
            XCTAssertTrue(waitForFocus(app.buttons["tv-episodes-season-1"]), "往上应落在正在看的这一季")
            TVRemote.press(.right)
            XCTAssertTrue(waitForFocus(seasonTwo), "右键没有挪到第 2 季")
            XCTAssertTrue(app.buttons["tv-episode-1"].waitForExistence(timeout: 10), "焦点移到第 2 季后没有列出它的分集")
            XCTAssertFalse(current.exists, "看别的季时不该有「正在播放」那一张")
            snapshot("tv-episodes-season2")
            TVRemote.press(.down)
            XCTAssertTrue(waitForFocus(app.buttons["tv-episode-1"]), "往下应落在第 2 季第一个有片源的集")
            TVRemote.press(.select)
            XCTAssertTrue(shelf.waitForNonExistence(timeout: 5))
            XCTAssertTrue(waitForTitle(app, contains: "S02E01"), "没有跨季换到第 2 季第 1 集")
        } else {
            TVRemote.press(.menu)
            XCTAssertTrue(shelf.waitForNonExistence(timeout: 5), "返回键应收起剧照排")
        }

        // 返回键收起（不退出播放）
        TVRemote.press(.up)
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        TVRemote.press(.menu)
        XCTAssertTrue(shelf.waitForNonExistence(timeout: 5), "返回键应收起剧照排")
        XCTAssertTrue(surface.exists, "收起剧照排不应退出播放")
    }

    @MainActor
    private func waitForSession(_ app: XCUIApplication) -> Bool {
        // 「选集」提示只在控制层显示时出现：按两下播放 / 暂停把控制层叫出来再找（上键会直接打开剧照排，不能用来唤出）
        TVRemote.press(.playPause)
        TVRemote.press(.playPause)
        return app.staticTexts["tv-player-episodes-hint"].waitForExistence(timeout: 20)
    }

    /// 进度条上方的片名行写着这一集（收起剧照排时控制层会露几秒）
    @MainActor
    private func waitForTitle(_ app: XCUIApplication, contains code: String) -> Bool {
        let label = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", code)).firstMatch
        let deadline = Date.now.addingTimeInterval(30)
        while Date.now < deadline {
            if label.exists { return true }
            usleep(500_000)
        }
        return label.exists
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.exists, element.hasFocus { return true }
            usleep(200_000)
        }
        return element.exists && element.hasFocus
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
}
