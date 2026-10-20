import FITgapCore
import XCTest

final class DeviceStorageTests: XCTestCase {
    func testKeychainRoundTripAndLocalDisconnectPreserveFIT() throws {
        let credentials = CredentialStore(service: "org.fitgap.tests.\(UUID().uuidString)")
        defer { try? credentials.remove(.zwift) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ActivityLibrary(directory: directory)
        var record = ActivityRecord(source: .zwift, remoteID: "1", name: "Synthetic", date: nil, duration: nil)
        let bytes = Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, 0x81, 0, 0xff, 0, 0])
        record.receipt = try library.files.save(bytes, key: record.key)
        record.status = .available
        try library.save([record])
        try credentials.write(Credentials(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: nil), for: .zwift)
        XCTAssertEqual(try credentials.read(.zwift)?.refreshToken, "synthetic-refresh")
        try credentials.write(Credentials(accessToken: "synthetic-rotated", refreshToken: nil, expiresAt: nil), for: .zwift)
        XCTAssertEqual(try credentials.read(.zwift)?.accessToken, "synthetic-rotated")
        try credentials.remove(.zwift)
        XCTAssertNil(try credentials.read(.zwift))
        XCTAssertEqual(try Data(contentsOf: library.verifiedFile(for: library.load()[0])), bytes)
    }
}
