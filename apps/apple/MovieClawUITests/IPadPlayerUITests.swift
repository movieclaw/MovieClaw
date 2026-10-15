import XCTest

/// iPad 上的播放器（docs/design/ipad.md §4）：横屏起播、控制层、画中画后回到主界面接着逛。
/// 需要一台能直放的服务器：MC_TEST_SERVER / MC_TEST_USERNAME / MC_TEST_PASSWORD + MC_TEST_MP4_ITEM（条目 id）
final class IPadPlayerUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    @MainActor
    func testPlaybackControlsAndPictureInPicture() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "只在 iPad 上跑")
        let server = try XCTUnwrap(env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 }, "需要 MC_TEST_SERVER")
        let item = try XCTUnwrap(env["MC_TEST_MP4_ITEM"].flatMap { $0.isEmpty ? nil : $0 }, "需要 MC_TEST_MP4_ITEM")
        let app = XCUIApplication()
        app.launchArguments = ["-mcServer", server, "-mcUser", env["MC_TEST_USERNAME"] ?? "admin",
                               "-mcPass", env["MC_TEST_PASSWORD"] ?? "", "-mcRoute", "/play/\(item)"]
        app.launch()

        let video = app.otherElements["player-video"].firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["player-screen"].waitForExistence(timeout: 30), "播放器没出现")
        // 等画面走起来，再点一下唤出控制层
        sleep(6)
        (video.exists ? video : app.windows.firstMatch).tap()
        let pip = app.buttons["player-pip"]
        XCTAssertTrue(pip.waitForExistence(timeout: 5), "控制层没出现")
        XCTAssertTrue(app.descendants(matching: .any)["player-time"].exists, "没有时间读数")

        // 画中画（控制层 3 秒后自动隐藏，趁它还在马上点）：按钮变成「退出画中画」；
        // 回到桌面后小窗接着播（开画中画后在 App 里收起播放器接着逛是 P3 的目标，docs/design/ipad.md §6）
        pip.tap()
        // 控制层可能已经藏起来（或被点一下反而藏起来）：每秒看一次按钮是否变成「退出画中画」，看不到就点画面唤出
        let exitPip = app.buttons.matching(NSPredicate(format: "label == %@", "退出画中画")).firstMatch
        var started = false
        for _ in 0 ..< 8 where !started {
            if exitPip.waitForExistence(timeout: 1) { started = true; break }
            if !app.buttons["player-pip"].exists { (video.exists ? video : app.windows.firstMatch).tap() }
        }
        XCTAssertTrue(started, "画中画没开起来")
        XCUIDevice.shared.press(.home)
        sleep(6)
        // 开着画中画时系统把 App 报成前台（小窗属于它），这里只确认它没被结束；小窗浮在桌面上接着播靠截图核对
        XCTAssertNotEqual(app.state, .notRunning, "回到桌面后 App 不该被结束")
    }

    /// 横屏下点返回要退出播放器（真机反馈：返回键写着「退出横屏」，只去请求转屏，iPad 不接受，退不出来）；
    /// iPad 方向跟随设备，没有横屏键
    @MainActor
    func testBackExitsPlayerInLandscape() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "只在 iPad 上跑")
        let server = try XCTUnwrap(env["MC_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 }, "需要 MC_TEST_SERVER")
        let item = try XCTUnwrap(env["MC_TEST_MP4_ITEM"].flatMap { $0.isEmpty ? nil : $0 }, "需要 MC_TEST_MP4_ITEM")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-mcServer", server, "-mcUser", env["MC_TEST_USERNAME"] ?? "admin",
                               "-mcPass", env["MC_TEST_PASSWORD"] ?? "", "-mcRoute", "/play/\(item)"]
        app.launch()
        let screen = app.descendants(matching: .any)["player-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "播放器没出现")
        sleep(5)
        let video = app.otherElements["player-video"].firstMatch
        (video.exists ? video : app.windows.firstMatch).tap()
        let close = app.buttons["player-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "控制层没出现")
        XCTAssertEqual(close.label, "退出播放")
        XCTAssertFalse(app.buttons["player-横屏"].exists || app.buttons["player-退出横屏"].exists, "iPad 上不该有横屏键")
        close.tap()
        XCTAssertTrue(screen.waitForNonExistence(timeout: 8), "横屏下点返回没有退出播放器")
    }
}
