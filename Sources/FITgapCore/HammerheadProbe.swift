import Foundation

public struct HammerheadActivity: Decodable, Sendable {
    public let id: String
    public let name: String?
    public let createdAt: String?
    /// Moving time as reported by Hammerhead, in milliseconds.
    public let duration: Double?
    public var key: ActivityKey { ActivityKey(source: Source.hammerhead.rawValue, id: id) }

    /// IDs end up in URL paths; only the documented form (`1000.activity.abcd`) is accepted.
    static func valid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
            && !id.hasPrefix(".")
    }
}

struct HammerheadPage: Decodable {
    let totalPages: Int?
    let currentPage: Int?
    let data: [HammerheadActivity]
}

struct HammerheadToken: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
    let user_id: String?

    enum CodingKeys: String, CodingKey { case access_token, refresh_token, expires_in, user_id }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        access_token = try values.decode(String.self, forKey: .access_token)
        refresh_token = try values.decodeIfPresent(String.self, forKey: .refresh_token)
        expires_in = try values.decodeIfPresent(Double.self, forKey: .expires_in)
        // The documentation shows a string; accept a number as well.
        user_id = (try? values.decodeIfPresent(String.self, forKey: .user_id))
            ?? (try? values.decodeIfPresent(Int64.self, forKey: .user_id)).flatMap { $0.map(String.init) }
    }

    func credentials(previous: Credentials? = nil) throws -> Credentials {
        guard !access_token.isEmpty else { throw ProbeError.invalidResponse }
        return Credentials(accessToken: access_token, refreshToken: refresh_token ?? previous?.refreshToken,
                           expiresAt: expires_in.map { Date().addingTimeInterval($0) },
                           accountID: user_id ?? previous?.accountID)
    }
}

/// Client for the official Hammerhead API. The client secret is a parameter of the token routes only;
/// API and file requests carry just the user's bearer token.
public final class HammerheadProbe: Sendable {
    private let session: URLSession
    private let base = "https://api.hammerhead.io/v1/api"

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

    public func connect(_ oauth: HammerheadOAuth, callback: URL, secret: String) async throws -> Credentials {
        try await exchange(oauth.tokenRequest(callback: callback, secret: secret)).credentials()
    }

    public func refresh(_ credentials: Credentials, secret: String) async throws -> Credentials {
        guard let refresh = credentials.refreshToken else { throw AccountError.reconnect }
        do { return try await exchange(HammerheadOAuth.refreshRequest(refreshToken: refresh, secret: secret)).credentials(previous: credentials) }
        catch HammerheadError.token(let code) where code == "invalid_grant" { throw AccountError.reconnect }
    }

    /// Revokes FITgap's link: Hammerhead drops the refresh tokens and anything this client imported (FITgap imports nothing).
    public func deauthorize(_ credentials: Credentials, secret: String) async throws {
        let (_, response) = try await session.data(for: HammerheadOAuth.deauthorizeRequest(token: credentials.accessToken, secret: secret))
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        guard response.statusCode == 200 else { throw ProbeError.http(response.statusCode) }
    }

    private func exchange(_ request: URLRequest) async throws -> HammerheadToken {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        guard response.statusCode == 200 else {
            // Only known OAuth identifiers reach the UI; never response descriptions.
            struct Failure: Decodable { let error: String?; let message: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            let code = failure?.error ?? failure?.message ?? ""
            if ["invalid_client", "invalid_grant", "invalid_scope", "access_denied", "unsupported_grant_type",
                "invalid_auth_request"].contains(code) { throw HammerheadError.token(code) }
            throw ProbeError.http(response.statusCode)
        }
        return try decode(data)
    }

    /// All activities, or those from `since` on (`startDate`, whole days). Stops at `totalPages` or an empty page.
    public func activities(token: String, since: Date? = nil, maximumPages: Int = 500) async throws -> [HammerheadActivity] {
        var result: [HammerheadActivity] = []
        var seen = Set<String>()
        var start = ""
        if let since {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let day = calendar.dateComponents([.year, .month, .day], from: since)
            start = String(format: "&startDate=%04d-%02d-%02d", day.year ?? 1970, day.month ?? 1, day.day ?? 1)
        }
        for number in 1...maximumPages {
            try Task.checkCancellation()
            let page: HammerheadPage = try decode(await send(apiRequest("/activities?page=\(number)&perPage=100" + start, token: token)))
            guard page.currentPage.map({ $0 == number }) ?? true, page.data.count <= 100 else { throw ProbeError.pagination }
            if page.data.isEmpty { return result }
            let fresh = page.data.filter { HammerheadActivity.valid($0.id) && seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { throw ProbeError.pagination }
            result.append(contentsOf: fresh)
            if let total = page.totalPages, number >= total { return result }
        }
        throw ProbeError.pagination
    }

    public func download(id: String, token: String, store: OriginalFITStore) async throws -> FITReceipt {
        guard HammerheadActivity.valid(id) else { throw ProbeError.invalidResponse }
        var request = apiRequest("/activities/\(id)/file", token: token)
        request.setValue("application/vnd.ant.fit, application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        let file: Data
        switch response.statusCode {
        case 200: file = data
        case 301, 302, 303, 307, 308:
            // A storage link is fetched once without the bearer token.
            guard let location = response.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0, relativeTo: request.url) })?.absoluteURL,
                  let url = MyWhooshActivity.allowed(location) else { throw ProbeError.unsafeURL }
            var plain = URLRequest(url: url)
            plain.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            file = try await send(plain)
        case 404: throw ProbeError.noFIT
        default: throw ProbeError.http(response.statusCode)
        }
        try Task.checkCancellation()
        return try store.save(file, key: ActivityKey(source: Source.hammerhead.rawValue, id: id))
    }

    func apiRequest(_ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: base + path)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        guard response.statusCode == 200 else { throw ProbeError.http(response.statusCode) }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ProbeError.invalidResponse }
    }
}
