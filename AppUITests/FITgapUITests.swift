import XCTest

@MainActor
final class FITgapUITests: XCTestCase {
    private func launch(language: String = "de", locale: String = "de_DE") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testGermanLocalization() { verifyLocalization(language: "de", locale: "de_DE", german: true) }
    func testEnglishLocalization() { verifyLocalization(language: "en", locale: "en_US", german: false) }
    func testUnsupportedLanguageFallsBackToEnglish() { verifyLocalization(language: "fr", locale: "fr_FR", german: false) }

    func testGermanPrivacyLink() throws { try verifyPrivacyLink(language: "de", locale: "de_DE", german: true) }
    func testEnglishPrivacyLink() throws { try verifyPrivacyLink(language: "en", locale: "en_US", german: false) }

    private func verifyPrivacyLink(language: String, locale: String, german: Bool) throws {
        let app = launch(language: language, locale: locale)
        app.buttons[german ? "Konten" : "Accounts"].tap()
        XCTAssertTrue(app.navigationBars[german ? "Konten" : "Accounts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[german ? "Nicht verbunden" : "Not connected"].firstMatch.exists)
        let link = app.descendants(matching: .any).matching(identifier: "privacy-policy").firstMatch
        let expectedLabel = german ? "Datenschutzerklärung" : "Privacy Policy"
        for _ in 0..<12 where !link.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(link.label, expectedLabel)
        XCTAssertTrue(link.isEnabled)
        XCTAssertTrue(link.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(link.frame.height, 44)
        XCTAssertGreaterThanOrEqual(link.frame.width, 44)
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", german
            ? "Tokens bleiben im Schlüsselbund dieses iPhones." : "Tokens stay in this iPhone’s Keychain.")).firstMatch
        XCTAssertTrue(footer.exists, app.debugDescription)
        XCTAssertGreaterThanOrEqual(link.frame.minY, footer.frame.maxY)
        capture(app, "Privacy-\(language)")
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription, .textClipped, .trait]) { issue in
            // Audit only findings assigned to the new link; iOS also reports unassigned findings for existing content.
            guard let element = issue.element else { return true }
            return element.identifier != "privacy-policy" && element.label != expectedLabel
        }
        // The native audit can scroll while inspecting large text. Reveal the link again before tapping.
        for _ in 0..<12 where !link.isHittable { app.swipeUp(velocity: .slow) }
        // Activate only the app's native link. Do not automate the browser.
        link.tap()
        let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed)
        app.activate()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        app.buttons[german ? "Fertig" : "Done"].tap()
        app.terminate()
    }

    private func verifyLocalization(language: String, locale: String, german: Bool) {
        // Uses the same host-seeded synthetic offline library as testReadableLibrary.
        let app = launch(language: language, locale: locale)
        XCTAssertTrue(app.buttons["share-zwift-900000000001"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons["share-zwift-900000000001"].label, german ? "Teilen" : "Share")
        XCTAssertEqual(app.images["shared-status-zwift-900000000001"].label, german ? "Geteilt" : "Shared")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", german ? "Dauer:" : "Duration:")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", german ? "Zuletzt geteilt:" : "Last shared:")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", german ? "Strecke:" : "Distance:")).firstMatch.exists)
        capture(app, "Library-\(language)")
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", german ? "FITs bleiben offline verfügbar." : "FIT files remain available offline.")).firstMatch
        for _ in 0..<8 where !footer.isHittable { app.swipeUp() }
        XCTAssertTrue(footer.isHittable, app.debugDescription)
        capture(app, "Library-footer-\(language)")
        app.buttons[german ? "Konten" : "Accounts"].tap()
        XCTAssertTrue(app.navigationBars[german ? "Konten" : "Accounts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[german ? "Nicht verbunden" : "Not connected"].firstMatch.exists)
        capture(app, "Accounts-\(language)")
        app.buttons["source-zwift"].tap()
        app.buttons["connect-zwift"].tap()
        XCTAssertTrue(app.secureTextFields[german ? "Passwort" : "Password"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields[german ? "E-Mail" : "Email"].exists)
        XCTAssertFalse(app.buttons[german ? "Zwift verbinden" : "Connect Zwift"].isEnabled)
        capture(app, "Sign-in-\(language)")
        app.buttons[german ? "Abbrechen" : "Cancel"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons[german ? "Fertig" : "Done"].tap()
        let fileOptions = app.buttons["file-options-zwift-900000000001"]
        for _ in 0..<12 where !fileOptions.isHittable { app.swipeDown() }
        fileOptions.tap()
        app.buttons[german ? "Datei löschen" : "Delete file"].firstMatch.tap()
        XCTAssertTrue(app.buttons[german ? "Datei löschen" : "Delete file"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", german ? "Die Datei wird nur auf diesem iPhone gelöscht." : "The file will only be deleted on this iPhone.")).firstMatch.exists)
        capture(app, "Delete-confirmation-\(language)")
        // iOS may present a popover dismissed by tapping outside, without a Cancel button.
        app.terminate()
    }

    func testAccountsAndSecureZwiftForm() {
        let app = launch()
        app.buttons["Konten"].tap()
        XCTAssertTrue(app.navigationBars["Konten"].waitForExistence(timeout: 5))
        capture(app, "Konten")
        app.buttons["source-zwift"].tap()
        app.buttons["connect-zwift"].tap()
        XCTAssertTrue(app.secureTextFields["Passwort"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["E-Mail"].exists)
        XCTAssertFalse(app.buttons["Zwift verbinden"].isEnabled)
        capture(app, "Zwift-Anmeldung-ohne-Kontodaten")
        app.buttons["Abbrechen"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Fertig"].tap()
    }

    func testOfflineShareAndDeletionPersist() {
        // The host seeds only a synthetic local FIT before this test. No fake accounts or API responses.
        let app = launch()
        let share = app.buttons["share-zwift-900000000001"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "Offline-Aktivitaeten")
        share.tap()
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Schließen", "Close", "Abbrechen", "Cancel"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "Natives-Share-Sheet")
        close.tap()
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        app.buttons["file-options-zwift-900000000001"].tap()
        app.buttons["Datei löschen"].firstMatch.tap()
        app.buttons["Datei löschen"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Lokal gelöscht"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Lokal gelöscht"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["share-zwift-900000000001"].exists)
    }

    func testReadableLibrary() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Lokale Prüfaktivität mit einem langen Namen für kleine Bildschirme"].waitForExistence(timeout: 5))
        capture(app, "Adaptive-Aktivitaetsliste")
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "FITs bleiben offline verfügbar.")).firstMatch
        for _ in 0..<8 where !footer.isHittable { app.swipeUp() }
        XCTAssertTrue(footer.isHittable, app.debugDescription)
        capture(app, "Aktivitaetsliste-Fussbereich")
    }

    func testPullToRefreshPreservesOfflineLibrary() {
        let app = launch()
        let name = app.staticTexts["Lokale Prüfaktivität mit einem langen Namen für kleine Bildschirme"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(name.exists)
        XCTAssertFalse(app.alerts["FITgap"].exists)
        XCTAssertTrue(app.buttons["Konten"].isEnabled)
        capture(app, "Nach-Pull-to-Refresh-ohne-Konto")
    }

    func testStartupErrorCanBeDismissed() {
        // Host seeds an incompatible index only in the isolated test simulator.
        let app = launch()
        let alert = app.alerts["FITgap"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "inkompatibel")).firstMatch.exists)
        alert.buttons["OK"].tap()
        XCTAssertFalse(alert.exists)
        app.buttons["Konten"].tap()
        XCTAssertTrue(app.navigationBars["Konten"].waitForExistence(timeout: 5))
        app.buttons["Fertig"].tap()
        XCTAssertFalse(alert.exists)
        capture(app, "Startfehler-geschlossen")
    }
}
