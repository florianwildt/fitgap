import FITgapCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var filter = ActivityFilter()
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
    @State private var importing = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.all

    private static let pageSize = 10
    private var wide: Bool { sizeClass == .regular }

    private var matches: [ActivityRecord] {
        model.visibleActivities.filter { activity in
            filter.matches(activity, now: .now)
                && (search.isEmpty || activity.displayName.localizedStandardContains(search) || activity.source.title.localizedStandardContains(search))
        }
    }

    /// Sources that appear in the list, in the order the accounts are listed.
    private var listedSources: [Source] {
        let present = Set(model.visibleActivities.map(\.source))
        return Source.allCases.filter(present.contains)
    }

    /// Activity types read from downloaded FITs; files not yet downloaded have no type yet.
    private var listedKinds: [ActivityKind] {
        let present = Set(model.visibleActivities.compactMap { ActivityKind($0.metrics) })
        return ActivityKind.allCases.filter(present.contains)
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
                            description: Text("Verbinde unter „Konten“ eine Datenquelle und ziehe die Liste nach unten – oder importiere eine FIT-Datei."))
                    }
                } else if matches.isEmpty {
                    if filter.isActive, search.isEmpty {
                        ContentUnavailableView {
                            Label("Keine passenden Aktivitäten", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("Für die gewählten Filter gibt es keine Aktivitäten.")
                        } actions: {
                            Button("Filter zurücksetzen") { filter = ActivityFilter() }
                        }
                    } else { ContentUnavailableView.search(text: search) }
                }
                let all = matches
                let visible = Array(all.prefix(limit))
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, activity in
                    // Each activity is its own inset card, like workouts in HealthFit or Fitness.
                    Section {
                        // Row buttons stay borderless and keep their own taps; the rest of the row opens the details.
                        ActivityRow(activity: activity, library: model.library, urgent: index < 3, connected: model.isDemo || model.connected.contains(activity.source), busy: model.busy || model.switchingMode,
                                    share: { prepareShare(activity) }, download: { model.download(activity) })
                        // The tag drives the list selection that opens the details; unlike a NavigationLink it shows no chevron.
                        .tag(activity.key)
                        .accessibilityIdentifier("activity-\(activity.source.rawValue)-\(activity.remoteID)")
                        .selectionDisabled(selecting && activity.status != .available)
                        .onAppear {
                            if index >= Self.jumpThreshold { showJump = true } else if index == 0 { showJump = false }
                            if activity.id == visible.last?.id, visible.count < all.count { limit += Self.pageSize }
                        }
                        .swipeActions(edge: .leading) {
                            if model.healthAvailable && activity.status == .available && activity.health == nil {
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
                }
                Section {
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
            .listSectionSpacing(.compact)
            .animation(.default, value: showJump)
            .transaction(value: search) { $0.animation = nil }
            .transaction(value: filter) { $0.animation = nil }
            .refreshable { await model.refreshAndWait() }
            .environment(\.editMode, $editMode)
            .navigationTitle(selecting ? String(localized: "\(picked.count) ausgewählt") : "FITgap")            .modifier(ChromeToolbar(show: !wide) { accounts = true })
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
                        if model.healthAvailable {
                            Button("In Health sichern", systemImage: "heart", action: exportSelectionToHealth)
                                .disabled(picked.isEmpty || model.busy || model.switchingMode)
                                .accessibilityIdentifier("health-export-selected")
                        }
                    }
                } else if wide {
                    // The sidebar column is narrow side by side, so the actions share one menu and the title keeps its room.
                    if #available(iOS 27, *) {
                        ToolbarOverflowMenu { listActions }
                    } else {
                        ToolbarItem(placement: .primaryAction) {
                            Menu { listActions } label: {
                                Label("Mehr", systemImage: filter.isActive ? "ellipsis.circle.fill" : "ellipsis.circle")
                            }
                            .accessibilityIdentifier("list-actions")
                        }
                    }
                } else {
                    if !model.visibleActivities.isEmpty {
                        ToolbarItem(placement: .primaryAction) { filterMenu }
                    }
                    ToolbarItem(placement: .primaryAction) { importButton }
                    ToolbarItem(placement: .primaryAction) { selectButton }
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
            .onChange(of: filter) { _, _ in limit = Self.pageSize; showJump = false }
            .onChange(of: model.libraryGeneration) { _, _ in search = ""; filter = ActivityFilter(); limit = Self.pageSize; deleteCandidate = nil; share = nil; selected = nil; endSelection() }
            .sheet(isPresented: $accounts) { AccountsView(model: model) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.fit], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): model.importFiles(urls)
                case .failure(let error): model.errorMessage = AppModel.message(error)
                }
            }
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
                if deleteCandidate?.source == .imported { Text("Die importierte Datei wird aus FITgap gelöscht. Das Original in der Dateien-App bleibt erhalten, und du kannst es jederzeit erneut importieren.") }
                else if model.isDemo { Text("Nur diese lokale Demo-Datei und ihre Teilen-Markierung werden gelöscht. Mit „Wiederherstellen“ erhältst du die Beispieldatei lokal zurück.") }
                else { Text("Die Datei wird nur auf diesem iPhone gelöscht. Die Aktivität beim Anbieter bleibt erhalten. Du kannst die Datei später über „Erneut laden“ herunterladen.") }
            }
    }

    private var filterMenu: some View {
        Menu {
            // Each picker opens as a submenu that shows its current choice.
            Picker("Zeitraum", systemImage: "calendar", selection: $filter.period) {
                Text("Gesamter Zeitraum").tag(ActivityFilter.Period?.none)
                ForEach(ActivityFilter.Period.allCases) { period in Text(period.title).tag(Optional(period)) }
            }
            .pickerStyle(.menu)
            if listedKinds.count > 1 || filter.kind != nil {
                Picker("Aktivitätstyp", systemImage: "figure.mixed.cardio", selection: $filter.kind) {
                    Text("Alle Typen").tag(ActivityKind?.none)
                    ForEach(listedKinds) { kind in Text(kind.title).tag(Optional(kind)) }
                }
                .pickerStyle(.menu)
            }
            if listedSources.count > 1 || filter.source != nil {
                Picker("Datenquelle", systemImage: "tray.full", selection: $filter.source) {
                    Text("Alle Quellen").tag(Source?.none)
                    ForEach(listedSources) { source in Text(source.title).tag(Optional(source)) }
                }
                .pickerStyle(.menu)
            }
            if filter.isActive {
                Section {
                    Button("Filter zurücksetzen", systemImage: "xmark.circle") { filter = ActivityFilter() }
                }
            }
        } label: {
            Label("Filtern", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityValue(filter.summary)
        .accessibilityIdentifier("activity-filter")
    }

    private var importButton: some View {
        Button("FIT importieren", systemImage: "square.and.arrow.down") { importing = true }
            .disabled(model.isDemo || !model.storageReady || model.switchingMode)
            .accessibilityIdentifier("import-fit")
    }

    private var selectButton: some View {
        Button("Auswählen", systemImage: "checkmark.circle") { picked.removeAll(); withAnimation { editMode = .active } }
            .disabled(model.activities.allSatisfy { $0.status != .available } || model.switchingMode)
            .accessibilityIdentifier("select-start")
    }

    /// Filter, import and selection in one menu, for the narrow sidebar column.
    @ViewBuilder private var listActions: some View {
        if !model.visibleActivities.isEmpty { filterMenu }
        importButton
        selectButton
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
    let library: ActivityLibrary
    let urgent: Bool
    let connected: Bool
    let busy: Bool
    let share: () -> Void
    let download: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(activityName).font(.headline)
                Spacer(minLength: 0)
                status
            }
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            Text("\(distance) · \(duration) · ↑ \(ascent)")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Strecke: \(distance), Dauer: \(duration), Höhenmeter: \(ascent)")
            if activity.status != .available {
                HStack {
                    Label(activity.status.title, systemImage: "arrow.down.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if connected {
                        Button(activity.source == .demo ? String(localized: "Wiederherstellen") : (activity.status == .deleted ? String(localized: "Erneut laden") : String(localized: "Laden")), systemImage: "arrow.down", action: download)
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44).disabled(busy)
                    }
                }
            }
            if RouteThumbnail.hasRoute(activity) {
                RouteThumbnail(activity: activity, library: library, urgent: urgent).padding(.top, 8)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// Shared and Health marks as small symbols, then the share button; the details list the dates.
    private var status: some View {
        HStack(spacing: 12) {
            if activity.sharedAt != nil {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Geteilt")
                    .accessibilityIdentifier("shared-status-\(activity.source.rawValue)-\(activity.remoteID)")
            }
            if activity.health != nil {
                // Saved by FITgap or already present from another app: either way the workout is in Health.
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .accessibilityLabel("In Health gespeichert")
                    .accessibilityIdentifier("health-status-\(activity.source.rawValue)-\(activity.remoteID)")
            }
            if activity.status == .available {
                Button("Teilen", systemImage: "square.and.arrow.up", action: share)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("share-\(activity.source.rawValue)-\(activity.remoteID)")
                    .disabled(busy)
            }
        }
        .font(.subheadline)
    }

    private var subtitle: String {
        let date = activity.date?.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()) ?? String(localized: "Datum unbekannt")
        return "\(date) · \(activity.source.title)"
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

/// Narrows the list by time, activity type and data source; an unset criterion lets every activity through.
struct ActivityFilter: Equatable {
    enum Period: String, CaseIterable, Identifiable {
        case week, month, twelveMonths, thisYear, lastYear
        var id: String { rawValue }
        var title: String {
            switch self {
            case .week: String(localized: "Letzte 7 Tage")
            case .month: String(localized: "Letzte 30 Tage")
            case .twelveMonths: String(localized: "Letzte 12 Monate")
            case .thisYear: String(localized: "Dieses Jahr")
            case .lastYear: String(localized: "Letztes Jahr")
            }
        }

        func contains(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
            let today = calendar.startOfDay(for: now)
            let year = calendar.dateInterval(of: .year, for: now)!
            switch self {
            case .week: return date >= calendar.date(byAdding: .day, value: -6, to: today)!
            case .month: return date >= calendar.date(byAdding: .day, value: -29, to: today)!
            case .twelveMonths: return date >= calendar.date(byAdding: .month, value: -12, to: today)!
            case .thisYear: return year.contains(date)
            case .lastYear: return calendar.dateInterval(of: .year, for: calendar.date(byAdding: .year, value: -1, to: now)!)!.contains(date)
            }
        }
    }

    var period: Period?
    var kind: ActivityKind?
    var source: Source?

    var isActive: Bool { period != nil || kind != nil || source != nil }

    /// Activities without a date or a readable type drop out once that criterion is set.
    func matches(_ activity: ActivityRecord, now: Date) -> Bool {
        if let source, activity.source != source { return false }
        if let kind, ActivityKind(activity.metrics) != kind { return false }
        if let period { guard let date = activity.date, period.contains(date, now: now) else { return false } }
        return true
    }

    var summary: String {
        let parts = [period?.title, kind?.title, source?.title].compactMap { $0 }
        return parts.isEmpty ? String(localized: "Kein Filter") : parts.formatted(.list(type: .and, width: .narrow))
    }
}

/// FIT `sport`/`sub_sport` values (Garmin FIT Global Profile); unknown values have no type.
enum ActivityKind: String, CaseIterable, Identifiable {
    case cycling, virtualCycling, indoorCycling, running, swimming, walking, hiking, rowing, fitnessEquipment, training
    var id: String { rawValue }

    init?(_ metrics: ActivityMetrics?) {
        switch (metrics?.sport, metrics?.subSport) {
        case (2, 6): self = .indoorCycling
        case (2, 58): self = .virtualCycling
        case (2, _): self = .cycling
        case (1, _): self = .running
        case (5, _): self = .swimming
        case (11, _): self = .walking
        case (17, _): self = .hiking
        case (15, _): self = .rowing
        case (4, _): self = .fitnessEquipment
        case (10, _): self = .training
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .indoorCycling: String(localized: "Indoor-Radfahren")
        case .virtualCycling: String(localized: "Virtuelles Radfahren")
        case .cycling: String(localized: "Radfahren")
        case .running: String(localized: "Laufen")
        case .swimming: String(localized: "Schwimmen")
        case .walking: String(localized: "Gehen")
        case .hiking: String(localized: "Wandern")
        case .rowing: String(localized: "Rudern")
        case .fitnessEquipment: String(localized: "Fitnessgerät")
        case .training: String(localized: "Training")
        }
    }
}

extension UTType {
    /// Declared in Info.plist; files from Garmin, Wahoo, Zwift and others use the `.fit` extension.
    static let fit = UTType(importedAs: "com.garmin.fit")
}
