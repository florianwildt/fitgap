import FITgapCore
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var activities: [ActivityRecord] = []
    @Published var connected = Set<Source>()
    @Published var busy = false
    @Published var progress = ""
    @Published var errorMessage: String?
    @Published var storageReady = false
    let library: ActivityLibrary
    private let credentials: CredentialStore
    private let defaults: UserDefaults
    private let wahoo = WahooProbe()
    private let zwift = ZwiftProbe()
    private let signIn = WahooSignIn()
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var resumeOnExpiration: (@MainActor () -> Void)?
    private var interrupted: (@MainActor () -> Void)?
    private var active = true
    private var started = false
    private var manuallyCancelled = false
    private var wahooFiles: [ActivityKey: WahooWorkout] = [:]
    private var accessCache: [Source: Credentials] = [:]
    private let cooldownKey = "wahooRetryAfter"
    private let wahooClientKey = "wahooClientID"
    private var cursorFile: URL { library.directory.appendingPathComponent("wahoo-catalog.json") }

    init(library: ActivityLibrary? = nil, credentials: CredentialStore = CredentialStore(), defaults: UserDefaults = .standard) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.library = library ?? ActivityLibrary(directory: support.appendingPathComponent("FITgap", isDirectory: true))
        self.credentials = credentials; self.defaults = defaults
        do {
            activities = try self.library.load()
            for source in Source.allCases where try credentials.read(source) != nil {
                // Tokens from another registered Wahoo app must not be reused after switching clients.
                if source == .wahoo, defaults.string(forKey: wahooClientKey) != WahooOAuth.clientID {
                    defaults.removeObject(forKey: cooldownKey)
                    continue
                }
                connected.insert(source)
            }
            storageReady = true
        } catch { errorMessage = Self.message(error) }
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
    }

    func refreshAndWait() async {
        refresh()
        await task?.value
    }

    func phaseChanged(_ phase: ScenePhase) {
        active = phase == .active
        if active {
            continueInterrupted()
            if let until = defaults.object(forKey: cooldownKey) as? Date, until <= Date(), !busy { refresh() }
        } else if phase == .background, resumeOnExpiration == nil { task?.cancel() }
    }

    func connectZwift(username: String, password: String) {
        run(label: "Zwift wird verbunden …") {
            let token = try await self.zwift.connect(username: username, password: password)
            try Task.checkCancellation()
            try self.credentials.write(token, for: .zwift)
            self.connected.insert(.zwift)
        }
    }

    func connectWahoo() {
        run(label: "Wahoo-Anmeldung …") {
            let oauth = try WahooOAuth()
            let callback = try await self.signIn.login(oauth)
            try Task.checkCancellation()
            let token = try await self.wahoo.connect(oauth, callback: callback)
            try Task.checkCancellation()
            try self.credentials.write(token, for: .wahoo)
            self.defaults.set(WahooOAuth.clientID, forKey: self.wahooClientKey)
            self.defaults.removeObject(forKey: self.cooldownKey)
            self.connected.insert(.wahoo)
        }
    }

    func disconnect(_ source: Source) {
        do { try credentials.remove(source); accessCache.removeValue(forKey: source); connected.remove(source) }
        catch { errorMessage = Self.message(error) }
        // Deliberately local: no server-side deauthorization that could delete provider data.
    }

    func refresh() {
        guard !connected.isEmpty || activities.contains(where: { $0.status == .available && $0.metrics == nil }) else { return }
        run(label: "Aktivitäten werden abgerufen …", resume: { [weak self] in self?.refresh() }) {
            try await self.fillMissingMetrics()
            var failures: [String] = []
            for source in Source.allCases where self.connected.contains(source) {
                do { try await self.sync(source) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    if let limit = error as? WahooRateLimit { self.defaults.set(limit.until, forKey: self.cooldownKey) }
                    else if !self.active { self.interrupted = self.resumeOnExpiration }
                    failures.append("\(source.title): \(Self.message(error))")
                }
            }
            if !failures.isEmpty { self.errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    private func access(_ source: Source) async throws -> String {
        if source == .wahoo, defaults.string(forKey: wahooClientKey) != WahooOAuth.clientID { throw AccountError.reconnect }
        if source == .wahoo, let until = defaults.object(forKey: cooldownKey) as? Date {
            if until > Date() { throw WahooRateLimit(until: until) }
            defaults.removeObject(forKey: cooldownKey)
        }
        let stored: Credentials?
        if let cached = accessCache[source] { stored = cached }
        else { stored = try credentials.read(source) }
        guard var token = stored else { throw AccountError.reconnect }
        if token.needsRefresh {
            token = try await (source == .zwift ? zwift.refresh(token) : wahoo.refresh(token))
            try credentials.write(token, for: source)
        }
        // Keep a running sync independent of repeated Keychain reads when the phone locks.
        // This memory-only cache is cleared when the operation ends; protection stays unchanged.
        accessCache[source] = token
        return token.accessToken
    }

    private func sync(_ source: Source) async throws {
        progress = "\(source.title): Aktivitäten werden abgerufen …"
        let token = try await access(source)
        switch source {
        case .zwift:
            let remote = try await zwift.activities(token: token)
            activities = ActivityLibrary.merging(remote.map(ActivityRecord.init), into: activities)
            try library.save(activities)
            let keys = pendingKeys
            let pending = remote.filter { keys.contains($0.key) }
            for (offset, activity) in pending.enumerated() {
                try Task.checkCancellation()
                progress = "Zwift: FIT \(offset + 1) von \(pending.count)"
                do { try await commit(await zwift.download(activity, store: library.files)) }
                catch { try recordFailure(activity.key, error: error); throw error }
            }
        case .wahoo:
            wahooFiles.removeAll(keepingCapacity: true)
            let cursor = (try? JSONDecoder().decode(WahooCatalogCursor.self, from: Data(contentsOf: cursorFile))) ?? WahooCatalogCursor()
            try await wahoo.catalog(token: token, cursor: cursor) { page, next in
                try await self.saveWahooPage(page, cursor: next)
            }
            let pending = activities.filter { $0.source == .wahoo && [.pending, .failed].contains($0.status) }
            for (offset, record) in pending.enumerated() {
                try Task.checkCancellation()
                progress = "Wahoo: FIT \(offset + 1) von \(pending.count)"
                do {
                    let token = try await access(.wahoo)
                    if let remote = wahooFiles[record.key] {
                        try await commit(await wahoo.download(remote, token: token, store: library.files))
                    } else {
                        try await commit(await wahoo.download(id: record.remoteID, token: token, store: library.files))
                    }
                }
                catch ProbeError.noFIT { try recordFailure(record.key, error: ProbeError.noFIT) }
                catch { try recordFailure(record.key, error: error); throw error }
            }
            wahooFiles.removeAll()
        }
    }

    private func saveWahooPage(_ page: WahooPage, cursor: WahooCatalogCursor) throws {
        activities = ActivityLibrary.merging(page.workouts.map(ActivityRecord.init), into: activities)
        try library.save(activities)
        // Save the cursor after the index: repeating a page is safe if either write is interrupted.
        try JSONEncoder().encode(cursor).write(to: cursorFile, options: .atomic)
        for workout in page.workouts { wahooFiles[workout.key] = workout }
        progress = "Wahoo: Seite \(page.page), \(page.total) Aktivitäten"
    }

    private var pendingKeys: Set<ActivityKey> {
        Set(activities.filter { [.pending, .failed].contains($0.status) }.map(\.key))
    }

    private func fillMissingMetrics() async throws {
        let missing = activities.filter { $0.status == .available && $0.metrics == nil }
        guard !missing.isEmpty else { return }
        let indices = Dictionary(uniqueKeysWithValues: activities.enumerated().map { ($0.element.key, $0.offset) })
        for start in stride(from: 0, to: missing.count, by: 10) {
            try Task.checkCancellation()
            progress = "Kennzahlen: \(start) von \(missing.count)"
            let end = min(start + 10, missing.count)
            let batch = Array(missing[start..<end])
            let worker = Task.detached(priority: .utility) { [library] in
                var result: [ActivityKey: (String, ActivityMetrics)] = [:]
                for record in batch {
                    try Task.checkCancellation()
                    if let hash = record.receipt?.sha256, let metrics = try? library.metrics(for: record) {
                        result[record.key] = (hash, metrics)
                    }
                }
                return result
            }
            let updates = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            if !updates.isEmpty {
                var updated = activities
                for (key, update) in updates {
                    if let index = indices[key], updated.indices.contains(index), updated[index].key == key,
                       updated[index].receipt?.sha256 == update.0 { updated[index].metrics = update.1 }
                }
                activities = updated
                // Keep completed batches durable even when a later file is slow or iOS stops us.
                try library.save(activities)
            }
            progress = "Kennzahlen: \(end) von \(missing.count)"
        }
    }

    private func commit(_ receipt: FITReceipt) async throws {
        if var record = activities.first(where: { $0.key == receipt.key }) {
            record.receipt = receipt
            let metrics = await Task.detached(priority: .utility) { [library, record] in try? library.metrics(for: record) }.value
            try Task.checkCancellation()
            guard let index = activities.firstIndex(where: { $0.key == receipt.key }) else { return }
            activities[index].receipt = receipt; activities[index].status = .available
            activities[index].metrics = metrics
            try library.save(activities)
        }
    }

    private func recordFailure(_ key: ActivityKey, error: Error) throws {
        guard !Task.isCancelled, !(error is CancellationError), let index = activities.firstIndex(where: { $0.key == key }) else { return }
        if case ProbeError.noFIT = error { activities[index].status = .unavailable }
        else { activities[index].status = .failed }
        try library.save(activities)
    }

    func download(_ record: ActivityRecord) {
        run(label: "\(record.source.title): FIT wird geladen …", resume: { [weak self] in self?.download(record) }) {
            let token = try await self.access(record.source)
            do {
                let receipt: FITReceipt
                if record.source == .zwift {
                    receipt = try await self.zwift.download(id: record.remoteID, token: token, store: self.library.files)
                } else {
                    receipt = try await self.wahoo.download(id: record.remoteID, token: token, store: self.library.files)
                }
                try await self.commit(receipt)
            } catch { try self.recordFailure(record.key, error: error); throw error }
        }
    }

    func deleteFile(_ record: ActivityRecord) {
        do {
            guard let index = activities.firstIndex(where: { $0.key == record.key }) else { return }
            activities[index] = try library.deletingFile(for: record)
            try library.save(activities)
        } catch { errorMessage = Self.message(error) }
    }

    func markShared(_ record: ActivityRecord) {
        do {
            guard let index = activities.firstIndex(where: { $0.key == record.key }) else { return }
            activities[index].sharedAt = Date()
            try library.save(activities)
        } catch { errorMessage = Self.message(error) }
    }

    func cancel() { manuallyCancelled = true; interrupted = nil; retryTask?.cancel(); task?.cancel() }

    func run(label: String, resume: (@MainActor () -> Void)? = nil, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, storageReady else { return }
        retryTask?.cancel()
        manuallyCancelled = false
        busy = true; progress = label; errorMessage = nil
        resumeOnExpiration = resume
        if resume != nil {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FITgap-Sync") { [weak self] in
                Task { @MainActor in self?.backgroundTimeExpired() }
            }
        }
        task = Task {
            defer {
                endBackgroundTask()
                accessCache.removeAll()
                wahooFiles.removeAll()
                resumeOnExpiration = nil
                busy = false; progress = ""; task = nil
                if !continueInterrupted(), !manuallyCancelled { scheduleRetry() }
            }
            do { try await operation() }
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                if let limit = error as? WahooRateLimit { defaults.set(limit.until, forKey: cooldownKey) }
                else if !active { interrupted = resumeOnExpiration }
                errorMessage = Self.message(error)
            }
        }
    }

    func backgroundTimeExpired() {
        interrupted = resumeOnExpiration
        task?.cancel()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    @discardableResult private func continueInterrupted() -> Bool {
        guard active, !busy, let action = interrupted else { return false }
        interrupted = nil
        action()
        return true
    }

    private func scheduleRetry() {
        guard connected.contains(.wahoo), let until = defaults.object(forKey: cooldownKey) as? Date, until > Date() else { return }
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(until.timeIntervalSinceNow)) }
            catch { return }
            guard let self, self.active else { return }
            self.refresh()
        }
    }

    static func message(_ error: Error) -> String {
        if let error = error as? ProbeError {
            if case .http(401) = error { return AccountError.reconnect.localizedDescription }
            return error.localizedDescription
        }
        if let error = error as? AccountError { return error.localizedDescription }
        if let error = error as? WahooError { return error.localizedDescription }
        if let error = error as? WahooRateLimit { return error.localizedDescription }
        if let error = error as? LibraryError { return error.localizedDescription }
        if let error = error as? URLError {
            if error.code == .cancelled { return "Abruf abgebrochen. Bereits gespeicherte FITs bleiben verfügbar." }
            return "Netzwerk nicht erreichbar oder Anfrage fehlgeschlagen. Bitte später erneut versuchen."
        }
        return "Lokale Daten konnten nicht gelesen oder gespeichert werden. Vorhandene Dateien bleiben erhalten."
    }
}
