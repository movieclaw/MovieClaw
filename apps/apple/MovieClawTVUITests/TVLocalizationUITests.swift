import XCTest

final class TVLocalizationUITests: XCTestCase {
    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MC_TEST_I18N"] == "1", let server = env["MC_TEST_SERVER"],
              URL(string: server)?.host == "127.0.0.1" else {
            throw XCTSkip("Requires the isolated i18n fixture")
        }
        continueAfterFailure = false
    }

    @MainActor private func launch(_ language: String) -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", env["MC_TEST_SERVER"]!,
                               "-mcUser", "admin", "-mcPass", env["MC_TEST_PASSWORD"]!,
                               "-mcTab", "account", "-AppleLanguages", "(\(language))", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testEnglishAccountAndAboutUseRealServer() {
        let app = launch("en")
        let about = app.buttons["tv-profiles-about"]
        XCTAssertTrue(about.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Who’s watching?"].exists)
        XCTAssertEqual(about.label, "About")
        XCTAssertEqual(app.buttons["tv-profiles-logout"].label, "Sign out")
        let currentProfile = app.element("tv-profile-admin")
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: currentProfile)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 12), .completed)
        snapshot("tv-account-en")
        TVRemote.select(about, by: .down)
        XCTAssertTrue(app.element("tv-about").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Open-source components"].exists)
        XCTAssertTrue(app.staticTexts["Data sources"].exists)
        XCTAssertTrue(app.element("tv-who-is-watching").waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["AetherEngine (MovieClaw fork)"].exists)
        snapshot("tv-about-en")
    }

    @MainActor func testUnsupportedLanguageFallsBackToEnglish() {
        let app = launch("ja")
        let about = app.buttons["tv-profiles-about"]
        XCTAssertTrue(about.waitForExistence(timeout: 30))
        XCTAssertEqual(about.label, "About")
    }

    @MainActor func testEnglishPlaybackPanelUsesRealMedia() throws {
        let env = ProcessInfo.processInfo.environment
        let item = try XCTUnwrap(env["MC_TEST_PLAYER_ITEM"])
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing", "-mcServer", env["MC_TEST_SERVER"]!,
                               "-mcUser", "admin", "-mcPass", env["MC_TEST_PASSWORD"]!,
                               "-mcRoute", "/play/\(item)/s00e00?t=0", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US"]
        app.launch()
        let surface = app.element("tv-player-surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: surface)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 12), .completed)
        XCTAssertEqual(surface.label, "Pause")
        let transport = app.element("tv-player-transport")
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            transport.label.range(of: "\\b0:(?!00)\\d\\d\\b", options: .regularExpression) != nil
        }, object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 60), .completed)
        TVRemote.press(.down)
        let panel = app.element("tv-player-panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Subtitles"].exists)
        XCTAssertTrue(app.staticTexts["Audio track"].exists)
        XCTAssertTrue(app.staticTexts["Quality"].exists)
        let text = panel.staticTexts.allElementsBoundByIndex.map(\.label).joined()
        XCTAssertNil(text.range(of: "[\\u3400-\\u9fff]", options: .regularExpression), text)
        snapshot("tv-playback-panel-en")
    }

    @MainActor func testTraditionalChineseUsesSimplifiedAlias() {
        let app = launch("zh-Hant")
        let about = app.buttons["tv-profiles-about"]
        XCTAssertTrue(about.waitForExistence(timeout: 30))
        XCTAssertEqual(about.label, "关于")
        XCTAssertTrue(app.staticTexts["谁在看？"].exists)
        snapshot("tv-account-zh-Hans")
    }

    @MainActor func testSystemLanguageSettingsProbe() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.TVSettings")
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        print("TV_I18N_SETTINGS_ROOT\n\(settings.debugDescription)\nTV_I18N_SETTINGS_END")
        snapshot("tv-system-settings-root")
        TVRemote.select(settings.cells["Apps"], by: .down)
        print("TV_I18N_SETTINGS_APPS\n\(settings.debugDescription)\nTV_I18N_SETTINGS_APPS_END")
        snapshot("tv-system-settings-apps")
        let movieclaw = settings.cells["MovieClaw"]
        if movieclaw.exists {
            TVRemote.select(movieclaw, trying: [.down, .up])
            print("TV_I18N_SETTINGS_APP\n\(settings.debugDescription)\nTV_I18N_SETTINGS_APP_END")
            snapshot("tv-system-settings-movieclaw")
            TVRemote.press(.menu)
        }
        TVRemote.press(.menu)
        TVRemote.select(settings.cells["General"], by: .up)
        print("TV_I18N_SETTINGS_GENERAL\n\(settings.debugDescription)\nTV_I18N_SETTINGS_GENERAL_END")
        snapshot("tv-system-settings-general")
    }
}
