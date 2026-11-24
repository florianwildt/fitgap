import HealthKit
import Photos
import SwiftUI

/// Access to Apple Health and Photos in one place: ask for what is still open, or go to Settings for decided access.
struct AccessSection: View {
    let healthAvailable: Bool
    @State private var healthOpen = false
    @State private var healthRequest = false
    @State private var photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        Section {
            if healthAvailable {
                if healthOpen {
                    Button("Apple-Health-Daten freigeben", systemImage: "heart.text.square") { healthRequest.toggle() }
                        .accessibilityIdentifier("access-health-request")
                } else {
                    LabeledContent { Text("Beantwortet") } label: { Label("Apple Health", systemImage: "heart.text.square") }
                        .accessibilityIdentifier("access-health-status")
                }
            }
            if photos == .notDetermined {
                Button("Fotos freigeben", systemImage: "photo.on.rectangle") {
                    Task { photos = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                }
                .accessibilityIdentifier("access-photos-request")
            } else {
                LabeledContent { Text(photoStatus) } label: { Label("Fotos", systemImage: "photo.on.rectangle") }
                    .accessibilityIdentifier("access-photos-status")
            }
            Button("In den Einstellungen ändern", systemImage: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .accessibilityIdentifier("access-settings")
        } header: {
            Text("Freigaben")
        } footer: {
            Text(healthAvailable
                 ? "iOS fragt jeden Wert nur einmal ab und zeigt FITgap nicht, ob Lesen erlaubt ist. Bereits beantwortete Health-Werte änderst du in den Einstellungen unter Apps › Health › Datenzugriff & Geräte › FITgap; Fotos unter Apps › FITgap."
                 : "Den Fotozugriff änderst du in den Einstellungen unter Apps › FITgap.")
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .healthDataAccessRequest(store: HealthAccess.store, shareTypes: HealthAccess.shareTypes, readTypes: HealthAccess.readTypes,
                                 trigger: healthRequest) { _ in
            Task { @MainActor in
                await refresh()
                NotificationCenter.default.post(name: HealthWorkoutsModel.accessChanged, object: nil)
            }
        }
    }

    private var photoStatus: String {
        switch photos {
        case .authorized: String(localized: "Alle Fotos")
        case .limited: String(localized: "Ausgewählte Fotos")
        case .denied, .restricted: String(localized: "Kein Zugriff")
        default: String(localized: "Nicht gefragt")
        }
    }

    private func refresh() async {
        photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if healthAvailable { healthOpen = await HealthAccess.needsRequest() }
    }
}
