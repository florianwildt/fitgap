import Foundation

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ZwiftActivity: Decodable, Sendable {
    public let id: Int64
    public let name: String
    public let startDate: String?
    public let endDate: String?
    public let fitFileBucket: String?
    public let fitFileKey: String?
    public var key: ActivityKey { ActivityKey(source: "zwift", id: String(id)) }

    public var downloadURL: URL? {
        guard let bucket = fitFileBucket, let key = fitFileKey, !key.isEmpty,
              bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil
        else { return nil }
        var url = URLComponents()
        url.scheme = "https"
        url.host = bucket + ".s3.amazonaws.com"
        url.path = "/" + key
        return url.url
    }
}

/// Experimental routes from the pinned reference sources in Pruefhistorie.md.
/// Public client identifier, no client secret. No persistent credential storage.
public final class ZwiftProbe: Sendable {
    private let session: URLSession
    private let base = "https://us-or-rly101.zwift.com"

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

    public func authenticate(username: String, password: String) async throws -> String {
        try await connect(username: username, password: password).accessToken
    }

    public func connect(username: String, password: String) async throws -> Credentials {
        try await tokenRequest(values: ["username": username, "password": password, "grant_type": "password"])
    }

    public func refresh(_ credentials: Credentials) async throws -> Credentials {
        guard let refresh = credentials.refreshToken else { throw AccountError.reconnect }
        return try await tokenRequest(values: ["refresh_token": refresh, "grant_type": "refresh_token"], previous: credentials)
    }

    private func tokenRequest(values: [String: String], previous: Credentials? = nil) async throws -> Credentials {
        var request = URLRequest(url: URL(string: "https://secure.zwift.com/auth/realms/zwift/tokens/access/codes")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = values.merging(["client_id": "Zwift_Mobile_Link"]) { _, new in new }
            .sorted { $0.key < $1.key }
            .map { $0.key + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }
            .joined(separator: "&").data(using: .utf8)
        let token: TokenResponse = try decode(await send(request))
        return try token.credentials(previous: previous)
    }

    public func activities(token: String) async throws -> [ZwiftActivity] {
        struct Profile: Decodable { let id: Int64 }
        let profile: Profile = try decode(await send(apiRequest(path: "/api/profiles/me", token: token)))
        return try await Pages.collect(key: { $0.key }) { start, limit in
            try self.decode(await self.send(self.apiRequest(
                path: "/api/profiles/\(profile.id)/activities/?start=\(start)&limit=\(limit)", token: token
            )))
        }
    }

    public func download(_ activity: ZwiftActivity, store: OriginalFITStore) async throws -> FITReceipt {
        guard let url = activity.downloadURL else { throw ProbeError.unsafeURL }
        // Storage requests never receive the API bearer token.
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let data = try await send(request)
        try Task.checkCancellation()
        return try store.save(data, key: activity.key)
    }

    public func download(id: String, token: String, store: OriginalFITStore) async throws -> FITReceipt {
        guard Int64(id) != nil else { throw ProbeError.invalidResponse }
        struct Profile: Decodable { let id: Int64 }
        let profile: Profile = try decode(await send(apiRequest(path: "/api/profiles/me", token: token)))
        let activity: ZwiftActivity = try decode(await send(apiRequest(path: "/api/profiles/\(profile.id)/activities/\(id)", token: token)))
        guard String(activity.id) == id else { throw ProbeError.invalidResponse }
        return try await download(activity, store: store)
    }

    private func apiRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: base + path)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FITgapProbe/0.1", forHTTPHeaderField: "User-Agent")
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
