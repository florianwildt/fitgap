import FITgapCore
import XCTest
@testable import FITgap

@MainActor
final class LocalizationTests: XCTestCase {
    func testErrorsAndStatusFollowAppLanguage() {
        let german = Bundle.main.preferredLocalizations.first == "de"
        XCTAssertEqual(DownloadStatus.deleted.title, german ? "Lokal gelöscht" : "Deleted locally")
        XCTAssertEqual(DownloadStatus.failed.title, german ? "Download fehlgeschlagen" : "Download failed")
        XCTAssertEqual(AppModel.message(AccountError.reconnect), german
            ? "Sitzung abgelaufen. Bitte das Konto erneut verbinden."
            : "Session expired. Please reconnect your account.")
        XCTAssertEqual(AppModel.message(ProbeError.http(503)), german
            ? "Serverfehler (HTTP 503)." : "Server error (HTTP 503).")
        XCTAssertTrue(AppModel.message(WahooError.token("invalid_grant")).contains(german
            ? "Wahoo hat die Sitzung abgelehnt (invalid_grant)." : "Wahoo rejected the session (invalid_grant)."))
        XCTAssertTrue(AppModel.message(WahooRateLimit(until: Date(timeIntervalSince1970: 1000))).hasPrefix(german
            ? "Abruflimit erreicht." : "Request limit reached."))
        XCTAssertTrue(AppModel.message(URLError(.notConnectedToInternet)).hasPrefix(german
            ? "Netzwerk nicht erreichbar" : "Network unavailable"))
        XCTAssertTrue(AppModel.message(LibraryError.invalidIndex).contains(german ? "inkompatibel" : "incompatible"))
    }

    func testInterpolatedProgressAndBothTranslationTables() throws {
        for language in ["de", "en"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Datenschutzerklärung", value: nil, table: nil),
                           language == "de" ? "Datenschutzerklärung" : "Privacy Policy")
            XCTAssertEqual(bundle.localizedString(forKey: "Datenschutz", value: nil, table: nil),
                           language == "de" ? "Datenschutz" : "Privacy")
            let format = bundle.localizedString(forKey: "Wahoo: FIT %lld von %lld", value: nil, table: nil)
            XCTAssertEqual(String(format: format, Int64(2), Int64(12)), language == "de"
                ? "Wahoo: FIT 2 von 12" : "Wahoo: FIT 2 of 12")
        }
    }
}
