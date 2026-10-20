import Foundation
import Testing
@testable import FITgapCore

private func libraryFixture() -> ActivityLibrary {
    ActivityLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}
private let fitBytes = Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, 0x81, 0, 0xff, 0, 0])
private func record(_ source: Source = .zwift) -> ActivityRecord {
    ActivityRecord(source: source, remoteID: "42", name: "Synthetic", date: Date(), duration: 120)
}

@Test func catalogMergesSourcesAndPreservesOfflineAndDeletedFiles() throws {
    let library = libraryFixture()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    var available = record()
    available.receipt = try library.files.save(fitBytes, key: available.key)
    available.status = .available
    available.sharedAt = Date()
    var incoming = available
    incoming.name = "Updated"; incoming.receipt = nil; incoming.sharedAt = nil; incoming.status = .pending
    var merged = ActivityLibrary.merging([incoming, record(.wahoo), incoming], into: [available])
    #expect(merged.count == 2)
    #expect(merged.first(where: { $0.source == .zwift })?.receipt?.sha256 == available.receipt?.sha256)
    #expect(merged.first(where: { $0.source == .zwift })?.sharedAt == available.sharedAt)
    try library.save(merged)
    #expect(try library.load().first(where: { $0.source == .zwift })?.sharedAt == available.sharedAt)
    #expect(try library.load().first(where: { $0.source == .wahoo })?.sharedAt == nil)
    let deleted = try library.deletingFile(for: available)
    merged = ActivityLibrary.merging([incoming], into: [deleted])
    #expect(merged[0].status == .deleted)
    try library.save(merged)
    #expect(try library.load()[0].status == .deleted)
    #expect(!FileManager.default.fileExists(atPath: library.files.directory.appendingPathComponent(available.key.filename).path))
}

@Test func completedFileRecoversAfterInterruptedIndexUpdateAndChecksBeforeSharing() throws {
    let library = libraryFixture()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let pending = record()
    try library.save([pending])
    _ = try library.files.save(fitBytes, key: pending.key)
    let recovered = try library.load()[0]
    #expect(recovered.status == .available)
    #expect(try Data(contentsOf: library.verifiedFile(for: recovered)) == fitBytes)
    let file = library.files.directory.appendingPathComponent(recovered.key.filename)
    try Data("damaged".utf8).write(to: file)
    #expect(throws: LibraryError.self) { try library.verifiedFile(for: recovered) }
}

@Test func incompatibleCatalogIsPreserved() throws {
    let library = libraryFixture()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    try library.save([record()])
    let file = library.directory.appendingPathComponent("activities.json")
    let newer = Data(#"{"version":999,"activities":[]}"#.utf8)
    try newer.write(to: file)
    #expect(throws: LibraryError.self) { try library.load() }
    #expect(try Data(contentsOf: file) == newer)
}

@Test func providerDatesAndTotalDurationUseRealSchema() throws {
    let zwift = try JSONDecoder().decode(ZwiftActivity.self, from: Data(#"{"id":1,"name":"Synthetic","startDate":"2026-10-20T10:00:00.000Z","endDate":"2026-10-20T11:00:30Z"}"#.utf8))
    #expect(ActivityRecord(zwift).duration == 3630)
    let wahoo = try JSONDecoder().decode(WahooWorkout.self, from: Data(#"{"id":1,"starts":"2026-10-20T10:00:00Z","minutes":60,"workout_summary":{"duration_total_accum":"3630.50","file":null}}"#.utf8))
    #expect(ActivityRecord(wahoo).duration == 3630.5)
    #expect(ActivityRecord(wahoo).date == ActivityRecord(zwift).date)
}

@Test func missingProviderTitleRemainsLanguageNeutralInStoredRecord() throws {
    let unnamed = WahooWorkout(id: 1, name: nil, starts: nil, minutes: nil, workout_summary: nil)
    #expect(ActivityRecord(unnamed).name.isEmpty)
    let named = WahooWorkout(id: 2, name: "My ride / Meine Fahrt", starts: nil, minutes: nil, workout_summary: nil)
    #expect(ActivityRecord(named).name == "My ride / Meine Fahrt")
}
