import XCTest

/// iPad 宽窗口：首页横排海报与海报墙的海报一样宽（真机反馈两边大小不一致），侧边栏展开 / 收起都成立
final class IPadPosterSizeUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    @MainActor
    private func posterWidth(route: String, collapse: Bool) throws -> CGFloat {
        let server = try XCTUnwrap(env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 }, "需要 MC_TEST_SERVER")
        let app = XCUIApplication()
        app.launchArguments = ["-mcServer", server, "-mcUser", env["MC_TEST_USERNAME"] ?? "admin",
                               "-mcPass", env["MC_TEST_PASSWORD"] ?? "", "-mcRoute", route]
        app.launch()
        sleep(6)
        if collapse {
            app.buttons.matching(NSPredicate(format: "identifier IN {'ToggleSidebar', 'ToggleSideBar'}")).firstMatch.tap()
            sleep(2)
        }
        // 海报格的读屏标签是「片名、年份」：取第一个完整露出的
        let cell = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".+、(19|20)[0-9]{2}$")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "\(route) 找不到海报格")
        let width = cell.frame.width
        print("[PosterSize] \(route) collapse=\(collapse) width=\(width)")
        app.terminate()
        return width
    }

    @MainActor
    func testHomeRowMatchesWall() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "只在 iPad 上跑")
        for collapse in [false, true] {
            let home = try posterWidth(route: "/library", collapse: collapse)
            let wall = try posterWidth(route: "/library/19", collapse: collapse)
            XCTAssertEqual(home, wall, accuracy: 1.5, "首页 \(home) 与海报墙 \(wall) 不一样宽（收起侧边栏：\(collapse)）")
        }
    }
}
