import FITgapCore
import SwiftUI

struct DemoSection: View {
    @ObservedObject var model: AppModel
    var identifierPrefix = ""
    @State private var reset = false

    var body: some View {
        if model.isDemo || model.canTryDemo {
            Section {
                if model.isDemo {
                    Label("Demo – Beispieldaten", systemImage: "play.circle")
                        .font(.headline)
                    Text("Synthetische Aktivitäten ohne Anbieteranmeldung. Echte Konten und Daten bleiben getrennt; Anbieterzugriffe sind pausiert.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Demo zurücksetzen") { reset = true }
                        .accessibilityIdentifier(identifierPrefix + "reset-demo")
                        .disabled(model.switchingMode || model.busy)
                    Button("Demo beenden") { Task { await model.setDemo(false) } }
                        .accessibilityIdentifier(identifierPrefix + "end-demo")
                        .disabled(model.switchingMode)
                    if let notice = model.demoNotice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("demo-notice")
                    }
                } else {
                    Button("Demo ausprobieren", systemImage: "play.circle") { Task { await model.setDemo(true) } }
                        .accessibilityIdentifier(identifierPrefix + "try-demo")
                        .disabled(model.switchingMode)
                    Text("Kernfunktionen mit synthetischen Aktivitäten und lokalen FIT-Dateien ausprobieren. Kein Konto bei Wahoo, Zwift oder MyWhoosh erforderlich.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.switchingMode {
                    HStack { ProgressView(); Text("Modus wird gewechselt …") }
                }
            }
            .confirmationDialog("Demo zurücksetzen?", isPresented: $reset, titleVisibility: .visible) {
                Button("Demo zurücksetzen", role: .destructive) { model.resetDemo() }
                Button("Abbrechen", role: .cancel) { }
            } message: {
                Text("Nur Demo-Dateien, Demo-Kennzahlen, Demo-Markierungen und in Apple Health gesicherte Demo-Trainings werden zurückgesetzt. Echte Daten bleiben erhalten.")
            }
        }
    }
}

struct DemoIndicator: View {
    let enabled: Bool
    var body: some View {
        if enabled {
            Label("Demo – Beispieldaten", systemImage: "play.circle.fill")
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 8)
                .background(.bar)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Demo – Beispieldaten")
                .accessibilityIdentifier("demo-indicator")
        }
    }
}

extension ActivityRecord {
    var displayName: String {
        if source == .demo {
            switch remoteID {
            case "recovery": return String(localized: "Demo: Lockere Morgenfahrt")
            case "endurance": return String(localized: "Demo: Ausdauertraining")
            default: return String(localized: "Demo: Tempofahrt")
            }
        }
        guard name.isEmpty else { return name }
        return source == .wahoo ? String(localized: "Wahoo-Aktivität") : String(localized: "Aktivität ohne Namen")
    }
}
