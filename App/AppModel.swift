import FITgapCore
import Foundation
import HealthKit
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var activities: [ActivityRecord] = [] { didSet { duplicates = DuplicateGroups(activities) } }
    /// Copies of one workout from several sources; only the fullest is listed, shared and saved to Health.
    @Published private(set) var duplicates = DuplicateGroups()
    var visibleActivities: [ActivityRecord] { activities.filter { !duplicates.hidden.contains($0.key) } }
    @Published var connected = Set<Source>()
    @Published var busy = false
    @Published var progress = "" { didSet { continued.update(subtitle: progress) } }
    @Published var errorMessage: String?
    @Published var storageReady = false
    @Published private(set) var isDemo = false
    @Published private(set) var switchingMode = false
    @Published private(set) var demoNotice: String?
    @Published private(set) var accountsReady = false
    /// Activities that start after this date are written to Apple Health after each sync.
    @Published private(set) var healthAutoExportSince: Date?
    /// Counts of the running or last Apple Health export in this app session.
    @Published private(set) var healthSummary: HealthExportSummary?
    var healthExporting: Bool { healthSummary?.finished == false }
    /// A finished export keeps its status visible until the user has looked at it.
    @Published private(set) var healthSummarySeen = true
    /// Names of the activities being written right now, so long ones do not look like a stalled export.
    @Published private(set) var healthInProgress: [String] = []

    func acknowledgeHealthSummary() {
        if healthSummary?.finished == true { healthSummarySeen = true }
    }
    var healthAvailable: Bool { HealthExporter.isAvailable }
    var canTryDemo: Bool { accountsReady && connected.isEmpty && !isDemo }
    private(set) var libraryGeneration = UUID()
    private let realLibrary: ActivityLibrary
    private let demo: DemoLibrary
    /// Real FITs only; demo files stay out of the Files app.
    private let filesFolder: FilesFolder?
    var library: ActivityLibrary { isDemo ? demo.library : realLibrary }
    private let credentials: CredentialStore
    private let defaults: UserDefaults
    private let wahoo: WahooProbe
    private let zwift: ZwiftProbe
    private let mywhoosh: MyWhooshProbe
    private let hammerhead: HammerheadProbe
    private let signIn = WahooSignIn()
    private let health = HealthExporter()
    private let continued = ContinuedProcessing()
    private let healthAutoExportKey = "healthAutoExportSince"
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
    private let fullScanKey = "wahooLastFullScan"
    private let hammerheadScanKey = "hammerheadLastFullScan"
    private let fullScanInterval: TimeInterval = 7 * 24 * 3600
    private let wahooClientKey = "wahooClientID"
    private var cursorFile: URL { library.directory.appendingPathComponent("wahoo-catalog.json") }

    init(library: ActivityLibrary? = nil, filesFolder: URL? = nil, credentials: CredentialStore = CredentialStore(), defaults: UserDefaults = .standard,
         wahoo: WahooProbe = WahooProbe(), zwift: ZwiftProbe = ZwiftProbe(), mywhoosh: MyWhooshProbe = MyWhooshProbe(),
         hammerhead: HammerheadProbe = HammerheadProbe()) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let real = library ?? ActivityLibrary(directory: support.appendingPathComponent("FITgap", isDirectory: true))
        realLibrary = real
        // An injected library without an explicit folder never writes into the real Documents folder.
        let documents = library == nil ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] : nil
        self.filesFolder = (filesFolder ?? documents).map(FilesFolder.init)
        demo = DemoLibrary(realDirectory: real.directory)
        self.credentials = credentials; self.defaults = defaults
        self.wahoo = wahoo; self.zwift = zwift; self.mywhoosh = mywhoosh; self.hammerhead = hammerhead
        healthAutoExportSince = defaults.object(forKey: healthAutoExportKey) as? Date
        let requestedDemo = defaults.bool(forKey: "demoMode")
        do {
            // Determine local connection state without provider requests or token renewal.
            try readConnections(clearMismatchedCooldown: !requestedDemo)
            accountsReady = true
            isDemo = requestedDemo && connected.isEmpty
            if requestedDemo && !isDemo { defaults.set(false, forKey: "demoMode") }
        } catch { errorMessage = Self.message(error) }
        do {
            // Cached real FITs remain readable even when the Keychain is temporarily unavailable.
            activities = try isDemo ? demo.load() : real.load()
            // Observers do not run for assignments in the initializer.
            duplicates = DuplicateGroups(activities)
            storageReady = accountsReady
        } catch { errorMessage = Self.message(error) }
    }

    private func readConnections(clearMismatchedCooldown: Bool = false) throws {
        connected.removeAll()
        for source in Source.providers where try credentials.read(source) != nil {
            if source == .wahoo, defaults.string(forKey: wahooClientKey) != WahooOAuth.clientID {
                if clearMismatchedCooldown { defaults.removeObject(forKey: cooldownKey) }
                continue
            }
            connected.insert(source)
        }
    }

    func setDemo(_ enabled: Bool) async {
        guard !switchingMode, enabled != isDemo, !enabled || canTryDemo else { return }
        switchingMode = true
        defer { switchingMode = false }
        // Keep the old library selected until all in-flight writes and detached metric work finish.
        cancel()
        let previous = task
        await previous?.value
        let removal = enabled ? nil : await removeDemoWorkouts()
        do {
            let records = try enabled ? demo.load() : realLibrary.load()
            // No network work resumes automatically on leaving the demo.
            if !enabled { try readConnections(); accountsReady = true }
            activities = records
            libraryGeneration = UUID()
            isDemo = enabled
            defaults.set(enabled, forKey: "demoMode")
            storageReady = true
            errorMessage = removal; demoNotice = nil
            if !enabled { exportMissingFiles() }
        } catch {
            if !enabled {
                // Exiting remains possible even if the real index or Keychain is unavailable.
                // Leave those bytes intact and present the normal storage error outside demo mode.
                activities = []; connected.removeAll(); storageReady = false; accountsReady = false
                libraryGeneration = UUID()
                isDemo = false
                defaults.set(false, forKey: "demoMode")
                demoNotice = nil
            }
            errorMessage = Self.message(error)
        }
    }

    func resetDemo() {
        guard isDemo, !switchingMode, !busy else { return }
        // Only demo workouts saved to Apple Health make the reset wait; otherwise it completes right away.
        guard activities.contains(where: { $0.health != nil }) else { renewDemo(); return }
        switchingMode = true
        Task {
            defer { switchingMode = false }
            if let removal = await removeDemoWorkouts() { errorMessage = removal; return }
            renewDemo()
        }
    }

    private func renewDemo() {
        do {
            activities = try demo.reset()
            libraryGeneration = UUID()
            storageReady = true
            errorMessage = nil
            demoNotice = String(localized: "Demo zurückgesetzt. Nur Beispieldaten wurden erneuert.")
        } catch { errorMessage = Self.message(error) }
    }

    func fileForSharing(_ record: ActivityRecord) throws -> URL {
        guard !switchingMode, activities.contains(where: { $0.key == record.key && $0.status == .available }) else {
            throw LibraryError.integrity
        }
        return try isDemo ? demo.export(record) : library.verifiedFile(for: record)
    }

    func start() {
        guard !started else { return }
        started = true
        exportMissingFiles()
        refresh()
    }

    func refreshAndWait() async {
        refresh(userInitiated: true)
        await task?.value
    }

    func phaseChanged(_ phase: ScenePhase) {
        active = phase == .active
        guard !isDemo, !switchingMode else { return }
        if active {
            continueInterrupted()
            if let until = defaults.object(forKey: cooldownKey) as? Date, until <= Date(), !busy { refresh() }
        } else if phase == .background, resumeOnExpiration == nil, !continued.isRunning { task?.cancel() }
    }

    func connectZwift(username: String, password: String) {
        guard !isDemo, !switchingMode else { return }
        run(label: String(localized: "Zwift wird verbunden …")) {
            let token = try await self.zwift.connect(username: username, password: password)
            try Task.checkCancellation()
            try self.credentials.write(token, for: .zwift)
            self.connected.insert(.zwift)
        }
    }

    func connectMyWhoosh(username: String, password: String) {
        guard !isDemo, !switchingMode else { return }
        run(label: String(localized: "MyWhoosh wird verbunden …")) {
            let session = try await self.mywhoosh.authenticate(username: username, password: password)
            try Task.checkCancellation()
            try self.credentials.write(session.credentials, for: .mywhoosh)
            self.accessCache.removeValue(forKey: .mywhoosh)
            self.connected.insert(.mywhoosh)
        }
    }

    func connectWahoo() {
        guard !isDemo, !switchingMode else { return }
        run(label: String(localized: "Wahoo-Anmeldung …")) {
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

    /// Builds without a Hammerhead client secret (forks, CI) hide Hammerhead unless an account is still connected.
    var providers: [Source] {
        Source.providers.filter { $0 != .hammerhead || HammerheadSecret.isAvailable || connected.contains(.hammerhead) }
    }

    func connectHammerhead() {
        guard !isDemo, !switchingMode else { return }
        run(label: String(localized: "Hammerhead-Anmeldung …")) {
            guard HammerheadSecret.isAvailable else { throw HammerheadError.unavailable }
            let oauth = try HammerheadOAuth()
            let callback = try await self.signIn.login(oauth)
            try Task.checkCancellation()
            guard let secret = HammerheadSecret.value() else { throw HammerheadError.unavailable }
            let token = try await self.hammerhead.connect(oauth, callback: callback, secret: secret)
            try Task.checkCancellation()
            try self.credentials.write(token, for: .hammerhead)
            self.accessCache.removeValue(forKey: .hammerhead)
            self.defaults.removeObject(forKey: self.hammerheadScanKey)
            self.connected.insert(.hammerhead)
        }
    }

    func connectionStatus(_ source: Source) -> String {
        if isDemo { return String(localized: "Im Demo-Modus pausiert") }
        return connected.contains(source) ? String(localized: "Verbunden") : String(localized: "Nicht verbunden")
    }

    func disconnect(_ source: Source) {
        guard !isDemo, !switchingMode, !busy else { return }
        guard source == .hammerhead else {
            do { try credentials.remove(source); accessCache.removeValue(forKey: source); connected.remove(source) }
            catch { errorMessage = Self.message(error) }
            // Deliberately local: no server-side deauthorization that could delete provider data.
            return
        }
        // Hammerhead: also revoke the link, so its refresh token stops working. This deletes only what FITgap
        // imported into Hammerhead, which is nothing. The local session goes either way.
        run(label: String(localized: "Hammerhead wird getrennt …")) {
            var revoked = false
            if let secret = HammerheadSecret.value(), let account = try? await self.account(.hammerhead) {
                revoked = (try? await self.hammerhead.deauthorize(account, secret: secret)) != nil
            }
            try self.credentials.remove(.hammerhead)
            self.accessCache.removeValue(forKey: .hammerhead); self.connected.remove(.hammerhead)
            if !revoked {
                self.errorMessage = String(localized: "Lokal getrennt. Hammerhead hat den Widerruf nicht bestätigt. Du kannst FITgap im Hammerhead Dashboard unter Konten entfernen.")
            }
        }
    }

    /// `userInitiated` (pull to refresh) lets the sync continue in the background on iOS 26 with system progress.
    func refresh(userInitiated: Bool = false) {
        guard !switchingMode else { return }
        if isDemo {
            do {
                activities = try demo.library.load()
                demoNotice = String(localized: "Demo lokal aktualisiert. Keine Anbieteranfrage; gelöschte Dateien bleiben gelöscht.")
            } catch { errorMessage = Self.message(error) }
            return
        }
        guard !connected.isEmpty || activities.contains(where: \.needsMetrics) else { return }
        run(label: String(localized: "Aktivitäten werden abgerufen …"), resume: { [weak self] in self?.refresh() },
            continuedTitle: userInitiated ? String(localized: "FITgap-Abgleich") : nil) {
            try await self.fillMissingMetrics()
            var failures: [String] = []
            for source in Source.providers where self.connected.contains(source) {
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
            // After the provider import, at app start and on every refresh: new activities go to Health.
            // Without a granted write access the automatic export stays silent; manual exports report it.
            if let since = self.healthAutoExportSince, self.health.canWrite {
                try await self.exportHealth(self.visibleActivities.filter { self.isNewForHealth($0, since: since) }.map(\.key), priority: .utility)
            }
        }
    }

    /// New means started or downloaded after the automatic export was turned on, so late uploads are included.
    private func isNewForHealth(_ record: ActivityRecord, since: Date) -> Bool {
        guard record.health == nil, record.status == .available else { return false }
        return (record.date ?? .distantPast) >= since || (record.receipt?.checkedAt ?? .distantPast) >= since
    }

    func setHealthAutoExport(_ enabled: Bool) {
        guard !isDemo, !switchingMode else { return }
        if !enabled { healthAutoExportSince = nil; defaults.removeObject(forKey: healthAutoExportKey); return }
        run(label: String(localized: "Apple Health wird vorbereitet …")) {
            try await self.health.requestAuthorization()
            guard self.health.canWrite else { throw HealthExportError.notAuthorized }
            let now = Date()
            self.healthAutoExportSince = now
            self.defaults.set(now, forKey: self.healthAutoExportKey)
        }
    }

    /// Writes the given downloaded activities to Apple Health; already exported or duplicate ones are skipped.
    func exportToHealth(_ records: [ActivityRecord], resume: (@MainActor () -> Void)? = nil) {
        guard !switchingMode else { return }
        let keys = records.filter { $0.health == nil && $0.status == .available }.map(\.key)
        guard !keys.isEmpty else { return }
        run(label: String(localized: "Apple Health wird vorbereitet …"), resume: resume,
            continuedTitle: String(localized: "Export nach Apple Health"), allowsDemo: true) {
            try await self.health.requestAuthorization()
            guard self.health.canWrite else { throw HealthExportError.notAuthorized }
            try await self.exportHealth(keys)
        }
    }

    /// Writes an activity that was skipped because another app's workout overlaps it, at the user's explicit request.
    func exportToHealthDespiteOverlap(_ record: ActivityRecord) {
        guard !switchingMode, record.status == .available, record.health?.existingSource != nil,
              let index = activities.firstIndex(where: { $0.key == record.key }) else { return }
        let previous = activities[index].health
        activities[index].health = nil
        run(label: String(localized: "Apple Health wird vorbereitet …"), continuedTitle: String(localized: "Export nach Apple Health"),
            allowsDemo: true) {
            do {
                try await self.health.requestAuthorization()
                guard self.health.canWrite else { throw HealthExportError.notAuthorized }
                try await self.exportHealth([record.key], includeOverlaps: true)
            } catch {
                self.restoreHealth(previous, for: record.key)
                throw error
            }
            self.restoreHealth(previous, for: record.key)
        }
        if !busy { activities[index].health = previous }
    }

    /// Puts the earlier mark back when the forced export did not record a new result.
    private func restoreHealth(_ previous: HealthExport?, for key: ActivityKey) {
        guard let index = activities.firstIndex(where: { $0.key == key }), activities[index].health == nil else { return }
        activities[index].health = previous
        try? library.save(activities)
    }

    nonisolated static func healthSyncIdentifier(_ record: ActivityRecord) -> String {
        "org.fitgap.\(record.source.rawValue).\(record.remoteID)"
    }

    /// Demo workouts are synthetic, so they leave Apple Health with the demo: on reset and when it ends.
    /// Returns the error message when Health refused; the marks then stay, so the list keeps showing what is in Health.
    private func removeDemoWorkouts() async -> String? {
        guard isDemo, activities.contains(where: { $0.health != nil }) else { return nil }
        do { try await health.removeWorkouts(syncIdentifiers: activities.map(Self.healthSyncIdentifier)) }
        catch { return Self.message(error) }
        for index in activities.indices { activities[index].health = nil }
        try? library.save(activities)
        return nil
    }

    /// Downloaded activities not yet saved to or found in Apple Health.
    var healthPending: [ActivityRecord] { visibleActivities.filter { $0.health == nil && $0.status == .available } }

    /// Saves the whole history; uses iOS background time and continues after an interruption when the app opens again.
    func exportAllToHealth() {
        exportToHealth(healthPending, resume: { [weak self] in self?.exportAllToHealth() })
    }

    /// Activities written in parallel; HealthKit saves are mostly waiting time, so a few run side by side.
    private static let healthWorkers = 3
    /// Time spans claimed by this run, so two copies of one ride (e.g. from Wahoo and Zwift) running side by side
    /// are not both written before either is visible in Health.
    private var healthClaims: [DateInterval] = []

    private func claimHealthInterval(_ interval: DateInterval) -> Bool {
        guard !healthClaims.contains(where: { HealthExporter.sameWorkout(interval, $0) }) else { return false }
        healthClaims.append(interval)
        return true
    }

    private func releaseHealthInterval(_ interval: DateInterval) {
        if let index = healthClaims.firstIndex(of: interval) { healthClaims.remove(at: index) }
    }

    /// User-started exports run at `.userInitiated`; iOS throttles `.utility` heavily when the device is warm or busy.
    private func exportHealth(_ keys: [ActivityKey], includeOverlaps: Bool = false, priority: TaskPriority = .userInitiated) async throws {
        guard !keys.isEmpty else { return }
        var failure: Error?
        var summary = HealthExportSummary(total: keys.count)
        healthSummary = summary
        healthSummarySeen = false
        healthClaims = []
        defer { summary.finished = true; healthSummary = summary; healthClaims = []; healthInProgress = [] }
        progress = String(localized: "Apple Health: \(0) von \(keys.count)")
        continued.report(0, of: keys.count)
        let library = library, health = health
        typealias Result = (key: ActivityKey, sha256: String, name: String, outcome: Swift.Result<HealthExporter.Outcome, Error>)
        let jobs = keys.compactMap { key -> (record: ActivityRecord, sha256: String, name: String)? in
            guard let record = activities.first(where: { $0.key == key && $0.status == .available && $0.health == nil }),
                  let sha256 = record.receipt?.sha256 else { return nil }
            return (record, sha256, record.displayName)
        }
        summary.total = jobs.count
        try await withThrowingTaskGroup(of: Result?.self) { group in
            var pending = jobs[...]
            /// Starts the next job and returns its name, or `nil` when none is left.
            func addNext() -> String? {
                guard let (record, sha256, name) = pending.popFirst() else { return nil }
                let key = record.key
                group.addTask(priority: priority) {
                    var claim: DateInterval?
                    do {
                        let activity = try library.activity(for: record)
                        if !includeOverlaps, let start = activity.start, let end = activity.end, end > start {
                            let interval = DateInterval(start: start, end: end)
                            guard await self.claimHealthInterval(interval) else { return (key, sha256, name, .success(.existing("FITgap"))) }
                            claim = interval
                        }
                        let outcome = try await health.export(activity, syncIdentifier: Self.healthSyncIdentifier(record),
                                                              name: name, source: record.source.title, sha256: sha256,
                                                              includeOverlaps: includeOverlaps)
                        return (key, sha256, name, .success(outcome))
                    } catch {
                        if let claim { await self.releaseHealthInterval(claim) }
                        return (key, sha256, name, .failure(error))
                    }
                }
                return name
            }
            for _ in 0..<Self.healthWorkers { if let name = addNext() { healthInProgress.append(name) } }
            while let result = try await group.next() {
                guard let result else { continue }
                if let index = healthInProgress.firstIndex(of: result.name) { healthInProgress.remove(at: index) }
                switch result.outcome {
                case .failure(let error):
                    if error is CancellationError { throw CancellationError() }
                    if case HealthExportError.notAuthorized = error { throw error }
                    failure = failure ?? error
                    summary.failed += 1
                case .success(let outcome):
                    if let index = activities.firstIndex(where: { $0.key == result.key }), activities[index].receipt?.sha256 == result.sha256 {
                        switch outcome {
                        case .exported:
                            activities[index].health = HealthExport(date: Date(), sha256: result.sha256, existingSource: nil)
                            summary.saved += 1
                        case .existing(let name):
                            activities[index].health = HealthExport(date: Date(), sha256: nil, existingSource: name)
                            summary.skipped += 1
                        }
                        try library.save(activities)
                    }
                }
                healthSummary = summary
                progress = String(localized: "Apple Health: \(summary.done) von \(summary.total)") + "\n" + summary.counts
                continued.report(summary.done, of: summary.total)
                try Task.checkCancellation()
                if let name = addNext() { healthInProgress.append(name) }
            }
        }
        // Close the progress sheet first so the error alert can be presented.
        summary.finished = true
        healthSummary = summary
        if let failure { errorMessage = Self.message(failure) }
    }

    private func access(_ source: Source) async throws -> String {
        try await account(source).accessToken
    }

    private func account(_ source: Source) async throws -> Credentials {
        try Task.checkCancellation()
        guard !isDemo, !switchingMode, source != .demo else { throw CancellationError() }
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
            switch source {
            case .zwift: token = try await zwift.refresh(token)
            case .wahoo: token = try await wahoo.refresh(token)
            case .hammerhead:
                guard let secret = HammerheadSecret.value() else { throw HammerheadError.unavailable }
                token = try await hammerhead.refresh(token, secret: secret)
            // MyWhoosh has no known refresh route; an expired session needs a new sign-in.
            case .mywhoosh, .demo: throw AccountError.reconnect
            }
            try Task.checkCancellation()
            try credentials.write(token, for: source)
        }
        // Keep a running sync independent of repeated Keychain reads when the phone locks.
        // This memory-only cache is cleared when the operation ends; protection stays unchanged.
        accessCache[source] = token
        return token
    }

    private func sync(_ source: Source) async throws {
        progress = String(localized: "\(source.title): Aktivitäten werden abgerufen …")
        continued.report(0, of: -1)
        let credentials = try await account(source)
        let token = credentials.accessToken
        switch source {
        case .demo: throw CancellationError()
        case .mywhoosh:
            let session = try MyWhooshSession(credentials)
            let remote = try await mywhoosh.activities(session: session)
            try Task.checkCancellation()
            activities = ActivityLibrary.merging(remote.map(ActivityRecord.init), into: activities)
            try library.save(activities)
            let keys = pendingKeys
            let pending = remote.filter { keys.contains($0.key) }
            for (offset, activity) in pending.enumerated() {
                try Task.checkCancellation()
                progress = String(localized: "MyWhoosh: FIT \(offset + 1) von \(pending.count)")
                continued.report(offset, of: pending.count)
                do { try await commit(await mywhoosh.download(activity, session: session, store: library.files).0) }
                // MyWhoosh delivered no valid FIT: the row shows "no FIT available" and later syncs stop retrying it.
                // "Download" in the row still tries again; the rejected format is logged under category MyWhoosh.
                catch ProbeError.invalidFIT { try recordFailure(activity.key, error: ProbeError.noFIT) }
                catch { try recordFailure(activity.key, error: error); throw error }
            }
        case .zwift:
            let remote = try await zwift.activities(token: token)
            try Task.checkCancellation()
            activities = ActivityLibrary.merging(remote.map(ActivityRecord.init), into: activities)
            try library.save(activities)
            let keys = pendingKeys
            let pending = remote.filter { keys.contains($0.key) }
            for (offset, activity) in pending.enumerated() {
                try Task.checkCancellation()
                progress = String(localized: "Zwift: FIT \(offset + 1) von \(pending.count)")
                continued.report(offset, of: pending.count)
                do { try await commit(await zwift.download(activity, store: library.files)) }
                catch { try recordFailure(activity.key, error: error); throw error }
            }
        case .wahoo:
            wahooFiles.removeAll(keepingCapacity: true)
            let cursor = (try? JSONDecoder().decode(WahooCatalogCursor.self, from: Data(contentsOf: cursorFile))) ?? WahooCatalogCursor()
            // A full scan at least weekly also finds late uploads that sort behind the newest page.
            let lastFull = defaults.object(forKey: fullScanKey) as? Date
            let fullScan = lastFull.map { Date().timeIntervalSince($0) > fullScanInterval || $0 > Date() } ?? true
            let known = fullScan ? [] : Set(activities.filter { $0.source == .wahoo }.map(\.key))
            try await wahoo.catalog(token: token, cursor: cursor, known: known) { page, next in
                try await self.saveWahooPage(page, cursor: next)
            }
            if fullScan { defaults.set(Date(), forKey: fullScanKey) }
            let pending = activities.filter { $0.source == .wahoo && [.pending, .failed].contains($0.status) }
            for (offset, record) in pending.enumerated() {
                try Task.checkCancellation()
                progress = String(localized: "Wahoo: FIT \(offset + 1) von \(pending.count)")
                continued.report(offset, of: pending.count)
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
        case .hammerhead:
            // Weekly full scan; in between only rides from two days before the newest known one.
            let known = activities.filter { $0.source == .hammerhead }
            let lastFull = defaults.object(forKey: hammerheadScanKey) as? Date
            let fullScan = known.isEmpty || lastFull.map { Date().timeIntervalSince($0) > fullScanInterval || $0 > Date() } ?? true
            let since = fullScan ? nil : known.compactMap(\.date).max()?.addingTimeInterval(-2 * 24 * 3600)
            let remote = try await hammerhead.activities(token: token, since: since)
            try Task.checkCancellation()
            activities = ActivityLibrary.merging(remote.map(ActivityRecord.init), into: activities)
            try library.save(activities)
            if fullScan { defaults.set(Date(), forKey: hammerheadScanKey) }
            let pending = activities.filter { $0.source == .hammerhead && [.pending, .failed].contains($0.status) }
            for (offset, record) in pending.enumerated() {
                try Task.checkCancellation()
                progress = String(localized: "Hammerhead: FIT \(offset + 1) von \(pending.count)")
                continued.report(offset, of: pending.count)
                do { try await commit(await hammerhead.download(id: record.remoteID, token: try await access(.hammerhead), store: library.files)) }
                catch ProbeError.noFIT { try recordFailure(record.key, error: ProbeError.noFIT) }
                catch { try recordFailure(record.key, error: error); throw error }
            }
        }
    }

    private func saveWahooPage(_ page: WahooPage, cursor: WahooCatalogCursor) throws {
        try Task.checkCancellation()
        activities = ActivityLibrary.merging(page.workouts.map(ActivityRecord.init), into: activities)
        try library.save(activities)
        // Save the cursor after the index: repeating a page is safe if either write is interrupted.
        try JSONEncoder().encode(cursor).write(to: cursorFile, options: .atomic)
        for workout in page.workouts { wahooFiles[workout.key] = workout }
    }

    private var pendingKeys: Set<ActivityKey> {
        Set(activities.filter { [.pending, .failed].contains($0.status) }.map(\.key))
    }

    private func fillMissingMetrics() async throws {
        let missing = activities.filter(\.needsMetrics)
        guard !missing.isEmpty else { return }
        let indices = Dictionary(uniqueKeysWithValues: activities.enumerated().map { ($0.element.key, $0.offset) })
        for start in stride(from: 0, to: missing.count, by: 10) {
            try Task.checkCancellation()
            progress = String(localized: "Kennzahlen: \(start) von \(missing.count)")
            continued.report(start, of: missing.count)
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
            progress = String(localized: "Kennzahlen: \(end) von \(missing.count)")
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
            if !isDemo, let filesFolder, activities[index].filesName == nil,
               let exported = try? filesFolder.export(activities[index], from: library) { activities[index] = exported }
            try library.save(activities)
        }
    }

    private func recordFailure(_ key: ActivityKey, error: Error) throws {
        guard !Task.isCancelled, !(error is CancellationError), let index = activities.firstIndex(where: { $0.key == key }) else { return }
        if case ProbeError.noFIT = error { activities[index].status = .unavailable; activities[index].noFITConfirmed = true }
        else { activities[index].status = .failed }
        try library.save(activities)
    }

    func download(_ record: ActivityRecord) {
        guard !switchingMode, !busy, activities.contains(where: { $0.key == record.key }) else { return }
        if isDemo {
            do {
                guard let index = activities.firstIndex(where: { $0.key == record.key }) else { return }
                activities[index] = try demo.restoring(record)
                try library.save(activities)
                demoNotice = String(localized: "Demo-Datei lokal wiederhergestellt.")
            } catch { errorMessage = Self.message(error) }
            return
        }
        guard record.source != .demo else { return }
        run(label: String(localized: "\(record.source.title): FIT wird geladen …"), resume: { [weak self] in self?.download(record) },
            continuedTitle: String(localized: "FITgap-Abgleich")) {
            let credentials = try await self.account(record.source)
            do {
                let receipt: FITReceipt
                switch record.source {
                case .zwift:
                    receipt = try await self.zwift.download(id: record.remoteID, token: credentials.accessToken, store: self.library.files)
                case .wahoo:
                    receipt = try await self.wahoo.download(id: record.remoteID, token: credentials.accessToken, store: self.library.files)
                case .mywhoosh:
                    receipt = try await self.mywhoosh.download(id: record.remoteID, session: MyWhooshSession(credentials), store: self.library.files)
                case .hammerhead:
                    receipt = try await self.hammerhead.download(id: record.remoteID, token: credentials.accessToken, store: self.library.files)
                case .demo: throw CancellationError()
                }
                try await self.commit(receipt)
            } catch { try self.recordFailure(record.key, error: error); throw error }
        }
    }

    func deleteFile(_ record: ActivityRecord) {
        guard !switchingMode, !busy else { return }
        do {
            guard let index = activities.firstIndex(where: { $0.key == record.key }) else { return }
            if isDemo { try demo.removeExport(record) }
            else if let filesFolder { activities[index] = try filesFolder.remove(activities[index]) }
            activities[index] = try library.deletingFile(for: activities[index])
            try library.save(activities)
        } catch { errorMessage = Self.message(error) }
    }

    /// One-time copy of downloads from before the Files folder existed; later downloads are copied in `commit`.
    private func exportMissingFiles() {
        guard !isDemo, storageReady, let filesFolder else { return }
        let missing = activities.filter { $0.status == .available && $0.filesName == nil }
        guard !missing.isEmpty else { return }
        let generation = libraryGeneration
        Task {
            // Checksums are verified off the main actor before each copy.
            let exported = await Task.detached(priority: .utility) { [library] in
                missing.compactMap { try? filesFolder.export($0, from: library) }
            }.value
            guard !isDemo, !switchingMode, generation == libraryGeneration else { return }
            var changed = false
            for record in exported {
                guard let index = activities.firstIndex(where: { $0.key == record.key }),
                      activities[index].status == .available, activities[index].filesName == nil,
                      activities[index].receipt?.sha256 == record.receipt?.sha256 else { continue }
                activities[index].filesName = record.filesName
                changed = true
            }
            guard changed else { return }
            do { try library.save(activities) } catch { errorMessage = Self.message(error) }
        }
    }

    func markShared(_ record: ActivityRecord, generation: UUID? = nil) {
        markShared([record], generation: generation)
    }

    /// Marks every handed-off file at once and saves the index a single time.
    func markShared(_ records: [ActivityRecord], generation: UUID? = nil) {
        guard !switchingMode, generation == nil || generation == libraryGeneration else { return }
        let now = Date()
        var changed = false
        for record in records {
            guard let index = activities.firstIndex(where: { $0.key == record.key }),
                  activities[index].status == .available,
                  activities[index].receipt?.sha256 == record.receipt?.sha256 else { continue }
            activities[index].sharedAt = now
            changed = true
        }
        guard changed else { return }
        do { try library.save(activities) } catch { errorMessage = Self.message(error) }
    }

    func cancel() { manuallyCancelled = true; interrupted = nil; retryTask?.cancel(); task?.cancel() }

    /// `continuedTitle` marks work the user started explicitly; on iOS 26 it may continue in the background with system progress.
    /// `allowsDemo` is only for the Apple Health export, so App Review can try HealthKit with the sample rides.
    func run(label: String, resume: (@MainActor () -> Void)? = nil, continuedTitle: String? = nil, allowsDemo: Bool = false,
             operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, storageReady, !switchingMode, !isDemo || allowsDemo else { return }
        retryTask?.cancel()
        manuallyCancelled = false
        busy = true; progress = label; errorMessage = nil
        resumeOnExpiration = resume
        if resume != nil {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FITgap-Sync") { [weak self] in
                Task { @MainActor in
                    // Work that iOS continues with system progress only gives up the short background time.
                    if self?.continued.isRunning == true { self?.endBackgroundTask() } else { self?.backgroundTimeExpired() }
                }
            }
        }
        if let continuedTitle {
            continued.begin(title: continuedTitle, subtitle: label) { [weak self] in self?.backgroundTimeExpired() }
        }
        task = Task {
            defer {
                continued.finish(success: !Task.isCancelled && errorMessage == nil)
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
        guard !isDemo, !switchingMode, active, !busy, let action = interrupted else { return false }
        interrupted = nil
        action()
        return true
    }

    private func scheduleRetry() {
        guard !isDemo, !switchingMode, connected.contains(.wahoo), let until = defaults.object(forKey: cooldownKey) as? Date, until > Date() else { return }
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
        if let error = error as? HammerheadError { return error.localizedDescription }
        if let error = error as? WahooRateLimit { return error.localizedDescription }
        if let error = error as? LibraryError { return error.localizedDescription }
        if let error = error as? HealthExportError { return error.localizedDescription }
        if error is FITActivity.ReadError { return String(localized: "Die FIT-Datei enthält keine lesbare Aktivität für Apple Health.") }
        if error is HKError { return String(localized: "Apple Health hat das Speichern abgelehnt. Bitte später erneut versuchen.") }
        if let error = error as? URLError {
            if error.code == .cancelled { return String(localized: "Abruf abgebrochen. Bereits gespeicherte FITs bleiben verfügbar.") }
            return String(localized: "Netzwerk nicht erreichbar oder Anfrage fehlgeschlagen. Bitte später erneut versuchen.")
        }
        return String(localized: "Lokale Daten konnten nicht gelesen oder gespeichert werden. Vorhandene Dateien bleiben erhalten.")
    }
}

struct HealthExportSummary: Equatable {
    var total: Int
    var saved = 0
    /// Already present in Apple Health, from FITgap or another app.
    var skipped = 0
    var failed = 0
    var finished = false
    var done: Int { saved + skipped + failed }

    var counts: String {
        var parts = [String(localized: "\(saved) gesichert"), String(localized: "\(skipped) als Dublette übersprungen")]
        if failed > 0 { parts.append(String(localized: "\(failed) fehlgeschlagen")) }
        return parts.joined(separator: " · ")
    }
}
