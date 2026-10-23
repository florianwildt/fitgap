import FITgapCore
import SwiftUI

struct AccountsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var zwiftLogin = false
    @State private var disconnectCandidate: Source?
    @State private var confirmHealthExport = false

    var body: some View {
        NavigationStack {
            Form {
                DemoSection(model: model, identifierPrefix: "accounts-")
                ForEach(Source.providers) { source in
                    Section(source.title) {
                        Label(model.isDemo ? String(localized: "Im Demo-Modus pausiert") : (model.connected.contains(source) ? String(localized: "Verbunden") : String(localized: "Nicht verbunden")),
                              systemImage: model.isDemo ? "pause.circle" : (model.connected.contains(source) ? "checkmark.circle" : "person.crop.circle"))
                        Button(model.connected.contains(source) ? String(localized: "Erneut verbinden") : String(localized: "Verbinden")) {
                            if source == .zwift { zwiftLogin = true } else { model.connectWahoo() }
                        }
                        .accessibilityIdentifier("connect-\(source.rawValue)")
                        .disabled(model.busy || !model.storageReady || model.isDemo || model.switchingMode)
                        if model.connected.contains(source) {
                            Button("Trennen", role: .destructive) { disconnectCandidate = source }.disabled(model.busy || model.isDemo || model.switchingMode)
                        }
                        if source == .zwift {
                            Text("Inoffizielle Schnittstelle. Änderungen bei Zwift können die Verbindung unterbrechen.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Anmeldung über Wahoo mit lesendem Zugriff.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.healthAvailable {
                    Section {
                        Toggle("Neue Aktivitäten automatisch sichern",
                               isOn: Binding(get: { model.healthAutoExportSince != nil }, set: { model.setHealthAutoExport($0) }))
                            .disabled(model.busy || model.isDemo || model.switchingMode || !model.storageReady)
                            .accessibilityIdentifier("health-auto-export")
                        let pending = model.healthPending.count
                        Button("Alle vergangenen Aktivitäten sichern", systemImage: "heart.text.square") { confirmHealthExport = true }
                            .badge(pending)
                            .disabled(pending == 0 || model.busy || model.isDemo || model.switchingMode || !model.storageReady)
                            .accessibilityIdentifier("health-export-all")
                        if let summary = model.healthSummary, summary.finished {
                            LabeledContent("Letzter Export", value: String(localized: "\(summary.done) von \(summary.total)"))
                            Text(summary.counts).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("health-export-summary")
                        }
                    } header: {
                        Text("Apple Health")
                    } footer: {
                        Text("FITgap schreibt Trainings nach Apple Health und liest dort nur Trainings, um Duplikate zu erkennen. Überschneidet sich ein vorhandenes Training (z. B. von Apple Watch, HealthFit oder der Anbieter-App) zeitlich mit einer Aktivität, wird sie übersprungen. Automatisch gesichert werden beim App-Start und nach jedem Abgleich alle Aktivitäten, die nach dem Einschalten beginnen oder geladen werden; ältere sicherst du über „Alle vergangenen Aktivitäten sichern“, in den Details oder per Auswahl.")
                    }
                }
                if model.busy && !model.healthExporting { Section { HStack { ProgressView(); Text(model.progress) }; Button("Abbrechen") { model.cancel() } } }
                if let error = model.errorMessage {
                    Section("Hinweis") { Text(error); Button("OK") { model.errorMessage = nil } }
                }
                Section {
                    Text("Tokens bleiben im Schlüsselbund dieses iPhones. Trennen entfernt nur die lokale Sitzung; die Freigabe beim Anbieter bleibt bestehen. Gespeicherte FITs bleiben erhalten und können einzeln gelöscht werden.")
                }
                Section("Datenschutz") {
                    Link(destination: URL(string: String(localized: "https://florianwildt.github.io/fitgap/privacy/"))!) {
                        Text("Datenschutzerklärung")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .tint(.blue)
                    .accessibilityIdentifier("privacy-policy")
                }
            }
            .safeAreaInset(edge: .bottom) { DemoIndicator(enabled: model.isDemo) }
            .navigationTitle("Konten")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(isPresented: $zwiftLogin) { ZwiftLoginView(model: model) }
            .modifier(HealthExportStatus(model: model))
            .confirmationDialog("\(disconnectCandidate?.title ?? String(localized: "Konto")) trennen?",
                                isPresented: Binding(get: { disconnectCandidate != nil }, set: { if !$0 { disconnectCandidate = nil } }),
                                titleVisibility: .visible) {
                Button("Trennen", role: .destructive) {
                    if let source = disconnectCandidate { model.disconnect(source) }
                    disconnectCandidate = nil
                }
                Button("Abbrechen", role: .cancel) { disconnectCandidate = nil }
            } message: { Text("Die lokale Sitzung wird entfernt. Deine FIT-Dateien bleiben verfügbar.") }
            .alert("\(model.healthPending.count) Aktivitäten in Apple Health sichern?", isPresented: $confirmHealthExport) {
                Button("Abbrechen", role: .cancel) {}
                Button("Sichern") { model.exportAllToHealth() }
            } message: {
                Text("Aktivitäten, für die Health bereits ein Training enthält, werden übersprungen. Ein unterbrochener Export wird beim nächsten Öffnen fortgesetzt.")
            }
        }
    }
}

private struct ZwiftLoginView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("E-Mail", text: $email)
                        .keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Passwort", text: $password).textContentType(.password)
                    Button("Zwift verbinden") {
                        model.connectZwift(username: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                        email = ""; password = ""; dismiss()
                    }
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || model.busy || model.isDemo || model.switchingMode)
                } footer: {
                    Text("Nur das eigene Konto verwenden. Das Passwort wird ausschließlich für die Anmeldung verarbeitet und nicht gespeichert.")
                }
            }
            .navigationTitle("Zwift verbinden")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { email = ""; password = ""; dismiss() } } }
        }
    }
}
