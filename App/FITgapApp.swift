import SwiftUI
import UIKit

/// Portrait stays the rule for regular iPhones; wide displays such as an unfolded foldable may rotate.
final class OrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        let size = window?.screen.bounds.size ?? UIScreen.main.bounds.size
        return min(size.width, size.height) >= 600 ? .all : .portrait
    }
}

@main
struct FITgapApp: App {
    @UIApplicationDelegateAdaptor(OrientationDelegate.self) private var delegate
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
