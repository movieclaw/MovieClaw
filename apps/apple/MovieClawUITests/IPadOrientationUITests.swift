import XCTest

/// iPad 截图辅助：转动模拟器设备方向（无界面启动的模拟器没有旋转快捷键，`simctl` 也没有旋转命令）。
/// 设备方向在测试结束后保持，之后用 `simctl launch` 起 App 截图即可。
final class IPadOrientationUITests: XCTestCase {
    func testRotateLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testRotatePortrait() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// 点掉挂在屏幕上的通知授权弹窗（截图前用；弹窗属于 SpringBoard，不用启动 App）
    func testAllowNotificationPrompt() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["允许"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }
}
