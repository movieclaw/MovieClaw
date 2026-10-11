import XCTest

/// 插件任务在任务中心显示服务端给的名字（`job_type_label`），不再是原始类型键（只读，不点任何操作）。
///
/// 需要服务器上有插件任务的历史，例如开着「网盘规格预探」的服务器扫过网盘库：
/// `MC_TEST_SERVER=… MC_TEST_USERNAME=… MC_TEST_PASSWORD=… scripts/test.sh -only-testing:MovieClawUITests/PluginJobLabelUITests`
final class PluginJobLabelUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor
    func testPluginJobsShowTheServerName() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-mcServer", env["MC_TEST_SERVER"] ?? "http://localhost:3000",
            "-mcUser", env["MC_TEST_USERNAME"] ?? "admin",
            "-mcPass", env["MC_TEST_PASSWORD"] ?? "mclaw-dev-2026",
            "-mcRoute", "/activity?view=history",
        ]
        app.launch()

        let named = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "网盘规格预探")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 30), "历史里应显示插件任务的名字")
        let raw = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "strm-prefetch:")).firstMatch
        XCTAssertFalse(raw.exists, "不该露出原始任务类型键")

        let screenshot = XCUIScreen.main.screenshot()
        if let dir = env["MC_SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("plugin-job-label.png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "plugin-job-label"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
