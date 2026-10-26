import XCTest

/// 大库海报墙（docs/design/tvos-app.md §3.1）：焦点片名暗带、索引条跳转、按住滚动的位置提示、筛选与筛空、详情返回原位。
///
/// 要一个几千部的库才看得出效果，夹具里没有现成的：没设 `MC_TEST_BIG_LIBRARY`（库 id）就跳过。
/// 其余环境变量同 `TVFlowUITests`：MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD，MC_SHOT_DIR 存截图。
final class TVBigLibraryUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var server: String { env["MC_TEST_SERVER"] ?? "http://127.0.0.1:8790" }
    private var username: String { env["MC_TEST_USERNAME"] ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"] ?? "mclaw-tv-2026" }

    override func setUp() {
        continueAfterFailure = false
    }

    /// 进大库的海报墙。sortByTitle：按标题排序进来（经启动参数写进本机记忆的排序，同「排序与筛选」里选了 A–Z）
    @MainActor
    private func launchWall(sortByTitle: Bool = false) throws -> XCUIApplication {
        guard let library = env["MC_TEST_BIG_LIBRARY"] else { throw XCTSkip("没有大库夹具（MC_TEST_BIG_LIBRARY）") }
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", server, "-mcUser", username, "-mcPass", password,
                               "-mcTab", "library-\(library)"]
        // 排序与「只看没看过的」按库记在本机，--reset-state 不清它们：显式给定，不吃上一轮留下的状态
        app.launchArguments += ["-movieclaw.tv.wall-sort.\(library).unwatched", "NO"]
        if sortByTitle {
            // WallSortState 的 JSON（{"sort":"title","reversed":false}），参数域按属性列表的 <十六进制> 读成 Data
            app.launchArguments += ["-movieclaw.tv.wall-sort.\(library)",
                                    "<7b22736f7274223a227469746c65222c227265766572736564223a66616c73657d>"]
        }
        app.launch()
        XCTAssertTrue(app.element("tv-library-\(library)").waitForExistence(timeout: 20))
        XCTAssertTrue(waitForFocus(posters(app).firstMatch, timeout: 15), "海报墙的第一张没有拿到焦点")
        return app
    }

    // MARK: 用例

    /// 焦点暗带 → 按住往下滚（位置提示）→ 索引条跳到 S → 进详情再返回、焦点回原处
    @MainActor
    func testFocusBandRailJumpAndReturn() throws {
        let app = try launchWall(sortByTitle: true)
        XCTAssertTrue(app.element("tv-rail-A").waitForExistence(timeout: 15), "按标题排序时没有索引条")
        TVRemote.press(.right)
        usleep(800_000)
        snapshot("01-focus-band")

        // 按住往下：焦点连续往下走，屏幕中央浮出当前所在的档。提示松手约一秒就收起，
        // 而长按要等应用空闲才返回，这里只留截图，提示本身靠录屏逐帧核对
        XCUIRemote.shared.press(.down, forDuration: 3)
        snapshot("02-hold-scroll")

        // 一路按右键到最右一列，再按一下进索引条：落在当前所在的档上（松手时焦点停在哪一列不定，按到进条为止）
        var focusedRail = focused(app)
        for _ in 0 ..< 6 where !focusedRail.identifier.hasPrefix("tv-rail-") {
            TVRemote.press(.right)
            usleep(500_000)
            focusedRail = focused(app)
        }
        snapshot("03-rail-entered")
        XCTAssertTrue(focusedRail.identifier.hasPrefix("tv-rail-"), "最右一列按右键没有进到索引条（焦点在 \(focusedRail.identifier)）")

        let target = app.element("tv-rail-S")
        TVRemote.focus(target, trying: [.down, .up], limit: 26)
        usleep(500_000)
        snapshot("04-rail-S")
        TVRemote.press(.select)
        // 跳过去时屏幕中央浮出这一档（与按住滚动时同一个位置提示），约一秒后收起
        let hud = app.element("tv-wall-hud")
        let hudShown = hud.waitForExistence(timeout: 2)
        snapshot("05a-jump-hud")
        XCTAssertTrue(hudShown, "跳转时没有出现位置提示")
        usleep(1_500_000)
        snapshot("05-jumped-S")
        let poster = focusedPoster(app)
        XCTAssertTrue(poster.exists, "跳转之后焦点没有落在海报上")

        // 往上走一排：前面一页已经补回来了，不会撞到「没有了」
        TVRemote.press(.up)
        usleep(800_000)
        XCTAssertTrue(focusedPoster(app).exists, "跳转后往上一排没有海报")
        snapshot("06-after-jump-up")
        TVRemote.press(.down)
        usleep(800_000)
        let back = focusedPoster(app).identifier

        TVRemote.press(.select)
        XCTAssertTrue(app.element("tv-item-play").waitForExistence(timeout: 15), "没有进入详情页")
        snapshot("07-detail")
        TVRemote.press(.menu)
        XCTAssertTrue(waitForFocus(app.element(back), timeout: 10), "从详情返回焦点没有回到原来那张（\(back)）")
        snapshot("08-returned")
    }

    /// 「排序与筛选」：按上映排序（索引条变年份）→ 类型「西部」、画质「4K」→ 只看没看过的 → 筛空给出放宽建议 → 按一下放宽。
    ///
    /// 系统菜单里谁有焦点在 XCUITest 里读不出来（截图上焦点正常），菜单项按位置盲按：
    /// 主菜单 0 最近添加 / 1 最近上映 / 2 评分最高 / 3 A–Z / 4 只看没看过的 / 5 类型 / 6 年代 / 7 画质；
    /// 二级菜单 0 是「全部」，其后按部数从多到少。结果用标题旁的条件摘要与筛空页核对
    @MainActor
    func testSortFilterAndRelax() throws {
        let app = try launchWall()
        openSortMenu(app)
        pickMenuItem(1)
        XCTAssertTrue(app.element("tv-rail-2025").waitForExistence(timeout: 15), "按上映排序时没有年份索引条")
        usleep(1_000_000)
        TVRemote.press(.down)
        TVRemote.press(.right, times: 5)
        usleep(800_000)
        snapshot("11-rail-years")
        TVRemote.press(.left)
        usleep(500_000)

        openSortMenu(app)
        pickMenuItem(5, select: true)
        usleep(800_000)
        snapshot("12-genre-menu")
        // 类型按部数从多到少，夹具里西部片最少，按到底就是它
        TVRemote.press(.down, times: 20)
        TVRemote.press(.select)
        XCTAssertTrue(waitForSubtitle(app, containing: "西部"), "选了类型后标题旁没有条件摘要")

        openSortMenu(app, fromGrid: false)
        pickMenuItem(7, select: true)
        usleep(800_000)
        snapshot("13-quality-menu")
        // 西部片里 1080p 最多、4K 其次
        TVRemote.press(.down, times: 2)
        TVRemote.press(.select)
        XCTAssertTrue(waitForSubtitle(app, containing: "4K"), "选了画质后标题旁没有「4K」")
        usleep(1_000_000)
        snapshot("14-filtered")

        openSortMenu(app, fromGrid: false)
        pickMenuItem(4)
        XCTAssertTrue(app.element("tv-wall-empty").waitForExistence(timeout: 15), "筛空时没有放宽建议")
        usleep(1_000_000)
        snapshot("15-empty-relax")
        let relax = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '去掉“西部”'")).firstMatch
        XCTAssertTrue(relax.exists, "没有「去掉“西部”可看…部」的建议")
        // 往下进到建议那一排，再按到最左边：第一条救回最多的（去掉“西部”）
        TVRemote.press(.down)
        usleep(600_000)
        TVRemote.select(relax, by: .left, limit: 4)
        XCTAssertTrue(posters(app).firstMatch.waitForExistence(timeout: 15), "放宽之后墙上还是空的")
        XCTAssertTrue(waitForSubtitle(app, containing: "4K · 未看"), "放宽只该去掉「西部」，其余条件应保留")
        XCTAssertFalse(app.element("tv-wall-subtitle").label.contains("西部"), "放宽之后标题里还有「西部」")
        usleep(1_500_000)
        snapshot("16-after-relax")
    }

    // MARK: 工具

    private func posters(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv-poster-'"))
    }

    /// 从第一排按上键到「排序与筛选」、按确认打开菜单。
    /// 系统 Menu 按钮的焦点读不出来（模拟器截图上它已经白底高亮，`hasFocus` 与「谁有焦点」的查询仍然落空），
    /// 所以不等焦点，改为按下之后确认菜单项出现了
    @MainActor
    private func openSortMenu(_ app: XCUIApplication, fromGrid: Bool = true,
                              file: StaticString = #filePath, line: UInt = #line) {
        if fromGrid {
            TVRemote.press(.up)
            usleep(600_000)
        }
        // 上一个菜单收起的过渡动画里按确认会被系统忽略：等一会儿，没打开就再按一次
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == '只看没看过的'")).firstMatch
        for _ in 0 ..< 3 {
            usleep(800_000)
            TVRemote.press(.select)
            if item.waitForExistence(timeout: 3) { return }
        }
        XCTFail("「排序与筛选」菜单没有打开", file: file, line: line)
    }

    /// 现在拿着焦点的按钮（海报、索引条的档都是按钮；按任意类型找会连外层容器一起匹配上）
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    /// 菜单里按位置挑一项：先按上到顶（到顶不循环），再往下 index 下，按确认
    @MainActor
    private func pickMenuItem(_ index: Int, select: Bool = true) {
        TVRemote.press(.up, times: 9)
        TVRemote.press(.down, times: index)
        usleep(300_000)
        if select { TVRemote.press(.select) }
    }

    @MainActor
    private func waitForSubtitle(_ app: XCUIApplication, containing text: String, timeout: TimeInterval = 15) -> Bool {
        let subtitle = app.element("tv-wall-subtitle")
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if subtitle.exists, subtitle.label.contains(text) { return true }
            usleep(300_000)
        }
        return false
    }

    /// 等某张海报拿到焦点（程序交焦点要一点时间），返回它；超时返回一个不存在的元素
    @MainActor
    private func focusedPoster(_ app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement {
        let query = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH 'tv-poster-'"))
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if query.count > 0 { return query.firstMatch }
            usleep(250_000)
        }
        return query.firstMatch
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.exists, element.hasFocus { return true }
            usleep(200_000)
        }
        return element.hasFocus
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
}
