import XCTest

final class LocalizationUITests: XCTestCase {
    @MainActor private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MC_TEST_I18N"] == "1", let server = env["MC_TEST_SERVER"],
              URL(string: server)?.host == "127.0.0.1" else {
            throw XCTSkip("Requires the isolated i18n fixture")
        }
        continueAfterFailure = false
    }

    @MainActor private func launch(_ language: String) {
        let env = ProcessInfo.processInfo.environment
        app.launchArguments = ["--ui-testing", "-mcServer", env["MC_TEST_SERVER"]!,
                               "-mcUser", "admin", "-mcPass", env["MC_TEST_PASSWORD"]!,
                               "-mcRoute", "/settings", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", "en_US"]
        app.launch()
    }

    @MainActor func testEnglishLanguageRowOpensSystemSettings() {
        launch("en")
        let row = app.buttons["app-language-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(row.label.contains("Language"))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "settings-language-en"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        row.tap()
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.Preferences").wait(for: .runningForeground, timeout: 10))
    }

    @MainActor func testUnsupportedLanguageFallsBackToEnglish() {
        launch("ja")
        let row = app.buttons["app-language-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(row.label.contains("Language"))
    }

    @MainActor func testTraditionalChineseUsesSimplifiedAlias() {
        launch("zh-Hant")
        let row = app.buttons["app-language-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(row.label.contains("语言"))
        XCTAssertTrue(row.label.contains("简体中文"))
    }

    @MainActor func testFreshSignInUsesEnglishAndChineseMessages() {
        let env = ProcessInfo.processInfo.environment
        for (language, connect, wrongPassword) in [
            ("en", "Connect to server", "Incorrect username or password"),
            ("zh-Hans", "连接服务器", "用户名或密码错误"),
        ] {
            app.launchArguments = ["--reset-state", "--ui-testing", "-AppleLanguages", "(\(language))",
                                   "-AppleLocale", "en_US"]
            app.launch()
            let start = app.buttons["welcome-start"]
            XCTAssertTrue(start.waitForExistence(timeout: 20))
            XCTAssertEqual(start.label, connect)
            start.tap()
            let address = app.textFields["server-address"]
            XCTAssertTrue(address.waitForExistence(timeout: 10))
            address.tap()
            address.typeText(env["MC_TEST_SERVER"]!)
            let username = app.textFields["login-username"]
            username.tap()
            username.typeText("admin")
            let password = app.secureTextFields["login-password"]
            password.tap()
            password.typeText("wrong-password")
            app.buttons["login-submit"].tap()
            let error = app.staticTexts["login-error"]
            XCTAssertTrue(error.waitForExistence(timeout: 15))
            XCTAssertEqual(error.label, wrongPassword)
            XCTAssertTrue(app.buttons["login-submit"].isEnabled)
            XCTAssertEqual(address.value as? String, env["MC_TEST_SERVER"])
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "sign-in-error-\(language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    @MainActor func testPlaybackMenusUseTheEffectiveLanguage() throws {
        let env = ProcessInfo.processInfo.environment
        let item = try XCTUnwrap(env["MC_TEST_PLAYER_ITEM"])
        for (language, paused, quality, subtitles, diagnostics) in [
            ("en", "Pause", "Quality", "Subtitles", "Playback diagnostics"),
            ("zh-Hans", "暂停", "画质", "字幕", "播放诊断"),
        ] {
            app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", env["MC_TEST_SERVER"]!,
                                   "-mcUser", "admin", "-mcPass", env["MC_TEST_PASSWORD"]!,
                                   "-mcRoute", "/play/\(item)/s00e00?t=0", "-mcPlayerDiagnostics", "YES",
                                   "-mcPlayerPinChrome", "YES", "-AppleLanguages", "(\(language))",
                                   "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.otherElements["player-screen"].waitForExistence(timeout: 30))
            let time = app.staticTexts["player-time"]
            let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                Int(time.value as? String ?? "0").map { $0 >= 2 } ?? false
            }, object: time)
            XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 60), .completed)
            let pause = app.buttons["player-play-pause"]
            XCTAssertEqual(pause.label, paused)
            pause.tap()
            XCTAssertTrue(app.staticTexts[diagnostics].exists)
            if language == "en" {
                let panel = app.otherElements["player-diagnostics"]
                let text = panel.staticTexts.allElementsBoundByIndex.map(\.label).joined()
                XCTAssertNil(text.range(of: "[\\u3400-\\u9fff]", options: .regularExpression), text)
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "playback-diagnostics-\(language)"
            shot.lifetime = .keepAlways
            add(shot)
            app.buttons["player-设置"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", quality)).firstMatch.waitForExistence(timeout: 5))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)).tap()
            app.buttons["player-字幕"].tap()
            XCTAssertTrue(app.staticTexts[subtitles].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["subtitle-off"].label, language == "en" ? "Off" : "关闭")
            app.buttons["subtitle-off"].tap()
            app.terminate()
        }
    }

    @MainActor func testStorageCleanupUsesTheReaderLanguage() {
        let env = ProcessInfo.processInfo.environment
        for (language, title, clear, cancel, result) in [
            ("en", "Image cache", "Clear cache", "Cancel", "Freed "),
            ("zh-Hans", "图片缓存", "清空缓存", "取消", "已释放 "),
        ] {
            app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", env["MC_TEST_SERVER"]!,
                                   "-mcUser", "admin", "-mcPass", env["MC_TEST_PASSWORD"]!,
                                   "-mcRoute", "/settings/app?tab=storage", "-AppleLanguages", "(\(language))",
                                   "-AppleLocale", "en_US"]
            app.launch()
            let row = app.buttons["storage-dir-cache.images"]
            XCTAssertTrue(row.waitForExistence(timeout: 30))
            for _ in 0..<8 where !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.isHittable)
            XCTAssertTrue(row.label.contains(title))
            row.tap()
            let clean = app.buttons["storage-clean-all"]
            XCTAssertTrue(clean.waitForExistence(timeout: 10))
            XCTAssertEqual(clean.label, clear)
            clean.tap()
            let dialog = app.alerts.firstMatch
            XCTAssertTrue(dialog.waitForExistence(timeout: 5))
            XCTAssertTrue(dialog.staticTexts[language == "en" ? "Clear “Image cache”?" : "清空「图片缓存」？"].exists)
            dialog.buttons[cancel].tap()
            XCTAssertTrue(clean.exists)
            clean.tap()
            XCTAssertTrue(dialog.waitForExistence(timeout: 5))
            let confirm = dialog.buttons.matching(NSPredicate(format: "label != %@", cancel)).firstMatch
            XCTAssertTrue(confirm.exists)
            confirm.tap()
            let notice = app.staticTexts["storage-clean-notice"]
            XCTAssertTrue(notice.waitForExistence(timeout: 15))
            XCTAssertTrue(notice.label.hasPrefix(result))
            if language == "en" {
                XCTAssertNotNil(notice.label.range(of: "entries removed: [1-9][0-9,]*", options: .regularExpression))
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "storage-cleanup-\(language)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    @MainActor func testScheduledTaskDraftDiscardAndSaveUseEnglish() {
        let env = ProcessInfo.processInfo.environment
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", env["MC_TEST_SERVER"]!,
                               "-mcUser", "admin", "-mcPass", env["MC_TEST_PASSWORD"]!,
                               "-mcRoute", "/settings/app?tab=tasks", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US"]
        app.launch()
        let row = app.buttons["task-row-library_reconcile"]
        XCTAssertTrue(app.navigationBars["Scheduled tasks"].waitForExistence(timeout: 30))
        for _ in 0..<10 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        XCTAssertTrue(row.label.contains("Library reconciliation"))
        row.tap()
        let enabled = app.switches["task-enabled-library_reconcile"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(enabled.value as? String, "0")
        let save = app.buttons["task-save-library_reconcile"]
        XCTAssertTrue(save.isEnabled)
        app.buttons["sheet-close"].tap()
        let alert = app.alerts["Discard unsaved changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Keep editing"].tap()
        XCTAssertEqual(enabled.value as? String, "0")
        app.buttons["sheet-close"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Discard changes"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertEqual(enabled.value as? String, "1")
        let hours = app.steppers["task-hours-library_reconcile"]
        XCTAssertTrue(hours.waitForExistence(timeout: 5))
        hours.buttons["task-hours-library_reconcile-Increment"].tap()
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Every 7 hours"), object: row)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [updated, closed], timeout: 15), .completed)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "scheduled-task-saved-en"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

}
