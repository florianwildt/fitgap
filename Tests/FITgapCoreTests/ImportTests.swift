import Foundation
import Testing
@testable import FITgapCore

private func libraryFixture() -> ActivityLibrary {
    ActivityLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}
private func demoFIT(_ id: String = "tempo") throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: "FITgap-Demo-\(id)", withExtension: "fit")))
}

@Test func importStoresVerifiedOriginalWithChecksumAsID() throws {
    let library = libraryFixture()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let data = try demoFIT()
    guard case .added(let record) = try library.importFIT(data, filename: "Morning Ride.fit", into: []) else {
        Issue.record("expected a new activity"); return
    }
    #expect(record.source == .imported)
    #expect(record.remoteID == record.receipt?.sha256)
    #expect(record.remoteID.count == 64)
    #expect(record.name == "Morning Ride")
    #expect(record.status == .available)
    #expect(record.date != nil && (record.duration ?? 0) > 0)
    #expect(record.metrics?.richness != nil)
    #expect(try Data(contentsOf: library.verifiedFile(for: record)) == data)
    #expect(!Source.providers.contains(.imported))
    #expect(FilesFolder.filename(for: record).hasSuffix("\(Source.imported.title) \(record.remoteID.prefix(12)).fit"))
}

@Test func importRejectsFilesThatAreNotCompleteActivities() throws {
    let library = libraryFixture()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let data = try demoFIT()
    #expect(throws: ImportError.notFIT("notes.txt")) { try library.importFIT(Data("hello, world".utf8), filename: "notes.txt", into: []) }
    #expect(throws: ImportError.notFIT("cut.fit")) { try library.importFIT(data.dropLast(10), filename: "cut.fit", into: []) }
    // Valid header but no session: not an activity.
    let empty = Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, 0x81, 0, 0xff, 0, 0])
    #expect(throws: ImportError.notFIT("course.fit")) { try library.importFIT(empty, filename: "course.fit", into: []) }
    let stored = (try? FileManager.default.contentsOfDirectory(atPath: library.files.directory.path)) ?? []
    #expect(stored.isEmpty)
}

@Test func importDeduplicatesByChecksumAcrossSources() throws {
    let library = libraryFixture()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    let data = try demoFIT()
    guard case .added(let first) = try library.importFIT(data, filename: "a.fit", into: []) else {
        Issue.record("expected a new activity"); return
    }
    // The same bytes under another name are the same import.
    guard case .existing(let key) = try library.importFIT(data, filename: "copy of a.fit", into: [first]) else {
        Issue.record("expected the existing import"); return
    }
    #expect(key == first.key)

    // A file already downloaded from a provider is not imported again.
    var downloaded = ActivityRecord(source: .wahoo, remoteID: "7", name: "", date: nil, duration: nil)
    downloaded.receipt = try library.files.save(data, key: downloaded.key)
    downloaded.status = .available
    guard case .existing(let wahoo) = try library.importFIT(data, filename: "a.fit", into: [downloaded]) else {
        Issue.record("expected the provider download"); return
    }
    #expect(wahoo == downloaded.key)

    // Other bytes are another activity.
    guard case .added(let other) = try library.importFIT(try demoFIT("recovery"), filename: "b.fit", into: [first]) else {
        Issue.record("expected a new activity"); return
    }
    #expect(other.key != first.key)
}

@Test func importedCopyJoinsDuplicateGroupWithProviderDownload() throws {
    let library = libraryFixture()
    defer { try? FileManager.default.removeItem(at: library.directory) }
    guard case .added(let imported) = try library.importFIT(try demoFIT(), filename: "a.fit", into: []) else {
        Issue.record("expected a new activity"); return
    }
    // A provider copy of the same ride that is still to load: the downloaded import wins.
    let pending = ActivityRecord(source: .zwift, remoteID: "1", name: "", date: imported.date, duration: imported.duration)
    let groups = DuplicateGroups([imported, pending])
    #expect(groups.hidden == [pending.key])
    #expect(groups.alternatives[imported.key] == [pending.key])
}
