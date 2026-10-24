import SwiftUI

/// While an Apple Health export runs, a status item in the bottom toolbar shows its progress without covering the app.
/// Tapping it opens the counts with the option to cancel; that sheet can be closed while the export continues
/// and stays open after the end. A finished result keeps its status item until it was opened.
struct HealthExportStatus: ViewModifier {
    @ObservedObject var model: AppModel
    /// False where the sync progress already shows the running export; the result still appears afterwards.
    var showsProgress = true
    /// Lets the sync progress open the same details; without it the modifier keeps its own state.
    var details: Binding<Bool>?
    @State private var ownDetails = false
    private var shown: Binding<Bool> { details ?? $ownDetails }

    func body(content: Content) -> some View {
        content
            .toolbar {
                // Shown while the export runs and afterwards until its result was opened.
                if let summary = model.healthSummary, summary.finished ? !model.healthSummarySeen : showsProgress {
                    ToolbarItem(placement: .status) {
                        Button { shown.wrappedValue = true } label: {
                            HStack(spacing: 8) {
                                if summary.finished {
                                    Image(systemName: summary.failed > 0 ? "exclamationmark.circle" : "checkmark.circle")
                                        .accessibilityHidden(true)
                                } else {
                                    ProgressView()
                                }
                                Text(summary.finished ? String(localized: "Health: \(summary.saved) gesichert · \(summary.skipped) übersprungen")
                                                      : String(localized: "Apple Health: \(summary.done) von \(summary.total)"))
                                    .font(.footnote).monospacedDigit()
                            }
                        }
                        .accessibilityIdentifier("health-export-status")
                    }
                }
            }
            .sheet(isPresented: shown, onDismiss: model.acknowledgeHealthSummary) {
                HealthExportProgressView(model: model)
            }
    }
}

/// Counts of the running or finished Apple Health export; it stays open after the end so the result can be read.
struct HealthExportProgressView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let summary = model.healthSummary {
                    Section {
                        ProgressView(value: Double(summary.done), total: Double(max(summary.total, 1))) {
                            Text("\(summary.done) von \(summary.total)")
                        }
                        .accessibilityIdentifier("health-export-progress")
                        if summary.finished {
                            Label(summary.done < summary.total ? String(localized: "Export abgebrochen") : String(localized: "Export abgeschlossen"),
                                  systemImage: summary.failed > 0 || summary.done < summary.total ? "exclamationmark.circle" : "checkmark.circle")
                                .accessibilityIdentifier("health-export-finished")
                        }
                    }
                    Section {
                        LabeledContent("Gesichert", value: summary.saved.formatted())
                        LabeledContent("Als Dublette übersprungen", value: summary.skipped.formatted())
                        if summary.failed > 0 { LabeledContent("Fehlgeschlagen", value: summary.failed.formatted()) }
                    } footer: {
                        if !summary.finished {
                            Text("Der Export läuft weiter, wenn du dieses Fenster schließt. Ein unterbrochener Export wird beim nächsten Öffnen fortgesetzt.")
                        }
                    }
                    if !summary.finished, !model.healthInProgress.isEmpty {
                        Section("Wird gerade gesichert") {
                            ForEach(Array(model.healthInProgress.enumerated()), id: \.offset) { _, name in
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text(name).lineLimit(2)
                                }
                            }
                        }
                    }
                    if summary.finished, let error = model.errorMessage {
                        Section("Hinweis") { Text(error) }
                    }
                    if !summary.finished {
                        Section {
                            Button("Export abbrechen", systemImage: "stop.circle", role: .destructive) { model.cancel() }
                                .accessibilityIdentifier("health-export-cancel")
                        }
                    }
                }
            }
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
