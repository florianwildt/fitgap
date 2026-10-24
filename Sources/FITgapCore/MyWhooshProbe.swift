import Foundation
import os

/// MyWhoosh answers with PascalCase or camelCase depending on the service; keys are matched case-insensitively.
private func field(_ object: [String: Any], _ names: [String]) -> Any? {
    for name in names {
        if let match = object.first(where: { $0.key.lowercased() == name }), !(match.value is NSNull) { return match.value }
    }
    return nil
}

private func text(_ value: Any?) -> String? {
    switch value {
    case let value as String: value.isEmpty ? nil : value
    case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID(): value.stringValue
    default: nil
    }
}

public struct MyWhooshActivity: Sendable {
    public let id: String
    public let name: String
    public let start: Date?
    public let duration: TimeInterval?
    /// Reference for the download endpoint; nil when MyWhoosh offers no file.
    public let fileID: String?
    public var key: ActivityKey { ActivityKey(source: Source.mywhoosh.rawValue, id: id) }

    init?(json: [String: Any]) {
        guard let id = text(field(json, ["id", "_id"])) else { return nil }
        self.id = id
        name = text(field(json, ["title", "name"])) ?? ""
        // `date` is Unix time in seconds and was 0 for one real activity; then the text dates apply.
        let unix = text(field(json, ["date", "timestamp"])).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        start = unix.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
            ?? ActivityRecord.parseDate(text(field(json, ["startdatetime"])))
            ?? ActivityRecord.parseDate(text(field(json, ["createdat"])))
        duration = text(field(json, ["rideduration"])).flatMap(Self.seconds)
        fileID = text(field(json, ["activityfileid"]))
    }

    /// Accepts plain seconds or `[h:]m:s`; anything else stays unknown.
    static func seconds(_ value: String) -> TimeInterval? {
        if let seconds = Double(value) { return seconds >= 0 ? seconds : nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).compactMap { Double($0) }
        guard (2...3).contains(parts.count), parts.count == value.split(separator: ":", omittingEmptySubsequences: false).count,
              parts.allSatisfy({ $0 >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Signed storage links: plain HTTPS only. They never receive the API token.
    static func allowed(_ url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil else { return nil }
        return url
    }
}

public struct MyWhooshSession: Sendable {
    public let token: String
    public let whooshID: String

    public init(token: String, whooshID: String) { self.token = token; self.whooshID = whooshID }

    public init(_ credentials: Credentials) throws {
        guard let whooshID = credentials.accountID else { throw AccountError.reconnect }
        self.init(token: credentials.accessToken, whooshID: whooshID)
    }

    /// No refresh route is known; the stored token carries the account ID and, if it is a JWT, its expiry.
    public var credentials: Credentials {
        Credentials(accessToken: token, refreshToken: nil, expiresAt: Self.expiry(of: token), accountID: whooshID)
    }

    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }
}

public struct MyWhooshPage: Sendable {
    /// nil when no activity list was found in the response.
    public let activities: [MyWhooshActivity]?
    public let itemCount: Int
    /// From `data.totalPages` when the server sends it.
    public let totalPages: Int?
    /// Field names and value types only, never values.
    public let shape: String
}

/// Unofficial routes from the reference sources in Pruefhistorie.md, confirmed with a real account.
/// No client secret; the password is only sent to the login route and never stored.
public final class MyWhooshProbe: Sendable {
    private let session: URLSession
    private let deviceID = UUID().uuidString
    private let base = "https://service14.mywhoosh.com/v2/rider/profile/"

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

    public func authenticate(username: String, password: String) async throws -> MyWhooshSession {
        let body: [String: Any] = [
            "Username": username, "Password": password, "Platform": "Android", "Action": 1001,
            "CorrelationId": UUID().uuidString, "DeviceId": deviceID, "Authorization": ""
        ]
        let request = try jsonRequest("https://services.mywhoosh.com/http-service/api/login", body: body)
        guard let object = try JSONSerialization.jsonObject(with: await send(request)) as? [String: Any]
        else { throw ProbeError.invalidResponse }
        // The service reports rejected sign-ins with HTTP 200 and Success = false.
        guard field(object, ["success"]) as? Bool != false else { throw ProbeError.http(401) }
        guard let token = text(field(object, ["accesstoken"])), let whooshID = text(field(object, ["whooshid"]))
        else { throw ProbeError.invalidResponse }
        return MyWhooshSession(token: token, whooshID: whooshID)
    }

    public func page(_ number: Int, limit: Int = 20, session: MyWhooshSession) async throws -> MyWhooshPage {
        let body: [String: Any] = ["page": number, "limit": limit, "sortDate": "DESC"]
        return try Self.parse(await send(jsonRequest(base + "activities", body: body, token: session.token)))
    }

    /// Ends at `totalPages` or an empty page; the server uses its own page size.
    public func activities(session: MyWhooshSession, maximumPages: Int = 500,
                           progress: (Int, MyWhooshPage) -> Void = { _, _ in }) async throws -> [MyWhooshActivity] {
        var result: [MyWhooshActivity] = []
        var seen = Set<String>()
        for number in 1...maximumPages {
            try Task.checkCancellation()
            let response = try await page(number, session: session)
            progress(number, response)
            guard let page = response.activities else { throw ProbeError.invalidResponse }
            if page.isEmpty { return result }
            let fresh = page.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { throw ProbeError.pagination }
            result.append(contentsOf: fresh)
            if let total = response.totalPages, number >= total { return result }
        }
        throw ProbeError.pagination
    }

    /// Single downloads only know the activity ID; the file reference is looked up in the list.
    public func download(id: String, session: MyWhooshSession, store: OriginalFITStore) async throws -> FITReceipt {
        for number in 1...500 {
            try Task.checkCancellation()
            let response = try await page(number, session: session)
            guard let page = response.activities else { throw ProbeError.invalidResponse }
            if let activity = page.first(where: { $0.id == id }) { return try await download(activity, session: session, store: store).0 }
            if page.isEmpty || response.totalPages.map({ number >= $0 }) == true { break }
        }
        throw ProbeError.noFIT
    }

    /// Asks MyWhoosh for a signed link, then fetches it without the API token.
    public func download(_ activity: MyWhooshActivity, session: MyWhooshSession, store: OriginalFITStore) async throws -> (FITReceipt, host: String) {
        guard let fileID = activity.fileID else { throw ProbeError.noFIT }
        let body = ["key": session.whooshID, "fileId": fileID]
        let response = try JSONSerialization.jsonObject(
            with: await send(jsonRequest(base + "download-activity-file", body: body, token: session.token))
        ) as? [String: Any]
        guard let response, field(response, ["error"]) as? Bool != true,
              let link = text(field(response, ["data"])).flatMap(URL.init(string:))
        else { throw ProbeError.invalidResponse }
        guard let url = MyWhooshActivity.allowed(link), let host = url.host else { throw ProbeError.unsafeURL }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let data = try await send(request)
        try Task.checkCancellation()
        do { return (try store.save(data, key: activity.key), host) }
        catch ProbeError.invalidFIT {
            Self.log.error("Rejected MyWhoosh download: \(Self.describe(data), privacy: .public)")
            throw ProbeError.invalidFIT
        }
    }

    /// Diagnostics in Console (subsystem org.fitgap.app); only sizes and the file signature, no activity content.
    private static let log = Logger(subsystem: "org.fitgap.app", category: "MyWhoosh")

    static func describe(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(14))
        let signature = bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let first = bytes.first, second = bytes.dropFirst().first
        let kind: String = switch (first, second) {
        case (0x50, 0x4B): "zip"
        case (0x1F, 0x8B): "gzip"
        case (0x7B, _), (0x5B, _): "json"
        case (0x3C, _): "html/xml"
        default: bytes.count >= 12 && Array(bytes[8..<12]) == Array(".FIT".utf8) ? "fit" : "unknown"
        }
        var text = "\(data.count) bytes, \(kind), signature \(signature)"
        if kind == "fit" {
            let body = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
            text += ", header \(bytes[0]), declared \(Int(bytes[0]) + body + 2) bytes"
        }
        return text
    }

    static func parse(_ data: Data) throws -> MyWhooshPage {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch { throw ProbeError.invalidResponse }
        let names = ["data", "results"]
        func list(_ value: Any, depth: Int) -> [Any]? {
            if let array = value as? [Any] { return array }
            guard depth > 0, let object = value as? [String: Any], let inner = field(object, names) else { return nil }
            return list(inner, depth: depth - 1)
        }
        let items = list(json, depth: 2)
        return MyWhooshPage(
            activities: items?.compactMap { ($0 as? [String: Any]).flatMap(MyWhooshActivity.init(json:)) },
            itemCount: items?.count ?? 0,
            totalPages: (json as? [String: Any]).flatMap { field($0, ["data"]) as? [String: Any] }
                .flatMap { text(field($0, ["totalpages"])) }.flatMap(Int.init),
            shape: shape(json, depth: 5)
        )
    }

    static func shape(_ value: Any, depth: Int) -> String {
        switch value {
        case let object as [String: Any]:
            guard depth > 0 else { return "{…}" }
            return "{" + object.keys.sorted().map { "\($0): \(shape(object[$0]!, depth: depth - 1))" }
                .joined(separator: ", ") + "}"
        case let array as [Any]:
            guard let first = array.first else { return "[]" }
            return "[\(array.count) × \(depth > 0 ? shape(first, depth: depth - 1) : "…")]"
        case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        case is String: return "string"
        case is NSNull: return "null"
        default: return "?"
        }
    }

    private func jsonRequest(_ url: String, body: [String: Any], token: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FITgapProbe/0.1", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        guard response.statusCode == 200 else { throw ProbeError.http(response.statusCode) }
        return data
    }
}
