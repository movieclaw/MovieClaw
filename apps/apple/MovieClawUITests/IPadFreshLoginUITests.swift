import XCTest

/// iPad 全新安装后登录进主界面，界面要能点能滑（真机反馈：首次登录后整屏点不动，杀掉重开才好）。
/// 需要服务器：MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD
final class IPadFreshLoginUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    @MainActor
    func testMainInterfaceRespondsAfterFreshLogin() throws {
        let server = try XCTUnwrap(env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 }, "需要 MC_TEST_SERVER")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing"]
        app.launch()
        let start = app.buttons["welcome-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let field = app.textFields["server-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(server)
        let user = app.textFields["login-username"]
        user.tap()
        user.typeText(env["MC_TEST_USERNAME"] ?? "admin")
        let pass = app.secureTextFields["login-password"]
        pass.tap()
        pass.typeText(env["MC_TEST_PASSWORD"] ?? "")
        // iPad 键盘盖住了按钮附近：直接在密码框里回车提交（同真机上按键盘的「继续」）
        pass.typeText("\n")

        // 登录后系统会问通知权限：点掉（真机上用户会看到同一个弹窗）
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["允许"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        // 主界面：点侧边栏 / 顶部标签栏里的「订阅」，页面要真的切过去
        let subscriptions = app.buttons["订阅"].firstMatch
        XCTAssertTrue(subscriptions.waitForExistence(timeout: 20), "没进主界面")
        sleep(2)
        subscriptions.tap()
        XCTAssertTrue(app.navigationBars["订阅"].waitForExistence(timeout: 8)
                      || app.staticTexts["订阅"].waitForExistence(timeout: 1), "点「订阅」没有反应")
        let home = app.buttons["首页"].firstMatch
        home.tap()
        XCTAssertTrue(app.staticTexts["接下来继续"].waitForExistence(timeout: 10), "点「首页」没有反应")
        app.swipeUp()
    }
}
