import AppKit
import XCTest

final class MacLocalizationUITests: XCTestCase {
    @MainActor private lazy var app = XCUIApplication(bundleIdentifier: ProcessInfo.processInfo.environment["MC_TEST_APP_BUNDLE_ID"]!)

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MC_TEST_I18N"] == "1", let server = env["MC_TEST_SERVER"],
              URL(string: server)?.host == "127.0.0.1",
              env["MC_TEST_APP_BUNDLE_ID"]?.hasPrefix("io.movieclaw.i18nqa") == true else {
            throw XCTSkip("Requires an isolated Mac QA bundle and loopback API")
        }
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        if let bundle = ProcessInfo.processInfo.environment["MC_TEST_APP_BUNDLE_ID"],
           bundle.hasPrefix("io.movieclaw.i18nqa") {
            await MainActor.run { XCUIApplication(bundleIdentifier: bundle).terminate() }
        }
        try await super.tearDown()
    }

    @MainActor func testAccountSwitchClearsPreviousDetails() async throws {
        let env = ProcessInfo.processInfo.environment
        app.launchArguments = ["--ui-testing", "-mcServer", env["MC_TEST_SERVER"]!,
                               "-mcUser", "admin", "-mcPass", env["MC_TEST_PASSWORD"]!,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        // XCTest can start a SwiftUI Mac app with only its menu bar. Reopen its main window.
        _ = try await NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: env["MC_TEST_APP_PATH"]!), configuration: .init())
        app.activate()
        let details = app.buttons["mac-home-hero-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 30))
        details.click()
        let play = app.buttons["mac-item-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(play.label.hasPrefix("Continue"), play.label)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Current account: admin.")).firstMatch.click()
        app.buttons["Add account…"].click()
        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.click()
        username.typeText(env["MC_TEST_MEMBER"]!)
        app.secureTextFields.firstMatch.click()
        app.secureTextFields.firstMatch.typeText(env["MC_TEST_PASSWORD"]!)
        app.buttons["Sign in"].click()
        let current = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Current account: " + env["MC_TEST_MEMBER_NICKNAME"]! + ".")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        // Account changes must clear the previous navigation stack and its private progress.
        let poster = app.buttons["mac-home-poster-" + env["MC_TEST_PLAYER_ITEM"]!]
        XCTAssertTrue(poster.waitForExistence(timeout: 10), "Switching accounts left the previous account's details visible")
        XCTAssertFalse(play.exists)
        poster.click()
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertFalse(play.label.hasPrefix("Continue"), "A new member inherited the administrator's resume point")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "mac-member-isolation-en"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
