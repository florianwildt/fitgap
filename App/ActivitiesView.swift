import FITgapCore
import SwiftUI
import UIKit

struct ActivitiesView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var accounts = false
    @State private var deleteCandidate: ActivityRecord?
    @State private var share: SharedFile?
    @State private var showError = false

    private var visible: [ActivityRecord] {
        model.activities.filter { search.isEmpty || $0.displayName.localizedStandardContains(search) || $0.source.title.localizedStandardContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                DemoSection(model: model)
                if model.busy {
                    Section {
                        HStack { ProgressView(); Text(model.progress).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                if model.activities.isEmpty {
                    Section {
                        ContentUnavailableView("Noch keine Aktivitäten", systemImage: "figure.outdoor.cycle",
                            description: Text("Verbinde unter „Konten“ Wahoo oder Zwift und wähle anschließend „Aktualisieren“."))
                    }
                } else if visible.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                Section {
                    ForEach(visible) { activity in
                        ActivityRow(activity: activity, connected: model.isDemo || model.connected.contains(activity.source), busy: model.busy || model.switchingMode,
                                    share: { prepareShare(activity) }, download: { model.download(activity) },
                                    delete: { deleteCandidate = activity })
                    }
                } footer: {
                    if model.isDemo {
                        Text("Demo-Dateien bleiben offline verfügbar. Aktualisieren liest nur den lokalen Demo-Bestand. Gelöschte Dateien lassen sich lokal wiederherstellen. Beim Teilen HealthFit wählen, sofern installiert. „Geteilt“ bestätigt nur die Dateiübergabe, keinen Import und keine Anbieteranbindung.")
                    } else { Text("FITs bleiben offline verfügbar. Aktualisieren startet beim App-Start oder durch Herunterziehen. Ein laufender Abruf nutzt die verfügbare iOS-Hintergrundzeit und wird nach einer Unterbrechung beim Öffnen fortgesetzt. Wähle beim Teilen HealthFit, sofern installiert. „Geteilt“ bestätigt keinen erfolgreichen Import.") }
                }
            }
            .refreshable { await model.refreshAndWait() }
            .navigationTitle("FITgap")
            .searchable(text: $search, prompt: "Aktivitäten suchen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Konten", systemImage: "person.crop.circle") { accounts = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.busy { Button("Abbrechen", role: .cancel) { model.cancel() } }
                    else {
                        Button("Aktualisieren", systemImage: "arrow.clockwise") { model.refresh() }
                            .disabled((!model.isDemo && model.connected.isEmpty) || !model.storageReady || model.switchingMode)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { DemoIndicator(enabled: model.isDemo) }
            .onChange(of: model.libraryGeneration) { _, _ in search = ""; deleteCandidate = nil; share = nil }
            .sheet(isPresented: $accounts) { AccountsView(model: model) }
            .sheet(item: $share) { item in
                ShareSheet(url: item.url) { completed in if completed { model.markShared(item.record, generation: item.generation) } }
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
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(activity.source.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if activity.sharedAt != nil {
                    Image(systemName: "checkmark.circle")
                        .font(.title3).foregroundStyle(.tint)
                        .accessibilityLabel("Geteilt")
                        .accessibilityIdentifier("shared-status-\(activity.source.rawValue)-\(activity.remoteID)")
                }
            }
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
                Text("Zuletzt geteilt: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Spacer(minLength: 8)
                if activity.receipt != nil || activity.status == .failed {
                    Menu {
                        Button("Datei löschen", systemImage: "trash", role: .destructive, action: delete)
                    } label: {
                        Label("Dateioptionen", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Dateioptionen für \(activityName)")
                    .accessibilityIdentifier("file-options-\(activity.source.rawValue)-\(activity.remoteID)")
                    .disabled(busy)
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

    private var distance: String {
        guard let meters = activity.metrics?.distanceMeters else { return "— km" }
        return (meters / 1000).formatted(.number.precision(.fractionLength(2))) + " km"
    }
    private var ascent: String {
        guard let meters = activity.metrics?.ascentMeters else { return "— m" }
        return meters.formatted(.number.precision(.fractionLength(0))) + " m"
    }
    private var averageSpeed: String {
        guard let speed = activity.metrics?.averageSpeedMetersPerSecond else { return "— km/h" }
        return (speed * 3.6).formatted(.number.precision(.fractionLength(2))) + " km/h"
    }
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
