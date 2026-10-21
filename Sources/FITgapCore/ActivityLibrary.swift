import CryptoKit
import Foundation

public enum DownloadStatus: String, Codable, Sendable {
    case pending, available, failed, unavailable, deleted
    public var title: String {
        switch self {
        case .pending: String(localized: "Noch nicht geladen", bundle: .module)
        case .available: String(localized: "Offline verfügbar", bundle: .module)
        case .failed: String(localized: "Download fehlgeschlagen", bundle: .module)
        case .unavailable: String(localized: "Keine FIT verfügbar", bundle: .module)
        case .deleted: String(localized: "Lokal gelöscht", bundle: .module)
        }
    }
}

public struct ActivityRecord: Codable, Identifiable, Sendable {
    public let source: Source
    public let remoteID: String
    public var name: String
    public var date: Date?
    public var duration: TimeInterval?
    public var status: DownloadStatus
    public var receipt: FITReceipt?
    public var sharedAt: Date?
    public var metrics: ActivityMetrics?
    public var key: ActivityKey { ActivityKey(source: source.rawValue, id: remoteID) }
    public var id: String { key.filename }
    /// Missing or older cached metrics are read once more from the verified original FIT.
    public var needsMetrics: Bool { status == .available && metrics?.isCurrent != true }

    public init(source: Source, remoteID: String, name: String, date: Date?, duration: TimeInterval?, status: DownloadStatus = .pending) {
        self.source = source; self.remoteID = remoteID; self.name = name
        self.date = date; self.duration = duration; self.status = status
    }

    public static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }

    public init(_ activity: ZwiftActivity) {
        let start = Self.parseDate(activity.startDate)
        let duration = Self.parseDate(activity.endDate).flatMap { end in start.map { end.timeIntervalSince($0) } }
        self.init(source: .zwift, remoteID: String(activity.id), name: activity.name, date: start,
                  duration: duration.flatMap { $0 >= 0 ? $0 : nil },
                  status: activity.downloadURL == nil ? .unavailable : .pending)
    }

    public init(_ workout: WahooWorkout) {
        // A missing provider title stays language-neutral in the stored index.
        self.init(source: .wahoo, remoteID: String(workout.id), name: workout.name ?? "",
                  date: Self.parseDate(workout.starts),
                  duration: workout.workout_summary?.duration_total_accum.flatMap(Double.init) ?? workout.minutes.map { $0 * 60 },
                  status: workout.workout_summary == nil ? .unavailable : .pending)
    }
}

public enum LibraryError: Error, LocalizedError {
    case invalidIndex, integrity
    public var errorDescription: String? {
        switch self {
        case .invalidIndex: String(localized: "Der lokale Aktivitätsbestand ist nicht lesbar oder inkompatibel. Vorhandene Dateien bleiben erhalten.", bundle: .module)
        case .integrity: String(localized: "Die lokale Datei fehlt oder ihre Prüfsumme stimmt nicht. Bitte die Datei löschen und erneut laden.", bundle: .module)
        }
    }
}

public struct ActivityLibrary: Sendable {
    public let directory: URL
    public var files: OriginalFITStore { OriginalFITStore(directory: directory.appendingPathComponent("Files", isDirectory: true)) }
    private var index: URL { directory.appendingPathComponent("activities.json") }
    private struct Index: Codable { let version: Int; let activities: [ActivityRecord] }
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> [ActivityRecord] {
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        let decoded: Index
        do { decoded = try JSONDecoder().decode(Index.self, from: Data(contentsOf: index)) }
        catch { throw LibraryError.invalidIndex }
        guard decoded.version == 1, Set(decoded.activities.map(\.key)).count == decoded.activities.count else {
            throw LibraryError.invalidIndex
        }
        return decoded.activities.map { record in
            var record = record
            let file = files.directory.appendingPathComponent(record.key.filename)
            if record.status != .deleted, FileManager.default.fileExists(atPath: file.path), record.receipt == nil,
               let data = try? Data(contentsOf: file.appendingPathExtension("json")),
               let receipt = try? JSONDecoder().decode(FITReceipt.self, from: data), receipt.key == record.key {
                // Recover a completed download if the app stopped before the index write.
                record.receipt = receipt; record.status = .available
            } else if record.status == .available, !FileManager.default.fileExists(atPath: file.path) {
                record.receipt = nil; record.status = .pending
            }
            return record
        }
    }

    public func save(_ records: [ActivityRecord]) throws {
        guard Set(records.map(\.key)).count == records.count else { throw LibraryError.invalidIndex }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Index(version: 1, activities: records)).write(to: index, options: .atomic)
    }

    public static func merging(_ incoming: [ActivityRecord], into existing: [ActivityRecord]) -> [ActivityRecord] {
        var records = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for incoming in incoming {
            if var previous = records[incoming.key] {
                previous.name = incoming.name; previous.date = incoming.date; previous.duration = incoming.duration
                if previous.status == .unavailable { previous.status = incoming.status }
                records[incoming.key] = previous
            } else { records[incoming.key] = incoming }
        }
        return records.values.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.id < $1.id
        }
    }

    private func verifiedData(for record: ActivityRecord) throws -> Data {
        let file = files.directory.appendingPathComponent(record.key.filename)
        guard let receipt = record.receipt, receipt.key == record.key,
              let data = try? Data(contentsOf: file), data.count == receipt.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == receipt.sha256 else { throw LibraryError.integrity }
        return data
    }

    public func verifiedFile(for record: ActivityRecord) throws -> URL {
        _ = try verifiedData(for: record)
        return files.directory.appendingPathComponent(record.key.filename)
    }

    public func metrics(for record: ActivityRecord) throws -> ActivityMetrics {
        FITMetrics.read(try verifiedData(for: record)) ?? ActivityMetrics()
    }

    public func deletingFile(for record: ActivityRecord) throws -> ActivityRecord {
        let file = files.directory.appendingPathComponent(record.key.filename)
        for url in [file, file.appendingPathExtension("json")] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var record = record
        record.receipt = nil; record.sharedAt = nil; record.status = .deleted
        return record
    }
}
