import CryptoKit
import Foundation
import Testing
@testable import FITgapCore

private let oauth = DropboxOAuth(verifier: "synthetic-verifier-synthetic-verifier-0123456789", state: "synthetic-state")
private let fit = Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, 0x81, 0, 0xff, 0, 0])

private func body(_ request: URLRequest) -> Data {
    var bytes = request.httpBody ?? Data()
    // URLSession can expose POST bodies to URLProtocol as a stream.
    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    return bytes
}

private func form(_ request: URLRequest) -> [String: String] {
    var parts = URLComponents()
    parts.percentEncodedQuery = String(decoding: body(request), as: UTF8.self)
    return Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

private func json(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: body(request))) as? [String: Any] ?? [:]
}

@Test func dropboxAuthorizationUsesPKCEOfflineAccessAndReadOnlyScopes() throws {
    let parts = try #require(URLComponents(url: oauth.authorizationURL, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(parts.host == "www.dropbox.com" && parts.path == "/oauth2/authorize")
    #expect(items["token_access_type"] == "offline" && items["code_challenge_method"] == "S256")
    #expect(items["scope"] == "files.metadata.read files.content.read" && items["redirect_uri"] == "fitgap://oauth/dropbox")
    #expect(items["state"] == "synthetic-state" && items["code_challenge"] != oauth.verifier)
    #expect(items["client_secret"] == nil)
}

@Test func dropboxTokenRequestCarriesVerifierAndNoSecret() throws {
    let request = try oauth.tokenRequest(callback: URL(string: "fitgap://oauth/dropbox?code=c%2B1&state=synthetic-state")!)
    #expect(request.url == URL(string: "https://api.dropboxapi.com/oauth2/token") && request.httpMethod == "POST")
    #expect(form(request) == ["grant_type": "authorization_code", "client_id": DropboxOAuth.clientID, "code": "c+1",
                              "code_verifier": oauth.verifier, "redirect_uri": "fitgap://oauth/dropbox"])
}

@Test(arguments: [
    "fitgap://oauth/dropbox?code=c&state=other",
    "fitgap://oauth/dropbox?code=c",
    "fitgap://oauth/dropbox?state=synthetic-state",
    "fitgap://oauth/wahoo?code=c&state=synthetic-state",
    "fitgap://oauth/dropbox?code=c&state=synthetic-state#x"
])
func dropboxRejectsForeignCallbacks(_ callback: String) {
    #expect(throws: DropboxError.self) { try oauth.tokenRequest(callback: URL(string: callback)!) }
}

@Test func dropboxIDsAndFITFilter() throws {
    #expect(DropboxFile.valid("id:a4ayc_80_OEAAAAAAAAAXw"))
    for id in ["", "id:", "a4ayc", "/Apps/x.fit", "id:a/b", "id:a b", "rev:abc"] { #expect(!DropboxFile.valid(id)) }
    func file(_ name: String, size: Int = 19, downloadable: Bool = true) throws -> DropboxFile {
        try JSONDecoder().decode(DropboxFile.self, from: Data(
            #"{"id":"id:abc","name":"\#(name)","size":\#(size),"is_downloadable":\#(downloadable)}"#.utf8))
    }
    #expect(try file("Ride.FIT").isFIT)
    #expect(try !file("Ride.gpx").isFIT && !file("Ride.fit.zip").isFIT && !file("Ride.fit", size: 3).isFIT)
    #expect(try !file("Ride.fit", downloadable: false).isFIT)
    let record = ActivityRecord(try JSONDecoder().decode(DropboxFile.self, from: Data(
        #"{"id":"id:abc","name":"2025-01-25 Ride.fit","client_modified":"2025-01-25T12:10:09Z"}"#.utf8)))
    #expect(record.source == .dropbox && record.name == "2025-01-25 Ride" && record.status == .pending)
    #expect(record.date == ActivityRecord.parseDate("2025-01-25T12:10:09Z"))
}

@Test func dropboxContentHashFollowsTheBlockScheme() {
    func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    #expect(DropboxFile.contentHash(fit) == hex(SHA256.hash(data: Data(SHA256.hash(data: fit)))))
    // Two blocks: the digests of both 4 MB parts are hashed together.
    let large = Data(repeating: 7, count: 4 * 1024 * 1024 + 5)
    let parts = Data(SHA256.hash(data: large.prefix(4 * 1024 * 1024))) + Data(SHA256.hash(data: large.suffix(5)))
    #expect(DropboxFile.contentHash(large) == hex(SHA256.hash(data: parts)))
    #expect(DropboxFile.contentHash(Data()) == hex(SHA256.hash(data: Data(SHA256.hash(data: Data())))))
}

/// Collects what the `@Sendable` page callback receives.
private final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func add(_ value: T) { lock.lock(); values.append(value); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class DropboxMock: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var limited = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var status = 200
        var headers: [String: String] = [:]
        var data = Data()
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        func entry(_ id: String, _ name: String, tag: String = "file", hash: String? = nil) -> String {
            let extra = hash.map { #","content_hash":"\#($0)""# } ?? ""
            return #"{".tag":"\#(tag)","id":"\#(id)","name":"\#(name)","path_display":"/Apps/Zwift/\#(name)","size":19\#(extra)}"#
        }
        switch (url.host, url.path) {
        case ("api.dropboxapi.com", "/oauth2/token"):
            let values = form(request)
            guard values["client_secret"] == nil, bearer == nil else { return fail() }
            if values["grant_type"] == "refresh_token" {
                if values["refresh_token"] == "revoked" {
                    status = 400; data = Data(#"{"error":"invalid_grant","error_description":"must not be exposed"}"#.utf8)
                } else { data = Data(#"{"access_token":"renewed","expires_in":14400,"token_type":"bearer"}"#.utf8) }
            } else if values["code"] == "narrow" {
                data = Data(#"{"access_token":"t","refresh_token":"r","expires_in":14400,"scope":"files.metadata.read"}"#.utf8)
            } else {
                guard values["code_verifier"] == oauth.verifier else { return fail() }
                data = Data(#"{"access_token":"token","refresh_token":"refresh","expires_in":14400,"token_type":"bearer","scope":"account_info.read files.content.read files.metadata.read","account_id":"dbid:synthetic","uid":"1"}"#.utf8)
            }
        case ("api.dropboxapi.com", "/2/files/list_folder"):
            let arg = json(request)
            if bearer == "Bearer expired" {
                status = 401; data = Data(#"{"error_summary":"expired_access_token/","error":{".tag":"expired_access_token"}}"#.utf8)
            } else if bearer == "Bearer limited" {
                Self.limited += 1
                status = 429; headers["Retry-After"] = Self.limited == 1 ? "0" : "3600"
                data = Data(#"{"error_summary":"too_many_requests/","error":{"reason":{".tag":"too_many_requests"},"retry_after":3600}}"#.utf8)
            } else if arg["path"] as? String == "/Missing" {
                status = 409; data = Data(#"{"error_summary":"path/not_found/..","error":{".tag":"path","path":{".tag":"not_found"}}}"#.utf8)
            } else {
                guard bearer == "Bearer token", arg["path"] as? String == "/Apps", arg["recursive"] as? Bool == true else { return fail() }
                let entries = [entry("id:a", "a.fit", hash: DropboxFile.contentHash(fit)), entry("id:dir", "Zwift.fit", tag: "folder"),
                               entry("id:gpx", "a.gpx"), entry("id:b", "B.FIT")]
                data = Data(#"{"entries":[\#(entries.joined(separator: ","))],"cursor":"c1","has_more":true}"#.utf8)
            }
        case ("api.dropboxapi.com", "/2/files/list_folder/continue"):
            guard bearer == "Bearer token" else { return fail() }
            switch json(request)["cursor"] as? String {
            case "c1":
                let entries = [entry("id:b", "B.FIT"), entry("id:c", "c.fit", hash: String(repeating: "0", count: 64)), entry("../x", "evil.fit")]
                data = Data(#"{"entries":[\#(entries.joined(separator: ","))],"cursor":"c2","has_more":false}"#.utf8)
            case "c2":
                data = Data(#"{"entries":[{".tag":"deleted","name":"a.fit"}],"cursor":"c3","has_more":false}"#.utf8)
            case "stale":
                status = 409; data = Data(#"{"error_summary":"reset/..","error":{".tag":"reset"}}"#.utf8)
            default: return fail()
            }
        case ("content.dropboxapi.com", "/2/files/download"):
            guard bearer == "Bearer token", request.value(forHTTPHeaderField: "Content-Type") == nil else { return fail() }
            let arg = (try? JSONSerialization.jsonObject(with: Data((request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? "").utf8))) as? [String: String]
            switch arg?["path"] {
            case "id:a", "id:c": data = fit
            case "id:b": data = Data("<html>not a fit</html>".utf8)
            default: status = 409; data = Data(#"{"error_summary":"path/not_found/."}"#.utf8)
            }
        case ("api.dropboxapi.com", "/2/auth/token/revoke"):
            guard bearer == "Bearer token" else { return fail() }
            data = Data("null".utf8)
        default: return fail()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)) }
    override func stopLoading() {}
}

private func mockClient() -> DropboxProbe {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DropboxMock.self]
    return DropboxProbe(session: URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil), maximumWait: 1)
}

@Suite(.serialized) struct DropboxSimulatedAccount {
    @Test func signInListsOnlyFITsWithCursorAndVerifiesDownloads() async throws {
        let client = mockClient()
        defer { client.close() }
        let credentials = try await client.connect(oauth, callback: URL(string: "fitgap://oauth/dropbox?code=valid&state=synthetic-state")!)
        #expect(credentials.accessToken == "token" && credentials.refreshToken == "refresh" && credentials.accountID == "dbid:synthetic")
        #expect(!credentials.needsRefresh)

        let pages = Collected<([String], DropboxCursor)>()
        try await client.catalog(token: "token", cursor: nil) { files, next in pages.add((files.map(\.id), next)) }
        #expect(pages.all.map(\.0) == [["id:a", "id:b"], ["id:c"]])
        #expect(pages.all.map(\.1.cursor) == ["c1", "c2"] && pages.all.allSatisfy { $0.1.root == "/Apps" })

        // Incremental: a saved cursor only returns changes; deletions are ignored.
        let later = Collected<String>()
        try await client.catalog(token: "token", cursor: DropboxCursor(root: "/Apps", cursor: "c2")) { files, _ in files.forEach { later.add($0.id) } }
        #expect(later.all.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OriginalFITStore(directory: directory)
        let receipt = try await client.download(id: "id:a", contentHash: DropboxFile.contentHash(fit), token: "token", store: store)
        #expect(receipt.byteCount == 19 && receipt.key == ActivityKey(source: "dropbox", id: "id:a"))
        // Not a FIT, a content hash mismatch, a missing file and a foreign path are never stored.
        await #expect(throws: ProbeError.self) { try await client.download(id: "id:b", token: "token", store: store) }
        await #expect(throws: ProbeError.self) {
            try await client.download(id: "id:c", contentHash: String(repeating: "0", count: 64), token: "token", store: store)
        }
        await #expect(throws: ProbeError.self) { try await client.download(id: "id:gone", token: "token", store: store) }
        await #expect(throws: ProbeError.self) { try await client.download(id: "../x", token: "token", store: store) }
        let saved = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".fit") }
        #expect(saved.count == 1)

        try await client.revoke(credentials)
    }

    @Test func resetCursorStartsOverAndMissingFolderIsEmpty() async throws {
        let client = mockClient()
        defer { client.close() }
        let reset = Collected<String>()
        try await client.catalog(token: "token", cursor: DropboxCursor(root: "/Apps", cursor: "stale")) { files, _ in files.forEach { reset.add($0.id) } }
        #expect(reset.all == ["id:a", "id:b", "id:c"])
        // A cursor of another folder is not reused.
        let other = Collected<String>()
        try await client.catalog(token: "token", cursor: DropboxCursor(root: "/Other", cursor: "c2")) { files, _ in files.forEach { other.add($0.id) } }
        #expect(other.all == ["id:a", "id:b", "id:c"])
        let missing = Collected<Int>()
        try await client.catalog(token: "token", cursor: nil, root: "/Missing") { files, _ in missing.add(files.count) }
        #expect(missing.all.isEmpty)
    }

    @Test func refreshExpiredTokenAndRateLimit() async throws {
        let client = mockClient()
        defer { client.close() }
        let renewed = try await client.refresh(Credentials(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast, accountID: "dbid:synthetic"))
        #expect(renewed.accessToken == "renewed" && renewed.refreshToken == "refresh" && renewed.accountID == "dbid:synthetic")
        #expect(!renewed.needsRefresh)
        await #expect(throws: AccountError.self) {
            try await client.refresh(Credentials(accessToken: "old", refreshToken: "revoked", expiresAt: .distantPast))
        }
        await #expect(throws: AccountError.self) {
            try await client.refresh(Credentials(accessToken: "old", refreshToken: nil, expiresAt: .distantPast))
        }
        await #expect(throws: DropboxError.self) {
            try await client.connect(oauth, callback: URL(string: "fitgap://oauth/dropbox?code=narrow&state=synthetic-state")!)
        }
        await #expect(throws: DropboxExpiredToken.self) { try await client.catalog(token: "expired", cursor: nil) { _, _ in } }
        // A short Retry-After is waited out once; a long one stops with the time to resume.
        DropboxMock.limited = 0
        await #expect(throws: DropboxRateLimit.self) { try await client.catalog(token: "limited", cursor: nil) { _, _ in } }
        #expect(DropboxMock.limited == 2)
    }
}
