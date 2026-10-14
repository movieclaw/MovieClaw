import XCTest

/// AI 会话模块的端到端验收。
///
/// 服务器是用户正在使用的真实 MovieClaw，智能体有真实的写能力（订阅、下载、改配置），因此硬规则：
/// - 每次点击前都经 `safeTap`：断言目标存在、`isHittable`、且不与底部标签栏重叠，否则用例直接失败；
/// - 用户已有的历史会话只读展示：不发消息、不改写、不重命名、不删除（历史会话里连「改写这条提问」都不点）；
/// - 只有 `testLiveSessionStreamRetryAndStop` 会真实发消息（最多 2 条、都是明确写了「只查询」的只读问题），
///   它会消耗模型额度，默认跳过，显式设置 `MC_ALLOW_AGENT_LIVE=1` 才跑；结束后删除它自己创建的会话；
/// - 新任务页的菜单用例只打开菜单、不发送。
///
/// 环境变量（scripts/test.sh 以 TEST_RUNNER_ 前缀转交）：MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD；
/// 截图落盘目录 MC_SHOT_DIR（可选）。
final class AgentUITests: XCTestCase {
    @MainActor
    func testChatGPTDisconnectNoticeIsVisible() throws {
        guard env["MC_ISOLATED_CHATGPT_QA"] == "1", server == "http://127.0.0.1:3018" else {
            throw XCTSkip("仅允许隔离的 ChatGPT QA 服务")
        }
        let credentials = #"{"client_id":"oaiapp_qa","subject":"qa","email":"qa@example.invalid","ext_agent_host_id":"urn:uuid:qa","access_token":"qa-access","refresh_token":"qa-refresh","scopes":["chatgpt.tokens.use.direct"],"expires_at":2100000000}"#
        let provider = try XCTUnwrap(backend.request("POST", "/llm/providers", body: [
            "name": "ChatGPT disconnect QA", "provider_type": "chatgpt", "api_key": credentials,
            "default_model": "qa-model", "extra_models": [["id": "qa-model", "context_window": 8192, "max_output_tokens": 2048]],
        ]) as? [String: Any])
        let id = try XCTUnwrap(provider["id"] as? Int)
        defer { backend.request("DELETE", "/llm/providers/\(id)") }
        let app = launch(route: "/settings/llm")
        XCTAssertTrue(app.staticTexts["qa@example.invalid"].waitForExistence(timeout: 15))
        safeTap(app, app.buttons["llm-provider-\(id)"], "ChatGPT QA 接入")
        safeTap(app, app.buttons["llm-provider-actions"], "接入操作")
        safeTap(app, app.buttons["llm-delete-\(id)"], "删除 QA 接入")
        safeTap(app, app.alerts.buttons["删除"], "确认删除 QA 接入")
        XCTAssertTrue(app.alerts["ChatGPT 接入已移除"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "远端撤销未确认")).firstMatch.exists)
        snapshot("chatgpt-unconfirmed-disconnect-notice")
        safeTap(app, app.alerts.buttons["知道了"], "断开提醒")
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var server: String { env["MC_TEST_SERVER"] ?? "http://localhost:3000" }
    private var username: String { env["MC_TEST_USERNAME"] ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"] ?? "mclaw-dev-2026" }

    private lazy var backend = AgentBackend(server: server, username: username, password: password)
    /// 本用例创建的会话（含派生出的会话），tearDown 里删除
    private var createdSessionIds: [String] = []

    override func tearDown() {
        for id in createdSessionIds.reversed() {
            // 运行中的会话服务端拒绝删除：等它结束（最多 2 分钟）
            for _ in 0 ..< 60 {
                let summary = backend.request("GET", "/sessions/\(id)") as? [String: Any]
                if (summary?["session"] as? [String: Any])?["running"] as? Bool != true { break }
                Thread.sleep(forTimeInterval: 2)
            }
            backend.request("DELETE", "/sessions/\(id)")
            print("已删除测试会话 \(id)")
        }
        super.tearDown()
    }

    // MARK: 启动与工具

    @MainActor
    private func launch(route: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password, "-mcRoute", route]
        app.launch()
        return app
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

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 唯一的点击入口：存在、可点、未被标签栏遮挡，才点
    @MainActor
    private func safeTap(_ app: XCUIApplication, _ target: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(target.waitForExistence(timeout: 15), "找不到「\(what)」", file: file, line: line)
        XCTAssertTrue(target.isHittable, "「\(what)」不可点（被遮挡或在屏幕外）", file: file, line: line)
        let bar = app.tabBars.firstMatch
        if bar.exists, bar.isHittable {
            XCTAssertFalse(bar.frame.intersects(target.frame), "「\(what)」与底部标签栏重叠，拒绝按坐标点击", file: file, line: line)
        }
        target.tap()
    }

    /// 长按气泡呼出原生菜单（复制 / 改写都只在这里）。气泡被顶到顶栏下面时先往回拉
    @MainActor
    private func longPressBubble(_ app: XCUIApplication, _ bubble: XCUIElement) {
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "找不到气泡")
        for _ in 0 ..< 10 where bubble.frame.minY < 120 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        }
        XCTAssertTrue(bubble.isHittable, "气泡不可点")
        // 点在右下角的文字区：提问气泡中央可能是图片缩略图
        bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).press(forDuration: 1.0)
    }

    /// 把目标轻扫到底部输入区之上（最多 10 次），避免按坐标点到输入框
    @MainActor
    private func scrollAboveComposer(_ app: XCUIApplication, _ target: XCUIElement) {
        let composerTop = element(app, "agent-composer-input").frame.minY - 60
        for _ in 0 ..< 10 {
            if target.isHittable, target.frame.maxY < composerTop, target.frame.minY > 120 { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        XCTAssertLessThan(target.frame.maxY, composerTop, "目标被底部输入区遮挡")
    }

    /// 点空白处收起弹层（点在顶栏下方的空白区，弹层都锚在底部输入框上方，不会点进弹层）
    @MainActor
    private func dismissPopover(_ app: XCUIApplication, _ panel: XCUIElement) {
        for _ in 0 ..< 3 where panel.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14)).tap()
            _ = panel.waitForNonExistence(timeout: 2)
        }
        XCTAssertFalse(panel.exists, "弹层没有收起")
    }

    /// 沉浸式：会话页与新任务页不显示标签栏
    @MainActor
    private func assertTabBarHidden(_ app: XCUIApplication) {
        let bar = app.tabBars.firstMatch
        XCTAssertFalse(bar.exists && bar.isHittable, "沉浸页不应显示标签栏")
    }

    // MARK: 历史会话只读展示

    /// 选一个内容丰富的历史会话（有行内媒体卡片，最好还带图片），只读展示：
    /// 转录、处理过程折叠、工具调用展开、气泡操作浮现、回到最新消息按钮。
    @MainActor
    func testHistorySessionReadOnlyShowcase() throws {
        let id = try XCTUnwrap(backend.richSessionId(), "服务器上没有带媒体卡片的历史会话，无法做只读展示")
        let app = launch(route: "/sessions/\(id)")

        let bubble = app.descendants(matching: .any).matching(identifier: "agent-user-bubble").firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 30), "会话转录没有加载出来")
        assertTabBarHidden(app)
        XCTAssertTrue(element(app, "agent-composer-input").exists, "底部输入框缺失")
        XCTAssertTrue(element(app, "agent-send").exists, "发送键缺失")
        snapshot("agent-history-bottom")

        // 卡片组（生成式 UI）
        XCTAssertTrue(element(app, "agent-media-cards").waitForExistence(timeout: 20), "行内媒体卡片没有渲染")

        // 回到顶部：离开底部后出现「回到最新消息」
        let scroll = app.scrollViews.firstMatch
        for _ in 0 ..< 25 { scroll.swipeDown(velocity: .fast) }
        snapshot("agent-history-top")
        let latest = element(app, "agent-scroll-latest")
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "离开底部后应出现「回到最新消息」")

        // 首条提问：长按出菜单（复制 + 改写；历史会话不点改写），气泡下方不常驻任何按钮
        let firstBubble = app.descendants(matching: .any).matching(identifier: "agent-user-bubble").firstMatch
        longPressBubble(app, firstBubble)
        XCTAssertTrue(app.buttons["复制"].waitForExistence(timeout: 5), "长按提问气泡应出现「复制」")
        XCTAssertTrue(app.buttons["改写这条提问"].exists, "长按提问气泡应出现「改写这条提问」")
        snapshot("agent-history-question-menu")
        safeTap(app, app.buttons["复制"], "复制提问")
        XCTAssertTrue(app.buttons["复制"].waitForNonExistence(timeout: 5), "点复制后菜单应收起")

        // 回答气泡：长按只有「复制」
        let answer = app.descendants(matching: .any).matching(identifier: "agent-answer-bubble").firstMatch
        scrollAboveComposer(app, answer)
        longPressBubble(app, answer)
        XCTAssertTrue(app.buttons["复制"].waitForExistence(timeout: 5), "长按回答气泡应出现「复制」")
        XCTAssertFalse(app.buttons["改写这条提问"].exists, "回答气泡不该有改写")
        snapshot("agent-history-answer-menu")
        safeTap(app, app.buttons["复制"], "复制回答")
        XCTAssertTrue(app.buttons["复制"].waitForNonExistence(timeout: 5), "点复制后菜单应收起")

        // 多段回答（列表 + 引用）：普通长度是一整个气泡，按它的中下部，浮起来的应是整个气泡（看截图）
        let answers = app.descendants(matching: .any).matching(identifier: "agent-answer-bubble")
        if answers.count > 1 {
            let middle = answers.element(boundBy: 1)
            scrollAboveComposer(app, middle)
            longPressBubble(app, middle)
            XCTAssertTrue(app.buttons["复制"].waitForExistence(timeout: 5), "长按多段回答的中间一截应出现「复制」")
            snapshot("agent-history-answer-menu-multi")
            safeTap(app, app.buttons["复制"], "复制多段回答")
            XCTAssertTrue(app.buttons["复制"].waitForNonExistence(timeout: 5), "点复制后菜单应收起")
        }

        // 处理过程胶囊（AgentTranscriptLayout.showsProcess，目前隐藏）：显示时挑含工具调用的那个 → 展开 → 展开一次工具调用
        let toggle = app.buttons.matching(identifier: "agent-process-toggle")
            .matching(NSPredicate(format: "label CONTAINS '命令' OR label CONTAINS '工具'")).firstMatch
        if toggle.exists {
            scrollAboveComposer(app, toggle)
            safeTap(app, toggle, "处理过程折叠块")
            let tool = element(app, "agent-tool-row")
            XCTAssertTrue(tool.waitForExistence(timeout: 5), "展开处理过程后应列出工具调用")
            scrollAboveComposer(app, tool)
            safeTap(app, tool, "工具调用行")
            snapshot("agent-history-tool-expanded")
        }

        // 逐屏往下截图（对照网页）
        for i in 0 ..< 6 {
            scroll.swipeUp(velocity: .slow)
            snapshot("agent-history-page-\(i)")
        }

        safeTap(app, element(app, "agent-scroll-latest"), "回到最新消息")
        XCTAssertTrue(element(app, "agent-scroll-latest").waitForNonExistence(timeout: 10), "回到最新消息后按钮应收起")
    }

    // MARK: 「我的」页的一行输入框（真实发消息，默认跳过）

    @MainActor
    func testQuickBarShowsModelControlsOnlyAfterExpansion() {
        let app = launch(route: "/my")
        let entry = element(app, "agent-quick-entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        XCTAssertFalse(element(app, "agent-model-menu").exists, "未展开入口应保持小框")
        safeTap(app, entry, "新会话快捷入口")
        let model = element(app, "agent-model-menu")
        XCTAssertTrue(model.waitForExistence(timeout: 20), "第一条消息前应能选择模型")
        safeTap(app, model, "模型与思考强度")
        XCTAssertTrue(element(app, "agent-model-panel").waitForExistence(timeout: 5))
        snapshot("quick-model-menu-before-first-message")
    }

    /// 「我的」根页：平时标签栏附件是一行输入框（下滑跟着标签栏收起）；点它附件让位、同一位置换上真输入框跟着键盘上去，
    /// 收键盘落回原位再换回附件——全程只有一个输入框。加号原地弹加号菜单，选的技能落在托盘里；发送 = 新建会话并进入。
    /// 共发 1 条只读消息，结束后删除本会话。
    @MainActor
    func testQuickBarStartsSession() throws {
        try XCTSkipUnless(env["MC_ALLOW_AGENT_LIVE"] == "1", "会消耗模型额度，需显式设置 MC_ALLOW_AGENT_LIVE=1")
        let marker = String(UUID().uuidString.prefix(6))
        let app = launch(route: "/my")
        let entry = element(app, "agent-quick-entry")
        let inputs = app.descendants(matching: .any).matching(identifier: "agent-composer-input")
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "「我的」页标签栏上方应有一行输入框")
        XCTAssertEqual(inputs.count, 0, "平时只有附件里的入口")
        XCTAssertFalse(app.buttons["more-new-session"].exists, "有一行输入框后列表里不再放「新会话」")
        let restY = element(app, "agent-quick-entry-plus").frame.midY
        snapshot("agent-quick-bar")

        // 点它：附件让位，真输入框跟着键盘上去，屏幕上只有它一个
        safeTap(app, entry, "一行输入框")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "点输入框应弹出键盘")
        sleep(1)
        XCTAssertEqual(inputs.count, 1, "打字时只应有一个输入框")
        XCTAssertFalse(entry.exists, "打字时附件应让位")
        XCTAssertTrue(element(app, "agent-model-menu").exists, "展开后应能在发送第一条消息前选模型和档位")
        let input = inputs.firstMatch
        XCTAssertLessThan(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "输入框应在键盘之上")
        snapshot("agent-quick-focused")

        // 往下拖收键盘：落回原位、换回附件，仍只有一个
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "往下拖应收起键盘")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "收起键盘后应换回附件")
        XCTAssertEqual(inputs.count, 0, "收起键盘后只剩附件")
        XCTAssertEqual(element(app, "agent-quick-entry-plus").frame.midY, restY, accuracy: 1, "附件回到原位")
        snapshot("agent-quick-dismissed")

        // 附件上的加号：原地换上真输入框并弹出加号菜单，选的技能落在托盘里
        safeTap(app, element(app, "agent-quick-entry-plus"), "一行输入框的加号")
        XCTAssertTrue(element(app, "agent-plus-menu").waitForExistence(timeout: 10), "加号应原地弹出加号菜单")
        snapshot("agent-quick-plus-menu")
        let skill = app.buttons.matching(NSPredicate(format: "label CONTAINS 'skill-creator'")).firstMatch
        XCTAssertTrue(skill.waitForExistence(timeout: 10), "加号菜单里应列出技能")
        skill.tap()
        XCTAssertTrue(app.staticTexts["⚡ skill-creator"].waitForExistence(timeout: 5), "选中的技能应落在托盘里")

        // 打字发送：新建会话并进入
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        safeTap(app, input, "输入框")
        input.typeText("Q\(marker) 只查询，不要做任何修改：我有哪些媒体库")
        snapshot("agent-quick-typing")
        safeTap(app, element(app, "agent-send"), "发送键")
        let agree = element(app, "agent-consent-agree")
        if agree.waitForExistence(timeout: 1) { safeTap(app, agree, "同意") }
        let bubble = app.descendants(matching: .any).matching(identifier: "agent-user-bubble").firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 30), "发送后应进入新会话")
        let sessionId = try XCTUnwrap(backend.sessionId(containing: marker), "服务端没有找到本用例创建的会话")
        createdSessionIds.append(sessionId)
        XCTAssertTrue(app.staticTexts["⚡ skill-creator"].exists, "提问应带着选中的技能")
        XCTAssertTrue(element(app, "agent-stop").waitForNonExistence(timeout: 300), "五分钟内没有等到本轮完成")
        XCTAssertTrue(element(app, "agent-group-time").exists, "对话组顶部应有时间")
        snapshot("agent-quick-session")
    }

    // MARK: 「我的」页下滑收起标签栏（只读）

    /// 从媒体库点头像页签进「我的」，第一次下滑标签栏就该收起，一行输入框跟着缩进标签栏那一行。
    /// 回归保护（2026-10-13）：会话输入框的预热挂在背景时，标签栏把它当成主滚动视图，拆掉后就再也不收起，
    /// 要等附件开关过一次（点一次输入框）才好。会话少到滑不动时跳过
    @MainActor
    func testMoreTabBarMinimizesOnFirstScroll() throws {
        try XCTSkipUnless(backend.sessionCount() >= 10, "会话太少，「我的」页滑不动")
        let app = launch(route: "/library")
        // 头像页签在最右（iOS 27 模拟器上按 open-more 标识找不到标签栏按钮，按位置取）
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        let buttons = app.tabBars.buttons
        buttons.element(boundBy: buttons.count - 1).tap()
        let entry = element(app, "agent-quick-entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "「我的」页标签栏上方应有一行输入框")
        sleep(2)  // 让会话输入框的预热建完又拆掉
        let rest = entry.frame
        XCTAssertGreaterThan(app.tabBars.buttons.count, 1)
        app.collectionViews.firstMatch.swipeUp(velocity: .default)
        sleep(2)
        XCTAssertEqual(app.tabBars.buttons.count, 1, "第一次下滑标签栏就应收起")
        XCTAssertGreaterThan(entry.frame.midY, rest.midY, "一行输入框应跟着缩进标签栏那一行")
        snapshot("agent-quick-minimized")
    }

    /// 「我的」下面的子页面（服务器设置等）标签栏上方也是 AI 一行输入框，不是「接着看」（2026-10-13 用户要求）；
    /// 在子页面里点它，同样原地换上跟键盘走的真输入框，收键盘换回附件（不发送）
    @MainActor
    func testQuickBarOnMoreSubpages() {
        let app = launch(route: "/my")
        let settings = element(app, "more-settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        safeTap(app, settings, "服务器设置")
        sleep(1)
        let entry = element(app, "agent-quick-entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "「我的」子页面标签栏上方应是 AI 一行输入框")
        XCTAssertFalse(element(app, "resume-accessory").exists, "子页面不该是「接着看」")
        safeTap(app, entry, "一行输入框")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "点输入框应弹出键盘")
        let input = element(app, "agent-composer-input")
        XCTAssertTrue(input.exists && !entry.exists, "子页面里打字时也是真输入框接替附件")
        XCTAssertLessThan(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "输入框应在键盘之上")
        snapshot("agent-quick-subpage-focused")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "往下拖应收起键盘")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "收起键盘后应换回附件")
    }

    // MARK: 翻到上面再发消息：回到最新（真实发消息，默认跳过）

    /// 长对话翻到上面时发出新消息，要跳到最新并跟着回答走（2026-10-13 用户反馈：之前停在原处不动）。
    /// 先发 3 条撑出几屏，翻到顶，再发第 4 条。共发 4 条只读消息，结束后删除本会话。
    @MainActor
    func testSendWhileScrolledUpJumpsToLatest() throws {
        try XCTSkipUnless(env["MC_ALLOW_AGENT_LIVE"] == "1", "会消耗模型额度，需显式设置 MC_ALLOW_AGENT_LIVE=1")
        let marker = String(UUID().uuidString.prefix(6))
        let app = launch(route: "/new")
        let input = element(app, "agent-composer-input")
        XCTAssertTrue(input.waitForExistence(timeout: 20))

        func ask(_ index: Int) {
            safeTap(app, input, "输入框")
            input.typeText("S\(marker)-\(index) 只查询，不要做任何修改：列出媒体库最近入库的 3 部电影")
            safeTap(app, element(app, "agent-send"), "发送")
            let agree = element(app, "agent-consent-agree")
            if agree.waitForExistence(timeout: 1) { safeTap(app, agree, "同意") }
        }
        for index in 1 ... 3 {
            ask(index)
            if index == 1 {
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "agent-user-bubble").firstMatch.waitForExistence(timeout: 30))
                createdSessionIds.append(try XCTUnwrap(backend.sessionId(containing: marker)))
            }
            XCTAssertTrue(element(app, "agent-send").waitForExistence(timeout: 300), "第 \(index) 轮没跑完")
        }

        // 翻到顶：离开了底部（键盘开着时第一个 scrollView 不一定是消息列，按坐标在消息区里拖）
        for _ in 0 ..< 10 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        let latest = element(app, "agent-scroll-latest")
        snapshot("agent-scrolled-up-before-send")
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "翻到上面后应出现「回到最新消息」")

        // 在上面发第 4 条：跳到最新，刚发的提问就在眼前
        ask(4)
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5), "发出后应跳到最新（不再显示「回到最新消息」）")
        let question = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "S\(marker)-4")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        let composerTop = input.frame.minY
        XCTAssertTrue(question.frame.maxY < composerTop && question.frame.minY > 0, "刚发的提问应在屏幕里、输入框之上")
        snapshot("agent-scrolled-up-after-send")

        // 回答流式写完后仍停在底部
        XCTAssertTrue(element(app, "agent-send").waitForExistence(timeout: 300), "第 4 轮没跑完")
        sleep(1)
        XCTAssertFalse(latest.exists, "回答写完后应仍停在最新")
        snapshot("agent-scrolled-up-answer-done")
    }

    // MARK: 新任务页的菜单（不发送）

    @MainActor
    func testNewSessionComposerMenus() {
        let app = launch(route: "/new")
        let input = element(app, "agent-composer-input")
        XCTAssertTrue(input.waitForExistence(timeout: 20), "新任务页缺少输入框")
        XCTAssertTrue(app.navigationBars["新会话"].waitForExistence(timeout: 5), "顶栏标题应为「新会话」")
        assertTabBarHidden(app)
        XCTAssertFalse(element(app, "agent-send").isEnabled, "空输入时发送键应不可用")

        // 「+」菜单：上传图片 + 使用技能
        safeTap(app, element(app, "agent-composer-plus"), "加号菜单")
        XCTAssertTrue(app.buttons["agent-pick-image"].waitForExistence(timeout: 5), "加号菜单缺少「照片图库」")
        XCTAssertTrue(app.buttons["agent-pick-file"].exists, "加号菜单缺少「选取文件」（同 Web 系统选择器的三种来源）")
        XCTAssertTrue(app.staticTexts["使用技能"].exists, "加号菜单缺少「使用技能」")
        let skill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '⚡'")).firstMatch
        var pickedSkill = false
        if skill.waitForExistence(timeout: 8) {
            snapshot("agent-new-plus-menu")
            safeTap(app, skill, "技能项")
            pickedSkill = true
        } else {
            snapshot("agent-new-plus-menu")
            dismissPopover(app, element(app, "agent-plus-menu"))
        }
        if pickedSkill {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '移除技能'")).firstMatch.waitForExistence(timeout: 5), "选中技能后输入框上方应出现技能 chip")
            XCTAssertTrue(element(app, "agent-send").isEnabled, "有技能时发送键应可用")
        }

        // 模型菜单：模型清单 + 思维链强度
        let model = element(app, "agent-model-menu")
        if model.waitForExistence(timeout: 8) {
            safeTap(app, model, "模型菜单")
            XCTAssertTrue(element(app, "agent-model-panel").waitForExistence(timeout: 5), "模型菜单没有打开")
            let thinking = app.staticTexts["思维链强度"].exists || app.staticTexts["思维链"].exists || app.staticTexts["该模型不支持调节思考强度"].exists
            XCTAssertTrue(thinking, "模型菜单下半缺少思维链控件")
            if app.staticTexts["思维链强度"].exists {
                XCTAssertTrue(app.staticTexts["更快"].exists && app.staticTexts["更聪明"].exists, "滑杆缺少「更快 / 更聪明」轴标签")
            }
            snapshot("agent-new-model-menu")
            dismissPopover(app, element(app, "agent-model-panel"))
        }

        // 「/」技能快选（有技能时弹出）
        safeTap(app, input, "输入框")
        input.typeText("/")
        if pickedSkill {
            XCTAssertTrue(element(app, "agent-slash-menu").waitForExistence(timeout: 8), "输入「/」应弹出技能快选")
        }
        snapshot("agent-new-slash")
    }

    // MARK: 实时流（真实发消息，默认跳过）

    /// 新任务 → 首条消息创建会话并替换路由到会话页 → 实时流（执行中… → 完成）→
    /// 改写这条提问「替换并重新提问」→ 停止。共发 2 条只读消息，结束后删除本会话。
    @MainActor
    func testLiveSessionStreamRetryAndStop() throws {
        try XCTSkipUnless(env["MC_ALLOW_AGENT_LIVE"] == "1", "会消耗模型额度，需显式设置 MC_ALLOW_AGENT_LIVE=1")
        let marker = String(UUID().uuidString.prefix(6))
        let question = "T\(marker) 只查询，不要做任何修改、订阅、下载或删除：列出媒体库最近入库的 3 部电影"

        let app = launch(route: "/new")
        let input = element(app, "agent-composer-input")
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        safeTap(app, input, "输入框")
        input.typeText(question)
        safeTap(app, element(app, "agent-send"), "发送")
        // 本机第一次发给 AI 前要先同意说明（装过并同意过的模拟器不会再问）
        let agree = element(app, "agent-consent-agree")
        if agree.waitForExistence(timeout: 1) { safeTap(app, agree, "同意") }

        // 创建会话后替换路由：顶栏不再是「新会话」，出现用户气泡与执行中
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "agent-user-bubble").firstMatch.waitForExistence(timeout: 30), "发送后没有进入会话页")
        // 运行中的三点气泡只在思考 / 调工具时出现（正文流式时换成气泡里的光标），先看界面再去服务端找会话：
        // 找会话要逐个读会话详情，会话一多就是几十秒，回答快的模型早就跑完了
        let sawRunning = element(app, "agent-turn-running").waitForExistence(timeout: 20)
        if sawRunning { snapshot("agent-live-running") }
        let sessionId = try XCTUnwrap(backend.sessionId(containing: marker), "服务端没有找到本用例创建的会话")
        createdSessionIds.append(sessionId)
        print("创建测试会话 \(sessionId)：\(question)")
        XCTAssertTrue(sawRunning, "运行中应显示「正在输入」的三点气泡")
        assertTabBarHidden(app)

        // 跑完的轮次底下不再有页脚：以停止键变回发送键为准
        XCTAssertTrue(element(app, "agent-stop").waitForNonExistence(timeout: 300), "五分钟内没有等到本轮完成")
        XCTAssertTrue(element(app, "agent-answer-bubble").exists, "跑完应有回答气泡")
        snapshot("agent-live-done")

        // 返回键应直接回到进入新任务前的页面（/new 已被替换，不叠两层）
        XCTAssertFalse(app.navigationBars["新会话"].exists)

        // 改写这条提问 → 替换并重新提问 → 立即停止
        let bubble = app.descendants(matching: .any).matching(identifier: "agent-user-bubble").firstMatch
        longPressBubble(app, bubble)
        safeTap(app, app.buttons["改写这条提问"], "改写这条提问")
        XCTAssertTrue(app.staticTexts["正在改写较早的提问，发送后将替换其后的对话"].waitForExistence(timeout: 5), "改写态横幅缺失")
        safeTap(app, input, "输入框")
        input.typeText("（改写：只列 1 部）")
        safeTap(app, element(app, "agent-send"), "发送改写")
        let confirm = app.alerts.buttons["替换并重新提问"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "改写发送前应二次确认")
        confirm.tap()
        let stop = element(app, "agent-stop")
        if stop.waitForExistence(timeout: 15), stop.isHittable {
            snapshot("agent-live-retry-running")
            stop.tap()
            let stopped = element(app, "agent-turn-stopped")
            XCTAssertTrue(stopped.waitForExistence(timeout: 60), "停止后应显示「已停止」")
        }
        snapshot("agent-live-stopped")

        // 派生（不启动模型）：新会话顶部是来源卡片「已从…续接上下文」
        let forked = try XCTUnwrap(backend.fork(sessionId), "派生会话失败")
        createdSessionIds.append(forked)
        print("派生测试会话 \(forked)（来源 \(sessionId)）")
        app.terminate()
        let forkedApp = launch(route: "/sessions/\(forked)")
        XCTAssertTrue(element(forkedApp, "agent-handoff").waitForExistence(timeout: 30), "派生会话缺少来源卡片")
        snapshot("agent-live-handoff")
    }
}

/// 直连后端的只读查询（选历史会话、找本用例创建的会话）与清理
private final class AgentBackend {
    let base: String
    let session: URLSession

    init(server: String, username: String, password: String) {
        base = server.hasSuffix("/") ? String(server.dropLast()) : server
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config)
        _ = request("POST", "/auth/login", body: ["username": username, "password": password, "remember": true])
    }

    @discardableResult
    func request(_ method: String, _ path: String, body: Any? = nil) -> Any? {
        var request = URLRequest(url: URL(string: base + "/api/v1" + path)!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Any?
        session.dataTask(with: request) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { result = json["data"] }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        return result
    }

    private func sessions() -> [[String: Any]] {
        request("GET", "/sessions?limit=50") as? [[String: Any]] ?? []
    }

    /// 有 show_media_cards 卡片（优先同时带图片附件）的历史会话
    /// 只用卡片的会话里挑最长的（只读展示要能翻好几屏；最新的那条可能只有一轮）
    func richSessionId() -> String? {
        var fallback: (id: String, entries: Int)?
        for summary in sessions() where summary["running"] as? Bool != true {
            guard let id = summary["id"] as? String,
                  let detail = request("GET", "/sessions/\(id)") as? [String: Any],
                  let entries = detail["entries"] as? [[String: Any]] else { continue }
            var cards = false
            var image = false
            for entry in entries {
                guard let message = entry["message"] as? [String: Any] else { continue }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] where (call["name"] as? String)?.hasPrefix("show_media_cards") == true {
                    cards = true
                }
                for part in message["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "image" {
                    image = true
                }
            }
            if cards, image { return id }
            if cards, entries.count > (fallback?.entries ?? 0) { fallback = (id, entries.count) }
        }
        return fallback?.id
    }

    /// 会话数（只读）
    func sessionCount() -> Int { sessions().count }

    /// 从源会话派生独立新会话（不触发模型运行），返回新会话 id
    func fork(_ id: String) -> String? {
        ((request("POST", "/sessions/\(id)/fork") as? [String: Any])?["session"] as? [String: Any])?["id"] as? String
    }

    /// 本用例创建的会话（按提问里的随机标记找）
    func sessionId(containing marker: String) -> String? {
        for _ in 0 ..< 10 {
            if let hit = sessions().first(where: { ($0["last_prompt"] as? String ?? "").contains(marker) || ($0["title"] as? String ?? "").contains(marker) }) {
                return hit["id"] as? String
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }
}
