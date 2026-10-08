import XCTest

/// 底部轻提示（Feedback 的 Toast）的交互验收：位置（标签栏 / 底部安全区 / 键盘之上）、尺寸、下滑 / 点按 / 到点收起、
/// 上拖回弹、新提示顶替旧提示、提示旁边照常可点，根部与 sheet 内表现一致。全部走真实操作（复制、轮换令牌、改密码）触发提示。
///
/// 只连一次性的本地后端：`MC_TEST_TOAST_FIXTURE=1 MC_TEST_SERVER=http://127.0.0.1:<端口> MC_TEST_PASSWORD=…`，
/// 用例会建 MCP 接入点、轮换令牌、改密码（结束时改回），不要指向真实服务器。
final class ToastUITests: XCTestCase {
    private var probe: SettingsTestAPI!
    private var server = ""
    private var password = ""
    @MainActor private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MC_TEST_TOAST_FIXTURE"] == "1", let server = env["MC_TEST_SERVER"], !server.isEmpty,
              let password = env["MC_TEST_PASSWORD"], !password.isEmpty else { throw XCTSkip("需要一次性本地后端") }
        continueAfterFailure = false
        self.server = server
        self.password = password
        probe = try SettingsTestAPI(server: server, username: "admin", password: password)
    }

    // MARK: 工具

    @MainActor private func launch(_ route: String) {
        app.launchArguments = ["--ui-testing", "-mcServer", server, "-mcUser", "admin", "-mcPass", password, "-mcRoute", route]
        app.launch()
    }

    /// 验收用的 MCP 接入点（没有就建一个），返回深链用的地址标识
    private func endpointSlug() throws -> String {
        let status = try probe.getObject("/mcp/status")
        if (status["endpoints"] as? [[String: Any]])?.contains(where: { $0["slug"] as? String == "toast-review" }) != true {
            try probe.request("POST", "/mcp/endpoints", body: ["name": "提示验收", "slug": "toast-review", "services": ["appearance"]])
        }
        return "toast-review"
    }

    @MainActor private var toasts: XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "toast") }
    @MainActor private var toast: XCUIElement { toasts.firstMatch }

    @MainActor private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 位置与尺寸：底边浮在 `limit`（标签栏顶 / 底部安全区 / 键盘顶）上方 4～`within`pt、水平居中、宽度随内容收拢、高度不低于 52pt
    @MainActor private func assertDocked(_ element: XCUIElement, above limit: CGFloat, within: CGFloat = 24, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(frame.maxY, limit - 4, "应浮在\(what)之上：\(frame) / \(limit)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.maxY, limit - within, "应贴着\(what)：\(frame) / \(limit)", file: file, line: line)
        XCTAssertEqual(frame.midX, window.midX, accuracy: 1, "应水平居中：\(frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 52, "高度不低于 52pt：\(frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.width, window.width - 32, "左右至少各留 16pt：\(frame)", file: file, line: line)
    }

    /// 标签栏顶边（iOS 26 的浮动标签栏）
    @MainActor private var tabBarTop: CGFloat {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.exists, "此页应有标签栏")
        return bar.frame.minY
    }

    @MainActor private func openFirstTool() -> (tool: XCUIElement, copy: XCUIElement) {
        let tool = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mcp-tool-' AND NOT identifier BEGINSWITH 'mcp-tool-copy'")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 20), "应列出工具")
        tool.tap()
        let copy = app.buttons["mcp-tool-copy-name"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        return (tool, copy)
    }

    // MARK: 用例

    /// 根部：复制工具名 → 提示浮在标签栏上；上拖回弹不收、下滑收起、连点只留一条、点按收起、到点自动收起、提示旁照常可点
    @MainActor func testRootToastGesturesAndLifetime() throws {
        launch("/settings/mcp?endpoint=\(try endpointSlug())&tab=tools")
        let (tool, copy) = openFirstTool()

        copy.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "复制后应弹提示")
        XCTAssertTrue(toast.staticTexts["已复制"].exists)
        Thread.sleep(forTimeInterval: 0.6)  // 等入场动画落定再量
        assertDocked(toast, above: tabBarTop, "标签栏")
        XCTAssertLessThan(toast.frame.width, app.windows.firstMatch.frame.width / 2, "短提示应随文字收拢：\(toast.frame)")
        let rest = toast.frame
        snapshot("根部-单行提示")

        // 往上拖：有阻尼、松手回弹，不收起
        let start = toast.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(toast.exists, "上拖不应收起")
        XCTAssertEqual(toast.frame.minY, rest.minY, accuracy: 2, "松手应回到原位")

        // 下滑：收起
        toast.swipeDown()
        XCTAssertTrue(waitGone(toast, timeout: 2), "下滑应收起")

        // 连点两次：新的顶替旧的，同一时刻只有一条
        copy.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        copy.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(toasts.count, 1, "同一时刻只显示一条提示")

        // 点按：收起
        toast.tap()
        XCTAssertTrue(waitGone(toast, timeout: 2), "点按应收起")

        // 不碰它：4 秒左右自动收起。从点下复制起算（XCUITest 每步要等 App 空闲，从「看到提示」起算会漏掉这段）
        let tapped = Date()
        copy.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: max(0, 3 - Date().timeIntervalSince(tapped)))
        XCTAssertTrue(toast.exists, "3 秒时不应已收起")
        XCTAssertTrue(waitGone(toast, timeout: max(0.5, 6 - Date().timeIntervalSince(tapped))), "成功提示应在 4 秒左右自动收起")

        // 提示在场时，提示以外的地方照常能点（提示窗口只接提示本身的触摸）：收起工具详情、返回上一页
        copy.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        tool.tap()
        XCTAssertTrue(waitGone(copy, timeout: 2), "提示在场时点工具行应能收起详情")
        XCTAssertTrue(toast.exists)
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.exists, "应有返回键")
        back.tap()
        XCTAssertTrue(waitGone(tool, timeout: 3), "提示在场时返回键应能返回上一页")
    }

    /// 键盘弹出时：提示浮在键盘之上，不被挡住
    @MainActor func testToastFloatsAboveKeyboard() throws {
        launch("/settings/mcp?endpoint=\(try endpointSlug())&tab=tools")
        let search = app.textFields["mcp-tools-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap()
        search.typeText("show")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "应弹出键盘")
        let (_, copy) = openFirstTool()
        XCTAssertTrue(keyboard.exists, "点工具行后键盘应还在")
        copy.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        snapshot("键盘-单行提示")
        // XCUITest 给的键盘范围从按键区算起，不含键盘顶部约 45pt 的边距，所以放宽到 64pt
        assertDocked(toast, above: keyboard.frame.minY, within: 64, "键盘")
    }

    /// sheet 内：轮换令牌后的结果页里复制地址 → 提示盖在 sheet 上、浮在底部安全区之上，同样下滑收起
    @MainActor func testSheetToastMatchesRoot() throws {
        launch("/settings/mcp?endpoint=\(try endpointSlug())")
        let actions = app.buttons["mcp-detail-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 20))
        actions.tap()
        app.buttons["mcp-detail-rotate"].tap()
        let confirm = app.alerts.buttons["生成新令牌"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "轮换前应确认")
        confirm.tap()
        let copyURL = app.buttons["mcp-issued-copy-url"]
        XCTAssertTrue(copyURL.waitForExistence(timeout: 10), "应弹出新令牌结果页")
        Thread.sleep(forTimeInterval: 0.8)  // 等 sheet 升起

        copyURL.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "sheet 里复制后应弹提示")
        XCTAssertTrue(toast.isHittable, "提示应在 sheet 之上可见、可操作")
        Thread.sleep(forTimeInterval: 0.6)
        // sheet 盖住了标签栏：贴底部安全区（主屏指示条上方，约 34pt）
        assertDocked(toast, above: app.windows.firstMatch.frame.maxY - 34, "底部安全区")
        snapshot("sheet-单行提示")
        toast.swipeDown()
        XCTAssertTrue(waitGone(toast, timeout: 2), "sheet 里同样下滑收起")
    }

    /// 长文案：改密码后的两行提示——多行时圆角矩形、文字完整、仍浮在标签栏之上且能下滑收起
    @MainActor func testLongMessageWrapsAndDismisses() throws {
        let next = password + "-next"
        let (server, password) = (server, password)
        // 改回原密码（用新密码登一次）。断言失败会中断用例、defer 不执行，所以挂在 teardown 上
        addTeardownBlock {
            if let back = try? SettingsTestAPI(server: server, username: "admin", password: next) {
                _ = try? back.request("PUT", "/auth/password", body: ["old_password": next, "new_password": password, "sign_out_paired": false])
            }
        }
        launch("/settings/profile")
        let edit = app.buttons["profile-password-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        edit.tap()
        for (id, value) in [("profile-old-password", password), ("profile-new-password", next), ("profile-confirm-password", next)] {
            let field = app.secureTextFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(value)
        }
        app.buttons["profile-change-password"].tap()

        XCTAssertTrue(toast.waitForExistence(timeout: 10), "改密码后应弹提示")
        Thread.sleep(forTimeInterval: 1.0)  // 等 sheet 收走、提示落到标签栏上方
        let text = toast.staticTexts.element(matching: NSPredicate(format: "label BEGINSWITH '密码已修改'"))
        XCTAssertTrue(text.exists)
        XCTAssertTrue(text.label.hasSuffix("本机保持登录。"), "长文案应完整显示：\(text.label)")
        assertDocked(toast, above: tabBarTop, "标签栏")
        XCTAssertGreaterThan(toast.frame.height, 56, "两行文字应把提示撑高（单行是 52pt）：\(toast.frame)")
        snapshot("根部-多行提示")
        toast.swipeDown()
        XCTAssertTrue(waitGone(toast, timeout: 2), "多行提示同样下滑收起")
    }
}
