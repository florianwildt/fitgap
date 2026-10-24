import XCTest

/// Captures only on dedicated, empty simulators; ordinary test runs skip this suite.
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let name = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(name.hasPrefix("FITgap App Store"), "Requires a dedicated App Store screenshot simulator.")
        // The overridden setUp is nonisolated, but XCTest runs it on the main thread.
        let dark = self.name.contains("DarkLibraries")
        MainActor.assumeIsolated { XCUIDevice.shared.appearance = dark ? .dark : .light }
    }

    func testGermanScreenshots() { captureStore(language: "de", locale: "de_DE") }
    func testEnglishScreenshots() { captureStore(language: "en", locale: "en_US") }
    func testDarkLibraries() {
        captureLibrary(language: "de", locale: "de_DE", dark: true)
        captureLibrary(language: "en", locale: "en_US", dark: true)
    }

    func testLightLibraries() {
        captureLibrary(language: "de", locale: "de_DE", dark: false)
        captureLibrary(language: "en", locale: "en_US", dark: false)
    }

    private func capture(_ name: String) {
        // Let transient scroll indicators and native sheet animations finish.
        Thread.sleep(forTimeInterval: 1.2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func showLibrary(_ app: XCUIApplication, german: Bool) {
        let title = app.staticTexts[german ? "Demo: Lockere Morgenfahrt" : "Demo: Easy Morning Ride"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<6 {
            let navigationBottom = app.navigationBars.firstMatch.frame.maxY
            let distance = min(160, max(-160, title.frame.minY - navigationBottom - 60))
            if abs(distance) < 8 { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertGreaterThanOrEqual(title.frame.minY, app.navigationBars.firstMatch.frame.maxY + 20)
        XCTAssertLessThanOrEqual(title.frame.minY, app.navigationBars.firstMatch.frame.maxY + 100)
        XCTAssertTrue(app.buttons["share-demo-recovery"].isHittable, app.debugDescription)
    }

    private func captureStore(language: String, locale: String) {
        let german = language == "de"
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        let indicator = app.descendants(matching: .any).matching(identifier: "demo-indicator").firstMatch
        if !indicator.exists {
            let start = app.buttons["try-demo"]
            XCTAssertTrue(start.waitForExistence(timeout: 5), app.debugDescription)
            start.tap()
        }
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        showLibrary(app, german: german)
        capture("\(language)-01-activities-light")

        app.buttons["share-demo-recovery"].tap()
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Schließen", "Close", "Abbrechen", "Cancel"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "FITgap-Demo-recovery")).firstMatch.waitForExistence(timeout: 5))
        capture("\(language)-02-share-fit")
        close.tap()

        let search = app.searchFields.firstMatch
        // Reveal the native search field by returning to the top of the list.
        app.swipeDown(velocity: .slow)
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText(german ? "Ausdauer\n" : "Endurance\n")
        XCTAssertTrue(app.staticTexts[german ? "Demo: Ausdauertraining" : "Demo: Endurance Ride"].waitForExistence(timeout: 5), app.debugDescription)
        capture("\(language)-03-search")
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Abbrechen", "Cancel", "Schließen", "Close", "close"])).firstMatch.tap()

        app.buttons[german ? "Konten" : "Accounts"].tap()
        XCTAssertTrue(app.buttons["accounts-end-demo"].waitForExistence(timeout: 5))
        app.buttons["accounts-end-demo"].tap()
        XCTAssertTrue(app.buttons["source-zwift"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["source-wahoo"].exists && app.buttons["source-mywhoosh"].exists)
        capture("\(language)-04-accounts")
        app.buttons[german ? "Fertig" : "Done"].tap()

        app.terminate()
    }

    private func captureLibrary(language: String, locale: String, dark: Bool) {
        let german = language == "de"
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        let indicator = app.descendants(matching: .any).matching(identifier: "demo-indicator").firstMatch
        if !indicator.exists {
            XCTAssertTrue(app.buttons["try-demo"].waitForExistence(timeout: 5))
            app.buttons["try-demo"].tap()
        }
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        showLibrary(app, german: german)
        capture("\(language)-\(dark ? "05-activities-dark" : "01-activities-light")")
        app.terminate()
    }
}
