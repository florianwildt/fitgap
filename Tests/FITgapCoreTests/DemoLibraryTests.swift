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
    for (record, expected) in zip(records, [(10800.0, 30.0, 6.0), (28800.0, 120.0, 8.0), (21600.0, 80.0, 9.0)]) {
        #expect(record.source == .demo)
        #expect(record.metrics == ActivityMetrics(distanceMeters: expected.0, ascentMeters: expected.1,
                                                  averageSpeedMetersPerSecond: expected.2))
        let original = try demo.library.verifiedFile(for: record)
        let exported = try demo.export(record)
        #expect(exported.lastPathComponent.hasPrefix("FITgap-Demo-"))
        #expect(try Data(contentsOf: original) == Data(contentsOf: exported))
        #expect(record.receipt!.byteCount < 4096)
    }
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
