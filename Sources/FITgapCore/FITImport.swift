import CryptoKit
import Foundation

public enum ImportError: Error, LocalizedError, Equatable {
    case notFIT(String), unreadable(String), demo
    public var errorDescription: String? {
        switch self {
        case .notFIT(let name): String(localized: "„\(name)“ ist keine vollständige FIT-Datei. Es wurde nichts importiert.", bundle: .module)
        case .unreadable(let name): String(localized: "„\(name)“ konnte nicht gelesen werden. Es wurde nichts importiert.", bundle: .module)
        case .demo: String(localized: "Im Demo-Modus können keine Dateien importiert werden. Beende zuerst die Demo.", bundle: .module)
        }
    }
}

public enum ImportResult: Sendable {
    /// A new activity whose original is stored and verified.
    case added(ActivityRecord)
    /// The same bytes are already in the library, imported or downloaded from a provider.
    case existing(ActivityKey)
}

extension ActivityLibrary {
    /// Stores a FIT the user opened in FITgap. Its checksum is the stable ID, so importing the same file again adds nothing.
    public func importFIT(_ data: Data, filename: String, into records: [ActivityRecord]) throws -> ImportResult {
        guard OriginalFITStore.isComplete(data) else { throw ImportError.notFIT(filename) }
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = ActivityKey(source: Source.imported.rawValue, id: sha256)
        if let known = records.first(where: { $0.key == key || ($0.status == .available && $0.receipt?.sha256 == sha256) }) {
            return .existing(known.key)
        }
        // A FIT without a readable session (e.g. a course or settings file) is not an activity.
        guard let activity = try? FITActivity.read(data) else { throw ImportError.notFIT(filename) }
        let name = (filename as NSString).deletingPathExtension
        let duration = activity.start.flatMap { start in activity.end.map { $0.timeIntervalSince(start) } }
        var record = ActivityRecord(source: .imported, remoteID: sha256, name: name, date: activity.start,
                                    duration: duration.flatMap { $0 >= 0 ? $0 : nil }, status: .available)
        record.receipt = try files.save(data, key: key)
        record.metrics = try? metrics(for: record)
        return .added(record)
    }
}
