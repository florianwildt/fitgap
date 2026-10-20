import XCTest

@MainActor
final class FITgapUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testAccountsAndSecureZwiftForm() {
        let app = launch()
        app.buttons["Konten"].tap()
        XCTAssertTrue(app.navigationBars["Konten"].waitForExistence(timeout: 5))
        capture(app, "Konten")
        app.buttons["connect-zwift"].tap()
        XCTAssertTrue(app.secureTextFields["Passwort"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["E-Mail"].exists)
        XCTAssertFalse(app.buttons["Zwift verbinden"].isEnabled)
        capture(app, "Zwift-Anmeldung-ohne-Kontodaten")
        app.buttons["Abbrechen"].tap()
        app.buttons["Fertig"].tap()
    }

    func testOfflineShareAndDeletionPersist() {
        // The host seeds only a synthetic local FIT before this test. No fake accounts or API responses.
        let app = launch()
        let share = app.buttons["share-zwift-900000000001"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Aktualisieren"].isEnabled)
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
