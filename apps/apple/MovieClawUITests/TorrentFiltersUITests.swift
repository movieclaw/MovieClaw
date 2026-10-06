import XCTest

/// 真后端快照 → 原生菜单点选 → 结果行；使用 seed_torrent_filters.py 的隔离数据。
/// MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD 指向该测试实例。
final class TorrentFiltersUITests: XCTestCase {
    @MainActor
    func testEveryFacetMultiSelectionClearingAndSort() throws {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["MC_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("需要隔离测试实例及 seed_torrent_filters.py 快照")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "-mcServer", env["MC_TEST_SERVER"] ?? "http://localhost:3000",
            "-mcUser", env["MC_TEST_USERNAME"] ?? "admin", "-mcPass", password,
            "-mcRoute", "/library",
        ]
        app.launch()
        let search = app.navigationBars.buttons["open-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        let resourceMode = app.segmentedControls.buttons["资源"]
        XCTAssertTrue(resourceMode.waitForExistence(timeout: 30))
        resourceMode.tap()
        let history = app.buttons.matching(NSPredicate(format: "identifier == 'history-row' AND label CONTAINS '筛选回归'")).firstMatch
        guard history.waitForExistence(timeout: 15) else {
            throw XCTSkip("缺少 seed_torrent_filters.py 的隔离测试快照")
        }
        history.tap()
        let rows = app.buttons.matching(identifier: "torrent-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        app.buttons["torrent-view-menu"].tap()
        app.buttons["列表"].firstMatch.tap()
        assertRows(app, count: 3)

        // 每个维度都必须能独立选中、过滤到真实命中行，并再次点选取消。
        let facets = [
            ("resolution", "2160p"), ("site", "测试站甲"), ("year", "2024"),
            ("season", "第1季"), ("episode", "第1集"), ("source", "WEB-DL"),
            ("platform", "Netflix"), ("codec", "HEVC"), ("hdr", "HDR10"),
            ("audio", "DDP"), ("subtitle", "简体中文字幕"), ("group", "GroupA"),
        ]
        for (dim, value) in facets {
            pick(app, dim: dim, value: value)
            assertRows(app, count: 2)
            XCTAssertTrue(rows.element(boundBy: 0).label.contains("筛选样本1"))
            XCTAssertTrue(rows.element(boundBy: 1).label.contains("筛选样本3"))
            XCTAssertTrue(app.buttons["torrent-filter-\(dim)"].label.contains(value))
            screenshot(dim)
            pick(app, dim: dim, value: value)
            assertRows(app, count: 3)
            XCTAssertFalse(app.buttons["torrent-filter-clear"].exists)
        }

        // 同维度多选为「或」，不同维度为「且」。
        pick(app, dim: "resolution", value: "2160p")
        pick(app, dim: "resolution", value: "1080p")
        assertRows(app, count: 3)
        pick(app, dim: "site", value: "测试站乙")
        assertRows(app, count: 1)
        XCTAssertTrue(rows.firstMatch.label.contains("筛选样本2"))
        openFacet(app, "site")
        app.buttons["移除此条件"].tap()
        assertRows(app, count: 3)
        openFacet(app, "resolution")
        app.buttons["移除此条件"].tap()
        XCTAssertFalse(app.buttons["torrent-filter-clear"].exists)

        // 排序翻转后清空所有筛选，仍保持当前排序。
        pick(app, dim: "resolution", value: "2160p")
        reveal(app, id: "torrent-sort")
        app.buttons["torrent-sort"].tap()
        app.buttons["做种数"].firstMatch.tap()
        XCTAssertTrue(app.buttons["torrent-sort"].label.contains("升序"))
        XCTAssertTrue(rows.firstMatch.label.contains("筛选样本3"))
        app.buttons["torrent-filter-clear"].tap()
        assertRows(app, count: 3)
        XCTAssertTrue(rows.firstMatch.label.contains("筛选样本3"))
        screenshot("清空后保持排序")
    }

    @MainActor
    private func assertRows(_ app: XCUIApplication, count: Int) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == %d", count),
            object: app.buttons.matching(identifier: "torrent-row")
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func reveal(_ app: XCUIApplication, id: String) {
        let strip = app.scrollViews["torrent-conditions"]
        let chip = app.buttons[id]
        for _ in 0 ..< 20 {
            // 屏幕边缘裁切的菜单会令 XCTest 的 isHittable 抛错，先按几何位置滚进视口。
            let frame = chip.frame
            let clear = app.buttons["torrent-filter-clear"]
            let left = clear.exists ? clear.frame.maxX + 8 : app.frame.minX + 16
            let right = app.frame.maxX - 16
            if frame.width > 0, frame.midX >= left + 4, frame.midX <= right - 4 { return }
            let center = (left + right) / 2
            // 在胶囊上方的内边距拖动，避免 Menu 把按住解释成打开菜单。
            let y = strip.frame.minY + 1
            let direction: CGFloat = frame.midX < center ? 1 : -1
            // 用视口内短拖动，避免 XCTest 按横向内容的离屏 frame 合成 swipe。
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: center - direction * 60, dy: y))
            let end = origin.withOffset(CGVector(dx: center + direction * 60, dy: y))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTFail("无法滚动到 \(id)")
    }

    @MainActor
    private func openFacet(_ app: XCUIApplication, _ dim: String) {
        reveal(app, id: "torrent-filter-\(dim)")
        app.buttons["torrent-filter-\(dim)"].tap()
    }

    @MainActor
    private func pick(_ app: XCUIApplication, dim: String, value: String) {
        openFacet(app, dim)
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", value)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "\(dim) 的 \(value) 应是可点击菜单项；\(app.debugDescription)")
        option.tap()
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "资源筛选-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
