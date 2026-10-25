import Foundation
import Testing
@testable import FITgapCore

private let oauth = HammerheadOAuth(state: "synthetic-state")
private let secret = "synthetic secret/+&="

private func form(_ request: URLRequest) -> [String: String] {
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
    var parts = URLComponents()
    parts.percentEncodedQuery = String(decoding: bytes, as: UTF8.self)
    return Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

@Test func hammerheadAuthorizationURLCarriesNoSecret() throws {
    let parts = try #require(URLComponents(url: oauth.authorizationURL, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(parts.host == "api.hammerhead.io" && parts.path == "/v1/auth/oauth/authorize")
    #expect(items == ["response_type": "code", "client_id": HammerheadOAuth.clientID, "scope": "activity:read",
                      "redirect_uri": "https://florianwildt.github.io/fitgap/oauth/hammerhead/", "state": "synthetic-state"])
}

@Test func hammerheadTokenRequestSendsSecretOnlyInTheEncodedBody() throws {
    let request = try oauth.tokenRequest(callback: URL(string: "fitgap://oauth/hammerhead?code=c%2B1&state=synthetic-state")!, secret: secret)
    #expect(request.url == URL(string: "https://api.hammerhead.io/v1/auth/oauth/token"))
    #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(form(request) == ["client_id": HammerheadOAuth.clientID, "client_secret": secret, "grant_type": "authorization_code",
                              "code": "c+1", "redirect_uri": HammerheadOAuth.redirect.absoluteString])
    #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(secret))
}

@Test(arguments: [
    "fitgap://oauth/hammerhead?code=c&state=other",
    "fitgap://oauth/hammerhead?code=c",
    "fitgap://oauth/hammerhead?code=c&state=synthetic-state&state=synthetic-state",
    "fitgap://oauth/hammerhead?state=synthetic-state",
    "fitgap://oauth/wahoo?code=c&state=synthetic-state",
    "https://florianwildt.github.io/fitgap/oauth/hammerhead/?code=c&state=synthetic-state",
    "fitgap://user@oauth/hammerhead?code=c&state=synthetic-state",
    "fitgap://oauth/hammerhead?code=c&state=synthetic-state#x"
])
func hammerheadRejectsForeignCallbacks(_ callback: String) {
    #expect(throws: HammerheadError.self) { try oauth.tokenRequest(callback: URL(string: callback)!, secret: secret) }
}

@Test func hammerheadDeniedSignInIsReported() {
    #expect {
        try oauth.tokenRequest(callback: URL(string: "fitgap://oauth/hammerhead?error=access_denied&state=synthetic-state")!, secret: secret)
    } throws: { error in
        if case HammerheadError.denied = error { return true } else { return false }
    }
}

@Test func hammerheadActivityIDsStayOutOfPathTricks() {
    #expect(HammerheadActivity.valid("1000.activity.abcd"))
    #expect(HammerheadActivity.valid("a-b_c.9"))
    for id in ["", "../x", "a/b", ".hidden", "a?b", "a b", "a%2F", String(repeating: "a", count: 201)] {
        #expect(!HammerheadActivity.valid(id))
    }
}

@Test func hammerheadRecordUsesSecondsAndCreationDate() throws {
    let activity = try JSONDecoder().decode(HammerheadActivity.self, from: Data(
        #"{"id":"1000.activity.abcd","name":"Synthetic ride","createdAt":"2025-01-25T12:10:09.409Z","duration":76765,"distance":123.45}"#.utf8))
    let record = ActivityRecord(activity)
    #expect(record.source == .hammerhead && record.status == .pending && record.name == "Synthetic ride")
    #expect(record.key == ActivityKey(source: "hammerhead", id: "1000.activity.abcd"))
    #expect(record.date == ActivityRecord.parseDate("2025-01-25T12:10:09.409Z"))
    #expect(record.duration == 76.765)
}

@Test func hammerheadTokenAcceptsNumericUserID() throws {
    let numeric = try JSONDecoder().decode(HammerheadToken.self, from: Data(#"{"access_token":"a","refresh_token":"r","expires_in":52000,"user_id":1000}"#.utf8))
    #expect(try numeric.credentials().accountID == "1000")
    let text = try JSONDecoder().decode(HammerheadToken.self, from: Data(#"{"access_token":"a","user_id":"1000"}"#.utf8))
    let previous = Credentials(accessToken: "old", refreshToken: "kept", expiresAt: nil, accountID: "1000")
    let renewed = try text.credentials(previous: previous)
    #expect(renewed.refreshToken == "kept" && renewed.expiresAt == nil && renewed.pkceVerifier == nil)
}

private let fit = Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, 0x81, 0, 0xff, 0, 0])

private final class HammerheadMock: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var status = 200
        var headers: [String: String] = [:]
        var data = Data()
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        func fail() { client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)) }
        switch (url.host, url.path) {
        case ("api.hammerhead.io", "/v1/auth/oauth/token"):
            let body = form(request)
            guard body["client_secret"] == secret, bearer == nil else { return fail() }
            if body["grant_type"] == "refresh_token" {
                if body["refresh_token"] == "revoked" {
                    status = 400; data = Data(#"{"error":"invalid_grant","error_description":"must not be exposed"}"#.utf8)
                } else { data = Data(#"{"access_token":"renewed","expires_in":52000,"user_id":"1000"}"#.utf8) }
            } else if body["code"] == "wrong-client" {
                status = 401; data = Data(#"{"error":"invalid_client","error_description":"must not be exposed"}"#.utf8)
            } else { data = Data(#"{"token_type":"Bearer","access_token":"token","refresh_token":"refresh","expires_in":52000,"user_id":"1000"}"#.utf8) }
        case ("api.hammerhead.io", "/v1/api/activities"):
            guard bearer == "Bearer token" else { return fail() }
            let page = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value ?? "") ?? 0
            let ids = page == 1 ? ["1000.activity.a", "1000.activity.b"] : ["1000.activity.b", "1000.activity.c", "../evil"]
            let list = ids.map { #"{"id":"\#($0)","name":"Synthetic","createdAt":"2025-01-25T12:10:09.409Z","duration":1000}"# }
            data = Data(#"{"totalItems":4,"totalPages":2,"perPage":2,"currentPage":\#(page),"data":[\#(list.joined(separator: ","))]}"#.utf8)
        case ("api.hammerhead.io", "/v1/api/activities/1000.activity.a/file"):
            guard bearer == "Bearer token" else { return fail() }
            data = fit
        case ("api.hammerhead.io", "/v1/api/activities/1000.activity.b/file"):
            guard bearer == "Bearer token" else { return fail() }
            status = 302; headers["Location"] = "https://storage.example.invalid/b.fit?sig=1"
        case ("storage.example.invalid", "/b.fit"):
            guard bearer == nil, request.value(forHTTPHeaderField: "Accept-Encoding") == "identity" else { return fail() }
            data = fit
        case ("api.hammerhead.io", "/v1/api/activities/1000.activity.c/file"):
            status = 302; headers["Location"] = "http://storage.example.invalid/c.fit"
        case ("api.hammerhead.io", "/v1/api/activities/1000.activity.d/file"):
            status = 404
        default: return client!.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockClient() -> HammerheadProbe {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HammerheadMock.self]
    return HammerheadProbe(session: URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil))
}

@Test func simulatedHammerheadSignInListAndDownload() async throws {
    let client = mockClient()
    defer { client.close() }
    let credentials = try await client.connect(oauth, callback: URL(string: "fitgap://oauth/hammerhead?code=valid&state=synthetic-state")!, secret: secret)
    #expect(credentials.accessToken == "token" && credentials.refreshToken == "refresh" && credentials.accountID == "1000")
    let activities = try await client.activities(token: credentials.accessToken)
    #expect(activities.map(\.id) == ["1000.activity.a", "1000.activity.b", "1000.activity.c"])

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OriginalFITStore(directory: directory)
    let direct = try await client.download(id: "1000.activity.a", token: "token", store: store)
    let redirected = try await client.download(id: "1000.activity.b", token: "token", store: store)
    #expect(direct.byteCount == 19 && redirected.key == ActivityKey(source: "hammerhead", id: "1000.activity.b"))
    await #expect(throws: ProbeError.self) { try await client.download(id: "1000.activity.c", token: "token", store: store) }
    await #expect(throws: ProbeError.self) { try await client.download(id: "1000.activity.d", token: "token", store: store) }
    await #expect(throws: ProbeError.self) { try await client.download(id: "../evil", token: "token", store: store) }
}

@Test func hammerheadClientErrorsAndRevokedRefreshNeedReconnect() async throws {
    let client = mockClient()
    defer { client.close() }
    await #expect(throws: HammerheadError.self) {
        try await client.connect(oauth, callback: URL(string: "fitgap://oauth/hammerhead?code=wrong-client&state=synthetic-state")!, secret: secret)
    }
    let renewed = try await client.refresh(Credentials(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast, accountID: "1000"), secret: secret)
    #expect(renewed.accessToken == "renewed" && renewed.refreshToken == "refresh" && !renewed.needsRefresh)
    await #expect(throws: AccountError.self) {
        try await client.refresh(Credentials(accessToken: "old", refreshToken: "revoked", expiresAt: .distantPast), secret: secret)
    }
    await #expect(throws: AccountError.self) {
        try await client.refresh(Credentials(accessToken: "old", refreshToken: nil, expiresAt: .distantPast), secret: secret)
    }
}
