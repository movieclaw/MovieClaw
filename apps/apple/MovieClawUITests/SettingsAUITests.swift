import XCTest

/// 设置模块（上）端到端验收：概览、个人信息、成员、设备、播放、AI 设定、更新与维护、网络、系统日志。
///
/// 依赖一台真实运行的 MovieClaw，账号经环境变量传入（scripts/test.sh 已转发）：
/// MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD；未提供密码时整组跳过——仓库开源，不写任何真实密码。
///
/// 安全约束（测试服务器是用户正在用的正式实例）：
/// - 绝不点：修改密码、清空观看记录的确认、应用更新 / 回退 / 重启的确认、代理与外部访问 / 端口、保留版本数、
///   清理缓存、定时任务、别人的设备令牌与接入请求、已有成员的任何写操作、远程转码保存；
/// - 可逆写操作动手前经接口记下原值，`tearDown` 一律经接口按原值写回（界面改回之外的第二道保险）：
///   昵称、播放策略两颗开关、AI 默认模型；
/// - 自建数据只用 `ios-test-` 前缀（成员、CLI 令牌），`tearDown` 兜底清理同前缀的残留；
/// - 每次点击前断言目标存在、可点且不被底部标签栏遮挡（`tapSafely`），否则用例失败——绝不按坐标盲点。
final class SettingsAUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"] ?? "http://localhost:3000" }
    private var username: String { env["MC_TEST_USERNAME"] ?? "admin" }
    private var password: String? { env["MC_TEST_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 } }

    private var probe: SettingsTestAPI?
    /// 用例开始时记下的原值（tearDown 写回）
    private var restorers: [(String, () throws -> Void)] = []

    override func tearDownWithError() throws {
        for (name, restore) in restorers.reversed() {
            do { try restore() } catch { XCTFail("恢复「\(name)」失败：\(error)") }
        }
        restorers = []
        // 兜底清理自建数据（只动 ios-test- 前缀）
        if let probe {
            for member in (try? probe.getArray("/members")) ?? [] {
                if let name = member["username"] as? String, name.hasPrefix("ios-test-"), let id = member["id"] as? Int {
                    _ = try? probe.request("DELETE", "/members/\(id)")
                }
            }
            for device in (try? probe.getArray("/auth/devices")) ?? [] {
                if let name = device["name"] as? String, name.hasPrefix("ios-test-"), let id = device["id"] as? String {
                    _ = try? probe.request("DELETE", "/auth/devices/\(id)")
                }
            }
        }
    }

    // MARK: 工具

    @MainActor
    private func launch(route: String, extra: [String] = []) throws -> XCUIApplication {
        guard let password else { throw XCTSkip("未提供 MC_TEST_PASSWORD，跳过联调用例") }
        continueAfterFailure = false
        if probe == nil { probe = try SettingsTestAPI(server: server, username: username, password: password) }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password, "-mcRoute", route] + extra
        app.launch()
        return app
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 把元素滚进可视区（避开底部标签栏）后返回。列表是懒加载的：还没出现的行先往下翻着找
    @MainActor
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, timeout: TimeInterval = 20, maxSwipes: Int = 10) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            // 先往回翻到顶（元素可能在当前视口上方），再往下找
            var tries = 0
            while !element.exists, tries < 4 {
                app.swipeDown(velocity: .fast)
                tries += 1
            }
            tries = 0
            while !element.exists, tries < maxSwipes {
                app.swipeUp(velocity: .slow)
                tries += 1
            }
        }
        XCTAssertTrue(element.exists, "应出现：\(element)")
        var swipes = 0
        while swipes < maxSwipes, element.exists, !isUnobscured(app, element) {
            let keyboard = app.keyboards.firstMatch
            let tabTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
            if keyboard.exists, element.frame.intersects(keyboard.frame) {
                // 键盘挡住了：往下拖一下列表收起键盘（列表设置了滚动即收键盘）
                app.swipeDown(velocity: .slow)
            } else if element.frame.maxY > tabTop - 8 || element.frame.minY > app.frame.maxY {
                app.swipeUp(velocity: .slow)
            } else {
                app.swipeDown(velocity: .slow)
            }
            swipes += 1
        }
        return element
    }

    /// 元素可点，且不与底部标签栏、键盘重叠
    @MainActor
    private func isUnobscured(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, tabBar.isHittable, element.frame.intersects(tabBar.frame) { return false }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, element.frame.intersects(keyboard.frame) { return false }
        return true
    }

    /// 安全点击：必须存在、可点、不被遮挡，否则用例失败（绝不按坐标盲点）
    @MainActor
    private func tapSafely(_ app: XCUIApplication, _ element: XCUIElement, _ what: String) {
        let target = reveal(app, element)
        guard isUnobscured(app, target) else {
            XCTFail("「\(what)」不可点或被遮挡，停止操作")
            return
        }
        target.tap()
    }

    /// 切换分区内的胶囊页签（纯界面状态）：列表刚刷新时偶尔吞掉一次点按，没切过去就再点
    @MainActor
    private func selectTab(_ app: XCUIApplication, _ id: String) {
        let tab = app.buttons[id]
        for _ in 0 ..< 3 {
            tapSafely(app, tab, id)
            if tab.waitForSelected(timeout: 3) { return }
        }
        XCTFail("页签「\(id)」没有切换过去")
    }

    /// 拨动开关：优先点开关本体（整行元素的中心落在标题上，点了不一定拨动）
    @MainActor
    private func toggleSafely(_ app: XCUIApplication, _ id: String) {
        let row = reveal(app, app.switches[id])
        let inner = row.switches.firstMatch
        tapSafely(app, inner.exists ? inner : row, id)
    }

    /// 弹出的确认框：标题必须含 expected（确认点的是自己创建的数据），再点指定按钮
    @MainActor
    private func confirmAlert(_ app: XCUIApplication, titleContains expected: String, button: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "应弹出确认框")
        XCTAssertTrue(alert.label.contains(expected), "确认框标题「\(alert.label)」应含「\(expected)」，拒绝确认")
        guard alert.label.contains(expected) else { return }
        let target = alert.buttons[button]
        XCTAssertTrue(target.exists && target.isHittable, "确认框应有「\(button)」")
        target.tap()
    }

    @MainActor
    private func cancelAlert(_ app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "应弹出确认框")
        alert.buttons["取消"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testSettingsIndexUsesSingleLineRows() throws {
        let app = try launch(route: "/my")
        XCTAssertTrue(app.buttons["open-scanner"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["open-search"].exists, "我的页只保留扫码")
        snapshot("我的-Logo与扫码")
        tapSafely(app, app.buttons["more-settings"], "服务器设置")
        XCTAssertTrue(app.staticTexts["settings-description"].waitForExistence(timeout: 10))
        let members = app.buttons["settings-members"]
        XCTAssertTrue(members.waitForExistence(timeout: 15))
        XCTAssertEqual(members.staticTexts.count, 1, "服务器设置入口只显示一行标题")
        XCTAssertFalse(app.staticTexts["家庭成员账号、能力开关与可见范围"].exists)
        XCTAssertFalse(app.staticTexts["登录着你的账号的浏览器、App、命令行与转码器"].exists)
        snapshot("服务器设置-单行入口")
        tapSafely(app, members, "成员入口")
        XCTAssertTrue(app.buttons["member-add"].waitForExistence(timeout: 15))
    }

    // MARK: 概览

    @MainActor
    func testOverviewPipelineHealth() throws {
        let app = try launch(route: "/settings/overview")
        XCTAssertTrue(app.staticTexts["订阅链路体检"].waitForExistence(timeout: 30))
        let recheck = app.buttons["overview-recheck"]
        tapSafely(app, recheck, "重新体检")
        let ready = app.staticTexts["公共链路"].waitForExistence(timeout: 30)
            || app.otherElements["setup-checklist"].waitForExistence(timeout: 5)
        XCTAssertTrue(ready, "体检结果应渲染开局清单或公共链路")
        snapshot("概览-链路体检")
    }

    // MARK: 个人信息

    @MainActor
    func testProfileNicknameRoundTripAndGuards() throws {
        let app = try launch(route: "/settings/profile")
        guard let probe else { return }
        let original = try probe.getObject("/auth/me")["nickname"] as? String ?? username
        restorers.append(("昵称", { _ = try probe.request("PUT", "/auth/profile", body: ["nickname": original]) }))

        // 改昵称 → 校验 → 改回
        let temp = "ios-test-\(Int(Date().timeIntervalSince1970) % 100000)"
        tapSafely(app, app.buttons["profile-nickname-edit"], "编辑昵称")
        let field = app.textFields["profile-nickname-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.clearAndType(temp)
        tapSafely(app, app.buttons["profile-nickname-save"], "保存昵称")
        XCTAssertTrue(waitUntil(15) { (try? probe.getObject("/auth/me"))?["nickname"] as? String == temp }, "接口昵称应更新为 \(temp)")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", temp)).firstMatch.waitForExistence(timeout: 10), "界面应显示新昵称")
        snapshot("个人信息-改昵称")

        tapSafely(app, app.buttons["profile-nickname-edit"], "编辑昵称")
        field.tap()
        field.clearAndType(original)
        tapSafely(app, app.buttons["profile-nickname-save"], "保存昵称")
        XCTAssertTrue(waitUntil(15) { (try? probe.getObject("/auth/me"))?["nickname"] as? String == original }, "接口昵称应改回 \(original)")

        // 修改密码：未填全时按钮禁用（不提交）
        tapSafely(app, app.buttons["profile-password-edit"], "修改密码")
        let change = app.buttons["profile-change-password"]
        XCTAssertFalse(change.isEnabled, "未填全三项时修改密码应禁用")
        tapSafely(app, app.buttons["sheet-close"], "关闭密码编辑")

        // 清空全部观看记录：只到确认框，点取消
        tapSafely(app, app.buttons["profile-actions"], "个人信息操作")
        tapSafely(app, app.buttons["profile-clear-history"], "清空观看记录")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10) && app.alerts.firstMatch.label.contains("清空全部观看记录"))
        cancelAlert(app)
        snapshot("个人信息-清空记录已取消")
    }

    // MARK: 成员

    @MainActor
    func testMemberLifecycleOnTestAccount() throws {
        let app = try launch(route: "/settings/members")
        guard let probe else { return }
        let name = "ios-test-\(Int(Date().timeIntervalSince1970) % 1_000_000)"

        tapSafely(app, app.buttons["member-add"], "添加成员")
        let usernameField = app.textFields["member-create-username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 10))
        usernameField.tap()
        usernameField.typeText(name)
        let nicknameField = app.textFields["member-create-nickname"]
        nicknameField.tap()
        nicknameField.typeText(name)
        tapSafely(app, app.buttons["member-create-regenerate"], "重新生成密码")
        tapSafely(app, app.buttons["member-create-submit"], "创建成员")
        XCTAssertTrue(app.buttons["credential-密码"].waitForExistence(timeout: 20), "应显示一次性密码")
        snapshot("成员-已创建")
        tapSafely(app, app.buttons["credential-copy-all"], "复制登录信息")
        tapSafely(app, app.buttons["password-result-done"], "完成")
        confirmAlert(app, titleContains: "已保存", button: "继续保存")
        tapSafely(app, app.buttons["password-result-done"], "完成")
        confirmAlert(app, titleContains: "已保存", button: "我已保存")

        let member = try XCTUnwrap(try probe.getArray("/members").first { $0["username"] as? String == name }, "接口应有新成员")
        let memberId = try XCTUnwrap(member["id"] as? Int)

        // 搜索进入详情，编辑仅保存当前分区。
        let search = app.searchFields.firstMatch
        tapSafely(app, search, "搜索新成员")
        search.typeText(name)
        tapSafely(app, app.buttons["member-row-\(name)"], "成员详情")
        snapshot("成员-详情")
        tapSafely(app, app.buttons["member-edit-permissions"], "功能权限")
        XCTAssertGreaterThan(app.navigationBars["功能权限"].frame.minY, app.frame.height * 0.3, "普通字号应打开短抽屉")
        XCTAssertFalse(app.switches["member-allow-download"].isEnabled)
        toggleSafely(app, "member-allow-search")
        toggleSafely(app, "member-allow-download")
        snapshot("成员-功能权限")
        tapSafely(app, app.buttons["member-edit-save"], "保存权限")
        XCTAssertTrue(waitUntil(15) {
            (try? probe.getArray("/members"))?.first { $0["id"] as? Int == memberId }?["allow_direct_download"] as? Bool == true
        })
        tapSafely(app, app.buttons["member-edit-content"], "内容分级")
        tapSafely(app, app.buttons["member-age-limit"], "选择内容分级")
        tapSafely(app, app.buttons["12 岁以下"], "选择年龄上限")
        snapshot("成员-内容分级")
        tapSafely(app, app.buttons["member-edit-save"], "保存分级")
        XCTAssertTrue(waitUntil(15) {
            (try? probe.getArray("/members"))?.first { $0["id"] as? Int == memberId }?["content_age_limit"] as? Int == 12
        })

        // 改昵称后取消：原值和其他权限必须保留。
        tapSafely(app, app.buttons["member-edit-profile"], "基本信息")
        snapshot("成员-基本信息抽屉")
        app.textFields["member-edit-nickname"].clearAndType("取消的昵称")
        tapSafely(app, app.buttons["sheet-cancel"], "取消编辑")
        confirmAlert(app, titleContains: "放弃", button: "放弃修改")
        XCTAssertEqual(try probe.getArray("/members").first { $0["id"] as? Int == memberId }?["nickname"] as? String, name)

        // 重置密码的取消、确认及一次性保存。
        tapSafely(app, app.buttons["member-reset-password"], "重置密码")
        confirmAlert(app, titleContains: "重置", button: "取消")
        tapSafely(app, app.buttons["member-reset-password"], "重置密码")
        confirmAlert(app, titleContains: "重置", button: "重置密码")
        XCTAssertTrue(app.buttons["credential-密码"].waitForExistence(timeout: 10))
        tapSafely(app, app.buttons["credential-copy-all"], "复制重置后的凭据")
        tapSafely(app, app.buttons["password-result-done"], "保存新密码")
        confirmAlert(app, titleContains: "已保存", button: "我已保存")

        tapSafely(app, app.buttons["member-actions"], "打开成员操作")
        snapshot("成员-右上角操作")
        tapSafely(app, app.buttons["member-disable"], "停用成员")
        confirmAlert(app, titleContains: name, button: "停用成员")
        XCTAssertTrue(waitUntil(15) {
            (try? probe.getArray("/members"))?.first { $0["id"] as? Int == memberId }?["status"] as? String == "disabled"
        })
        tapSafely(app, app.buttons["member-actions"], "打开成员操作")
        tapSafely(app, app.buttons["member-enable"], "启用成员")
        XCTAssertTrue(waitUntil(15) {
            (try? probe.getArray("/members"))?.first { $0["id"] as? Int == memberId }?["status"] as? String == "active"
        })
        tapSafely(app, app.buttons["member-actions"], "打开成员操作")
        tapSafely(app, app.buttons["member-delete"], "删除成员")
        confirmAlert(app, titleContains: name, button: "取消")
        XCTAssertTrue(try probe.getArray("/members").contains { $0["id"] as? Int == memberId })
        tapSafely(app, app.buttons["member-actions"], "打开成员操作")
        tapSafely(app, app.buttons["member-delete"], "删除成员")
        confirmAlert(app, titleContains: name, button: "删除成员")
        XCTAssertTrue(waitUntil(15) {
            !((try? probe.getArray("/members")) ?? []).contains { $0["id"] as? Int == memberId }
        })
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        snapshot("成员-删除后搜索空状态")
    }

    @MainActor
    func testMemberAccessScopesAndSearch() throws {
        let app = try launch(route: "/settings/members")
        guard let probe else { return }
        let name = "ios-test-scopes-\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        let member = try XCTUnwrap(try probe.request("POST", "/members", body: ["username": name, "password": "test-member-password", "nickname": "范围测试"]) as? [String: Any])
        let id = try XCTUnwrap(member["id"] as? Int)
        _ = try probe.request("PUT", "/members/\(id)", body: ["allow_search": true])
        let memberSession = try SettingsTestAPI(server: server, username: name, password: "test-member-password")
        app.terminate()
        app.launch()
        snapshot("成员-列表")
        tapSafely(app, app.searchFields.firstMatch, "搜索成员")
        app.searchFields.firstMatch.typeText(name + "\n")
        tapSafely(app, app.buttons["member-row-\(name)"], "进入详情")
        tapSafely(app, app.buttons["member-actions"], "打开成员操作")
        tapSafely(app, app.buttons["member-signout"], "全部设备下线")
        confirmAlert(app, titleContains: "全部设备", button: "全部下线")
        XCTAssertTrue(waitUntil(15) { (try? memberSession.getObject("/auth/me")) == nil }, "全部下线后成员会话应失效")
        tapSafely(app, app.buttons["member-edit-libraries"], "媒体库范围")
        tapSafely(app, app.buttons["member-library-mode"], "选择媒体库模式")
        tapSafely(app, app.buttons["指定媒体库"], "限定媒体库")
        let allLibraries = try probe.getArray("/libraries")
        let library = allLibraries.first { $0["access_mode"] as? String == "selected" } ?? allLibraries.first
        if let libraryID = library?["id"] as? Int {
            tapSafely(app, app.buttons["member-library-\(libraryID)"], "选择媒体库")
        }
        snapshot("成员-媒体库选择")
        tapSafely(app, app.buttons["member-edit-save"], "保存媒体库范围")
        XCTAssertTrue(waitUntil(15) {
            (try? probe.getArray("/members"))?.first { $0["id"] as? Int == id }?["all_libraries"] as? Bool == false
        })
        tapSafely(app, app.buttons["member-edit-sites"], "站点范围")
        tapSafely(app, app.buttons["member-site-mode"], "选择站点模式")
        tapSafely(app, app.buttons["指定站点"], "限定站点")
        if let site = try probe.getArray("/sites/catalog").first,
           let siteID = site["site_id"] as? String {
            tapSafely(app, app.buttons["member-site-\(siteID)"], "选择一个站点")
        }
        snapshot("成员-站点选择")
        tapSafely(app, app.buttons["member-edit-save"], "保存站点范围")
        let saved = try XCTUnwrap(try probe.getArray("/members").first { $0["id"] as? Int == id })
        XCTAssertEqual(saved["all_sites"] as? Bool, false)
        XCTAssertEqual(saved["all_libraries"] as? Bool, false)
        XCTAssertEqual(saved["allow_search"] as? Bool, true)
        if let libraryID = library?["id"] as? Int {
            XCTAssertEqual(saved["library_ids"] as? [Int], [libraryID])
            if library?["access_mode"] as? String == "selected" {
                tapSafely(app, app.buttons["member-edit-libraries"], "恢复共享库并保留单独授权")
                tapSafely(app, app.buttons["member-library-mode"], "选择媒体库模式")
                tapSafely(app, app.buttons["全部共享库"], "全部共享库")
                tapSafely(app, app.buttons["member-edit-save"], "保存共享范围")
                XCTAssertTrue(waitUntil(15) {
                    let next = (try? probe.getArray("/members"))?.first { $0["id"] as? Int == id }
                    return next?["all_libraries"] as? Bool == true && next?["library_ids"] as? [Int] == [libraryID]
                }, "全部共享库模式必须保留指定成员库的授权")
            }
        }
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, name)
    }

    @MainActor
    func testMemberLargeTextAndEmptySearch() throws {
        let app = try launch(route: "/settings/members", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        guard let probe else { return }
        let name = "ios-test-large-\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        _ = try probe.request("POST", "/members", body: ["username": name, "password": "test-member-password", "nickname": "家里的长昵称成员"])
        app.terminate()
        app.launch()
        tapSafely(app, app.searchFields.firstMatch, "大字体搜索")
        app.searchFields.firstMatch.typeText(name + "\n")
        snapshot("成员-大字体列表")
        tapSafely(app, app.buttons["member-row-\(name)"], "大字体详情")
        snapshot("成员-大字体详情")
        tapSafely(app, app.buttons["member-edit-permissions"], "大字体功能权限")
        toggleSafely(app, "member-allow-subscribe")
        tapSafely(app, app.buttons["sheet-cancel"], "取消大字体编辑")
        confirmAlert(app, titleContains: "放弃", button: "放弃修改")
        app.navigationBars.buttons.firstMatch.tap()
        app.searchFields.firstMatch.clearAndType("no-such-member")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "no-such-member")).firstMatch.waitForExistence(timeout: 5))
        snapshot("成员-无搜索结果")
    }

    // MARK: 设备

    /// 「我的」页右上角扫码 → 独立批准页 → 批准 → 设备拿到的令牌就是批准者本人的。
    /// 模拟器没有相机：用 -mcScanResult 注入「扫到的二维码」（电视上那张码的内容），其余全是真实路径。
    @MainActor
    func testScanQRCodeApprovesAppleTV() throws {
        guard let password else { throw XCTSkip("未提供 MC_TEST_PASSWORD，跳过联调用例") }
        let pairing = try SettingsTestAPI(server: server, username: username, password: password)
        guard let grant = try pairing.request("POST", "/auth/device/authorize", body: [
            "client_type": "tvos", "client_name": "ios-test 客厅 Apple TV", "platform": "tvOS 26.0",
        ]) as? [String: Any],
            let userCode = grant["user_code"] as? String, let deviceCode = grant["device_code"] as? String,
            let qr = grant["verification_uri_complete"] as? String
        else { return XCTFail("发起配对失败") }

        let app = try launch(route: "/my", extra: ["-mcScanResult", qr])
        XCTAssertTrue(app.buttons["open-scanner"].waitForExistence(timeout: 20), "「我的」页右上角应有扫码按钮")
        XCTAssertFalse(app.buttons["open-search"].exists, "我的页只保留扫码")
        snapshot("我的-扫码入口")
        tapSafely(app, app.buttons["open-scanner"], "「我的」页的扫码按钮")
        let approve = app.buttons["device-approve-\(userCode)"]
        XCTAssertTrue(approve.waitForExistence(timeout: 20), "扫到后应进入批准页并显示这条请求")
        XCTAssertTrue(app.staticTexts["ios-test 客厅 Apple TV"].exists)
        snapshot("批准页-审批卡")
        approve.tap()
        XCTAssertTrue(app.otherElements["device-approval-result"].waitForExistence(timeout: 15), "批准后应显示结果页")
        snapshot("批准页-已批准")

        guard let token = try pairing.request("POST", "/auth/device/token", body: ["device_code": deviceCode]) as? [String: Any],
              let value = token["token"] as? String
        else { return XCTFail("批准后设备应拿到令牌") }
        // 用这枚令牌问「我是谁」：就是批准者本人；问完注销，不留测试设备
        try revoke(token: value, expectUser: username)
        app.buttons["device-approval-done"].tap()
    }

    /// 用设备令牌确认身份后注销它
    private func revoke(token: String, expectUser: String) throws {
        func call(_ method: String, _ path: String) throws -> [String: Any] {
            var request = URLRequest(url: URL(string: server)!.appending(path: "api/v1\(path)"))
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let semaphore = DispatchSemaphore(value: 0)
            var body: Data?
            URLSession.shared.dataTask(with: request) { data, _, _ in body = data; semaphore.signal() }.resume()
            semaphore.wait()
            return (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        }
        let me = try call("GET", "/auth/me")
        XCTAssertEqual((me["data"] as? [String: Any])?["username"] as? String, expectUser, "令牌应属于批准者")
        _ = try call("DELETE", "/auth/devices/current")
    }

    @MainActor
    func testCreateAndRevokeOwnToken() throws {
        let app = try launch(route: "/settings/devices")
        guard let probe else { return }
        let name = "ios-test-token-\(Int(Date().timeIntervalSince1970) % 1_000_000)"
        XCTAssertTrue(app.buttons["devices-approve-entry"].waitForExistence(timeout: 20), "设备页顶部应有「批准新设备登录」入口")
        XCTAssertTrue(app.buttons["devices-approve-entry"].isHittable)
        XCTAssertTrue(app.buttons["token-create-open"].isHittable, "创建令牌应在首屏内")
        snapshot("设备-首页主要操作")

        tapSafely(app, app.buttons["token-create-open"], "创建令牌入口")
        let field = app.textFields["token-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertFalse(app.buttons["token-create-submit"].isEnabled, "空名称不能创建")
        field.typeText("\(name)\n")
        tapSafely(app, app.buttons["token-create-submit"], "创建令牌")
        XCTAssertTrue(app.descendants(matching: .any)["token-created-card"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["已创建「\(name)」"].exists)
        snapshot("设备-令牌已创建")
        tapSafely(app, app.buttons["token-copy"], "复制令牌")
        tapSafely(app, app.buttons["token-created-dismiss"], "完成")
        tapSafely(app, app.alerts.buttons["继续保存"], "返回保存令牌")
        XCTAssertTrue(app.descendants(matching: .any)["token-created-card"].exists)
        tapSafely(app, app.buttons["token-created-dismiss"], "再次完成")
        tapSafely(app, app.buttons["我已保存"], "确认保存")

        tapSafely(app, app.buttons["devices-all-paired"], "命令行与转码器")
        tapSafely(app, app.buttons["device-row-\(name)"], "令牌详情")
        tapSafely(app, app.buttons["device-rename"], "改名")
        let renameField = app.alerts.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.clearAndType(name + "-renamed")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(waitUntil(15) {
            ((try? probe.getArray("/auth/devices")) ?? []).contains { $0["name"] as? String == name + "-renamed" }
        }, "改名应持久化到服务端")
        snapshot("设备-详情")
        tapSafely(app, app.buttons["device-revoke"], "注销自建令牌")
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(try probe.getArray("/auth/devices").contains { $0["name"] as? String == name + "-renamed" })
        tapSafely(app, app.buttons["device-revoke"], "再次注销")
        confirmAlert(app, titleContains: name + "-renamed", button: "注销")
        XCTAssertTrue(waitUntil(15) {
            !((try? probe.getArray("/auth/devices")) ?? []).contains { $0["name"] as? String == name + "-renamed" }
        }, "自建令牌应已注销")
        snapshot("设备-已吊销")
    }

    /// 分类页 → 长列表搜索 → 详情 → 返回；从概览切换分类，右上角保留清理入口。
    @MainActor
    func testDeviceCategoriesSearchAndNavigation() throws {
        let app = try launch(route: "/settings/devices")
        guard let probe else { return }
        guard server.contains("127.0.0.1"), try probe.getArray("/auth/devices").contains(where: { ($0["name"] as? String) == "device-fixture-offline-cli" }) else {
            throw XCTSkip("需要独立的设备验收数据")
        }
        tapSafely(app, app.buttons["devices-all-browser"], "浏览器分类")
        XCTAssertTrue(app.buttons["devices-cleanup-entry"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["devices-list-category"].exists)
        XCTAssertFalse(app.buttons["devices-list-done"].exists, "层级浏览不应使用完成来返回")
        let search = app.searchFields.firstMatch
        tapSafely(app, search, "设备搜索")
        search.typeText("browser-079")
        let target = app.buttons["device-row-device-fixture-browser-079"]
        tapSafely(app, target, "搜索远端列表记录")
        XCTAssertTrue(app.navigationBars["设备详情"].waitForExistence(timeout: 5))
        snapshot("设备-搜索后的详情")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(target.waitForExistence(timeout: 5), "返回后保留搜索结果")
        snapshot("设备-搜索结果")
        if app.buttons["取消"].exists { app.buttons["取消"].tap() }
        else if app.buttons["关闭"].exists { app.buttons["关闭"].tap() }
        app.navigationBars.buttons.firstMatch.tap()
        tapSafely(app, app.buttons["devices-all-player"], "播放器分类")
        XCTAssertTrue(app.staticTexts["暂无播放器设备"].waitForExistence(timeout: 5), app.debugDescription)
        snapshot("设备-空分类")
        XCTAssertTrue(app.buttons["devices-cleanup-entry"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        tapSafely(app, app.buttons["devices-all-paired"], "命令行分类")
        XCTAssertTrue(app.buttons["device-row-device-fixture-offline-cli"].waitForExistence(timeout: 5))
        let searchAgain = app.searchFields.firstMatch
        tapSafely(app, searchAgain, "搜索不存在的设备")
        searchAgain.typeText("does-not-exist")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "does-not-exist")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        snapshot("设备-搜索无结果")
    }

    /// 分类清理：时间切换、空名单、取消和真实注销；其他分类、本机必须保留。
    @MainActor
    func testCleanupSheetPreviewsBeforeRevoking() throws {
        let app = try launch(route: "/settings/devices")
        guard let probe else { return }
        guard server.contains("127.0.0.1"), try probe.getArray("/auth/devices").contains(where: { ($0["name"] as? String) == "device-fixture-offline-cli" }) else {
            throw XCTSkip("需要独立的设备验收数据")
        }
        let before = try probe.getArray("/auth/devices")
        let appKinds = ["ios", "tvos", "macos", "android"]
        let appIDs = Set(before.filter { appKinds.contains($0["kind"] as? String ?? "") }.compactMap { $0["id"] as? String })
        let outsideIDs = Set(before.compactMap { $0["id"] as? String }).subtracting(appIDs)
        let preview = try XCTUnwrap(try probe.request("POST", "/auth/devices/cleanup", body: ["inactive_days": 30, "dry_run": true]) as? [String: Any])
        let targetIDs = Set((preview["devices"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }).intersection(appIDs)
        guard !targetIDs.isEmpty else { throw XCTSkip("请重新生成独立的设备验收数据") }
        tapSafely(app, app.buttons["devices-all-app"], "App 分类")
        tapSafely(app, app.buttons["devices-cleanup-entry"], "清理入口")
        let days = app.segmentedControls["devices-cleanup-days"]
        XCTAssertTrue(days.waitForExistence(timeout: 10))
        days.buttons["7 天"].tap()
        let submit = app.buttons["devices-cleanup-submit"]
        XCTAssertTrue(app.staticTexts["devices-cleanup-summary"].waitForExistence(timeout: 10))
        snapshot("设备-清理浮层")
        tapSafely(app, submit, "查看注销确认")
        snapshot("设备-清理确认")
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(Set(try probe.getArray("/auth/devices").compactMap { $0["id"] as? String }), Set(before.compactMap { $0["id"] as? String }))
        days.buttons["90 天"].tap()
        XCTAssertTrue(app.staticTexts["没有需要清理的设备"].waitForExistence(timeout: 10))
        XCTAssertFalse(submit.isEnabled)
        snapshot("设备-清理空名单")
        days.buttons["30 天"].tap()
        XCTAssertTrue(app.staticTexts["\(targetIDs.count) 台设备超过 30 天未使用"].waitForExistence(timeout: 10))
        tapSafely(app, submit, "清理当前分类")
        confirmAlert(app, titleContains: "\(targetIDs.count)", button: "清理 \(targetIDs.count) 台设备")
        XCTAssertTrue(waitUntil(30) {
            let remaining = Set(((try? probe.getArray("/auth/devices")) ?? []).compactMap { $0["id"] as? String })
            return targetIDs.isDisjoint(with: remaining)
        })
        let remaining = Set(try probe.getArray("/auth/devices").compactMap { $0["id"] as? String })
        XCTAssertTrue(outsideIDs.isSubset(of: remaining), "清理 App 不得注销浏览器、命令行或播放器")
        XCTAssertTrue(appIDs.subtracting(targetIDs).isSubset(of: remaining), "活跃设备和本机必须保留")
        XCTAssertTrue(app.navigationBars["App"].waitForExistence(timeout: 5))
        snapshot("设备-分类清理完成")
    }

    @MainActor
    func testDeviceSettingsAccessibilityTextAndApprovalInput() throws {
        let app = try launch(route: "/settings/devices", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        guard let probe else { return }
        guard server.contains("127.0.0.1"), try probe.getArray("/auth/devices").contains(where: { ($0["name"] as? String) == "device-fixture-offline-cli" }) else {
            throw XCTSkip("需要独立的设备验收数据")
        }
        tapSafely(app, app.buttons["devices-all-paired"], "大字体下进入分类")
        tapSafely(app, app.buttons["devices-cleanup-entry"], "大字体下打开清理")
        XCTAssertTrue(app.buttons["devices-cleanup-days"].waitForExistence(timeout: 5), "大字体下时间选择应使用菜单")
        tapSafely(app, app.buttons["devices-cleanup-days"], "大字体下选择清理时间")
        tapSafely(app, app.buttons["90 天"], "选择 90 天")
        snapshot("设备-大字体清理")
        tapSafely(app, app.buttons["sheet-cancel"], "关闭大字体清理")
        tapSafely(app, app.buttons["device-row-device-fixture-offline-cli"], "大字体下进入详情")
        snapshot("设备-大字体详情")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        tapSafely(app, app.buttons["devices-approve-entry"], "大字体下批准设备")
        let code = app.textFields["pairing-code"]
        tapSafely(app, code, "输入配对码")
        code.typeText("BAD\n")
        XCTAssertTrue(app.staticTexts["device-approval-error"].waitForExistence(timeout: 5))
        snapshot("设备-大字体配对校验")
        tapSafely(app, app.buttons["device-approval-close"], "关闭批准流程")
        XCTAssertTrue(app.navigationBars["设备"].waitForExistence(timeout: 5))
    }

    // MARK: 播放

    @MainActor
    func testPlaybackPolicyTogglesRestore() throws {
        let app = try launch(route: "/settings/playback")
        guard let probe else { return }
        let policy = try probe.getObject("/playback/policy")
        let trick = policy["trickplay_enabled"] as? Bool ?? true
        let cache = policy["transcode_cache_enabled"] as? Bool ?? true
        restorers.append(("播放策略", {
            _ = try probe.request("PUT", "/playback/policy", body: ["trickplay_enabled": trick, "transcode_cache_enabled": cache])
        }))

        for (id, key, original) in [("playback-trickplay", "trickplay_enabled", trick), ("playback-transcode-cache", "transcode_cache_enabled", cache)] {
            toggleSafely(app, id)
            XCTAssertTrue(waitUntil(15) { (try? probe.getObject("/playback/policy"))?[key] as? Bool == !original }, "\(key) 应已切换")
            toggleSafely(app, id)
            XCTAssertTrue(waitUntil(15) { (try? probe.getObject("/playback/policy"))?[key] as? Bool == original }, "\(key) 应已恢复")
        }

        // 远程转码：只看，不保存
        tapSafely(app, app.buttons["remote-transcode-settings"], "远程转码设置")
        XCTAssertTrue(reveal(app, app.switches["remote-transcode-enabled"]).exists)
        snapshot("播放-远程转码")
    }

    // MARK: AI 设定

    @MainActor
    func testAIDefaultModelSwitchRestore() throws {
        let app = try launch(route: "/settings/ai")
        guard let probe else { return }
        let defaults = try probe.getObject("/llm/defaults")
        let agent = defaults["agent_model"] as? String
        let subtitle = defaults["subtitle_model"] as? String
        restorers.append(("AI 默认模型", {
            _ = try probe.request("PUT", "/llm/defaults", body: ["agent_model": agent.map { $0 as Any } ?? NSNull(), "subtitle_model": subtitle.map { $0 as Any } ?? NSNull()])
        }))
        let models = try probe.getArray("/llm/models")
        guard let other = models.first(where: { $0["ref"] as? String != agent }), let otherRef = other["ref"] as? String,
              let otherLabel = other["label"] as? String, let agent,
              let originalLabel = models.first(where: { $0["ref"] as? String == agent })?["label"] as? String else {
            throw XCTSkip("模型清单不足两个，跳过切换")
        }

        func pick(_ label: String) {
            tapSafely(app, app.buttons["ai-agent-model"], "智能体默认模型")
            let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            tapSafely(app, option, "模型 \(label)")
            tapSafely(app, app.buttons["ai-model-save"], "保存模型")
        }
        pick(otherLabel)
        XCTAssertTrue(waitUntil(15) { (try? probe.getObject("/llm/defaults"))?["agent_model"] as? String == otherRef }, "应切到 \(otherRef)")
        snapshot("AI 设定-已切换")
        pick(originalLabel)
        XCTAssertTrue(waitUntil(15) { (try? probe.getObject("/llm/defaults"))?["agent_model"] as? String == agent }, "应切回 \(agent)")
    }

    // MARK: 更新与维护（只读 + 确认框只到取消）

    @MainActor
    func testMaintenanceTabsReadOnly() throws {
        let app = try launch(route: "/settings/app")
        XCTAssertTrue(app.staticTexts["app-current-version"].waitForExistence(timeout: 30), "应显示当前版本")
        snapshot("更新与维护-版本")
        // 重启应用：只到确认框，点取消
        tapSafely(app, app.buttons["app-actions"], "维护操作")
        tapSafely(app, app.buttons["app-restart"], "重启应用")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10) && app.alerts.firstMatch.label.contains("重启应用"))
        cancelAlert(app)
        XCTAssertFalse(app.otherElements["restart-waiting"].exists, "取消后不应进入重启等待")

        tapSafely(app, app.buttons["app-storage"], "缓存管理")
        XCTAssertTrue(app.staticTexts["磁盘概览"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["storage-refresh"].exists, "应有刷新统计按钮")
        snapshot("更新与维护-缓存")

        tapSafely(app, app.navigationBars["缓存管理"].buttons.firstMatch, "返回更新与维护")
        tapSafely(app, app.buttons["app-tasks"], "定时任务")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        snapshot("更新与维护-定时任务")
        tapSafely(app, row, "编辑任务")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-mode-'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("更新与维护-任务抽屉")
        tapSafely(app, app.buttons["sheet-close"], "关闭任务")
    }

    private func maintenanceFixture(mode: String = "available") throws -> SettingsTestAPI {
        guard env["MC_TEST_MAINTENANCE_FIXTURE"] == "1", server == "http://127.0.0.1:8129", let password else {
            throw XCTSkip("仅在独立维护测试服务上运行")
        }
        let fixture = try SettingsTestAPI(server: server, username: username, password: password)
        _ = try fixture.request("POST", "/e2e/maintenance/reset", body: ["mode": mode])
        return fixture
    }

    @MainActor
    func testMaintenanceUpdateAndTaskFlow() throws {
        let fixture = try maintenanceFixture()
        let app = try launch(route: "/settings/app")
        tapSafely(app, app.buttons["app-changelog"], "更新说明")
        snapshot("维护-更新说明玻璃抽屉")
        tapSafely(app, app.buttons["sheet-close"], "关闭更新说明")
        tapSafely(app, app.buttons["app-open-rollback"], "历史版本")
        tapSafely(app, app.buttons["rollback-target-0"], "查看回退后果")
        XCTAssertTrue(app.buttons["rollback-confirm"].exists)
        snapshot("维护-历史版本玻璃抽屉")
        tapSafely(app, app.buttons["sheet-close"], "取消回退")
        XCTAssertEqual((try fixture.getObject("/e2e/maintenance/state")["actions"] as? [String])?.count, 0)
        tapSafely(app, app.buttons["app-tasks"], "定时任务")
        tapSafely(app, app.buttons["task-row-fixture"], "编辑任务")
        toggleSafely(app, "task-enabled-fixture")
        tapSafely(app, app.buttons["task-save-fixture"], "保存任务")
        XCTAssertTrue(waitUntil(10) {
            (try? fixture.getArray("/scheduled-tasks"))?.first?["enabled"] as? Bool == false
        })
        XCTAssertEqual(try fixture.getArray("/scheduled-tasks").first?["interval_seconds"] as? Int, 1200)
        tapSafely(app, app.buttons["task-row-fixture"], "再次编辑任务")
        toggleSafely(app, "task-enabled-fixture")
        tapSafely(app, app.buttons["sheet-close"], "取消任务修改")
        confirmAlert(app, titleContains: "放弃", button: "放弃修改")
        XCTAssertEqual(try fixture.getArray("/scheduled-tasks").first?["enabled"] as? Bool, false)
        tapSafely(app, app.navigationBars["定时任务"].buttons.firstMatch, "返回更新与维护")
        tapSafely(app, app.buttons["app-check-update"], "检查更新")
        snapshot("维护-可用更新")
        tapSafely(app, app.buttons["app-apply-update"], "安装测试更新")
        XCTAssertTrue(waitUntil(20) { app.staticTexts["app-current-version"].label == "v0.32.0" })
        XCTAssertFalse(app.buttons["app-apply-update"].exists)
        snapshot("维护-更新成功")
    }

    @MainActor
    func testMaintenanceUpdateFailure() throws {
        _ = try maintenanceFixture(mode: "failed")
        let app = try launch(route: "/settings/app")
        tapSafely(app, app.buttons["app-apply-update"], "安装失败场景")
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '测试网络中断'")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["app-apply-update"].exists, "失败后允许重新更新")
        XCTAssertEqual(app.staticTexts["app-current-version"].label, "v0.31.0")
        snapshot("维护-更新失败")
        app.terminate()
        _ = try maintenanceFixture(mode: "incompatible")
        let incompatible = try launch(route: "/settings/app")
        XCTAssertTrue(incompatible.buttons["app-changelog"].waitForExistence(timeout: 15))
        XCTAssertFalse(incompatible.buttons["app-apply-update"].exists, "依赖不兼容时不应提供应用内安装")
        snapshot("维护-需升级镜像")
    }

    @MainActor
    func testMaintenanceDeepLinksAndLargeText() throws {
        let fixture = try maintenanceFixture()
        let app = try launch(route: "/settings/app?tab=tasks", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.navigationBars["定时任务"].waitForExistence(timeout: 20))
        tapSafely(app, app.buttons["task-row-fixture"], "大字号任务")
        XCTAssertTrue(app.switches["task-enabled-fixture"].waitForExistence(timeout: 10))
        snapshot("维护-大字号任务")
        tapSafely(app, app.buttons["sheet-close"], "关闭任务")
        app.terminate()
        let storage = try launch(route: "/settings/app?tab=storage")
        XCTAssertTrue(storage.navigationBars["缓存管理"].waitForExistence(timeout: 20))
        let row = storage.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'storage-dir-'")).firstMatch
        tapSafely(storage, row, "缓存详情")
        XCTAssertTrue(storage.staticTexts["占用空间"].waitForExistence(timeout: 10))
        snapshot("维护-缓存详情玻璃抽屉")
        tapSafely(storage, storage.buttons["storage-clean-all"], "清理确认")
        confirmAlert(storage, titleContains: "海报缓存", button: "取消")
        XCTAssertEqual(try fixture.getObject("/e2e/maintenance/state")["cleaned"] as? Bool, false)
        tapSafely(storage, storage.buttons["storage-clean-all"], "执行测试缓存清理")
        let alert = storage.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let clear = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH '清空并释放'")).firstMatch
        XCTAssertTrue(clear.exists)
        clear.tap()
        XCTAssertTrue(waitUntil(10) { (try? fixture.getObject("/e2e/maintenance/state"))?["cleaned"] as? Bool == true })
        XCTAssertTrue(storage.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '已释放'")).firstMatch.waitForExistence(timeout: 10))
        tapSafely(storage, storage.buttons["sheet-close"], "关闭缓存详情")
    }

    // MARK: 网络（只点「测试」）

    @MainActor
    func testNetworkServiceTestOnly() throws {
        let app = try launch(route: "/settings/network")
        tapSafely(app, app.buttons["network-services"], "代理服务与测试")
        tapSafely(app, app.buttons["network-test-tmdb"], "TMDB 测试")
        XCTAssertTrue(app.otherElements["network-test-result-tmdb"].waitForExistence(timeout: 40)
            || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '连通' OR label == '不通'")).firstMatch.waitForExistence(timeout: 5),
            "应显示测试结果")
        snapshot("网络-测试结果")
    }

    // MARK: 系统日志

    @MainActor
    func testLogsFilterSearchRefreshFullscreen() throws {
        let app = try launch(route: "/settings/logs")
        XCTAssertTrue(app.staticTexts["logs-meta"].waitForExistence(timeout: 30), "应显示日志大小与行数")
        tapSafely(app, app.buttons["logs-level-警告"], "警告筛选")
        tapSafely(app, app.buttons["logs-level-全部"], "全部筛选")
        let search = app.textFields["logs-search"]
        tapSafely(app, search, "搜索框")
        search.typeText("GET")
        snapshot("日志-搜索")
        let refresh = app.segmentedControls["logs-auto-refresh"]
        tapSafely(app, refresh.buttons["30s"], "30s")
        tapSafely(app, refresh.buttons["10s"], "10s")
        tapSafely(app, app.buttons["logs-fullscreen"], "全屏")
        XCTAssertTrue(app.buttons["logs-fullscreen-done"].waitForExistence(timeout: 10))
        snapshot("日志-全屏")
        app.buttons["logs-fullscreen-done"].tap()
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.8)
        }
        return condition()
    }
}

// MARK: - 接口探针（测试进程自己的会话，只用于记原值、核对与写回）

final class SettingsTestAPI {
    private let base: URL
    private let session: URLSession
    /// 登录拿到的会话 Cookie（自己带，不与 App / 其它用例共享 Cookie 存储）
    private var cookies: [HTTPCookie] = []

    init(server: String, username: String, password: String) throws {
        base = URL(string: server)!.appending(path: "api/v1")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
        _ = try request("POST", "/auth/login", body: ["username": username, "password": password, "remember": false])
    }

    @discardableResult
    func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Any? {
        var request = URLRequest(url: base.appending(path: String(path.dropFirst())))
        request.httpMethod = method
        if !cookies.isEmpty {
            request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?)
        session.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = result.2 { throw error }
        let http = result.1 as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if let http, let url = http.url, let fields = http.allHeaderFields as? [String: String] {
            let fresh = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            for cookie in fresh {
                cookies.removeAll { $0.name == cookie.name }
                cookies.append(cookie)
            }
        }
        let json = result.0.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        guard (200 ..< 300).contains(status) else {
            throw NSError(domain: "SettingsTestAPI", code: status, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path) → \(status) \(json?["message"] ?? "")"])
        }
        return json?["data"]
    }

    func getObject(_ path: String) throws -> [String: Any] {
        try request("GET", path) as? [String: Any] ?? [:]
    }

    func getArray(_ path: String) throws -> [[String: Any]] {
        try request("GET", path) as? [[String: Any]] ?? []
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        // 光标放到末尾再删（输入框右对齐，点中心会把光标落在文字前面）
        coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        if let current = value as? String, !current.isEmpty, current != placeholderValue {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        typeText(text)
    }

    func waitForSelected(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isSelected == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
