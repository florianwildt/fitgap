import Foundation
import Testing
@testable import FITgapCore

@Test func bundledDemoUsesIndependentLibraryWithConsistentMetricsAndVerifiedExports() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("Real")
    let demo = DemoLibrary(realDirectory: real)
    let records = try demo.load()
    #expect(records.count == 3)
    #expect(!FileManager.default.fileExists(atPath: real.path))
    // Values written by the official Garmin FIT SDK in scripts/generate-demo-fit.py.
    let samples = [(10800.0, 30.0, 6.0, 1800.0, 120.0), (28800.0, 120.0, 8.0, 3600.0, 145.0), (21600.0, 80.0, 9.0, 2400.0, 155.0)]
    for (record, expected) in zip(records, samples) {
        #expect(record.source == .demo)
        #expect(record.metrics == ActivityMetrics(distanceMeters: expected.0, ascentMeters: expected.1,
            averageSpeedMetersPerSecond: expected.2, descentMeters: 0, timerSeconds: expected.3, elapsedSeconds: expected.3,
            maximumSpeedMetersPerSecond: expected.2, averageHeartRate: expected.4, maximumHeartRate: expected.4,
            sport: 2, subSport: 6))
        let original = try demo.library.verifiedFile(for: record)
        let exported = try demo.export(record)
        #expect(exported.lastPathComponent.hasPrefix("FITgap-Demo-"))
        #expect(try Data(contentsOf: original) == Data(contentsOf: exported))
        #expect(record.receipt!.byteCount < 4096)
    }
    // A demo cache from before the extended session fields is read again once.
    var legacy = records
    legacy[1].metrics = try JSONDecoder().decode(ActivityMetrics.self, from: Data(#"{"distanceMeters":28800}"#.utf8))
    #expect(legacy[1].needsMetrics)
    try demo.library.save(legacy)
    #expect(try demo.load()[1].metrics == records[1].metrics)
    let record = records[0]
    let file = try demo.library.verifiedFile(for: record)
    try Data("deliberately corrupt synthetic file".utf8).write(to: file)
    #expect(throws: LibraryError.self) { try demo.export(record) }
    #expect(throws: LibraryError.self) {
        try demo.restoring(ActivityRecord(source: .wahoo, remoteID: "recovery", name: "", date: nil, duration: nil))
    }
    #expect(throws: LibraryError.self) {
        try demo.export(ActivityRecord(source: .demo, remoteID: "../unknown", name: "", date: nil, duration: nil))
    }
}
