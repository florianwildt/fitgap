import Compression
import Foundation

public struct IntervalsActivity: Decodable, Sendable {
    public let id: String
    public let name: String?
    /// UTC start time (`2024-05-01T06:00:00Z`).
    public let start_date: String?
    /// Local start time without zone; the list endpoint pages by it.
    public let start_date_local: String?
    public let elapsed_time: Double?
    public let moving_time: Double?
    /// Format of the original upload (`fit`, `gpx`, `tcx`); missing for Strava stubs and manual entries.
    public let file_type: String?
    public let source: String?
    public var key: ActivityKey { ActivityKey(source: Source.intervals.rawValue, id: id) }

    /// Only originals uploaded as FIT; Strava stubs offer no file at all.
    public var hasOriginalFIT: Bool { file_type?.lowercased() == "fit" && source?.uppercased() != "STRAVA" }

    /// IDs end up in URL paths; intervals.icu uses `i12345678`.
    static func valid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// The `newest` cursor is sent as a query value; only the documented local form is accepted.
    static func cursor(_ local: String?) -> String? {
        guard let local, local.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return local
    }
}

/// Athlete ID and personal API key from intervals.icu › Settings › Developer Settings.
public struct IntervalsAccount: Sendable {
    public let athleteID: String
    public let apiKey: String

    public init(athleteID: String, apiKey: String) throws {
        let athlete = athleteID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validAthlete(athlete), !key.isEmpty, key.count <= 200, !key.contains(where: \.isNewline) else {
            throw IntervalsError.rejected
        }
        self.athleteID = athlete; self.apiKey = key
    }

    public init(_ credentials: Credentials) throws {
        guard let athlete = credentials.accountID else { throw AccountError.reconnect }
        try self.init(athleteID: athlete, apiKey: credentials.accessToken)
    }

    /// `i12345` as shown in the settings; plain digits are accepted as well.
    static func validAthlete(_ id: String) -> Bool {
        id.count <= 20 && id.range(of: "^i?[0-9]+$", options: .regularExpression) != nil
    }

    /// The API key does not expire; it stays valid until the user regenerates it.
    public var credentials: Credentials {
        Credentials(accessToken: apiKey, refreshToken: nil, expiresAt: nil, accountID: athleteID)
    }

    var authorization: String { "Basic " + Data("API_KEY:\(apiKey)".utf8).base64EncodedString() }
}

public enum IntervalsError: Error, LocalizedError {
    case rejected
    public var errorDescription: String? {
        String(localized: "intervals.icu hat Athleten-ID oder API-Key abgelehnt. Bitte beides in den Developer Settings prüfen.", bundle: .module)
    }
}

/// Client for the official intervals.icu API (https://intervals.icu/api-docs.html) with Basic auth
/// (`API_KEY` and the personal key). Only original files are downloaded, never the regenerated `fit-file`.
public final class IntervalsProbe: Sendable {
    private let session: URLSession
    private let base = "https://intervals.icu/api/v1"
    static let fields = "id,name,start_date,start_date_local,elapsed_time,moving_time,file_type,source"

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    init(session: URLSession) { self.session = session }

    public func close() { session.invalidateAndCancel() }

    /// Checks ID and key with one minimal list request; nothing is stored here.
    public func verify(_ account: IntervalsAccount) async throws {
        do { _ = try await list(account, oldest: "2000-01-01", newest: nil, limit: 1) }
        catch ProbeError.http(let code) where code == 401 || code == 403 || code == 404 { throw IntervalsError.rejected }
    }

    /// Activities with an original FIT, newest first, from `since` on (whole days) or all.
    /// The list has no pages; it is read backwards in windows ending at the oldest start seen so far.
    public func activities(_ account: IntervalsAccount, since: Date? = nil, pageSize: Int = 200,
                           maximumPages: Int = 500) async throws -> [IntervalsActivity] {
        var oldest = "1970-01-01"
        if let since {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let day = calendar.dateComponents([.year, .month, .day], from: since)
            oldest = String(format: "%04d-%02d-%02d", day.year ?? 1970, day.month ?? 1, day.day ?? 1)
        }
        var result: [IntervalsActivity] = []
        var seen = Set<String>()
        var newest: String?
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let page = try await list(account, oldest: oldest, newest: newest, limit: pageSize)
            guard page.count <= pageSize else { throw ProbeError.pagination }
            let fresh = page.filter { IntervalsActivity.valid($0.id) && seen.insert($0.id).inserted }
            result.append(contentsOf: fresh.filter(\.hasOriginalFIT))
            if page.count < pageSize { return result }
            // A full window that adds nothing new would repeat forever.
            guard !fresh.isEmpty, let next = page.compactMap({ IntervalsActivity.cursor($0.start_date_local) }).min() else {
                throw ProbeError.pagination
            }
            newest = next
        }
        throw ProbeError.pagination
    }

    func list(_ account: IntervalsAccount, oldest: String, newest: String?, limit: Int) async throws -> [IntervalsActivity] {
        var parts = URLComponents(string: base + "/athlete/\(account.athleteID)/activities")!
        parts.queryItems = [URLQueryItem(name: "oldest", value: oldest)] + (newest.map { [URLQueryItem(name: "newest", value: $0)] } ?? [])
            + [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "fields", value: Self.fields)]
        var request = URLRequest(url: parts.url!)
        request.setValue(account.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        do { return try JSONDecoder().decode([IntervalsActivity].self, from: data) }
        catch { throw ProbeError.invalidResponse }
    }

    /// The original upload, which intervals.icu serves gzip-compressed. GPX/TCX originals count as no FIT.
    public func download(id: String, account: IntervalsAccount, store: OriginalFITStore) async throws -> FITReceipt {
        guard IntervalsActivity.valid(id) else { throw ProbeError.invalidResponse }
        var request = URLRequest(url: URL(string: base + "/activity/\(id)/file")!)
        request.setValue(account.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/gzip, application/octet-stream, */*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        var file: Data
        switch response.statusCode {
        case 200: file = data
        case 301, 302, 303, 307, 308:
            // A storage link is fetched once without the API key.
            guard let location = response.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0, relativeTo: request.url) })?.absoluteURL,
                  let url = MyWhooshActivity.allowed(location) else { throw ProbeError.unsafeURL }
            var plain = URLRequest(url: url)
            plain.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            file = try await send(plain)
        case 404: throw ProbeError.noFIT
        default: throw ProbeError.http(response.statusCode)
        }
        try Task.checkCancellation()
        if Gzip.isCompressed(file) { file = try Gzip.decompress(file) }
        guard file.count >= 12, Array(file[file.startIndex + 8..<file.startIndex + 12]) == Array(".FIT".utf8) else { throw ProbeError.noFIT }
        return try store.save(file, key: ActivityKey(source: Source.intervals.rawValue, id: id))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        guard response.statusCode == 200 else { throw ProbeError.http(response.statusCode) }
        return data
    }
}

/// Single-member gzip (RFC 1952) with Apple's Compression framework; CRC-32 and length are checked.
enum Gzip {
    /// FIT files stay far below this; it bounds memory for a corrupt or hostile stream.
    static let maximumSize = 64 << 20

    static func isCompressed(_ data: Data) -> Bool { data.starts(with: [0x1F, 0x8B]) }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw ProbeError.invalidFIT }
        let flags = bytes[3]
        guard flags & 0xE0 == 0 else { throw ProbeError.invalidFIT }
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw ProbeError.invalidFIT }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index <= bytes.count - 8 else { throw ProbeError.invalidFIT }
        let trailer = bytes.count - 8
        func word(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        let size = Int(word(trailer + 4))
        guard size <= maximumSize else { throw ProbeError.invalidFIT }

        var output = Data()
        output.reserveCapacity(size)
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                guard let chunk else { return }
                guard output.count + chunk.count <= maximumSize else { throw ProbeError.invalidFIT }
                output.append(chunk)
            }
            try filter.write(Data(bytes[index..<trailer]))
            try filter.finalize()
        } catch { throw ProbeError.invalidFIT }
        guard output.count == size, crc32(output) == word(trailer) else { throw ProbeError.invalidFIT }
        return output
    }

    private static let table: [UInt32] = (0..<256).map { value in
        (0..<8).reduce(UInt32(value)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
