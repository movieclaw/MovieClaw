import XCTest

/// iPad 上的弹层（真机反馈：切换账号、下载弹层不居中、不展开、也不贴底）：打开后停几秒，外面截图核对
final class IPadSheetsUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    @MainActor
    private func launch(_ route: String) throws -> XCUIApplication {
        let server = try XCTUnwrap(env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 }, "需要 MC_TEST_SERVER")
        let app = XCUIApplication()
        app.launchArguments = ["-mcServer", server, "-mcUser", env["MC_TEST_USERNAME"] ?? "admin",
                               "-mcPass", env["MC_TEST_PASSWORD"] ?? "", "-mcRoute", route]
        app.launch()
        return app
    }

    @MainActor
    func testAccountSwitcherSheet() throws {
        let app = try launch("/my")
        let button = app.buttons["open-account-switcher"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        button.tap()
        XCTAssertTrue(app.staticTexts["切换账号"].waitForExistence(timeout: 5) || app.navigationBars.count > 0)
        sleep(5)
    }

    @MainActor
    func testMovieDownloadSheet() throws {
        let item = try XCTUnwrap(env["MC_TEST_MP4_ITEM"].flatMap { $0.isEmpty ? nil : $0 }, "需要 MC_TEST_MP4_ITEM")
        let library = env["MC_TEST_MP4_LIBRARY"].flatMap { $0.isEmpty ? nil : $0 } ?? "19"
        let app = try launch("/library/\(library)/item/\(item)")
        let menu = app.buttons["item-actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let download = app.buttons["下载"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5), "菜单里没有「下载」")
        download.tap()
        sleep(5)
    }
}
