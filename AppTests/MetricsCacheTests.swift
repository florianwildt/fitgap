import FITgapCore
import XCTest
@testable import FITgap

@MainActor
final class MetricsCacheTests: XCTestCase {
    private func fixture(count: Int) throws -> ActivityLibrary {
        let library = ActivityLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        // Synthetic session: 1,000 m, 20 m ascent, 5 m/s. Original bytes are never changed by the app.
        let body: [UInt8] = [0x40, 0, 0, 18, 0, 3, 9, 4, 0x86, 22, 2, 0x84, 124, 4, 0x86, 0,
                             0xa0, 0x86, 1, 0, 20, 0, 0x88, 0x13, 0, 0]
        let data = Data([14, 0x20, 0, 0, UInt8(body.count), 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0] + body + [0, 0])
        var records: [ActivityRecord] = []
        for id in 0..<count {
            var record = ActivityRecord(source: .wahoo, remoteID: String(id), name: "Synthetic", date: nil, duration: 200)
            record.receipt = try library.files.save(data, key: record.key)
            record.status = .available
            record.sharedAt = Date(timeIntervalSince1970: 1000)
            records.append(record)
        }
        try library.save(records)
        return library
    }

    private func model(_ library: ActivityLibrary) -> AppModel {
        let id = UUID().uuidString
        return AppModel(library: library, credentials: CredentialStore(service: "org.fitgap.cache.\(id)"),
                        defaults: UserDefaults(suiteName: "org.fitgap.cache.\(id)")!)
    }

    func testInterruptedMetricsPassPersistsCompletedBatchAndResumesOnlyMissingEntries() async throws {
        let library = try fixture(count: 25)
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let first = model(library)
        let observer = first.$activities.dropFirst().sink { records in
            if records.filter({ $0.metrics != nil }).count == 10 { first.cancel() }
        }
        first.start()
        await first.refreshAndWait()
        observer.cancel()
        XCTAssertNil(first.errorMessage)
        let saved = try library.load()
        XCTAssertEqual(saved.filter { $0.metrics != nil }.count, 10)
        XCTAssertTrue(saved.allSatisfy { $0.sharedAt == Date(timeIntervalSince1970: 1000) })
        // Corrupt one already cached test file: it must never be read for metrics on continuation.
        let cached = try XCTUnwrap(saved.first { $0.metrics != nil })
        let path = library.files.directory.appendingPathComponent(cached.key.filename)
        try Data("synthetic unreadable original".utf8).write(to: path)
        let resumed = model(library)
        resumed.start()
        await resumed.refreshAndWait()
        XCTAssertEqual(try library.load().filter { $0.metrics != nil }.count, 25)
        XCTAssertTrue(resumed.activities.allSatisfy { $0.metrics?.distanceMeters == 1000 })
        XCTAssertNil(resumed.errorMessage)
        // Sharing still checks the original bytes even though displaying cached totals does not.
        XCTAssertThrowsError(try library.verifiedFile(for: cached))
    }

    func testWarmStartUsesSavedMetricsWithoutStartingFITProcessing() async throws {
        let library = try fixture(count: 1)
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let cold = model(library)
        cold.start()
        await cold.refreshAndWait()
        let saved = try library.load()[0]
        XCTAssertEqual(saved.metrics?.averageSpeedMetersPerSecond, 5)
        try Data("synthetic unreadable original".utf8).write(to: library.files.directory.appendingPathComponent(saved.key.filename))
        let warm = model(library)
        warm.start()
        XCTAssertFalse(warm.busy)
        XCTAssertEqual(warm.progress, "")
        XCTAssertEqual(warm.activities[0].metrics, saved.metrics)
        XCTAssertNil(warm.errorMessage)
    }
}
