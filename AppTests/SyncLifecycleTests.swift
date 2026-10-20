import FITgapCore
import SwiftUI
import XCTest
@testable import FITgap

@MainActor
final class SyncLifecycleTests: XCTestCase {
    private func makeModel() -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(library: ActivityLibrary(directory: directory),
            credentials: CredentialStore(service: "org.fitgap.lifecycle.\(UUID().uuidString)"),
            defaults: UserDefaults(suiteName: "org.fitgap.lifecycle.\(UUID().uuidString)")!)
        return (model, directory)
    }

    func testRefreshWaitsForExistingWorkAndDoesNotStartDuplicate() async {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        var completed = 0
        model.run(label: "Synthetic") {
            try await Task.sleep(for: .milliseconds(100))
            completed += 1
        }
        model.run(label: "Duplicate") { completed += 100 }
        await model.refreshAndWait()
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(model.busy)
    }

    func testBackgroundTransitionKeepsWorkAndExpirationResumesOnActivation() async throws {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        var resumed = 0
        model.run(label: "Synthetic", resume: { resumed += 1 }) {
            try await Task.sleep(for: .seconds(60))
        }
        model.phaseChanged(.background)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.busy)
        model.backgroundTimeExpired()
        await model.refreshAndWait()
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(resumed, 0)
        model.phaseChanged(.active)
        XCTAssertEqual(resumed, 1)
        model.phaseChanged(.active)
        XCTAssertEqual(resumed, 1)
    }

    func testManualCancellationDoesNotResumeOnActivation() async {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        var resumed = 0
        model.run(label: "Synthetic", resume: { resumed += 1 }) { try await Task.sleep(for: .seconds(60)) }
        model.phaseChanged(.background)
        model.cancel()
        await model.refreshAndWait()
        model.phaseChanged(.active)
        XCTAssertEqual(resumed, 0)
        XCTAssertNil(model.errorMessage)
    }

    func testCancelledNetworkOperationDoesNotShowFailure() async {
        let (model, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.run(label: "Synthetic URLSession cancellation") {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { throw URLError(.cancelled) }
        }
        model.cancel()
        await model.refreshAndWait()
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
    }

    func testClientSwitchRequiresNewWahooLoginAndPreservesLocalFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ActivityLibrary(directory: directory)
        var record = ActivityRecord(source: .wahoo, remoteID: "7", name: "Synthetic", date: nil, duration: nil)
        let bytes = Data([14, 0x20, 0, 0, 3, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54, 0, 0, 0x81, 0, 0xff, 0, 0])
        record.receipt = try library.files.save(bytes, key: record.key)
        record.status = .available
        try library.save([record])
        let store = CredentialStore(service: "org.fitgap.client-switch.\(UUID().uuidString)")
        defer { try? store.remove(.wahoo) }
        try store.write(Credentials(accessToken: "synthetic-old-app-token", refreshToken: nil, expiresAt: nil), for: .wahoo)
        let suite = "org.fitgap.client-switch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic-old-client", forKey: "wahooClientID")
        defaults.set(Date().addingTimeInterval(3600), forKey: "wahooRetryAfter")
        let changed = AppModel(library: library, credentials: store, defaults: defaults)
        XCTAssertFalse(changed.connected.contains(.wahoo))
        XCTAssertNil(defaults.object(forKey: "wahooRetryAfter"))
        XCTAssertEqual(try Data(contentsOf: library.verifiedFile(for: changed.activities[0])), bytes)
        defaults.set(WahooOAuth.clientID, forKey: "wahooClientID")
        let matching = AppModel(library: library, credentials: store, defaults: defaults)
        XCTAssertTrue(matching.connected.contains(.wahoo))
    }
}
