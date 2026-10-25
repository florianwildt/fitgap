import FITgapCore
import SwiftUI

struct AccountsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmHealthExport = false
    @State private var healthDetails = false

    var body: some View {
        NavigationStack {
            Form {
                DemoSection(model: model, identifierPrefix: "accounts-")
                Section {
                    ForEach(model.providers) { source in
                        NavigationLink {
                            SourceAccountView(model: model, source: source)
                        } label: {
                            LabeledContent(source.title, value: model.connectionStatus(source))
                        }
                        .accessibilityIdentifier("source-\(source.rawValue)")
                    }
                } header: {
                    Text("Datenquellen")
                } footer: {
                    Text("Tokens bleiben im Schlüsselbund dieses iPhones. Trennen entfernt die lokale Sitzung; die Freigabe beim Anbieter bleibt bestehen, nur bei Hammerhead und Dropbox wird sie widerrufen. Gespeicherte FITs bleiben erhalten und können einzeln gelöscht werden.")
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
                            .disabled(pending == 0 || model.busy || model.switchingMode || !model.storageReady)
                            .accessibilityIdentifier("health-export-all")
                        if let summary = model.healthSummary, summary.finished {
                            LabeledContent("Letzter Export", value: String(localized: "\(summary.done) von \(summary.total)"))
                            Text(summary.counts).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("health-export-summary")
                        }
                    } header: {
                        Text("Apple Health")
                    } footer: {
                        if model.isDemo {
                            Text("Demo: Die Beispielfahrten werden als synthetische Trainings in Apple Health gesichert und beim Zurücksetzen oder Beenden der Demo dort wieder entfernt. Automatisches Sichern ist in der Demo pausiert.")
                        } else {
                            Text("FITgap schreibt Trainings nach Apple Health und liest dort nur Trainings, um Duplikate zu erkennen. Überschneidet sich ein vorhandenes Training (z. B. von Apple Watch, HealthFit oder der Anbieter-App) zeitlich mit einer Aktivität, wird sie übersprungen. Automatisch gesichert werden beim App-Start und nach jedem Abgleich alle Aktivitäten, die nach dem Einschalten beginnen oder geladen werden; ältere sicherst du über „Alle vergangenen Aktivitäten sichern“, in den Details oder per Auswahl.")
                        }
                    }
                }
                // One progress for the whole run: provider import, then the Apple Health export.
                if model.busy {
                    Section {
                        // During the Apple Health export the progress opens its details.
                        if model.healthExporting {
                            Button { healthDetails = true } label: {
                                HStack { ProgressView(); Text(model.progress); Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            }
                            .tint(.primary)
                            .accessibilityIdentifier("accounts-sync-progress")
                        } else {
                            HStack { ProgressView(); Text(model.progress) }
                        }
                        Button("Abbrechen") { model.cancel() }
                    }
                }
                if let error = model.errorMessage {
                    Section("Hinweis") { Text(error); Button("OK") { model.errorMessage = nil } }
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
            .modifier(HealthExportStatus(model: model, showsProgress: false, details: $healthDetails))
            .alert("\(model.healthPending.count) Aktivitäten in Apple Health sichern?", isPresented: $confirmHealthExport) {
                Button("Abbrechen", role: .cancel) {}
                Button("Sichern") { model.exportAllToHealth() }
            } message: {
                Text("Aktivitäten, für die Health bereits ein Training enthält, werden übersprungen. Ein unterbrochener Export wird beim nächsten Öffnen fortgesetzt.")
            }
        }
    }
}

/// Connection details of one data source, so the accounts list keeps a single row per provider.
private struct SourceAccountView: View {
    @ObservedObject var model: AppModel
    let source: Source
    @State private var passwordLogin = false
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            Section {
                Label(model.connectionStatus(source),
                      systemImage: model.isDemo ? "pause.circle" : (model.connected.contains(source) ? "checkmark.circle" : "person.crop.circle"))
                Button(model.connected.contains(source) ? String(localized: "Erneut verbinden") : String(localized: "Verbinden")) {
                    switch source {
                    case .wahoo: model.connectWahoo()
                    case .hammerhead: model.connectHammerhead()
                    case .dropbox: model.connectDropbox()
                    default: passwordLogin = true
                    }
                }
                .accessibilityIdentifier("connect-\(source.rawValue)")
                .disabled(model.busy || !model.storageReady || model.isDemo || model.switchingMode)
                if model.connected.contains(source) {
                    Button("Trennen", role: .destructive) { confirmDisconnect = true }
                        .disabled(model.busy || model.isDemo || model.switchingMode)
                }
            } footer: {
                switch source {
                case .zwift: Text("Inoffizielle Schnittstelle. Änderungen bei Zwift können die Verbindung unterbrechen.")
                case .mywhoosh: Text("Inoffizielle Schnittstelle. Änderungen bei MyWhoosh können die Verbindung unterbrechen. Läuft die Sitzung ab, ist eine neue Anmeldung nötig.")
                case .hammerhead: Text("Anmeldung über Hammerhead mit lesendem Zugriff auf Aktivitäten. Trennen widerruft auch die Freigabe bei Hammerhead.")
                case .dropbox: Text("Anmeldung über Dropbox mit nur lesendem Zugriff. FITgap lädt FIT-Dateien aus dem Ordner „Apps“, in den Dienste wie Zwift, Wahoo, Karoo oder TrainerRoad exportieren. Trennen widerruft auch die Freigabe bei Dropbox.")
                default: Text("Anmeldung über Wahoo mit lesendem Zugriff.")
                }
            }
            if model.busy { Section { HStack { ProgressView(); Text(model.progress) }; Button("Abbrechen") { model.cancel() } } }
            if let error = model.errorMessage {
                Section("Hinweis") { Text(error); Button("OK") { model.errorMessage = nil } }
            }
        }
        .navigationTitle(source.title)
        .sheet(isPresented: $passwordLogin) { PasswordLoginView(model: model, source: source) }
        .confirmationDialog("\(source.title) trennen?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Trennen", role: .destructive) { model.disconnect(source) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            if source == .hammerhead {
                Text("Die lokale Sitzung wird entfernt und die Freigabe bei Hammerhead widerrufen. Deine FIT-Dateien bleiben verfügbar.")
            } else if source == .dropbox {
                Text("Die lokale Sitzung wird entfernt und die Freigabe bei Dropbox widerrufen. Deine Dateien in Dropbox und in FITgap bleiben erhalten.")
            } else {
                Text("Die lokale Sitzung wird entfernt. Deine FIT-Dateien bleiben verfügbar.")
            }
        }
    }
}

/// Sign-in for the unofficial interfaces of Zwift and MyWhoosh.
private struct PasswordLoginView: View {
    @ObservedObject var model: AppModel
    let source: Source
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
                    Button("\(source.title) verbinden") {
                        let username = email.trimmingCharacters(in: .whitespacesAndNewlines)
                        if source == .mywhoosh { model.connectMyWhoosh(username: username, password: password) }
                        else { model.connectZwift(username: username, password: password) }
                        email = ""; password = ""; dismiss()
                    }
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || model.busy || model.isDemo || model.switchingMode)
                } footer: {
                    Text("Nur das eigene Konto verwenden. Das Passwort wird ausschließlich für die Anmeldung verarbeitet und nicht gespeichert.")
                }
            }
            .navigationTitle("\(source.title) verbinden")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { email = ""; password = ""; dismiss() } } }
        }
    }
}
