import XCTest

/// 离线下载的下载顺序与「优先下载」端到端验收（docs/design/offline-download.md §5.5）：真 App、真服务器、真片源。
///
/// App 连一个限速、记请求日志的代理（`MC_PRIORITY_PROXY`，默认 http://127.0.0.1:18970），代理后面是服务器。
/// 测试经它的控制口（`MC_PRIORITY_CONTROL`，默认 http://127.0.0.1:18971）给下载内容限速（POST /mode {"rate": 字节每秒}），
/// 读请求日志（GET /log：每个请求的开始时间、路径、Range、发了多少字节、有没有中途断开），据此核对谁先下、被打断的是不是续传。
/// 台子（不入库）：电影库 1 部 141 MB 的 mp4（条目 1、文件 1），剧集库 1 部剧 3 集各 64 MB 的 mkv（条目 2、文件 2～4）；
/// 账号默认 admin / mcoffline123（`MC_TEST_USERNAME` / `MC_TEST_PASSWORD`）。
final class OfflinePriorityUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var proxy: String { env["MC_PRIORITY_PROXY"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:18970" }
    private var control: String { env["MC_PRIORITY_CONTROL"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:18971" }
    private var username: String { env["MC_TEST_USERNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "admin" }
    private var password: String { env["MC_TEST_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 } ?? "mcoffline123" }
    private let movieId = 1
    private let movieFile = 1
    private let showId = 2
    /// 第 1～3 集的文件号
    private let episodeFiles = [2, 3, 4]

    override func setUp() {
        continueAfterFailure = false
        setRate(0)
    }

    override func tearDown() {
        setRate(0)
    }

    // MARK: 用例

    /// 整季 + 一部电影排队 → 电影详情页状态条「优先下载」→ 电影立刻开始、正在下的那集让路 →
    /// 下载页第 3 集行首轻扫「优先下载」→ 第 3 集先下 → 全部下完；被打断的两个都是续传（不从头下）
    @MainActor
    func test1PrioritizeInterruptsAndResumes() throws {
        setRate(1_000_000)
        clearLog()
        let app = launch(route: "/library/2/item/\(showId)", then: "/library/1/item/\(movieId)", thenDelay: 30)
        downloadWholeSeason(app)
        XCTAssertTrue(waitUntil(timeout: 30) { self.started(self.episodeFiles[0]) }, "第 1 集应先开始下")

        // 第二个页面（电影）到点自己打开：下原画，排在三集后面
        let bar = app.buttons["item-download"]
        let movieTitle = app.staticTexts.matching(NSPredicate(format: "identifier == 'item-title' AND label == '大雄兔'")).firstMatch
        XCTAssertTrue(movieTitle.waitForExistence(timeout: 60), "应切到电影详情")
        downloadMovie(app)
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { bar.label.contains("前面还有") }, "电影应在排队：\(bar.label)")
        snapshot("p1-movie-queued")

        // 状态条菜单：「优先下载」在「暂停」上面
        bar.tap()
        let prioritize = app.buttons["优先下载"]
        XCTAssertTrue(prioritize.waitForExistence(timeout: 5), app.debugDescription)
        snapshot("p2-capsule-menu")
        let firstTap = Date().timeIntervalSince1970
        prioritize.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.startedAfter(firstTap).first == self.movieFile },
                      "优先后电影应立刻开始：\(contentLog())")
        XCTAssertTrue(waitUntil(timeout: 20) { bar.label.hasPrefix("下载中") }, "状态条应变成下载中：\(bar.label)")
        let interrupted = contentRequests().filter { $0.aborted && $0.start < firstTap }.map(\.file)
        XCTAssertFalse(interrupted.isEmpty, "正在下的那集应被打断让路：\(contentLog())")
        snapshot("p3-movie-downloading")

        // 下载页：第 3 集行首一侧轻扫 →「优先下载」
        openDownloads(app)
        let third = app.descendants(matching: .any)["offline-downloading-\(episodeFiles[2])"]
        XCTAssertTrue(third.waitForExistence(timeout: 20), app.debugDescription)
        reveal(app, third)
        if let yielded = interrupted.first {
            XCTAssertTrue(waitUntil(timeout: 10) { self.rowSays(app, file: yielded, "下一个下载") }, "让路的那集应写「下一个下载」")
        }
        snapshot("p4-downloads-order")
        third.swipeRight()
        let menuItem = app.buttons["优先下载"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "行首一侧轻扫应出「优先下载」")
        snapshot("p5-row-swipe")
        let secondTap = Date().timeIntervalSince1970
        menuItem.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.startedAfter(secondTap).first == self.episodeFiles[2] },
                      "第 3 集应立刻开始：\(contentLog())")
        snapshot("p6-third-first")

        // 放开限速，等全部下完
        setRate(0)
        XCTAssertTrue(waitUntil(timeout: 240) { !self.anyActive(app) }, "应全部下完：\(contentLog())")
        snapshot("p7-all-done")

        // 第二次优先之后的先后：第 3 集 → 电影（续传）→ 被第一次打断的那集（续传，它当时在系统里排着、也被取消重交过）→ 剩下的
        let after = startedAfter(secondTap)
        print("[OfflinePriority] 第二次优先之后的请求顺序：\(after)\n\(contentLog())")
        XCTAssertEqual(after.first, episodeFiles[2])
        XCTAssertEqual(after.dropFirst().first, movieFile, "电影接着下")
        for file in [movieFile] + interrupted {
            let resumed = contentRequests().filter { $0.file == file && $0.start > secondTap }.first
            XCTAssertNotNil(resumed?.rangeStart, "文件 \(file) 应续传：\(contentLog())")
            XCTAssertGreaterThan(resumed?.rangeStart ?? 0, 0, "文件 \(file) 不该从头下")
        }
    }

    /// 下载页直接拖：按住第 3 集拖到第 2 集上面 → 正在下的第 1 集不受影响，下完接着下第 3 集；
    /// 再把第 2 集拖到最上面 → 它立刻开始，第 1 集让路
    @MainActor
    func test2DragToReorder() throws {
        setRate(1_000_000)
        clearLog()
        let app = launch(route: "/library/2/item/\(showId)")
        downloadWholeSeason(app)
        XCTAssertTrue(waitUntil(timeout: 30) { self.started(self.episodeFiles[0]) })
        openDownloads(app)

        let firstDrag = Date().timeIntervalSince1970
        dragRow(app, file: episodeFiles[2], above: episodeFiles[1])
        XCTAssertTrue(waitUntil(timeout: 10) { self.rowSays(app, file: self.episodeFiles[2], "下一个下载") }, "第 3 集应排到下一个")
        snapshot("r1-dragged")
        XCTAssertFalse(contentRequests().contains { $0.file == episodeFiles[0] && $0.aborted }, "正在下的第 1 集不该被打断：\(contentLog())")

        // 第 2 集拖到最上面：它成了排第一、能下的那个 → 立刻开始（先滚回顶上：滚过之后第一行上沿压在吸顶的分组标题下面）
        app.swipeDown()
        let secondDrag = Date().timeIntervalSince1970
        dragRow(app, file: episodeFiles[1], above: episodeFiles[0])
        XCTAssertTrue(waitUntil(timeout: 20) { self.startedAfter(secondDrag).first == self.episodeFiles[1] },
                      "拖到最上面应立刻开始：\(contentLog())")
        snapshot("r2-second-on-top")

        setRate(0)
        XCTAssertTrue(waitUntil(timeout: 240) { !self.anyActive(app) }, "应全部下完：\(contentLog())")
        let order = startedAfter(firstDrag)
        print("[OfflinePriority] 拖动之后的请求顺序：\(order)\n\(contentLog())")
        XCTAssertEqual(order.first, episodeFiles[1])
        XCTAssertEqual(Array(order.dropFirst().prefix(2)), [episodeFiles[0], episodeFiles[2]], "然后是让路的第 1 集、再第 3 集")
        let resumed = contentRequests().filter { $0.file == episodeFiles[0] && $0.start > secondDrag }.first
        XCTAssertGreaterThan(resumed?.rangeStart ?? 0, 0, "让路的第 1 集应续传")
    }

    /// 长按菜单暂停 → 继续（回归；行可拖动、又每秒刷新进度时菜单照样点得动）：暂停的那集让路给下一集；继续后回到它原来的位置，正在下的不打断，下完接着它续传
    @MainActor
    func test3PauseResumeKeepsPlaceAndBytes() throws {
        // 菜单开着时 XCUITest 等界面静止会等满 60 秒（行在刷进度）：下慢一点，点到「暂停」时那集还在下
        setRate(300_000)
        clearLog()
        let app = launch(route: "/library/2/item/\(showId)")
        downloadWholeSeason(app)
        let first = episodeFiles[0]
        XCTAssertTrue(waitUntil(timeout: 40) { (self.contentRequests().last { $0.file == first }?.bytes ?? 0) > 2_000_000 })
        openDownloads(app)
        let row = app.descendants(matching: .any)["offline-downloading-\(first)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        reveal(app, row)
        row.press(forDuration: 1.2)
        let pause = app.buttons["暂停"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "长按正在下的那行应出菜单")
        snapshot("s1-row-menu")
        let pausedAt = Date().timeIntervalSince1970
        pause.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.startedAfter(pausedAt).first == self.episodeFiles[1] }, "暂停后下一集开始：\(contentLog())")

        row.press(forDuration: 1.2)
        let resume = app.buttons["继续下载"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        let resumedAt = Date().timeIntervalSince1970
        resume.tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(contentRequests().contains { $0.file == episodeFiles[1] && $0.aborted }, "继续不该打断正在下的：\(contentLog())")
        XCTAssertTrue(waitUntil(timeout: 10) { self.rowSays(app, file: first, "下一个下载") }, "继续后回到原位、排在正在下的后面")

        setRate(0)
        XCTAssertTrue(waitUntil(timeout: 240) { !self.anyActive(app) }, "应全部下完：\(contentLog())")
        let order = startedAfter(resumedAt)
        print("[OfflinePriority] 继续之后的请求顺序：\(order)\n\(contentLog())")
        XCTAssertEqual(order.first, first, "正在下的那集下完就轮到它")
        XCTAssertGreaterThan(contentRequests().first { $0.file == first && $0.start > resumedAt }?.rangeStart ?? 0, 0, "续传，不从头下")
    }

    /// 转码档整季（回归）：导出在服务端排队（503 等转码、到点重试）也能按顺序全部下完
    @MainActor
    func test4TranscodedSeasonCompletes() throws {
        clearLog()
        let app = launch(route: "/library/2/item/\(showId)")
        downloadWholeSeason(app, profile: "480p")
        // 服务器上同档的导出转过就直接复用，可能还没点开下载页就已经下完了
        openDownloads(app, expectDownloading: false)
        XCTAssertTrue(waitUntil(timeout: 420) { !self.anyActive(app) }, "转码档应全部下完")
        XCTAssertTrue(app.descendants(matching: .any)["offline-storage-item-\(showId)"].waitForExistence(timeout: 10))
        snapshot("t1-transcoded-done")
    }

    /// 没开「使用蜂窝网络下载」、眼下是计费网络（开发开关模拟）：下载中顶上说清楚在等 Wi-Fi，各行写「等待 Wi-Fi」；
    /// 点提示里的「使用蜂窝网络下载」→ 提示消失、照常排队
    @MainActor
    func test5WaitingForWiFiSaysSo() throws {
        setRate(1_000_000)
        clearLog()
        let app = launch(route: "/library/2/item/\(showId)", extra: ["-mcNetworkCost", "metered"])
        downloadWholeSeason(app)
        openDownloads(app)
        let notice = app.descendants(matching: .any)["offline-waiting-wifi"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "计费网络上应提示在等 Wi-Fi")
        XCTAssertTrue(waitUntil(timeout: 20) { self.rowSays(app, file: self.episodeFiles[1], "等待 Wi-Fi") }, "排队的应写「等待 Wi-Fi」")
        snapshot("w1-waiting-wifi")
        app.buttons["offline-use-cellular"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !notice.exists }, "开了蜂窝下载，提示应消失")
        XCTAssertTrue(waitUntil(timeout: 20) { self.rowSays(app, file: self.episodeFiles[1], "下一个下载") })
        snapshot("w2-cellular-on")
    }

    /// 切网络（蜂窝 ↔ Wi-Fi）时正在下的连接会断：排第一的那集要很快接着下（续传），不能让排第二的趁机先下完
    @MainActor
    func test6ConnectionDropKeepsOrder() throws {
        setRate(1_000_000)
        clearLog()
        let app = launch(route: "/library/2/item/\(showId)")
        downloadWholeSeason(app)
        let first = episodeFiles[0], second = episodeFiles[1]
        XCTAssertTrue(waitUntil(timeout: 40) { (self.contentRequests().last { $0.file == first }?.bytes ?? 0) > 5_000_000 })
        let droppedAt = Date().timeIntervalSince1970
        _ = request("POST", "/drop", body: ["path": "/offline/files/\(first)/content"])
        XCTAssertTrue(waitUntil(timeout: 20) { self.contentRequests().contains { $0.file == first && $0.start > droppedAt && $0.bytes > 0 } },
                      "断开后第 1 集应很快接着下：\(contentLog())")
        let resumed = contentRequests().first { $0.file == first && $0.start > droppedAt }
        XCTAssertGreaterThan(resumed?.rangeStart ?? 0, 0, "续传，不从头下：\(contentLog())")
        setRate(0)
        XCTAssertTrue(waitUntil(timeout: 240) { (self.contentRequests().filter { $0.end == nil }).isEmpty && !self.contentRequests().isEmpty
            && Set(self.contentRequests().filter { !$0.aborted }.map(\.file)).isSuperset(of: Set(self.episodeFiles)) }, "应全部下完：\(contentLog())")
        let log = contentRequests()
        print("[OfflinePriority] 断连之后：\(contentLog())")
        let firstDone = log.last { $0.file == first && !$0.aborted }?.end ?? .infinity
        let secondDone = log.last { $0.file == second && !$0.aborted }?.end ?? 0
        XCTAssertLessThan(firstDone, secondDone, "排第一的应先下完：\(contentLog())")
        let secondBytesBeforeFirstDone = log.filter { $0.file == second && $0.start < firstDone }.reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertLessThan(secondBytesBeforeFirstDone, 8_000_000, "第 1 集下完之前第 2 集不该占着带宽：\(contentLog())")
    }

    // MARK: 操作

    @MainActor
    private func launch(route: String, then: String? = nil, thenDelay: Double = 0, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--ui-testing", "--reset-state", "-mcServer", proxy, "-mcUser", username, "-mcPass", password, "-mcRoute", route]
        if let then { args += ["-mcRouteThen", then, "-mcRouteThenDelay", String(thenDelay)] }
        args += extra
        app.launchArguments = args
        app.launch()
        return app
    }

    /// 剧集详情页「⋯」→「下载」→ 全部 3 集（默认原画）
    @MainActor
    private func downloadWholeSeason(_ app: XCUIApplication, profile: String = "original") {
        XCTAssertTrue(app.staticTexts["item-title"].waitForExistence(timeout: 30))
        let menu = app.buttons["item-actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let download = app.buttons["下载"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        let option = app.buttons["offline-profile-\(profile)"]
        XCTAssertTrue(option.waitForExistence(timeout: 30))
        app.segmentedControls["offline-scope"].buttons["全部 3 集"].tap()
        option.tap()
        app.buttons["offline-profile-confirm"].tap()
    }

    /// 电影详情页「⋯」→「下载」→ 原画
    @MainActor
    private func downloadMovie(_ app: XCUIApplication) {
        let menu = app.buttons["item-actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let download = app.buttons["下载"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        let original = app.buttons["offline-profile-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 30))
        original.tap()
        app.buttons["offline-profile-confirm"].tap()
    }

    /// 我的 → 下载
    @MainActor
    private func openDownloads(_ app: XCUIApplication, expectDownloading: Bool = true) {
        // 开始下载后底部有一条「已开始下载」提示，压着标签栏时点不到「我的」：点不进去就再点一次
        let header = app.descendants(matching: .any)[expectDownloading ? "offline-storage-downloading" : "offline-storage-summary"]
        for _ in 0 ..< 3 where !header.exists {
            let more = app.descendants(matching: .any).matching(identifier: "open-more").firstMatch
            // 往下滚过页面时标签栏会收起：往回滚一下让它展开
            if !more.waitForExistence(timeout: 3) { app.swipeDown() }
            XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
            more.tap()
            let tab = app.descendants(matching: .any)["more-tab-downloads"]
            if tab.waitForExistence(timeout: 5) { tab.tap() }
            _ = header.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(header.exists, app.debugDescription)
    }

    /// 把这一行滚到屏幕上半部：底部压着标签栏和 AI 输入条，按下去会按到它们身上
    @MainActor
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        let window = app.windows.firstMatch
        for _ in 0 ..< 4 where element.frame.maxY > window.frame.height * 0.65 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
    }

    /// 下载页里按住一行，拖到另一行的上半部
    @MainActor
    private func dragRow(_ app: XCUIApplication, file: Int, above target: Int) {
        let row = app.descendants(matching: .any)["offline-downloading-\(file)"]
        let to = app.descendants(matching: .any)["offline-downloading-\(target)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10) && to.exists, app.debugDescription)
        reveal(app, row)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: to.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
    }

    /// 下载页某一行写着这句话（行是一个整体的可访问元素时看它的标签，否则看里面的文字）
    @MainActor
    private func rowSays(_ app: XCUIApplication, file: Int, _ text: String) -> Bool {
        let row = app.descendants(matching: .any)["offline-downloading-\(file)"]
        return row.label.contains(text) || row.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).count > 0
    }

    /// 下载页的「下载中」分组还在不在
    @MainActor
    private func anyActive(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["offline-storage-downloading"].exists
    }

    // MARK: 代理

    private struct ContentRequest: CustomStringConvertible {
        let file: Int
        let start: Double
        let rangeStart: Int64?
        let bytes: Int64
        let aborted: Bool
        /// 连接结束的时刻（还在发为空）
        let end: Double?
        var description: String {
            "文件\(file)@\(String(format: "%.1f", start.truncatingRemainder(dividingBy: 1000)))"
                + (rangeStart.map { " Range \($0)-" } ?? "") + " \(bytes / 1_000_000)MB" + (aborted ? " 断开" : "")
        }
    }

    /// 下载内容请求（/offline/files/<文件>/content），按开始时间
    private func contentRequests() -> [ContentRequest] {
        guard let data = request("GET", "/log"),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> ContentRequest? in
            guard let path = row["path"] as? String, path.hasSuffix("/content"), (row["method"] as? String) == "GET",
                  let file = path.split(separator: "/").dropLast().last.flatMap({ Int($0) }) else { return nil }
            let range = (row["range"] as? String).flatMap { $0.split(separator: "=").last?.split(separator: "-").first }.flatMap { Int64($0) }
            return ContentRequest(file: file, start: row["start"] as? Double ?? 0, rangeStart: range,
                                  bytes: (row["bytes"] as? NSNumber)?.int64Value ?? 0, aborted: row["aborted"] as? Bool ?? false,
                                  end: row["end"] as? Double)
        }.sorted { $0.start < $1.start }
    }

    private func contentLog() -> String { contentRequests().map(\.description).joined(separator: " | ") }

    private func started(_ file: Int) -> Bool { contentRequests().contains { $0.file == file && $0.bytes > 0 } }

    /// 这个时刻之后开始的下载请求（真收到数据的），按先后、同一个文件只记第一次
    private func startedAfter(_ time: Double) -> [Int] {
        var seen = Set<Int>()
        return contentRequests().filter { $0.start > time && $0.bytes > 0 }.map(\.file).filter { seen.insert($0).inserted }
    }

    private func setRate(_ rate: Int) {
        _ = request("POST", "/mode", body: ["rate": rate])
    }

    private func clearLog() {
        _ = request("POST", "/log/clear")
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) -> Data? {
        var request = URLRequest(url: URL(string: control + path)!)
        request.httpMethod = method
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return result
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return condition()
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
