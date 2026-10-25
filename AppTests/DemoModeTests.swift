import Foundation
import SwiftUI
import XCTest
@testable import FITgapCore
@testable import FITgap

private final class DemoRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class DemoNetworkTrap: URLProtocol, @unchecked Sendable {
    static let requests = DemoRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.record()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() { }
}

private final class DemoHangingRequest: URLProtocol, @unchecked Sendable {
    static let started = DemoRequestLog()
    static let stopped = DemoRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.record() }
    override func stopLoading() { Self.stopped.record() }
}

@MainActor
final class DemoModeTests: XCTestCase {
    @MainActor private struct Environment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.fitgap.demo.\(UUID().uuidString)"
        let credentials = CredentialStore(service: "org.fitgap.demo.\(UUID().uuidString)")
        var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
        var library: ActivityLibrary { ActivityLibrary(directory: root.appendingPathComponent("Real")) }
        func model(hanging: Bool = false) -> AppModel {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = hanging ? [DemoHangingRequest.self] : [DemoNetworkTrap.self]
            let session = URLSession(configuration: config)
            return AppModel(library: library, credentials: credentials, defaults: defaults,
                            wahoo: WahooProbe(session: session), zwift: ZwiftProbe(session: session),
                            mywhoosh: MyWhooshProbe(session: session), hammerhead: HammerheadProbe(session: session),
                            dropbox: DropboxProbe(session: session))
        }
        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            for source in Source.providers { try? credentials.remove(source) }
        }
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path.replacingOccurrences(of: directory.path, with: "")] = try Data(contentsOf: url)
        }
        return result
    }

    func testDemoLifecyclePreservesRealFilesCredentialsCursorAndCooldownWithoutRequests() async throws {
        let env = Environment()
        defer { env.cleanup() }
        let seeds = try DemoLibrary(realDirectory: env.root.appendingPathComponent("Seed")).load()
        let seedLibrary = DemoLibrary(realDirectory: env.root.appendingPathComponent("Seed")).library
        var real = ActivityRecord(source: .wahoo, remoteID: "recovery", name: "Synthetic real-library control",
                                  date: seeds[0].date, duration: 1800)
        let bytes = try Data(contentsOf: seedLibrary.verifiedFile(for: seeds[0]))
        real.receipt = try env.library.files.save(bytes, key: real.key)
        real.metrics = try env.library.metrics(for: real)
        real.status = .available; real.sharedAt = Date(timeIntervalSince1970: 1000)
        try env.library.save([real])
        let cursor = env.library.directory.appendingPathComponent("wahoo-catalog.json")
        try Data("synthetic saved cursor".utf8).write(to: cursor)
        env.defaults.set(WahooOAuth.clientID, forKey: "wahooClientID")
        let cooldown = Date().addingTimeInterval(3600)
        env.defaults.set(cooldown, forKey: "wahooRetryAfter")
        let before = try snapshot(env.library.directory)
        let requests = DemoNetworkTrap.requests.value
        var model = env.model()
        XCTAssertTrue(model.connected.isEmpty)
        XCTAssertTrue(model.canTryDemo)
        await model.setDemo(true)
        XCTAssertTrue(model.isDemo)
        XCTAssertEqual(model.activities.count, 3)
        XCTAssertTrue(model.activities.allSatisfy { $0.source == .demo && $0.metrics != nil })
        XCTAssertNotEqual(model.library.directory, env.library.directory)
        model.start()
        await model.refreshAndWait()
        model.phaseChanged(.background); model.phaseChanged(.active)
        model.connectZwift(username: "unused", password: "unused")
        model.connectWahoo()
        model.disconnect(.wahoo)
        model.download(real)
        model.deleteFile(real)
        model.markShared(real)
        let record = model.activities[0]
        let export = try model.fileForSharing(record)
        XCTAssertEqual(export.lastPathComponent, "FITgap-Demo-recovery.fit")
        XCTAssertEqual(try Data(contentsOf: export), bytes)
        let generation = model.libraryGeneration
        model.markShared(record, generation: generation)
        XCTAssertNotNil(model.activities[0].sharedAt)
        model.deleteFile(model.activities[0])
        XCTAssertEqual(model.activities[0].status, .deleted)
        XCTAssertNil(model.activities[0].sharedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        model.refresh()
        XCTAssertEqual(model.activities[0].status, .deleted)
        // Persisted demo mode must be selected before startup/foreground can access providers.
        model = env.model()
        XCTAssertTrue(model.isDemo)
        model.start(); model.phaseChanged(.active)
        XCTAssertEqual(model.activities[0].status, .deleted)
        model.download(model.activities[0])
        XCTAssertEqual(model.activities[0].status, .available)
        XCTAssertEqual(try Data(contentsOf: model.fileForSharing(model.activities[0])), bytes)
        model.markShared(model.activities[0])
        let staleGeneration = model.libraryGeneration
        model.resetDemo()
        XCTAssertTrue(model.activities.allSatisfy { $0.sharedAt == nil && $0.status == .available })
        model.markShared(record, generation: staleGeneration)
        XCTAssertTrue(model.activities.allSatisfy { $0.sharedAt == nil })
        await model.setDemo(false)
        XCTAssertFalse(model.isDemo)
        XCTAssertTrue(model.connected.isEmpty)
        XCTAssertEqual(model.activities[0].name, real.name)
        XCTAssertEqual(model.activities[0].sharedAt, real.sharedAt)
        XCTAssertEqual(try snapshot(env.library.directory), before)
        XCTAssertEqual(env.defaults.object(forKey: "wahooRetryAfter") as? Date, cooldown)
        XCTAssertEqual(env.defaults.string(forKey: "wahooClientID"), WahooOAuth.clientID)
        for source in Source.providers {
            XCTAssertNil(try env.credentials.read(source))
        }
        XCTAssertEqual(DemoNetworkTrap.requests.value, requests)
        XCTAssertNil(model.errorMessage)
    }

    func testSwitchWaitsForCancellationAndBlocksConcurrentActionsAndResume() async throws {
        let env = Environment()
        defer { env.cleanup() }
        let model = env.model()
        var cancelled = false
        var resumed = false
        var began = false
        model.run(label: "In-flight synthetic sync", resume: { resumed = true }) {
            began = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                // Simulates asynchronous cleanup that must finish in the original library.
                await Task.yield()
                XCTAssertFalse(model.isDemo)
                XCTAssertEqual(model.library.directory, env.library.directory)
                cancelled = true
                throw error
            }
        }
        while !began { await Task.yield() }
        let transition = Task { await model.setDemo(true) }
        while !model.switchingMode { await Task.yield() }
        model.refresh(); model.connectWahoo()
        model.connectZwift(username: "unused", password: "unused")
        await model.setDemo(false) // A concurrent switch is ignored.
        await transition.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(model.isDemo)
        XCTAssertFalse(model.busy)
        model.phaseChanged(.background); model.backgroundTimeExpired(); model.phaseChanged(.active)
        XCTAssertFalse(resumed)
        await model.setDemo(false)
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertFalse(env.defaults.bool(forKey: "demoMode"))
    }

    func testConnectedProviderSyncCannotBeReplacedByDemo() async throws {
        let env = Environment()
        defer { env.cleanup() }
        try env.credentials.write(Credentials(accessToken: "synthetic-live-session", refreshToken: nil,
                                               expiresAt: .distantFuture), for: .wahoo)
        env.defaults.set(WahooOAuth.clientID, forKey: "wahooClientID")
        let model = env.model(hanging: true)
        let started = DemoHangingRequest.started.value
        let stopped = DemoHangingRequest.stopped.value
        model.refresh()
        let deadline = Date().addingTimeInterval(5)
        while DemoHangingRequest.started.value == started, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(DemoHangingRequest.started.value, started + 1)
        XCTAssertTrue(model.busy)
        await model.setDemo(true)
        XCTAssertFalse(model.isDemo)
        XCTAssertTrue(model.busy)
        XCTAssertFalse(model.canTryDemo)
        XCTAssertEqual(DemoHangingRequest.stopped.value, stopped)
        model.cancel()
        await model.refreshAndWait()
        model.disconnect(.wahoo)
        XCTAssertTrue(model.canTryDemo)
        await model.setDemo(true)
        XCTAssertTrue(model.isDemo)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(DemoHangingRequest.stopped.value, stopped + 1)
        model.refresh(); model.phaseChanged(.active)
        XCTAssertEqual(DemoHangingRequest.started.value, started + 1)
        XCTAssertNil(try env.credentials.read(.wahoo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.library.directory.path))
        XCTAssertNil(model.errorMessage)
    }

    func testEitherConnectedProviderBlocksDemoAndOverridesPersistedDemoPreference() async throws {
        for source in Source.providers {
            let env = Environment()
            defer { env.cleanup() }
            try env.credentials.write(Credentials(accessToken: "synthetic-expired-session", refreshToken: "synthetic-refresh",
                                                   expiresAt: .distantPast), for: source)
            env.defaults.set(WahooOAuth.clientID, forKey: "wahooClientID")
            let model = env.model()
            XCTAssertEqual(model.connected, [source])
            XCTAssertFalse(model.canTryDemo)
            let requests = DemoNetworkTrap.requests.value
            await model.setDemo(true)
            XCTAssertFalse(model.isDemo)
            XCTAssertFalse(env.defaults.bool(forKey: "demoMode"))
            XCTAssertEqual(try env.credentials.read(source)?.accessToken, "synthetic-expired-session")
            env.defaults.set(true, forKey: "demoMode")
            let restarted = env.model()
            XCTAssertFalse(restarted.isDemo)
            XCTAssertFalse(restarted.canTryDemo)
            XCTAssertFalse(env.defaults.bool(forKey: "demoMode"))
            XCTAssertEqual(restarted.connected, [source])
            XCTAssertEqual(DemoNetworkTrap.requests.value, requests)
            XCTAssertEqual(try env.credentials.read(source)?.refreshToken, "synthetic-refresh")
            restarted.disconnect(source)
            // Hammerhead also tries to revoke the link, which runs as an operation (here against the network trap).
            while restarted.busy { await Task.yield() }
            XCTAssertTrue(restarted.canTryDemo)
            await restarted.setDemo(true)
            XCTAssertTrue(restarted.isDemo)
        }
    }

    func testDemoStartsWithoutRealLibraryAndCanExitAfterDemoIndexFailure() async throws {
        let env = Environment()
        defer { env.cleanup() }
        let model = env.model()
        XCTAssertTrue(model.activities.isEmpty)
        await model.setDemo(true)
        let demoDirectory = model.library.directory
        try Data("broken synthetic index".utf8).write(to: demoDirectory.appendingPathComponent("activities.json"))
        let restarted = env.model()
        XCTAssertTrue(restarted.isDemo)
        XCTAssertFalse(restarted.storageReady)
        restarted.resetDemo()
        XCTAssertTrue(restarted.storageReady)
        XCTAssertEqual(restarted.activities.count, 3)
        await restarted.setDemo(false)
        XCTAssertTrue(restarted.activities.isEmpty)
        XCTAssertFalse(restarted.isDemo)
    }

    func testExitRemainsPossibleWhenRealIndexIsUnreadableAndPreservesItsBytes() async throws {
        let env = Environment()
        defer { env.cleanup() }
        let model = env.model()
        await model.setDemo(true)
        try FileManager.default.createDirectory(at: env.library.directory, withIntermediateDirectories: true)
        let index = env.library.directory.appendingPathComponent("activities.json")
        let bytes = Data("intentionally incompatible synthetic real index".utf8)
        try bytes.write(to: index)
        await model.setDemo(false)
        XCTAssertFalse(model.isDemo)
        XCTAssertFalse(model.storageReady)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: index), bytes)
        XCTAssertFalse(env.defaults.bool(forKey: "demoMode"))
    }
}
