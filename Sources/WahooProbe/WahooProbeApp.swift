import AppKit
import AuthenticationServices
import FITgapCore
import SwiftUI

@MainActor
final class WahooCheck: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var status = "Prüft Anmeldung, Aktivitätsliste und einen echten FIT-Download."
    @Published var workouts: [WahooWorkout] = []
    @Published var running = false
    private var session: ASWebAuthenticationSession?
    private var task: Task<Void, Never>?
    private var callback: CheckedContinuation<URL, Error>?

    var outputDirectory: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("validation/wahoo", isDirectory: true)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first!
    }

    func start() {
        guard !running else { return }
        running = true
        workouts = []
        task = Task {
            let client = WahooProbe()
            var stage = "Anmeldung"
            defer { client.close(); running = false; session = nil; task = nil }
            do {
                let oauth = try WahooOAuth()
                status = "Bitte im Systembrowser bei Wahoo anmelden und den Lesezugriff erlauben."
                let callback = try await login(oauth)
                try Task.checkCancellation()
                stage = "Tokenaustausch"
                status = "Wahoo-Anmeldung wird abgeschlossen …"
                let token = try await client.authenticate(oauth, callback: callback)
                stage = "Aktivitätsliste"
                status = "Anmeldung erfolgreich. Aktivitäten werden seitenweise gelesen …"
                workouts = try await client.activities(token: token)
                stage = "FIT-Download"
                status = "\(workouts.count) Aktivitäten gelesen. Erste verfügbare FIT wird geladen …"
                let receipt = try await client.downloadFirstFIT(from: workouts, token: token,
                                                               store: OriginalFITStore(directory: outputDirectory))
                status = "Kontotest erfolgreich. \(workouts.count) Aktivitäten, FIT mit \(receipt.byteCount) Bytes gespeichert.\nSHA-256: \(receipt.sha256)\nKein Geräte- oder HealthFit-Importtest."
            } catch is CancellationError {
                status = "Prüfung abgebrochen."
            } catch let error as WahooError {
                status = "\(stage): \(error.localizedDescription)"
            } catch let error as ProbeError {
                status = "\(stage): \(error.localizedDescription)"
            } catch let error as URLError {
                status = "\(stage): Netzwerkfehler (Code \(error.code.rawValue)). Keine erfolgreiche Kontovalidierung."
            } catch {
                status = "\(stage): Systemanmeldung oder lokales Speichern fehlgeschlagen. Keine erfolgreiche Kontovalidierung."
            }
        }
    }

    private func login(_ oauth: WahooOAuth) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            callback = continuation
            let auth = ASWebAuthenticationSession(url: oauth.authorizationURL, callbackURLScheme: WahooOAuth.redirect.scheme) { url, error in
                Task { @MainActor in
                    if let url { self.finishLogin(.success(url)) }
                    else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        self.finishLogin(.failure(WahooError.denied))
                    } else { self.finishLogin(.failure(WahooError.browser)) }
                }
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = true
            session = auth
            if !auth.start() { finishLogin(.failure(WahooError.browser)) }
        }
    }

    private func finishLogin(_ result: Result<URL, Error>) {
        let pending = callback
        callback = nil
        pending?.resume(with: result)
    }

    func cancel() {
        task?.cancel()
        session?.cancel()
        finishLogin(.failure(CancellationError()))
    }
}

@main
struct WahooProbeApp: App {
    @StateObject private var check = WahooCheck()

    var body: some Scene {
        Window("FITgap – Wahoo-Kontotest", id: "wahoo-probe") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Wahoo-Kontotest").font(.title2.bold())
                Text("Nur das eigene Konto verwenden. Anmeldung über Wahoo mit PKCE. Zugangsdaten und Tokens werden nicht gespeichert.")
                HStack {
                    Button("Mit Wahoo anmelden und prüfen") { check.start() }
                        .disabled(check.running)
                    if check.running {
                        ProgressView().controlSize(.small).accessibilityLabel("Prüfung läuft")
                        Button("Abbrechen") { check.cancel() }
                    }
                }
                Text(check.status).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Prüfstatus: \(check.status)")
                if !check.workouts.isEmpty {
                    List(check.workouts) { workout in
                        VStack(alignment: .leading) {
                            Text(workout.name ?? "Wahoo-Aktivität")
                            Text(workout.starts ?? "Datum unbekannt").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Abgerufene Wahoo-Aktivitäten")
                }
                Text("Dateien: \(check.outputDirectory.path)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(24).frame(minWidth: 560, idealWidth: 680, minHeight: 320, idealHeight: 500)
        }
    }
}
