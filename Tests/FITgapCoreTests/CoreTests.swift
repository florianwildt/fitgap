import CryptoKit
import Foundation
import Testing
@testable import FITgapCore

private func fixture(_ byte: UInt8 = 0x81) -> Data {
    // Synthetic FIT-shaped bytes, deliberately not a real activity or CRC validation fixture.
    Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, byte, 0, 0xff, 0, 0])
}

private func temporaryStore() -> OriginalFITStore {
    OriginalFITStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}

@Test func identityAndOriginalBytes() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let key = ActivityKey(source: "zwift", id: "123")
    let other = ActivityKey(source: "wahoo", id: "123")
    #expect(key != other)
    #expect(key.filename != other.filename)
    #expect(ActivityKey(source: "a:b", id: "c").filename != ActivityKey(source: "a", id: "b:c").filename)
    let original = fixture()
    let receipt = try store.save(original, key: key)
    let file = store.directory.appendingPathComponent(key.filename)
    #expect(try Data(contentsOf: file) == original)
    #expect(receipt.sha256 == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
    #expect(receipt.byteCount == original.count)
    _ = try store.save(original, key: key)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count == 2)
    #expect(throws: ProbeError.self) { try store.save(fixture(0x82), key: key) }
    #expect(try Data(contentsOf: file) == original)
}

@Test func partialAndNonFITNeverCommitted() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let key = ActivityKey(source: "zwift", id: "1")
    #expect(throws: ProbeError.self) { try store.save(fixture().dropLast(), key: key) }
    #expect(throws: ProbeError.self) { try store.save(Data("<html>error response</html>".utf8), key: key) }
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func cancellationNeverCommitted() async {
    let store = temporaryStore()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try store.save(fixture(), key: ActivityKey(source: "zwift", id: "2"))
    }
    do { _ = try await task.value; Issue.record("Cancelled operation saved data") }
    catch { #expect(error is CancellationError) }
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

private actor Offsets {
    var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}

@Test func paginationShortOverlappingAndEmptyPages() async throws {
    let offsets = Offsets()
    let values: [Int] = try await Pages.collect(limit: 20, key: { ActivityKey(source: "zwift", id: String($0)) }) { start, _ in
        await offsets.add(start)
        switch start {
        case 0: return [10, 11]
        case 2: return [11, 12]
        default: return []
        }
    }
    #expect(values == [10, 11, 12])
    #expect(await offsets.values == [0, 2, 4])
}

@Test func repeatedPageStopsInsteadOfLooping() async {
    do {
        let _: [Int] = try await Pages.collect(key: { ActivityKey(source: "zwift", id: String($0)) }) { _, _ in [1] }
        Issue.record("Repeated page accepted")
    } catch { #expect(error is ProbeError) }
}

@Test func laterPageFailureIsNotSuccess() async {
    do {
        let _: [Int] = try await Pages.collect(key: { ActivityKey(source: "zwift", id: String($0)) }) { start, _ in
            if start == 0 { return [1] }
            throw URLError(.networkConnectionLost)
        }
        Issue.record("Partial list treated as complete")
    } catch { #expect(error is URLError) }
}

private final class InterruptedDownload: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.value(forHTTPHeaderField: "Authorization") != nil {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture().prefix(15))
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
    override func stopLoading() {}
}

@Test func interruptedNetworkDownloadLeavesNoFile() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [InterruptedDownload.self]
    let client = ZwiftProbe(session: URLSession(configuration: config))
    defer { client.close() }
    let activity = try JSONDecoder().decode(ZwiftActivity.self, from: Data(
        #"{"id":1,"name":"Synthetic","fitFileBucket":"example-bucket","fitFileKey":"activity.fit"}"#.utf8
    ))
    let store = temporaryStore()
    do {
        _ = try await client.download(activity, store: store)
        Issue.record("Interrupted download succeeded")
    } catch let error as URLError { #expect(error.code == .networkConnectionLost) }
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func downloadURLCannotEscapeStorageHost() throws {
    let activity = try JSONDecoder().decode(ZwiftActivity.self, from: Data(
        #"{"id":1,"name":"Synthetic","fitFileBucket":"evil.example/steal?x=","fitFileKey":"activity.fit"}"#.utf8
    ))
    #expect(activity.downloadURL == nil)
}
