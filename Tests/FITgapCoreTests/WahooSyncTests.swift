import Foundation
import Testing
@testable import FITgapCore

private actor SavedCatalog {
    var ids = Set<Int64>()
    var pages: [Int] = []
    var cursor = WahooCatalogCursor()
    func save(_ page: WahooPage, _ next: WahooCatalogCursor) {
        ids.formUnion(page.workouts.map(\.id)); pages.append(page.page); cursor = next
    }
}

private final class CatalogMock: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let scenario = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let number = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "page" }?.value ?? "1")!
        let total = scenario.contains("shifted") ? 1100 : 1000
        let size = scenario.contains("clamped") ? 30 : 100
        var headers: [String: String] = [:]
        let data: Data
        if url.host == "example.invalid" {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            data = Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, 0x81, 0, 0xff, 0, 0])
        } else if scenario.contains("exhausted") {
            headers = ["X-RateLimit-Remaining": "249,99,0", "X-RateLimit-Reset": "120"]
            data = Data(#"{"workouts":[{"id":7,"workout_summary":{"file":{"url":"https://example.invalid/7.fit"}}}],"page":1,"per_page":30,"total":1}"#.utf8)
        } else {
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "per_page" && $0.value == "100" })
            let start = total - (number - 1) * size
            let ids = start > 0 ? Array(stride(from: start, through: max(1, start-size+1), by: -1)) : []
            data = try! JSONSerialization.data(withJSONObject: ["workouts": ids.map { ["id": $0] }, "page": number, "total": total, "per_page": size])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func catalogClient() -> WahooProbe {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CatalogMock.self]
    return WahooProbe(session: URLSession(configuration: config))
}

@Test func thousandWorkoutCatalogResumesFromPersistedPageWithoutLosingIDs() async throws {
    let client = catalogClient()
    defer { client.close() }
    let saved = SavedCatalog()
    do {
        try await client.catalog(token: "normal", cursor: WahooCatalogCursor()) { page, next in
            await saved.save(page, next)
            if page.page == 2 { throw CancellationError() }
        }
        Issue.record("Expected interrupted catalog")
    } catch { #expect(error is CancellationError) }
    // The same JSON round trip is used for the on-device checkpoint.
    let bytes = try JSONEncoder().encode(await saved.cursor)
    let cursor = try JSONDecoder().decode(WahooCatalogCursor.self, from: bytes)
    #expect(cursor.nextPage == 3)
    try await client.catalog(token: "normal", cursor: cursor) { page, next in await saved.save(page, next) }
    #expect(await saved.ids == Set((1...1000).map(Int64.init)))
    #expect(await saved.pages == [1, 2, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    #expect(await saved.cursor.nextPage == 1)
}

@Test func shiftedCatalogRestartsWhenResumeAnchorMoved() async throws {
    let client = catalogClient()
    defer { client.close() }
    let saved = SavedCatalog()
    try await client.catalog(token: "shifted", cursor: WahooCatalogCursor(nextPage: 3, pageSize: 100, anchorID: 801)) {
        page, next in await saved.save(page, next)
    }
    #expect(await saved.pages == Array(1...11))
    #expect(await saved.ids.count == 1100)
}

@Test func catalogHonorsServerPageSize() async throws {
    let client = catalogClient()
    defer { client.close() }
    let saved = SavedCatalog()
    try await client.catalog(token: "clamped", cursor: WahooCatalogCursor()) { page, next in await saved.save(page, next) }
    #expect(await saved.ids.count == 1000)
    #expect(await saved.pages.count == 34)
}

@Test func wahooResetHeadersUseSecondsAndSafeFallback() {
    let now = Date(timeIntervalSince1970: 1000)
    func response(_ code: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.wahooligan.com/v1/workouts")!, statusCode: code, httpVersion: nil, headerFields: headers)!
    }
    #expect(WahooRateLimit.deadline(response(200, ["X-RateLimit-Remaining": "10,5,1"]), now: now) == nil)
    #expect(WahooRateLimit.deadline(response(200, ["X-RateLimit-Remaining": "10,5,0", "X-RateLimit-Reset": "3600"]), now: now) == now.addingTimeInterval(3601))
    #expect(WahooRateLimit.deadline(response(429, ["X-RateLimit-Reset": "120", "Retry-After": "200"]), now: now) == now.addingTimeInterval(201))
    #expect(WahooRateLimit.deadline(response(429, ["X-RateLimit-Reset": "NaN"]), now: now) == now.addingTimeInterval(301))
}

@Test func exhaustedAPIBudgetStillAllowsOriginalCDNDownload() async throws {
    let client = catalogClient()
    defer { client.close() }
    let workouts = try await client.activities(token: "exhausted")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let receipt = try await client.download(workouts[0], token: "exhausted", store: OriginalFITStore(directory: directory))
    #expect(receipt.byteCount == 19)
    do {
        _ = try await client.activities(token: "exhausted")
        Issue.record("Exhausted API should not issue another request")
    } catch { #expect(error is WahooRateLimit) }
}
