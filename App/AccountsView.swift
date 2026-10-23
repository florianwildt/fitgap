import FITgapCore
import SwiftUI

struct AccountsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var zwiftLogin = false
    @State private var disconnectCandidate: Source?

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
                if model.busy { Section { HStack { ProgressView(); Text(model.progress) }; Button("Abbrechen") { model.cancel() } } }
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
            .confirmationDialog("\(disconnectCandidate?.title ?? String(localized: "Konto")) trennen?",
                                isPresented: Binding(get: { disconnectCandidate != nil }, set: { if !$0 { disconnectCandidate = nil } }),
                                titleVisibility: .visible) {
                Button("Trennen", role: .destructive) {
                    if let source = disconnectCandidate { model.disconnect(source) }
                    disconnectCandidate = nil
                }
                Button("Abbrechen", role: .cancel) { disconnectCandidate = nil }
            } message: { Text("Die lokale Sitzung wird entfernt. Deine FIT-Dateien bleiben verfügbar.") }
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
