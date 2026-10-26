import XCTest

/// 详情页「搜索资源」带英文名/原名同搜（issue #680）的联调验收：发现详情、订阅「手动选种」进结果页，
/// 页头写着「另含 英文名 · 原名」，只认英文名的站点的结果也出来了。
///
/// 要连 tests/e2e/_search_also_api_launcher 起的隔离后端（假 TMDB 与假 PT 站：馒头只认中文名、
/// TTG 只认英文名），凭据只由环境传入：MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD，
/// 「手动选种」另需 MC_TEST_SUB_ID（为 tmdb:movie:104 建好的订阅；test.sh 不转交，用 TEST_RUNNER_MC_TEST_SUB_ID 传）。
final class SearchAlsoKeywordsUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let english = "The Gangster, the Cop, the Devil"
    private let original = "악인전"

    @MainActor
    func testDiscoverDetailSearchesEnglishAndOriginalTitles() throws {
        let app = try launch(route: "/media/movie/104")
        let search = app.buttons["detail-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 35), "发现详情应有「搜索资源」")
        search.tap()
        try assertResultsWithAlso(app, name: "iphone-discover-search")
    }

    @MainActor
    func testManualPickSearchesEnglishAndOriginalTitles() throws {
        let subId = try XCTUnwrap(env["MC_TEST_SUB_ID"].flatMap { $0.isEmpty ? nil : $0 }, "需提供 MC_TEST_SUB_ID")
        let app = try launch(route: "/subscriptions/\(subId)")
        let pick = app.buttons["manual-pick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 35), "订阅详情应有「手动选种」")
        pick.tap()
        try assertResultsWithAlso(app, name: "iphone-manual-pick")
    }

    @MainActor
    private func launch(route: String) throws -> XCUIApplication {
        continueAfterFailure = false
        try XCTSkipUnless(["MC_TEST_SERVER", "MC_TEST_USERNAME", "MC_TEST_PASSWORD"].allSatisfy { !(env[$0] ?? "").isEmpty },
                          "需提供 MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD")
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-mcServer", try XCTUnwrap(env["MC_TEST_SERVER"]),
            "-mcUser", try XCTUnwrap(env["MC_TEST_USERNAME"]),
            "-mcPass", try XCTUnwrap(env["MC_TEST_PASSWORD"]),
            "-mcRoute", route,
        ]
        app.launch()
        return app
    }

    @MainActor
    private func assertResultsWithAlso(_ app: XCUIApplication, name: String) throws {
        let also = app.staticTexts["torrent-also-keywords"]
        XCTAssertTrue(also.waitForExistence(timeout: 30), "结果页应写出同搜的词")
        XCTAssertEqual(also.label, "另含 \(english) · \(original)")
        // 只认英文名的 TTG 的种子（scene 命名）也在结果里
        let sceneRelease = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "WiKi")).firstMatch
        XCTAssertTrue(sceneRelease.waitForExistence(timeout: 20), "只认英文名的站点的结果应出现")
        XCTAssertTrue(app.staticTexts["共 2 条结果"].exists, "两站各一条，同一种子不重复")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = env["MC_SHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        app.terminate()
    }
}
