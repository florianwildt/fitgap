import CryptoKit
import Foundation

public enum ProbeError: Error, LocalizedError {
    case invalidResponse, invalidFIT, changedFile, pagination, noFIT, unsafeURL
    case http(Int), terminal

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Der Anbieter hat unerwartete Daten geliefert. Bitte später erneut versuchen."
        case .invalidFIT: "Keine vollständige FIT-Datei erhalten. Es wurde nichts gespeichert."
        case .changedFile: "Für diese Aktivität sind bereits andere Bytes gespeichert. Datei bleibt erhalten."
        case .pagination: "Die Aktivitätsliste konnte nicht vollständig geladen werden. Bitte später erneut versuchen."
        case .noFIT: "Keine FIT-Datei verfügbar."
        case .unsafeURL: "Unzulässige Downloadadresse. Prüfung abgebrochen."
        case .http(let code):
            switch code {
            case 401: "Anmeldung abgelehnt oder Sitzung abgelaufen (HTTP 401)."
            case 403: "Zugriff verweigert (HTTP 403). Kontoberechtigung oder Schnittstellenfreigabe prüfen."
            case 429: "Abruflimit erreicht (HTTP 429). Später erneut versuchen."
            default: "Serverfehler (HTTP \(code))."
            }
        case .terminal: "Ein lokales interaktives Terminal mit verdeckter Eingabe ist erforderlich."
        }
    }
}

public struct ActivityKey: Codable, Hashable, Sendable {
    public let source: String
    public let id: String

    public init(source: String, id: String) {
        self.source = source
        self.id = id
    }

    public var filename: String {
        // JSON keeps even unusual IDs unambiguous and out of filesystem paths.
        let data = try! JSONEncoder().encode([source, id])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".fit"
    }
}

public struct FITReceipt: Codable, Sendable {
    public let key: ActivityKey
    public let sha256: String
    public let byteCount: Int
    public let checkedAt: Date
}

public struct OriginalFITStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func save(_ data: Data, key: ActivityKey) throws -> FITReceipt {
        try Task.checkCancellation()
        // Only inspect the header and declared length; never decode/re-encode FIT records.
        guard data.count >= 14 else { throw ProbeError.invalidFIT }
        let bytes = [UInt8](data.prefix(12))
        let header = Int(bytes[0])
        let body = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        guard [12, 14].contains(header), Array(bytes[8..<12]) == Array(".FIT".utf8),
              data.count == header + body + 2 else { throw ProbeError.invalidFIT }
        let receipt = FITReceipt(
            key: key, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count, checkedAt: Date()
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(key.filename)
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file) == data else { throw ProbeError.changedFile }
        } else {
            try Task.checkCancellation()
            // Foundation forbids .atomic + .withoutOverwriting. A complete staging file
            // on the same filesystem is published with an exclusive atomic hard link.
            let staging = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: staging) }
            try data.write(to: staging, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            try Task.checkCancellation()
            try FileManager.default.linkItem(at: staging, to: file)
        }
        // A crash between the two writes is recoverable: the next run verifies the existing FIT.
        try JSONEncoder().encode(receipt).write(to: file.appendingPathExtension("json"), options: .atomic)
        return receipt
    }
}

public enum Pages {
    /// Continue through short pages too: the unofficial server may impose its own page size.
    public static func collect<T: Sendable>(
        limit: Int = 20, maximumPages: Int = 500,
        key: @Sendable (T) -> ActivityKey,
        fetch: @Sendable (_ start: Int, _ limit: Int) async throws -> [T]
    ) async throws -> [T] {
        guard limit > 0, maximumPages > 0 else { throw ProbeError.pagination }
        var result: [T] = []
        var seen = Set<ActivityKey>()
        var start = 0
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let page = try await fetch(start, limit)
            if page.isEmpty { return result }
            let fresh = page.filter { seen.insert(key($0)).inserted }
            guard !fresh.isEmpty else { throw ProbeError.pagination }
            result.append(contentsOf: fresh)
            start += page.count
        }
        throw ProbeError.pagination
    }
}
