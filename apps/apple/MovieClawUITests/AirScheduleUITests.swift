import XCTest

/// 剧集详情页播出日历（issue #547）的端到端验收：季进度条入口卡、未播出的集不再按缺集置灰、日程弹层
/// （已播折叠 / 展开、今天的入库预告、补缺集入口）、未订阅的海外剧（地区标注 + 订阅追更）、已完结剧不出日历。
///
/// 依赖专门灌好的夹具后端（MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD）：库 1 里
/// 条目 1「长街夜行」24 集、周一至周四每天两集、今天播第 13–14 集、已订阅且缺第 7 集；
/// 条目 2「Harbor Lights」美国周四周更、未订阅；条目 3「旧城往事」已播完。
final class AirScheduleUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:18547" }
    private var username: String { env["MC_TEST_USERNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"] ?? "" }

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
        if let dir = env["MC_SHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// 分集区在详情页下方：滚到日历卡可点
    @MainActor
    private func revealCard(_ app: XCUIApplication) -> XCUIElement {
        let section = app.descendants(matching: .any)["season-episodes"]
        XCTAssertTrue(section.waitForExistence(timeout: 20), "应出现分集区")
        let card = app.buttons["air-schedule-card"]
        for _ in 0..<5 where !(card.exists && card.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        return card
    }

    @MainActor
    func testAiringSubscribedShow() {
        let app = launch(item: 1)
        let card = revealCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "在播剧应出现播出日历入口")
        XCTAssertTrue(card.label.contains("今天更新 第 13–14 集"), card.label)
        XCTAssertTrue(card.label.contains("周一至周四更新"), card.label)
        XCTAssertTrue(card.label.contains("缺第 7 集"), card.label)
        snapshot("01 入口卡")

        // 今天播出 / 之后的集：剧照位换成播出状态，不标「缺」；真缺的第 7 集照旧
        let today = app.buttons["episode-13"]
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        XCTAssertTrue(today.label.contains("今天播出"), today.label)
        XCTAssertFalse(today.label.contains("缺"), today.label)
        XCTAssertTrue(app.buttons["episode-15"].label.contains("明天"), app.buttons["episode-15"].label)
        XCTAssertTrue(app.buttons["episode-7"].label.contains("缺"), app.buttons["episode-7"].label)

        card.tap()
        let sheet = app.descendants(matching: .any)["air-schedule-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "点入口应打开日程弹层")
        XCTAssertTrue(app.staticTexts["第 13–14 集"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["大结局"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS '大结局'")).count > 0)
        XCTAssertFalse(app.staticTexts["第 1–4 集"].exists, "已播出的日子默认折叠")
        XCTAssertTrue(app.buttons["air-schedule-find"].exists, "缺集应有补集入口")
        snapshot("02 日程弹层")

        app.buttons["air-schedule-past"].tap()
        XCTAssertTrue(app.staticTexts["第 1–4 集"].waitForExistence(timeout: 5), "展开后应列出已播出的日子")
        snapshot("03 展开已播出")
    }

    @MainActor
    func testUnsubscribedOverseasShow() {
        let app = launch(item: 2)
        let card = revealCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.contains("（美国）"), card.label)
        XCTAssertTrue(card.label.contains("每周四更新"), card.label)
        card.tap()
        XCTAssertTrue(app.buttons["订阅追更"].waitForExistence(timeout: 5), "未订阅应给订阅入口")
        XCTAssertTrue(app.staticTexts["播出日期为美国当地日期"].exists)
        XCTAssertFalse(app.buttons["air-schedule-find"].exists, "未订阅没有缺集")
        snapshot("04 未订阅海外剧")
    }

    @MainActor
    func testFinishedShowHasNoSchedule() {
        let app = launch(item: 3)
        let section = app.descendants(matching: .any)["season-episodes"]
        XCTAssertTrue(section.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["air-schedule-card"].exists, "已播完的季不出日历")
    }
}
