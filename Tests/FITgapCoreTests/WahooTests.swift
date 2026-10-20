import Foundation
import Testing
@testable import FITgapCore

private let testOAuth = WahooOAuth(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "synthetic-state")

@Test func pkceUsesRFC7636S256VectorAndReadOnlyScopes() throws {
    let items = URLComponents(url: testOAuth.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
    #expect(values["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(values["code_challenge_method"] == "S256")
    #expect(values["scope"] == "user_read workouts_read")
    #expect(values["code_verifier"] == nil)
    let request = try testOAuth.tokenRequest(callback: URL(string: "fitgap://oauth/wahoo?state=synthetic-state&code=synthetic-code")!)
    let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://api.wahooligan.com/oauth/token")
    #expect(body["code_verifier"] == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(body["code"] == "synthetic-code")
    #expect(body["client_secret"] == nil)
}

@Test func eachOAuthAttemptHasFreshStateAndVerifier() throws {
    let first = try WahooOAuth()
    let second = try WahooOAuth()
    func values(_ oauth: WahooOAuth) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: oauth.authorizationURL, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value!) })
    }
    #expect(values(first)["state"] != values(second)["state"])
    #expect(values(first)["code_challenge"] != values(second)["code_challenge"])
    let request = try first.tokenRequest(callback: URL(string: "fitgap://oauth/wahoo?state=\(values(first)["state"]!)&code=synthetic-code")!)
    let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
    #expect(body["code_verifier"]!.count == 43)
}

@Test(arguments: [
    "fitgap://oauth/wahoo?code=synthetic-code",
    "fitgap://oauth/wahoo?state=wrong&code=synthetic-code",
    "fitgap://oauth/wahoo?state=synthetic-state&state=synthetic-state&code=synthetic-code",
    "fitgap://oauth/wahoo?state=synthetic-state&code=one&code=two",
    "fitgap://oauth/other?state=synthetic-state&code=synthetic-code",
    "https://oauth/wahoo?state=synthetic-state&code=synthetic-code",
    "fitgap://evil/wahoo?state=synthetic-state&code=synthetic-code",
    "fitgap://oauth/wahoo?state=synthetic-state&code=synthetic-code#fragment",
    "fitgap://oauth/wahoo?state=synthetic-state&error=access_denied"
])
func invalidOAuthCallbacksAreRejected(_ value: String) {
    #expect(throws: WahooError.self) { try testOAuth.tokenRequest(callback: URL(string: value)!) }
}

private func page(_ number: Int, total: Int, ids: [Int64], size: Int = 2) -> WahooPage {
    WahooPage(workouts: ids.map { WahooWorkout(id: $0, name: "Synthetic", starts: nil, minutes: nil, workout_summary: nil) },
              total: total, page: number, per_page: size)
}

@Test func wahooPaginationUsesMetadataAndDeduplicates() async throws {
    let workouts = try await WahooPages.collect { requested in
        #expect(requested <= 2)
        return requested == 1 ? page(1, total: 3, ids: [1, 2]) : page(2, total: 3, ids: [2, 3])
    }
    #expect(workouts.map(\.id) == [1, 2, 3])
    #expect(try await WahooPages.collect { _ in page(1, total: 0, ids: []) }.isEmpty)
}

@Test func wahooMissingOrRepeatedPageCannotSucceed() async {
    for next in [page(1, total: 3, ids: [1, 2]), page(2, total: 3, ids: []), page(2, total: 4, ids: [2, 3])] {
        do {
            _ = try await WahooPages.collect { number in number == 1 ? page(1, total: 4, ids: [1, 2]) : next }
            Issue.record("Incomplete or repeated page succeeded")
        } catch { #expect(error is ProbeError) }
    }
}

private final class WahooMock: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let data: Data
        var status = 200
        if url.path == "/oauth/token" {
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
            guard let body = try? JSONDecoder().decode([String: String].self, from: bytes) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse)); return
            }
            if body["grant_type"] == "refresh_token" {
                guard body["refresh_token"] == "synthetic-old-refresh", body["code_verifier"] == "synthetic-verifier",
                      body["client_secret"] == nil else {
                    client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return
                }
                data = Data(#"{"access_token":"synthetic-refreshed","refresh_token":"synthetic-rotated","expires_in":7200,"scope":"user_read workouts_read"}"#.utf8)
            } else if body["code"] == "wrong-scope" {
                data = Data(#"{"access_token":"synthetic-token","scope":"user_read"}"#.utf8)
            } else if body["code"] == "denied" {
                status = 400
                data = Data(#"{"error":"invalid_client","error_description":"must not be exposed"}"#.utf8)
            } else {
                data = Data(#"{"access_token":"synthetic-token","scope":"user_read workouts_read"}"#.utf8)
            }
        } else if url.path == "/v1/workouts" {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token" else {
                client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return
            }
            data = Data(#"{"workouts":[{"id":7,"name":"Synthetic","workout_summary":{"file":{"url":"https://example.invalid/fits/7.fit"}}}],"page":1,"per_page":30,"total":1}"#.utf8)
        } else if url.host == "example.invalid" {
            guard request.value(forHTTPHeaderField: "Authorization") == nil,
                  request.value(forHTTPHeaderField: "Accept-Encoding") == "identity" else {
                client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return
            }
            data = Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, 0x81, 0, 0xff, 0, 0])
        } else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockClient() -> WahooProbe {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WahooMock.self]
    return WahooProbe(session: URLSession(configuration: config))
}

@Test func simulatedWahooLoginListDownloadKeepsStorageRequestUnauthenticated() async throws {
    let client = mockClient()
    defer { client.close() }
    let token = try await client.authenticate(testOAuth, callback: URL(string: "fitgap://oauth/wahoo?state=synthetic-state&code=valid")!)
    let workouts = try await client.activities(token: token)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let receipt = try await client.downloadFirstFIT(from: workouts, token: token, store: OriginalFITStore(directory: directory))
    #expect(receipt.key == ActivityKey(source: "wahoo", id: "7"))
    #expect(receipt.byteCount == 19)
    #expect(try Data(contentsOf: directory.appendingPathComponent(receipt.key.filename)).count == 19)
}

@Test(arguments: ["wrong-scope", "denied"])
func wahooScopeAndClientErrorsStopTheTest(_ code: String) async {
    let client = mockClient()
    defer { client.close() }
    do {
        _ = try await client.authenticate(testOAuth, callback: URL(string: "fitgap://oauth/wahoo?state=synthetic-state&code=\(code)")!)
        Issue.record("Invalid scope or client accepted")
    } catch { #expect(error is WahooError) }
}

@Test func wahooRefreshRotatesCredentialsAndRetainsVerifier() async throws {
    let client = mockClient()
    defer { client.close() }
    let expired = Credentials(accessToken: "synthetic-expired", refreshToken: "synthetic-old-refresh",
                              expiresAt: .distantPast, pkceVerifier: "synthetic-verifier")
    #expect(expired.needsRefresh)
    let refreshed = try await client.refresh(expired)
    #expect(refreshed.accessToken == "synthetic-refreshed")
    #expect(refreshed.refreshToken == "synthetic-rotated")
    #expect(refreshed.pkceVerifier == "synthetic-verifier")
    #expect(!refreshed.needsRefresh)
}
