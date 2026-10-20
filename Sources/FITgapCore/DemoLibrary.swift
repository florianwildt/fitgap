import Foundation

/// Owns only the sibling demo directory. No provider IDs, credentials or network access.
public struct DemoLibrary: Sendable {
    public let library: ActivityLibrary
    public init(realDirectory: URL) {
        library = ActivityLibrary(directory: realDirectory.deletingLastPathComponent()
            .appendingPathComponent(realDirectory.lastPathComponent + "-Demo", isDirectory: true))
    }

    private struct Sample {
        let id: String
        let date: String
        let duration: TimeInterval
    }
    private static let samples = [
        Sample(id: "recovery", date: "2026-06-15T07:00:00Z", duration: 1800),
        Sample(id: "endurance", date: "2026-06-13T09:30:00Z", duration: 3600),
        Sample(id: "tempo", date: "2026-06-10T17:15:00Z", duration: 2400)
    ]

    public func load() throws -> [ActivityRecord] {
        if FileManager.default.fileExists(atPath: library.directory.appendingPathComponent("activities.json").path) {
            return try library.load()
        }
        let records = try Self.samples.map { sample in
            try restoring(ActivityRecord(source: .demo, remoteID: sample.id, name: "",
                                         date: ActivityRecord.parseDate(sample.date), duration: sample.duration))
        }
        try library.save(records)
        return records
    }

    public func reset() throws -> [ActivityRecord] {
        // Read every bundled replacement before touching the existing demo state.
        for sample in Self.samples { _ = try bytes(id: sample.id) }
        if FileManager.default.fileExists(atPath: library.directory.path) {
            try FileManager.default.removeItem(at: library.directory)
        }
        return try load()
    }

    public func restoring(_ record: ActivityRecord) throws -> ActivityRecord {
        guard record.source == .demo else { throw LibraryError.invalidIndex }
        var restored = record
        restored.receipt = try library.files.save(bytes(id: record.remoteID), key: record.key)
        restored.metrics = try library.metrics(for: restored)
        restored.status = .available
        return restored
    }

    public func export(_ record: ActivityRecord) throws -> URL {
        guard record.source == .demo, Self.samples.contains(where: { $0.id == record.remoteID }) else {
            throw LibraryError.invalidIndex
        }
        let original = try library.verifiedFile(for: record)
        let exports = library.directory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let file = exports.appendingPathComponent("FITgap-Demo-\(record.remoteID).fit")
        try Data(contentsOf: original).write(to: file, options: .atomic)
        return file
    }

    public func removeExport(_ record: ActivityRecord) throws {
        guard record.source == .demo, Self.samples.contains(where: { $0.id == record.remoteID }) else {
            throw LibraryError.invalidIndex
        }
        let file = library.directory.appendingPathComponent("Exports/FITgap-Demo-\(record.remoteID).fit")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func bytes(id: String) throws -> Data {
        guard Self.samples.contains(where: { $0.id == id }),
              let url = Bundle.module.url(forResource: "FITgap-Demo-\(id)", withExtension: "fit") else {
            throw LibraryError.invalidIndex
        }
        return try Data(contentsOf: url)
    }
}
