import CryptoKit
import Foundation

/// A `.fit` file from a Dropbox listing. The Dropbox `id` stays the same when the file is moved or renamed.
public struct DropboxFile: Decodable, Sendable {
    public let id: String
    public let name: String
    public let path_display: String?
    public let client_modified: String?
    public let size: Int?
    /// Dropbox content hash (SHA-256 over 4 MB blocks), checked after the download.
    public let content_hash: String?
    public let is_downloadable: Bool?
    public var key: ActivityKey { ActivityKey(source: Source.dropbox.rawValue, id: id) }

    /// Rides only: no folders, deleted entries, exports (Google Docs) or files too large for a FIT.
    var isFIT: Bool {
        Self.valid(id) && name.lowercased().hasSuffix(".fit") && is_downloadable != false
            && (size.map { (14...DropboxProbe.maximumBytes).contains($0) } ?? true)
    }

    /// IDs travel in the `Dropbox-API-Arg` header; only the documented `id:` form is accepted.
    static func valid(_ id: String) -> Bool {
        id.count <= 200 && id.range(of: "^id:[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// Dropbox content hash: SHA-256 over the concatenated SHA-256 digests of each 4 MB block.
    static func contentHash(_ data: Data) -> String {
        var blocks = Data()
        var offset = 0
        repeat {
            let end = min(offset + 4 * 1024 * 1024, data.count)
            blocks.append(contentsOf: SHA256.hash(data: data[offset..<end]))
            offset = end
        } while offset < data.count
        return SHA256.hash(data: blocks).map { String(format: "%02x", $0) }.joined()
    }
}

extension ActivityRecord {
    /// Name without `.fit`; the start time comes from the FIT once it is downloaded, until then the file date.
    public init(_ file: DropboxFile) {
        let name = file.name.lowercased().hasSuffix(".fit") ? String(file.name.dropLast(4)) : file.name
        self.init(source: .dropbox, remoteID: file.id, name: name, date: Self.parseDate(file.client_modified), duration: nil)
    }
}

public struct DropboxRateLimit: Error, LocalizedError, Sendable {
    public let until: Date
    public init(until: Date) { self.until = until }
    public var errorDescription: String? {
        String(localized: "Abruflimit erreicht. Dropbox pausiert bis \(until.formatted(date: .omitted, time: .shortened)).", bundle: .module)
    }
}

/// Dropbox reports an expired access token separately; the app renews it once and repeats the call.
public struct DropboxExpiredToken: Error, Sendable {}

/// Where the next sync continues; bound to the listed folder.
public struct DropboxCursor: Codable, Sendable, Equatable {
    public let root: String
    public let cursor: String
    public init(root: String, cursor: String) { self.root = root; self.cursor = cursor }
}

private struct DropboxListing: Decodable {
    struct Entry: Decodable {
        let tag: String
        let file: DropboxFile?
        enum CodingKeys: String, CodingKey { case tag = ".tag" }
        init(from decoder: Decoder) throws {
            tag = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .tag)
            file = tag == "file" ? try? DropboxFile(from: decoder) : nil
        }
    }
    let entries: [Entry]
    let cursor: String
    let has_more: Bool
}

/// Client for the official Dropbox API v2: read-only listing and download, bearer token only.
public final class DropboxProbe: Sendable {
    /// Services such as Zwift, Wahoo, Karoo, Rouvy or TrainerRoad write their exports into `/Apps/<service>`.
    public static let root = "/Apps"
    static let maximumBytes = 100 * 1024 * 1024
    private let session: URLSession
    /// Short `Retry-After` pauses are waited out; longer ones end the sync with a notice.
    private let maximumWait: TimeInterval

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        maximumWait = 30
    }

    init(session: URLSession, maximumWait: TimeInterval = 30) { self.session = session; self.maximumWait = maximumWait }

    public func close() { session.invalidateAndCancel() }

    public func connect(_ oauth: DropboxOAuth, callback: URL) async throws -> Credentials {
        try await exchange(oauth.tokenRequest(callback: callback))
    }

    public func refresh(_ credentials: Credentials) async throws -> Credentials {
        guard let refresh = credentials.refreshToken else { throw AccountError.reconnect }
        do { return try await exchange(DropboxOAuth.refreshRequest(refreshToken: refresh), previous: credentials) }
        catch DropboxError.token(let code) where code == "invalid_grant" { throw AccountError.reconnect }
    }

    /// Ends FITgap's authorization at Dropbox; the refresh token stops working too. Files stay untouched.
    public func revoke(_ credentials: Credentials) async throws {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    private func exchange(_ request: URLRequest, previous: Credentials? = nil) async throws -> Credentials {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        guard response.statusCode == 200 else {
            // Only known OAuth identifiers reach the UI; never response descriptions.
            struct Failure: Decodable { let error: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? ""
            if ["invalid_client", "invalid_grant", "invalid_scope", "invalid_request", "unsupported_grant_type"].contains(code) {
                throw DropboxError.token(code)
            }
            throw ProbeError.http(response.statusCode)
        }
        struct Token: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double?; let scope: String?; let account_id: String? }
        let token: Token = try decode(data)
        guard !token.access_token.isEmpty else { throw ProbeError.invalidResponse }
        if let scope = token.scope, !Set(scope.split(separator: " ").map(String.init)).isSuperset(of: DropboxOAuth.scopes) {
            throw DropboxError.scope
        }
        guard token.refresh_token != nil || previous?.refreshToken != nil else { throw ProbeError.invalidResponse }
        return Credentials(accessToken: token.access_token, refreshToken: token.refresh_token ?? previous?.refreshToken,
                           expiresAt: token.expires_in.map { Date().addingTimeInterval($0) },
                           accountID: token.account_id ?? previous?.accountID)
    }

    /// Lists `.fit` files below `root` recursively. Without a cursor the whole folder is read, otherwise only
    /// changes since the last sync. Each page goes to `page` with the cursor to save after it; an invalidated
    /// cursor starts over, a missing folder ends the listing without a cursor.
    public func catalog(
        token: String, cursor: DropboxCursor?, root: String = DropboxProbe.root, maximumPages: Int = 2000,
        page: @Sendable (_ files: [DropboxFile], _ next: DropboxCursor) async throws -> Void
    ) async throws {
        var current = cursor?.root == root ? cursor?.cursor : nil
        var seen = Set<String>()
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let listing: DropboxListing
            do {
                if let current {
                    listing = try decode(await send(rpc("/files/list_folder/continue", ["cursor": current], token: token)))
                } else {
                    listing = try decode(await send(rpc("/files/list_folder", [
                        "path": root, "recursive": true, "include_deleted": false,
                        "include_non_downloadable_files": false, "limit": 2000
                    ], token: token)))
                }
            } catch DropboxConflict.reset where current != nil {
                current = nil; seen.removeAll()
                continue
            } catch DropboxConflict.notFound where current == nil { return }
            guard !listing.cursor.isEmpty, listing.cursor != current else { throw ProbeError.pagination }
            let files = listing.entries.compactMap(\.file).filter { $0.isFIT && seen.insert($0.id).inserted }
            try await page(files, DropboxCursor(root: root, cursor: listing.cursor))
            current = listing.cursor
            if !listing.has_more { return }
        }
        throw ProbeError.pagination
    }

    public func download(_ file: DropboxFile, token: String, store: OriginalFITStore) async throws -> FITReceipt {
        guard file.isFIT else { throw ProbeError.noFIT }
        return try await download(id: file.id, contentHash: file.content_hash, token: token, store: store)
    }

    public func download(id: String, contentHash: String? = nil, token: String, store: OriginalFITStore) async throws -> FITReceipt {
        guard DropboxFile.valid(id) else { throw ProbeError.invalidResponse }
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(String(decoding: try JSONEncoder().encode(["path": id]), as: UTF8.self), forHTTPHeaderField: "Dropbox-API-Arg")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let data: Data
        do { data = try await send(request) }
        catch DropboxConflict.notFound { throw ProbeError.noFIT }
        guard data.count <= Self.maximumBytes else { throw ProbeError.invalidFIT }
        if let contentHash, DropboxFile.contentHash(data) != contentHash.lowercased() { throw ProbeError.invalidFIT }
        try Task.checkCancellation()
        // The store checks the FIT header and declared length before anything is written.
        return try store.save(data, key: ActivityKey(source: Source.dropbox.rawValue, id: id))
    }

    private func rpc(_ path: String, _ body: [String: Any], token: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2" + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private enum DropboxConflict: Error { case reset, notFound }

    private func send(_ request: URLRequest, attempt: Int = 0) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        switch response.statusCode {
        case 200: return data
        case 401:
            struct Failure: Decodable { struct Tag: Decodable { let tag: String; enum CodingKeys: String, CodingKey { case tag = ".tag" } }; let error: Tag? }
            if (try? JSONDecoder().decode(Failure.self, from: data))?.error?.tag == "expired_access_token" { throw DropboxExpiredToken() }
            throw ProbeError.http(401)
        case 409:
            // Endpoint errors: `error_summary` starts with the union path, e.g. `path/not_found/..` or `reset/..`.
            struct Failure: Decodable { let error_summary: String? }
            let summary = (try? JSONDecoder().decode(Failure.self, from: data))?.error_summary ?? ""
            if summary.hasPrefix("reset") { throw DropboxConflict.reset }
            if summary.hasPrefix("path/not_found") { throw DropboxConflict.notFound }
            throw ProbeError.http(409)
        case 429, 503:
            let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "").flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            guard response.statusCode == 429 || retry != nil else { throw ProbeError.http(response.statusCode) }
            let seconds = retry ?? 60
            if seconds <= maximumWait, attempt < 3 {
                try await Task.sleep(for: .seconds(seconds))
                return try await send(request, attempt: attempt + 1)
            }
            throw DropboxRateLimit(until: Date().addingTimeInterval(max(seconds, 1)))
        default: throw ProbeError.http(response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ProbeError.invalidResponse }
    }
}
