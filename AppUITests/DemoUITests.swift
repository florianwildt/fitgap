import XCTest

@MainActor
final class DemoUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<45 {
            let safeTop = (app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 74) + 4
            let demoBottom = app.otherElements.matching(identifier: "demo-indicator")
                .allElementsBoundByIndex.map { $0.frame.minY }.max()
            let safeBottom = (demoBottom ?? app.frame.maxY - 20) - 4
            if element.exists, element.isHittable,
               element.frame.midY > safeTop, element.frame.midY < safeBottom { return }
            var moveUp = upward
            if element.exists, element.frame.height > 0 {
                if element.frame.midY <= safeTop { moveUp = false }
                else if element.frame.midY >= safeBottom { moveUp = true }
            }
            // Small drags avoid skipping a control between the fixed navigation/search bars.
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.68))
            let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.48))
            if moveUp { lower.press(forDuration: 0.05, thenDragTo: upper) }
            else { upper.press(forDuration: 0.05, thenDragTo: lower) }
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    func testGermanDemoLifecycle() { verifyDemo(german: true) }
    func testEnglishDemoLifecycle() { verifyDemo(german: false) }

    private func verifyDemo(german: Bool) {
        // Run on an isolated simulator with an empty real library and no provider credentials.
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", german ? "(de)" : "(en)", "-AppleLocale", german ? "de_DE" : "en_US"]
        app.launch()
        if app.descendants(matching: .any).matching(identifier: "demo-indicator").firstMatch.exists {
            let end = app.buttons["end-demo"]
            reveal(end, in: app); end.tap()
        }
        let start = app.buttons.matching(identifier: "try-demo").firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(start.label, german ? "Demo ausprobieren" : "Try Demo")
        reveal(start, in: app, upward: false)
        capture(app, "Demo-entry-\(german)")
        start.tap()
        let indicator = app.descendants(matching: .any).matching(identifier: "demo-indicator").firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertEqual(indicator.label, german ? "Demo – Beispieldaten" : "Demo – Sample Data")
        capture(app, "Demo-controls-\(german)")
        let share = app.buttons["share-demo-recovery"]
        reveal(share, in: app)
        XCTAssertTrue(app.staticTexts[german ? "Demo: Lockere Morgenfahrt" : "Demo: Easy Morning Ride"].exists)
        let metrics = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", german ? "Strecke:" : "Distance:")).firstMatch
        reveal(metrics, in: app)
        XCTAssertTrue(metrics.exists)
        XCTAssertTrue(metrics.label.contains(german ? "10,80" : "10.80"), metrics.label)
        XCTAssertTrue(indicator.isHittable)
        capture(app, "Demo-metrics-\(german)")
        // Tapping the row outside its buttons opens the session details read from the bundled FIT.
        metrics.tap()
        XCTAssertTrue(app.navigationBars[german ? "Demo: Lockere Morgenfahrt" : "Demo: Easy Morning Ride"].waitForExistence(timeout: 5))
        capture(app, "Demo-details-\(german)")
        // Rows below the fold are created lazily, e.g. with the largest accessibility text size.
        for value in ["0:30:00", german ? "120 S/min" : "120 bpm", german ? "Indoor-Radfahren" : "Indoor cycling"] {
            let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
            reveal(row, in: app)
            XCTAssertTrue(row.exists, app.debugDescription)
        }
        capture(app, "Demo-details-bottom-\(german)")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        reveal(share, in: app)
        share.tap()
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Schließen", "Close", "Abbrechen", "Cancel"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "FITgap-Demo-recovery")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "Demo-native-share-\(german)")
        close.tap()
        XCTAssertFalse(app.images["shared-status-demo-recovery"].exists)
        reveal(share, in: app); share.tap()
        let copy = app.cells.matching(NSPredicate(format: "label IN %@", ["Copy", "Kopieren"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.tap()
        XCTAssertTrue(app.images["shared-status-demo-recovery"].waitForExistence(timeout: 5))
        capture(app, "Demo-handoff-marked-\(german)")
        let options = app.buttons["file-options-demo-recovery"]
        reveal(options, in: app); options.tap()
        let delete = app.buttons[german ? "Datei löschen" : "Delete file"].firstMatch
        delete.tap(); delete.tap()
        let deleted = app.staticTexts[german ? "Lokal gelöscht" : "Deleted locally"]
        XCTAssertTrue(deleted.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, "Demo-deleted-\(german)")
        app.terminate(); app.launch()
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        reveal(deleted, in: app)
        XCTAssertTrue(deleted.exists)
        XCTAssertFalse(share.exists)
        let restore = app.buttons[german ? "Wiederherstellen" : "Restore"].firstMatch
        reveal(restore, in: app); restore.tap()
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        let notice = app.staticTexts["demo-notice"]
        reveal(notice, in: app, upward: false)
        XCTAssertTrue(notice.label.contains(german ? "Keine Anbieteranfrage" : "No provider request"))
        let reset = app.buttons["reset-demo"]
        reveal(reset, in: app, upward: false); reset.tap()
        app.buttons[german ? "Demo zurücksetzen" : "Reset Demo"].firstMatch.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains(german ? "Demo zurückgesetzt" : "Demo reset"))
        app.buttons[german ? "Konten" : "Accounts"].tap()
        let connect = app.buttons["connect-zwift"]
        reveal(connect, in: app)
        XCTAssertFalse(connect.isEnabled)
        XCTAssertTrue(indicator.exists)
        capture(app, "Demo-accounts-\(german)")
        let privacy = app.descendants(matching: .any).matching(identifier: "privacy-policy").firstMatch
        reveal(privacy, in: app)
        XCTAssertTrue(privacy.isEnabled)
        capture(app, "Demo-privacy-preserved-\(german)")
        let end = app.buttons["accounts-end-demo"]
        reveal(end, in: app, upward: false)
        end.tap()
        capture(app, "Demo-after-end-\(german)")
        reveal(app.buttons["accounts-try-demo"], in: app, upward: false)
        app.buttons[german ? "Fertig" : "Done"].tap()
        XCTAssertFalse(indicator.exists)
        reveal(start, in: app, upward: false)
        XCTAssertTrue(start.exists)
        app.terminate(); app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(indicator.exists)
        app.buttons[german ? "Konten" : "Accounts"].tap()
        let accountStart = app.buttons["accounts-try-demo"]
        reveal(accountStart, in: app, upward: false); accountStart.tap()
        reveal(app.buttons["accounts-end-demo"], in: app)
        app.buttons["accounts-end-demo"].tap()
        app.buttons[german ? "Fertig" : "Done"].tap()
        XCTAssertFalse(indicator.exists)
        capture(app, "Demo-ended-\(german)")
        app.terminate()
    }
}
