import SwiftUI

@main
struct FITgapApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ActivitiesView(model: model)
                .task { model.start() }
                .onChange(of: phase) { _, value in model.phaseChanged(value) }
        }
    }
}
