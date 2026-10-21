import FITgapCore
import SwiftUI
import UIKit

/// iOS 26 shows the search field as a toolbar icon that expands on tap.
private struct MinimizedSearch: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.searchToolbarBehavior(.minimize) } else { content }
    }
}

struct ActivitiesView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var accounts = false
    @State private var deleteCandidate: ActivityRecord?
    @State private var share: SharedFile?
    @State private var showError = false
    @State private var limit = Self.pageSize
    @State private var visibleRows: Set<Int> = []

    private static let pageSize = 10

    private var matches: [ActivityRecord] {
        model.activities.filter { search.isEmpty || $0.displayName.localizedStandardContains(search) || $0.source.title.localizedStandardContains(search) }
    }

    private static let jumpThreshold = 6

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                DemoSection(model: model)
                if model.activities.isEmpty {
                    Section {
                        ContentUnavailableView("Noch keine Aktivitäten", systemImage: "figure.outdoor.cycle",
                            description: Text("Verbinde unter „Konten“ Wahoo oder Zwift und ziehe die Liste nach unten."))
                    }
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                let all = matches
                let visible = Array(all.prefix(limit))
                Section {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, activity in
                        // Row buttons stay borderless and keep their own taps; the rest of the row opens the details.
                        NavigationLink {
                            ActivityDetailView(model: model, initial: activity)
                        } label: {
                            ActivityRow(activity: activity, connected: model.isDemo || model.connected.contains(activity.source), busy: model.busy || model.switchingMode,
                                        share: { prepareShare(activity) }, download: { model.download(activity) })
                        }
                        .accessibilityIdentifier("activity-\(activity.source.rawValue)-\(activity.remoteID)")
                        .onAppear {
                            visibleRows.insert(index)
                            if activity.id == visible.last?.id, visible.count < all.count { limit += Self.pageSize }
                        }
                        .onDisappear { visibleRows.remove(index) }
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
                if (visibleRows.max() ?? 0) >= Self.jumpThreshold, let first = matches.first {
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
            .animation(.default, value: (visibleRows.max() ?? 0) >= Self.jumpThreshold)
            .refreshable { await model.refreshAndWait() }
            .animation(.default, value: model.busy)
            .navigationTitle("FITgap")
            .searchable(text: $search, prompt: "Aktivitäten suchen")
            .modifier(MinimizedSearch())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Konten", systemImage: "person.crop.circle") { accounts = true }
                }
                if #available(iOS 26, *) { DefaultToolbarItem(kind: .search, placement: .topBarTrailing) }
            }
            .safeAreaInset(edge: .bottom) { DemoIndicator(enabled: model.isDemo) }
            .overlay(alignment: .bottom) {
                if model.busy {
                    HStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text(model.progress).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Abbrechen", role: .cancel) { model.cancel() }
                            .buttonStyle(.bordered).tint(.white)
                    }
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                    .padding(.bottom, 8).padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: search) { _, _ in limit = Self.pageSize; visibleRows = [] }
            .onChange(of: model.libraryGeneration) { _, _ in search = ""; limit = Self.pageSize; deleteCandidate = nil; share = nil }
            .sheet(isPresented: $accounts) { AccountsView(model: model) }
            .sheet(item: $share) { item in
                ShareSheet(url: item.url) { completed in if completed { model.markShared(item.record, generation: item.generation) } }
            }
            }
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
    }

    private func prepareShare(_ activity: ActivityRecord) {
        do { share = SharedFile(record: activity, url: try model.fileForSharing(activity), generation: model.libraryGeneration) }
        catch { model.errorMessage = AppModel.message(error) }
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

    private var activityName: String {
        activity.displayName
    }

    private var duration: String {
        guard let seconds = activity.duration, seconds.isFinite, seconds >= 0 else { return String(localized: "unbekannt") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? String(localized: "unbekannt")
    }

    private var distance: String { ActivityFormat.distance(activity.metrics?.distanceMeters) ?? "— km" }
    private var ascent: String { activity.metrics?.ascentMeters.map(ActivityFormat.meters) ?? "— m" }
    private var averageSpeed: String { ActivityFormat.speed(activity.metrics?.averageSpeedMetersPerSecond) ?? "— km/h" }
}

private struct SharedFile: Identifiable {
    let id = UUID()
    let record: ActivityRecord
    let url: URL
    let generation: UUID
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in completion(completed) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
