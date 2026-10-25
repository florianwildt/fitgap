import Foundation
import Testing
@testable import FITgapCore

private let fit = Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, 0x81, 0, 0xff, 0, 0])
/// `fit` gzipped by Python's gzip module, with the original file name in the header.
private let gzippedFIT = Data([
    0x1f, 0x8b, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x72, 0x69, 0x64, 0x65, 0x2e, 0x66, 0x69, 0x74, 0x00, 0xe3,
    0x53, 0x60, 0x60, 0x60, 0x66, 0x60, 0x60, 0xd0, 0x73, 0xf3, 0x0c, 0x61, 0x60, 0x68, 0x64, 0xf8, 0xcf, 0xc0, 0x00, 0x00,
    0x29, 0x3b, 0x43, 0xd4, 0x13, 0x00, 0x00, 0x00
])
/// A gzipped GPX original.
private let gzippedGPX = Data([
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xb3, 0xb1, 0xaf, 0xc8, 0xcd, 0x51, 0x28, 0x4b, 0x2d, 0x2a,
    0xce, 0xcc, 0xcf, 0xb3, 0x55, 0x32, 0xd4, 0x33, 0x50, 0xb2, 0xb7, 0xb3, 0x49, 0x2f, 0xa8, 0xb0, 0xb3, 0xd1, 0x07, 0x91,
    0x00, 0xd6, 0x73, 0x98, 0x61, 0x20, 0x00, 0x00, 0x00
])
private let account = try! IntervalsAccount(athleteID: " i12345 ", apiKey: "synthetic-key\n")
private let basic = "Basic " + Data("API_KEY:synthetic-key".utf8).base64EncodedString()

private func activity(_ id: String, _ local: String, type: String? = "fit", source: String = "GARMIN_CONNECT") -> String {
    let file = type.map { #","file_type":"\#($0)""# } ?? ""
    return #"{"id":"\#(id)","name":"Synthetic","start_date":"\#(local)Z","start_date_local":"\#(local)","elapsed_time":3600,"moving_time":3500,"source":"\#(source)"\#(file)}"#
}

private final class IntervalsMock: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var status = 200
        var data = Data()
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        guard url.host == "intervals.icu", request.value(forHTTPHeaderField: "Authorization") == basic else {
            return respond(url, status: 401, data: Data())
        }
        switch url.path {
        case "/api/v1/athlete/i12345/activities":
            guard query["fields"] == IntervalsProbe.fields, query["oldest"] == "1970-01-01" || query["oldest"] == "2000-01-01" else {
                return respond(url, status: 400, data: Data())
            }
            // Two windows of two; the second starts at the oldest start of the first and repeats it.
            let list: [String] = switch query["newest"] {
            case nil: [activity("i3", "2025-03-01T08:00:00"), activity("i2", "2025-02-01T08:00:00", type: "gpx")]
            case "2025-02-01T08:00:00": [activity("i2", "2025-02-01T08:00:00", type: "gpx"), activity("i1", "2025-01-01T08:00:00")]
            default: [#"{"id":"99"}"#]
            }
            data = Data("[\(list.prefix(Int(query["limit"] ?? "") ?? 0).joined(separator: ","))]".utf8)
        case "/api/v1/athlete/i99/activities": status = 403
        case "/api/v1/activity/i3/file": data = gzippedFIT
        case "/api/v1/activity/i1/file": data = fit
        case "/api/v1/activity/i2/file": data = gzippedGPX
        case "/api/v1/activity/i4/file": data = Data(gzippedFIT.dropLast(5) + [0, 0, 0, 0, 0])
        case "/api/v1/activity/i5/file": status = 404
        case "/api/v1/activity/i6/file": status = 429
        default: status = 500
        }
        respond(url, status: status, data: data)
    }

    private func respond(_ url: URL, status: Int, data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockClient() -> IntervalsProbe {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [IntervalsMock.self]
    return IntervalsProbe(session: URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil))
}

@Test func intervalsAccountValidatesInputAndKeepsKeyOutOfAccountID() throws {
    #expect(account.athleteID == "i12345" && account.apiKey == "synthetic-key")
    let stored = account.credentials
    #expect(stored.accessToken == "synthetic-key" && stored.accountID == "i12345" && !stored.needsRefresh && stored.refreshToken == nil)
    #expect(try IntervalsAccount(stored).authorization == basic)
    for athlete in ["", "x12", "i12/../x", "i 1", "12345678901234567890123"] {
        #expect(throws: IntervalsError.self) { try IntervalsAccount(athleteID: athlete, apiKey: "k") }
    }
    #expect(throws: IntervalsError.self) { try IntervalsAccount(athleteID: "i1", apiKey: " ") }
    #expect(throws: AccountError.self) { try IntervalsAccount(Credentials(accessToken: "k", refreshToken: nil, expiresAt: nil)) }
}

@Test func intervalsKeepsOnlyFITOriginals() throws {
    let list = try JSONDecoder().decode([IntervalsActivity].self, from: Data("""
        [\(activity("i1", "2025-01-01T08:00:00")), \(activity("i2", "2025-01-01T08:00:00", type: "tcx")),
         \(activity("i3", "2025-01-01T08:00:00", type: nil, source: "MANUAL")), \(activity("i4", "2025-01-01T08:00:00", source: "STRAVA")),
         {"id":"5"}]
        """.utf8))
    #expect(list.filter(\.hasOriginalFIT).map(\.id) == ["i1"])
    let record = ActivityRecord(list[0])
    #expect(record.source == .intervals && record.status == .pending && record.duration == 3600)
    #expect(record.date == ActivityRecord.parseDate("2025-01-01T08:00:00Z"))
    #expect(IntervalsActivity.cursor("2025-01-01T08:00:00") != nil && IntervalsActivity.cursor("2025-01-01T08:00:00Z&x=1") == nil)
    for id in ["", "../x", "a/b", "a?b", String(repeating: "1", count: 65)] { #expect(!IntervalsActivity.valid(id)) }
}

@Test func gzipChecksHeaderLengthAndChecksum() throws {
    #expect(try Gzip.decompress(gzippedFIT) == fit)
    #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    var corrupt = gzippedFIT
    corrupt[corrupt.count - 6] ^= 0xFF
    #expect(throws: ProbeError.self) { try Gzip.decompress(corrupt) }
    #expect(throws: ProbeError.self) { try Gzip.decompress(gzippedFIT.prefix(20)) }
    #expect(throws: ProbeError.self) { try Gzip.decompress(fit) }
}

@Test func simulatedIntervalsListAndDownload() async throws {
    let client = mockClient()
    defer { client.close() }
    try await client.verify(account)
    let activities = try await client.activities(account, pageSize: 2)
    #expect(activities.map(\.id) == ["i3", "i1"])

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OriginalFITStore(directory: directory)
    let gzipped = try await client.download(id: "i3", account: account, store: store)
    let plain = try await client.download(id: "i1", account: account, store: store)
    #expect(gzipped.byteCount == fit.count && plain.key == ActivityKey(source: "intervals", id: "i1"))
    await #expect { try await client.download(id: "i2", account: account, store: store) } throws: { error in
        if case ProbeError.noFIT = error { true } else { false }
    }
    await #expect { try await client.download(id: "i5", account: account, store: store) } throws: { error in
        if case ProbeError.noFIT = error { true } else { false }
    }
    await #expect(throws: ProbeError.self) { try await client.download(id: "i4", account: account, store: store) }
    await #expect(throws: ProbeError.self) { try await client.download(id: "../i1", account: account, store: store) }
}

@Test func intervalsReportsRejectedKeysAndRateLimits() async throws {
    let client = mockClient()
    defer { client.close() }
    let wrongKey = try IntervalsAccount(athleteID: "i12345", apiKey: "wrong")
    await #expect(throws: IntervalsError.self) { try await client.verify(wrongKey) }
    await #expect(throws: IntervalsError.self) { try await client.verify(IntervalsAccount(athleteID: "i99", apiKey: "synthetic-key")) }
    await #expect { try await client.activities(wrongKey) } throws: { error in
        if case ProbeError.http(401) = error { true } else { false }
    }
    let store = OriginalFITStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    await #expect { try await client.download(id: "i6", account: account, store: store) } throws: { error in
        if case ProbeError.http(429) = error { true } else { false }
    }
}
