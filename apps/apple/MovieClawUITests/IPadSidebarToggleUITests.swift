import XCTest

/// iPad 横屏收起 / 展开侧边栏（真机反馈：收起后顶部标签栏不该出现库与合集；轮播大图的文字没贴左、换图时露出下一张）
final class IPadSidebarToggleUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    @MainActor
    func testToggleSidebarOnPage() throws {
        let server = try XCTUnwrap(env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 }, "需要 MC_TEST_SERVER")
        let route = env["MC_TEST_ROUTE"].flatMap { $0.isEmpty ? nil : $0 } ?? "/library"
        let app = XCUIApplication()
        app.launchArguments = ["-mcServer", server, "-mcUser", env["MC_TEST_USERNAME"] ?? "admin",
                               "-mcPass", env["MC_TEST_PASSWORD"] ?? "", "-mcRoute", route]
        app.launch()
        sleep(8)
        // 收起前后侧边栏开关不是同一个按钮（收起后在顶部标签栏里），按标识或标签找
        func toggle() -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier IN {'ToggleSidebar', 'ToggleSideBar'} OR label IN %@",
                                             ["显示边栏", "隐藏边栏", "Show Sidebar", "Hide Sidebar"])).firstMatch
        }
        XCTAssertTrue(toggle().waitForExistence(timeout: 5), "找不到侧边栏开关")
        // 收起 → 停 4 秒 → 展开 → 停 4 秒 → 快速来回三次 → 停 4 秒（外面按间隔截图）
        toggle().tap(); sleep(3)
        print("[Probe] 收起后：\(app.buttons.allElementsBoundByIndex.prefix(12).map { "\($0.identifier)|\($0.label)" })")
        XCTAssertTrue(toggle().waitForExistence(timeout: 3), "收起后找不到展开按钮")
        toggle().tap(); sleep(4)
        for _ in 0 ..< 3 { toggle().tap(); usleep(400_000); toggle().tap(); usleep(400_000) }
        sleep(4)
        toggle().tap(); sleep(4)
    }
}
