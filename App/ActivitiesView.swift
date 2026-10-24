import FITgapCore
import SwiftUI
import UIKit

/// iOS 26 shows the search field as a toolbar icon that expands on tap.
private struct MinimizedSearch: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.searchToolbarBehavior(.minimize) } else { content }
    }
}

/// Account button and search icon; shown in the list column when compact, in the details column when side by side.
private struct ChromeToolbar: ViewModifier {
    let show: Bool
    let accounts: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if show {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Konten", systemImage: "person.crop.circle", action: accounts)
                }
                if #available(iOS 26, *) { DefaultToolbarItem(kind: .search, placement: .topBarTrailing) }
            }
        } else { content }
    }
}

struct ActivitiesView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var accounts = false
    @State private var deleteCandidate: ActivityRecord?
    @State private var share: SharedFiles?
    @State private var showError = false
    @State private var limit = Self.pageSize
    @State private var showJump = false
    @State private var selected: ActivityKey?
    @State private var editMode = EditMode.inactive
    @State private var picked = Set<ActivityKey>()
    @State private var sharedSelection = false
    @State private var healthDetails = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.all

    private static let pageSize = 10
    private var wide: Bool { sizeClass == .regular }

    private var matches: [ActivityRecord] {
        model.activities.filter { search.isEmpty || $0.displayName.localizedStandardContains(search) || $0.source.title.localizedStandardContains(search) }
    }

    private static let jumpThreshold = 6

    private var selecting: Bool { editMode.isEditing }
    /// Downloaded files in the current search; only these can be picked for sharing.
    private var pickable: [ActivityRecord] { matches.filter { $0.status == .available } }

    /// Outside selection mode the list keeps its single selection that drives the details column.
    private var listSelection: Binding<Set<ActivityKey>> {
        Binding(get: { selecting ? picked : Set([selected].compactMap { $0 }) },
                set: { if selecting { picked = $0 } else { selected = $0.first } })
    }

    var body: some View {
        // Compact widths collapse to a single stack; wide screens (e.g. an unfolded iPhone Duo) show list and details side by side.
        // The system sizes the columns and adapts them to the fold, so no column width is set.
        NavigationSplitView(columnVisibility: $columns) {
            ScrollViewReader { proxy in
            List(selection: listSelection) {
                DemoSection(model: model)
                if model.activities.isEmpty {
                    Section {
                        ContentUnavailableView("Noch keine Aktivitäten", systemImage: "figure.outdoor.cycle",
                            description: Text("Verbinde unter „Konten“ Wahoo, Zwift oder MyWhoosh und ziehe die Liste nach unten."))
                    }
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                let all = matches
                let visible = Array(all.prefix(limit))
                Section {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, activity in
                        // Row buttons stay borderless and keep their own taps; the rest of the row opens the details.
                        NavigationLink(value: activity.key) {
                            ActivityRow(activity: activity, connected: model.isDemo || model.connected.contains(activity.source), busy: model.busy || model.switchingMode,
                                        share: { prepareShare(activity) }, download: { model.download(activity) })
                        }
                        .accessibilityIdentifier("activity-\(activity.source.rawValue)-\(activity.remoteID)")
                        .selectionDisabled(selecting && activity.status != .available)
                        .onAppear {
                            if index >= Self.jumpThreshold { showJump = true } else if index == 0 { showJump = false }
                            if activity.id == visible.last?.id, visible.count < all.count { limit += Self.pageSize }
                        }
                        .swipeActions(edge: .leading) {
                            if model.healthAvailable && !model.isDemo && activity.status == .available && activity.health == nil {
                                Button("In Health sichern", systemImage: "heart") { model.exportToHealth([activity]) }
                                    .tint(.pink)
                                    .disabled(model.busy || model.switchingMode)
                                    .accessibilityIdentifier("health-swipe-\(activity.source.rawValue)-\(activity.remoteID)")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if activity.receipt != nil || activity.status == .failed {
                                Button("Datei löschen", systemImage: "trash", role: .destructive) { deleteCandidate = activity }
                                    .disabled(model.busy || model.switchingMode)
                                    .accessibilityIdentifier("delete-\(activity.source.rawValue)-\(activity.remoteID)")
                            }
                        }
                    }
                } footer: {
                    if model.isDemo {
                        Text("Demo-Dateien bleiben offline verfügbar. Aktualisieren liest nur den lokalen Demo-Bestand. Gelöschte Dateien lassen sich lokal wiederherstellen. Beim Teilen HealthFit wählen, sofern installiert. „Geteilt“ bestätigt nur die Dateiübergabe, keinen Import und keine Anbieteranbindung.")
                    } else { Text("FITs bleiben offline verfügbar. Aktualisieren startet beim App-Start oder durch Herunterziehen. Ein laufender Abruf nutzt die verfügbare iOS-Hintergrundzeit und wird nach einer Unterbrechung beim Öffnen fortgesetzt. Wähle beim Teilen HealthFit, sofern installiert. „Geteilt“ bestätigt keinen erfolgreichen Import.") }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showJump, let first = matches.first {
                    Button {
                        withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                    } label: {
                        Image(systemName: "arrow.up").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .padding(.trailing, 16).padding(.bottom, model.busy ? 72 : 16)
                    .accessibilityLabel("Nach oben")
                    .accessibilityIdentifier("scroll-to-top")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.default, value: showJump)
            .transaction(value: search) { $0.animation = nil }
            .refreshable { await model.refreshAndWait() }
            .environment(\.editMode, $editMode)
            .navigationTitle(selecting ? String(localized: "\(picked.count) ausgewählt") : "FITgap")
            .modifier(ChromeToolbar(show: !wide) { accounts = true })
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig", systemImage: "checkmark") { endSelection() }
                            .accessibilityIdentifier("select-done")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        let all = Set(pickable.map(\.key))
                        if !all.isEmpty && all.isSubset(of: picked) {
                            Button("Auswahl aufheben", systemImage: "circle") { picked.removeAll() }
                                .accessibilityIdentifier("select-none")
                        } else {
                            Button("Alle auswählen", systemImage: "checkmark.circle.badge.plus") { picked.formUnion(all) }
                                .disabled(all.isEmpty)
                                .accessibilityIdentifier("select-all")
                        }
                        Button("Teilen", systemImage: "square.and.arrow.up", action: prepareSelectionShare)
                            .disabled(picked.isEmpty || model.busy || model.switchingMode)
                            .accessibilityValue(Text("\(picked.count) ausgewählt"))
                            .accessibilityIdentifier("share-selected")
                        if model.healthAvailable && !model.isDemo {
                            Button("In Health sichern", systemImage: "heart", action: exportSelectionToHealth)
                                .disabled(picked.isEmpty || model.busy || model.switchingMode)
                                .accessibilityIdentifier("health-export-selected")
                        }
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Auswählen", systemImage: "checkmark.circle") { picked.removeAll(); withAnimation { editMode = .active } }
                            .disabled(model.activities.allSatisfy { $0.status != .available } || model.switchingMode)
                            .accessibilityIdentifier("select-start")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { DemoIndicator(enabled: model.isDemo) }
            .overlay(alignment: .bottom) {
                // One progress for the whole run: provider import, then the Apple Health export.
                if model.busy {
                    SyncProgressCapsule(model: model) { healthDetails = true }
                        .padding(.bottom, 8).padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.busy)
            .onChange(of: search) { _, _ in limit = Self.pageSize; showJump = false }
            .onChange(of: model.libraryGeneration) { _, _ in search = ""; limit = Self.pageSize; deleteCandidate = nil; share = nil; selected = nil; endSelection() }
            .sheet(isPresented: $accounts) { AccountsView(model: model) }
            .modifier(HealthExportStatus(model: model, showsProgress: false, details: $healthDetails))
            // Selection mode ends once the share sheet is gone, whether the handoff finished or was cancelled.
            .sheet(item: $share, onDismiss: { if sharedSelection { sharedSelection = false; endSelection() } }) { item in
                ShareSheet(urls: item.urls) { completed in
                    if completed { model.markShared(item.records, generation: item.generation) }
                }
            }
            }
        } detail: {
            Group {
            if let selected, let activity = model.activities.first(where: { $0.key == selected }) {
                ActivityDetailView(model: model, initial: activity)
            } else {
                ContentUnavailableView("Aktivität auswählen", systemImage: "figure.outdoor.cycle",
                    description: Text("Wähle links eine Aktivität, um ihre Details zu sehen."))
            }
            }
            .modifier(ChromeToolbar(show: wide) { accounts = true })
        }
        // Side by side, account and search sit in the details navigation area on the right.
        .searchable(text: $search, prompt: "Aktivitäten suchen")
        .modifier(MinimizedSearch())
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.errorMessage, initial: true) { _, message in showError = message != nil && !accounts }
            .onChange(of: accounts) { _, shown in showError = !shown && model.errorMessage != nil }
            .alert("FITgap", isPresented: $showError) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .confirmationDialog("Lokale FIT löschen?", isPresented: Binding(get: { deleteCandidate != nil },
                                set: { if !$0 { deleteCandidate = nil } }), titleVisibility: .visible) {
                Button("Datei löschen", role: .destructive) {
                    if let record = deleteCandidate { model.deleteFile(record) }
                    deleteCandidate = nil
                }
                Button("Abbrechen", role: .cancel) { deleteCandidate = nil }
            } message: {
                if model.isDemo { Text("Nur diese lokale Demo-Datei und ihre Teilen-Markierung werden gelöscht. Mit „Wiederherstellen“ erhältst du die Beispieldatei lokal zurück.") }
                else { Text("Die Datei wird nur auf diesem iPhone gelöscht. Die Aktivität beim Anbieter bleibt erhalten. Du kannst die Datei später über „Erneut laden“ herunterladen.") }
            }
    }

    private func prepareShare(_ activity: ActivityRecord) {
        do { share = SharedFiles(records: [activity], urls: [try model.fileForSharing(activity)], generation: model.libraryGeneration) }
        catch { model.errorMessage = AppModel.message(error) }
    }

    private func exportSelectionToHealth() {
        model.exportToHealth(model.activities.filter { picked.contains($0.key) })
        endSelection()
    }

    private func endSelection() {
        picked.removeAll()
        withAnimation { editMode = .inactive }
    }

    /// Hands the picked files to one share sheet; files that fail verification stay unshared and visible in the list.
    private func prepareSelectionShare() {
        var records: [ActivityRecord] = [], urls: [URL] = [], failure: Error?
        for activity in model.activities where picked.contains(activity.key) && activity.status == .available {
            do { urls.append(try model.fileForSharing(activity)); records.append(activity) }
            catch { failure = failure ?? error }
        }
        if records.isEmpty { if let failure { model.errorMessage = AppModel.message(failure) }; return }
        sharedSelection = true
        share = SharedFiles(records: records, urls: urls, generation: model.libraryGeneration)
    }
}

private struct ActivityRow: View {
    let activity: ActivityRecord
    let connected: Bool
    let busy: Bool
    let share: () -> Void
    let download: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(activity.source.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(activityName).font(.headline)
            if let date = activity.date { Text(date, format: .dateTime.day().month(.abbreviated).year().hour().minute()).font(.subheadline) }
            else { Text("Datum unbekannt").font(.subheadline) }
            Text("Dauer: \(duration)").font(.subheadline).foregroundStyle(.secondary)
            Text("\(distance) · ↑ \(ascent) · Ø \(averageSpeed)")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Strecke: \(distance), Höhenmeter: \(ascent), Durchschnittsgeschwindigkeit: \(averageSpeed)")
            if activity.status != .available {
                Label(activity.status.title, systemImage: "arrow.down.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let date = activity.sharedAt {
                HStack(spacing: 6) {
                    Text("Zuletzt geteilt: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "checkmark.circle")
                        .font(.caption).foregroundStyle(.tint)
                        .accessibilityLabel("Geteilt")
                        .accessibilityIdentifier("shared-status-\(activity.source.rawValue)-\(activity.remoteID)")
                }
            }
            if activity.health != nil {
                // Saved by FITgap or already present from another app: either way the workout is in Health.
                Label("In Health gespeichert", systemImage: "heart.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("health-status-\(activity.source.rawValue)-\(activity.remoteID)")
            }
            HStack {
                if activity.status == .available {
                    Button("Teilen", systemImage: "square.and.arrow.up", action: share)
                        .accessibilityIdentifier("share-\(activity.source.rawValue)-\(activity.remoteID)")
                        .frame(minHeight: 44).disabled(busy)
                } else if connected {
                    Button(activity.source == .demo ? String(localized: "Wiederherstellen") : (activity.status == .deleted ? String(localized: "Erneut laden") : String(localized: "Laden")), systemImage: "arrow.down", action: download)
                        .frame(minHeight: 44).disabled(busy)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var activityName: String {
        activity.displayName
    }

    private var duration: String {
        guard let seconds = activity.duration, seconds.isFinite, seconds >= 0 else { return String(localized: "unbekannt") }
        return Self.durationFormatter.string(from: seconds) ?? String(localized: "unbekannt")
    }

    private var distance: String { ActivityFormat.distance(activity.metrics?.distanceMeters) ?? "— km" }
    private var ascent: String { activity.metrics?.ascentMeters.map(ActivityFormat.meters) ?? "— m" }
    private var averageSpeed: String { ActivityFormat.speed(activity.metrics?.averageSpeedMetersPerSecond) ?? "— km/h" }
}

private struct SharedFiles: Identifiable {
    let id = UUID()
    let records: [ActivityRecord]
    let urls: [URL]
    let generation: UUID
}

private struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in completion(completed) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
